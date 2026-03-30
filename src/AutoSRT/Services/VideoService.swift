import AVFoundation
import AppKit
import AutoSRT
import Foundation
import ffmpegkit

public enum VideoQuality: String, CaseIterable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var presetName: String {
        switch self {
        case .high:
            return "-preset slow"  // Most compatible on macOS
        case .medium:
            return "-preset medium"  // Balanced quality
        case .low:
            return "-preset fast"  // Lower quality, smaller file size
        }
    }

    var encoderOption: String {
        switch self {
        case .high:
            return "-crf 14"  // High quality
        case .medium:
            return "-crf 23"  // Balanced quality
        case .low:
            return "-crf 28"  // Lower quality, smaller file size
        }
    }
}

public enum VideoError: Error {
    case invalidAsset
    case compositionFailed(String)
    case exportFailed(String)
    case invalidVideo
    case invalidSubtitle
}

public class VideoService {
    public static let shared = VideoService()
    private let logger = LoggerService.shared

    private init() {}

    private func calculateMargins(for text: String, fontSize: CGFloat, videoWidth: CGFloat) -> (
        left: Int, right: Int
    ) {
        let textWidth = text.size(fontSize: fontSize).width
        let margin = max(0, (videoWidth - textWidth) / 2)
        return (Int(margin), Int(margin))
    }

    private func getVideoResolution(url: URL) async throws -> CGSize {
        let asset = AVAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.invalidVideo
        }
        let size = try await track.load(.naturalSize)
        return size
    }

    public func renderSubtitledVideo(
        videoURL: URL,
        subtitlesURL: URL,
        outputURL: URL,
        quality: VideoQuality = .high,
        fontSize: CGFloat = 20,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> URL {
        logger.log("Starting video rendering with subtitles")

        // Prepare input and output files
        let inputPath = videoURL.path
        let outputPath = outputURL.path

        // Create a temporary directory for the subtitle file
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoSRT", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)

        // Get video duration for progress calculation
        let asset = AVAsset(url: videoURL)
        let totalDuration = CMTimeGetSeconds(asset.duration)
        // Get NotoSansSC-Regular.ttf in Resources
        let defaultFontFile = Bundle.main.path(forResource: "NotoSansSC-Regular", ofType: "ttf")!

        // Escape the path properly for shell command
        let escapedSrtPath = "'\(subtitlesURL.path.replacingOccurrences(of: "'", with: "\\'"))'"
        let escapedInputPath = inputPath
        let escapedOutputPath = outputPath

        var command = ""
        // get command for srt format subtitlesURL
        if subtitlesURL.pathExtension == "srt" {
            // Create FFmpeg command for rendering

            // Get font path
            let primaryColor = Settings.shared.videoService.primaryColor
            let secondaryColor = Settings.shared.videoService.secondaryColor
            let outlineColor = Settings.shared.videoService.outlineColor
            let backColor = Settings.shared.videoService.backColor
            let defaultFontName = Settings.shared.videoService.fontName
            let defaultFontPath = Settings.shared.videoService.fontPath
            var fontConfig = "Fontname=\(defaultFontName),Fontfile=\(defaultFontFile)"

            var forceStyle = [
                "Fontsize=\(Int(fontSize))",
                "PrimaryColour=\(primaryColor)",
                "BorderStyle=\(Settings.shared.videoService.borderStyle.rawValue)",
                "Outline=\(Settings.shared.videoService.outlineWidth)",
                "Shadow=\(Settings.shared.videoService.shadowDepth)",
                "MarginL=\(Settings.shared.videoService.marginHorizontal)",
                "MarginR=\(Settings.shared.videoService.marginHorizontal)",
                "ScaleX=\(Settings.shared.videoService.textScale)",
            ]
            if backColor != Settings.VideoService.noneColor {
                forceStyle.append("BackColour=\(backColor)")
            }
            if secondaryColor != Settings.VideoService.noneColor {
                forceStyle.append("SecondaryColour=\(secondaryColor)")
            }
            if outlineColor != Settings.VideoService.noneColor {
                forceStyle.append("OutlineColour=\(outlineColor)")
            }
            let forceStyleString = forceStyle.joined(separator: ",")

            command = """
                    -y \
                    -i "\(escapedInputPath)" \
                    -sub_charenc UTF-8 \
                    -filter_complex "[0:v]subtitles='\(escapedSrtPath)':force_style='\(fontConfig),\(forceStyleString)'" \
                    \(quality.presetName) \
                    \(quality.encoderOption) \
                    -c:v libx264 \
                    -c:a copy \
                    -progress pipe:1 \
                    "\(escapedOutputPath)"
                """
        } else if subtitlesURL.pathExtension == "ass" {
            // Create FFmpeg command for rendering
            command = """
                    -y \
                    -i "\(escapedInputPath)" \
                    -vf "subtitles=\(escapedSrtPath):force_style='Fontfile=\(defaultFontFile)'" \
                    \(quality.presetName) \
                    -c:v libx264 \
                    -c:a copy \
                    "\(escapedOutputPath)"
                """
        } else {
            throw VideoError.invalidSubtitle
        }

        logger.log("Executing FFmpeg command: \(command)")
        return try await withCheckedThrowingContinuation { continuation in
            FFmpegKit.executeAsync(
                command,
                withCompleteCallback: { session in
                    guard let returnCode = session?.getReturnCode() else {
                        continuation.resume(
                            throwing: VideoError.exportFailed("FFmpeg session failed"))
                        return
                    }

                    if ReturnCode.isSuccess(returnCode) {
                        // Log detailed session information
                        let sessionLogs = session?.getAllLogsAsString() ?? "No logs available"
                        let sessionOutput = session?.getOutput() ?? "No output available"
                        let sessionError = session?.getFailStackTrace() ?? "No error trace"

                        self.logger.log("FFmpeg Session Logs: \(sessionLogs)", level: .debug)
                        self.logger.log("FFmpeg Session Output: \(sessionOutput)", level: .debug)

                        // Check if file exists and is valid
                        let fileManager = FileManager.default
                        let fileExists = fileManager.fileExists(atPath: outputPath)
                        let fileSize =
                            (try? fileManager.attributesOfItem(atPath: outputPath)[.size] as? Int64)
                            ?? 0

                        self.logger.log("Output File Exists: \(fileExists)", level: .debug)
                        self.logger.log("Output File Size: \(fileSize) bytes", level: .debug)

                        // More comprehensive success checking
                        if fileExists && fileSize > 0 {
                            continuation.resume(returning: outputURL)
                        } else {
                            let errorMessage =
                                "FFmpeg failed. Return Code: \(returnCode)\nError Trace: \(sessionError)"
                            self.logger.log(errorMessage, level: .error)
                            continuation.resume(throwing: VideoError.exportFailed(errorMessage))
                        }
                    } else {
                        let errorMessage = "FFmpeg failed. Return Code: \(returnCode)"
                        self.logger.log(errorMessage, level: .error)
                        continuation.resume(throwing: VideoError.exportFailed(errorMessage))
                    }
                },
                withLogCallback: { log in
                    if let message = log?.getMessage() {
                        self.logger.log("ffmpeg output: \(message)", level: .debug)
                    }
                },
                withStatisticsCallback: { statistics in
                    guard let time = statistics?.getTime() else { return }
                    let progress = Double(time) / (totalDuration * 1000)
                    progressHandler?(min(max(progress, 0), 1))
                })
        }
    }
}
