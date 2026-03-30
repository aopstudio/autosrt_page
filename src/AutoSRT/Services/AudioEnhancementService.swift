import AVFoundation
import Foundation
import ffmpegkit

public class AudioEnhancementService {
    public static let shared = AudioEnhancementService()
    private let logger = LoggerService.shared

    private init() {}

    public enum AudioEnhancementError: Error {
        case processingFailed(String)
        case invalidInput
    }

    /// Enhances the audio by reducing noise and enhancing human voice
    /// - Parameters:
    ///   - inputURL: URL of the input audio/video file
    ///   - outputURL: URL where the enhanced audio/video will be saved
    ///   - progressHandler: Optional closure to handle progress updates
    /// - Returns: URL of the processed file
    public func enhanceAudio(
        inputURL: URL,
        outputURL: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> URL {
        logger.log("Starting audio enhancement process")

        let inputPath = inputURL.path
        let outputPath = outputURL.path

        // get input path duration
        let asset = AVAsset(url: inputURL)
        let inputDuration = CMTimeGetSeconds(asset.duration)

        // FFmpeg command for audio enhancement:
        // 1. highpass filter to remove low frequency noise (below 100Hz)
        // 2. lowpass filter to remove high frequency noise (above 8000Hz)
        // 3. anlmdn (Noise reduction using Non-Local Means algorithm)
        // 4. compand for dynamic range compression to enhance voice
        // 5. volume normalization
        let audioFilters = [
            "highpass=f=100",  // Remove low frequency noise
            "lowpass=f=8000",  // Remove high frequency noise
            "anlmdn=s=0.001:p=0.003:r=0.01",  // Noise reduction
            "compand=attacks=0.02:decays=0.2:points=-80/-80|-45/-45|-27/-25|0/-10|20/-7:gain=2",  // Dynamic range compression
            "volume=2.0",  // Normalize volume
        ].joined(separator: ",")

        // Construct FFmpeg command
        let command = """
            -i '\(inputPath)' \
            -af '\(audioFilters)' \
            -c:v copy \
            -y '\(outputPath)'
            """

        return try await withCheckedThrowingContinuation { continuation in
            FFmpegKit.executeAsync(
                command,
                withCompleteCallback: { session in
                    guard let returnCode = session?.getReturnCode() else {
                        continuation.resume(
                            throwing: AudioEnhancementError.processingFailed("Unknown error"))
                        return
                    }

                    if returnCode.isValueSuccess() {
                        continuation.resume(returning: outputURL)
                    } else {
                        let errorMessage = session?.getLogsAsString() ?? "Unknown error"
                        continuation.resume(
                            throwing: AudioEnhancementError.processingFailed(errorMessage))
                    }
                },
                withLogCallback: { log in
                    if let message = log?.getMessage() {
                        self.logger.log(message)
                    }
                },
                withStatisticsCallback: { statistics in
                    guard let time = statistics?.getTime() else { return }
                    let progress = Double(time) / (inputDuration * 1000)
                    progressHandler?(progress)
                }
            )
        }
    }
}
