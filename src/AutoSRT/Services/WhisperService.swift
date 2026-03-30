import AVFoundation
import Foundation
import ffmpegkit
import whisper

// Global variable to store the current progress callback
private var currentProgressCallback: ((String, Double) -> Void)? = nil

// C-compatible callback function that doesn't capture context
private func whisperProgressCallback(
    ctx: OpaquePointer?, state: OpaquePointer?, progress: Int32, user_data: UnsafeMutableRawPointer?
) {
    currentProgressCallback?(
        "Transcribing \(progress)%...", (Double(progress) / 100.0).clamped(to: 0.0...1.0))
}

extension NSObject {
    func apply(_ closure: (Self) -> Void) -> Self {
        closure(self)
        return self
    }
}

enum WhisperServiceError: Error {
    case modelNotFound(String)
    case contextCreationFailed(String)
    case transcriptionFailed(String)
    case audioExtractionFailed(String)
    case invalidSRTFormat(String)
    case invalidLanguage(String)
}

class WhisperService {
    static let shared = WhisperService()
    private let logger = LoggerService.shared
    private var modelPath: String = ""
    private var whisperPath: String = ""

    private init() {
        whisperPath = Bundle.main.path(forResource: "whisper", ofType: "") ?? ""
    }

    /// Initialize the model, downloading it if it doesn't exist
    public func initializeModel(
        progressHandler: ((@Sendable (DownloadService.DownloadProgress) -> Void))? = nil
    ) async throws {
        let defaultModelPath =
            Bundle.main.path(forResource: "ggml-large-v3-turbo", ofType: "bin") ?? ""
        if !defaultModelPath.isEmpty {
            modelPath = defaultModelPath
            logger.log("Whispers model found in bundle.", level: .info)
            return
        }

        // Model doesn't exist, download it
        logger.log("Whipser model not found in bundle, downloading...", level: .info)

        // Get application support directory
        let appSupportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        // Create models directory
        let modelsDir = appSupportDir.appendingPathComponent("AutoSRT/Models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelsDir, withIntermediateDirectories: true, attributes: nil)

        // Check if model already exists in application support directory
        let modelPathAtAppSupportDir: URL = modelsDir.appendingPathComponent(
            "ggml-large-v3-turbo/ggml-large-v3-turbo.bin", isDirectory: false)
        if FileManager.default.fileExists(atPath: modelPathAtAppSupportDir.path) {
            modelPath = modelPathAtAppSupportDir.path
            logger.log("Successfully loaded whisper turbo model from application support directory")
            return
        }

        // Download the model
        guard let modelURL = URL(string: Settings.WhisperService.turboModelUrl) else {
            throw EmbeddingError.modelNotFound
        }

        // Download the model
        let downloadedURL = try await DownloadService.shared.downloadModel(
            from: modelURL,
            modelName: "ggml-large-v3-turbo",
            destinationDirectory: modelsDir
        ) { @Sendable progress in
            // self.logger.log("Downloading SentenceBERT model: \(Int(progress.progress * 100))%", level: .info)
            progressHandler?(progress)
        }

        modelPath =
            downloadedURL.appendingPathComponent("ggml-large-v3-turbo.bin", isDirectory: false)
            .path
        logger.log("Successfully downloaded model at \(modelPath)")
    }

    private func transcribeAudio(
        audioFile: URL, language: Language,
        progressCallback: @escaping (String, Double) -> Void
    ) async throws -> [Subtitle] {
        if modelPath.isEmpty {
            throw NSError(
                domain: "WhisperService", code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model not found"])
        }
        // Create unique output file for this transcription
        let outputSrtPath = audioFile.deletingPathExtension()
            .appendingPathExtension(language.rawValue)
            .appendingPathExtension("srt")

        // Remove existing output file if it exists
        if FileManager.default.fileExists(atPath: outputSrtPath.path) {
            try FileManager.default.removeItem(at: outputSrtPath)
        }

        var prompt =
            "transcribe to \(language.displayName), segment naturally, suitable for reading"
        var languageCode = language.whisperCode

        if language == .SimplifiedChinese || language == .TraditionalChinese {
            languageCode = "zh"  // Use standard 'zh' code
            prompt = "使用简体中文转录，如果出现繁体字请转换为简体字, 断句自然，符合阅读习惯"  // "Transcribe using Simplified Chinese, convert Traditional characters to Simplified"
        }

        // get process number of system
        #if os(macOS)
            let maxThread = max(ProcessInfo.processInfo.activeProcessorCount / 3, 5)
        #else
            let maxThread = 5
        #endif
        // Use ProcessInfo to get system memory information
        let physicalMemory = ProcessInfo.processInfo.physicalMemory

        var maxProcess = 3
        if physicalMemory < 1024 * 1024 * 1024 * 16 {
            maxProcess = 1
        }

        var arguments = [
            "-t", "\(maxThread)",
            "-p", "\(maxProcess)",
            "-m", modelPath,
            "-f", audioFile.path,
            "-l", languageCode,
            "-np",
            "-osrt",
            "-mc", "\(Settings.shared.whisperService.contextLength)",
            "-tp", "\(Settings.shared.whisperService.temperature)",
            "-bs", "8",
            "-bo", "8",
            "-ac", "1500",
            "-fa",
            "-sow",
            "--prompt", "'\(prompt)'",
            "-of", outputSrtPath.deletingPathExtension().path,
        ]

        // Add any additional language-specific arguments here if needed
        switch language {
        case .Japanese, .Korean, .SimplifiedChinese, .TraditionalChinese:
            arguments.append(contentsOf: [
                "--max-len", "\(Settings.shared.whisperService.maxCJKSegmentLength)",
            ])  // Shorter segments for CJK languages
        default:
            arguments.append(contentsOf: [
                "--max-len", "\(Settings.shared.whisperService.maxDefaultSegmentLength)",
            ])
        }
        logger.log("Whisper transcription arguments: \(arguments.joined(separator: " "))")

        // Execute whisper command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        logger.log("Starting whisper transcription with language: \(language)")
        try process.run()

        // Get audio duration for progress calculation
        let asset = AVAsset(url: audioFile)
        let totalDuration = CMTimeGetSeconds(asset.duration)

        // Read output in real-time
        let handle = pipe.fileHandleForReading
        //collect output
        for try await line in handle.bytes.lines {
            // logger.log(line)
            // parse line and update progress, line format: [00:20:36.240 --> 00:20:43.240]   Questions?
            let timecodeLine = line.trimmingCharacters(in: .whitespaces)
            // extract string in []
            guard
                let timecodeRange = timecodeLine.range(of: "\\[.*?\\]", options: .regularExpression)
            else { continue }
            let timecodeString = String(timecodeLine[timecodeRange].dropFirst().dropLast())

            let timecodes = timecodeString.components(separatedBy: " --> ")
            guard timecodes.count == 2,
                let startTime = parseTimecode(
                    timecodes[0].replacingOccurrences(of: ".", with: ":")),
                let endTime = parseTimecode(timecodes[1].replacingOccurrences(of: ".", with: ":"))
            else {
                continue
            }
            let progress = Double(endTime) / totalDuration
            let percent = String.init(format: "%.2f", progress * 100)
            progressCallback(
                "Transcribing \(percent)%:: \(timecodes[0]) - \(timecodes[1])...", progress * 0.8)
        }

        // Wait for process to complete
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw WhisperServiceError.transcriptionFailed(
                "Whisper process failed with status \(process.terminationStatus)")
        }

        // Parse the generated SRT file
        let subtitles = try await parseSRT(from: outputSrtPath) { message, progress in
            progressCallback(message, 0.8 + 0.2 * progress)
        }

        try FileManager.default.removeItem(at: outputSrtPath)

        return subtitles
    }

    private func transcribeAudioWithC(
        audioFile: URL, language: Language,
        progressCallback: @escaping (String, Double) -> Void
    ) async throws -> [Subtitle] {

        var context: OpaquePointer?

        // Initialize whisper context with CoreML model
        // Only initialize context if it hasn't been initialized yet
        if context == nil {
            let params = whisper_context_default_params()
            context = whisper_init_from_file_with_params(modelPath, params)
        }

        if context == nil {
            logger.log("Couldn't load model at \(modelPath)", level: .error)
            throw WhisperServiceError.contextCreationFailed(modelPath)
        }

        let state = whisper_init_state(context)

        // Load audio samples as Float32 mono 16kHz
        let samples = try loadAudioSamples(from: audioFile)

        // Get audio duration in ms
        let audioDuration = Double(samples.count) / 16000.0 * 1000.0
        // Configure Whisper C API parameters and report initial progress
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        params.n_threads = Int32(maxThreads)

        if language == .SimplifiedChinese || language == .TraditionalChinese {
            "zh".withCString { cString in
                params.language = UnsafePointer(cString)
            }
        }
        params.print_special = false
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.temperature = Float(Settings.shared.whisperService.temperature)
        params.split_on_word = true
        if language == .Japanese || language == .Korean || language == .SimplifiedChinese
            || language == .TraditionalChinese
        {
            params.max_len = Int32(Settings.shared.whisperService.maxCJKSegmentLength)
        } else {
            params.max_len = Int32(Settings.shared.whisperService.maxDefaultSegmentLength)
        }
        params.duration_ms = Int32(audioDuration)
        params.offset_ms = Int32(0)
        params.tdrz_enable = true
        params.single_segment = false
        params.audio_ctx = 1500
        params.token_timestamps = false
        params.translate = false
        params.n_max_text_ctx = Int32(Settings.shared.whisperService.contextLength)

        // Set the global progress callback
        currentProgressCallback = progressCallback

        // Use the global C-compatible function as the callback
        params.progress_callback = whisperProgressCallback
        params.progress_callback_user_data = nil

        progressCallback("Loaded audio samples, starting transcription...", 0.1)
        logger.log("Starting whisper transcription via C API with language: \(language)")

        return try samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                whisper_free_state(state)
                whisper_free(context)
                throw WhisperServiceError.transcriptionFailed("Failed to get audio buffer address")
            }

            let result = whisper_full_with_state(
                context!, state, params, baseAddress, Int32(samples.count))
            guard result == 0 else {
                whisper_free_state(state)
                whisper_free(context)
                throw WhisperServiceError.transcriptionFailed(
                    "whisper_full failed with code \(result)")
            }

            // Build subtitles from segments
            let nSegments = whisper_full_n_segments_from_state(state)
            var subtitles: [Subtitle] = []
            for i in 0..<nSegments {
                let t0 = whisper_full_get_segment_t0_from_state(state, i)
                // convert t0 to start time in TimeInterval
                let startTime = TimeInterval(t0) / 1000.0
                let t1 = whisper_full_get_segment_t1_from_state(state, i)
                // convert t1 to end time in TimeInterval
                let endTime = TimeInterval(t1) / 1000.0
                guard let cstr = whisper_full_get_segment_text_from_state(state, i) else {
                    continue
                }
                let text = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
                subtitles.append(
                    Subtitle(
                        startTime: startTime, endTime: endTime,
                        sourceText: text,
                        translatedText: "", index: Int(i)))
            }

            whisper_free_state(state)
            whisper_free(context!)

            progressCallback("Transcription complete!", 1.0)
            return subtitles
        }
    }

    // Helper: load audio samples from file as Float32 mono 16kHz
    private func loadAudioSamples(from audioFile: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: audioFile)

        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000.0,
                channels: 1,
                interleaved: false)
        else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create output format")
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create audio converter")
        }

        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create PCM buffer")
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            do {
                guard
                    let temp = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat, frameCapacity: inNumPackets)
                else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                try file.read(into: temp)
                outStatus.pointee = .haveData
                return temp
            } catch {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        converter.convert(to: buffer, error: &error, withInputFrom: inputBlock)
        if let err = error {
            throw WhisperServiceError.audioExtractionFailed(
                "Audio conversion error: \(err.localizedDescription)")
        }

        let count = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw WhisperServiceError.audioExtractionFailed("Failed to get float channel data")
        }

        // Get the first channel (mono)
        let data = channelData[0]

        logger.log("Extracted audio samples: \(count) samples")
        return Array(UnsafeBufferPointer(start: data, count: count))
    }

    private func parseSRT(from url: URL, progressCallback: @escaping (String, Double) -> Void)
        async throws -> [Subtitle]
    {
        guard let srtContent = try? String(contentsOf: url, encoding: .utf8) else {
            throw WhisperServiceError.transcriptionFailed("Failed to read SRT output file")
        }

        // Parse the SRT content into subtitles
        var subtitles: [Subtitle] = []
        let lines = srtContent.components(separatedBy: .newlines)
        var index = 0

        while index < lines.count {
            // Skip empty lines
            while index < lines.count && lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
            }
            if index >= lines.count { break }

            // Skip subtitle number
            index += 1
            if index >= lines.count { break }

            // Parse time codes
            let timecodeLine = lines[index].trimmingCharacters(in: .whitespaces)
            let timecodes = timecodeLine.components(separatedBy: " --> ")
            guard timecodes.count == 2,
                let startTime = parseTimecode(timecodes[0]),
                let endTime = parseTimecode(timecodes[1])
            else {
                throw WhisperServiceError.invalidSRTFormat(
                    "Invalid timecode format: \(timecodeLine)")
            }
            index += 1

            // Parse subtitle text
            var text = ""
            while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty
            {
                if !text.isEmpty {
                    text += "\n"
                }
                text += lines[index].replacingOccurrences(of: "BLANK_AUDIO", with: "AutoSRT")
                index += 1
            }

            // Create subtitle with appropriate language
            let subtitle = Subtitle(
                startTime: startTime,
                endTime: endTime,
                sourceText: text,
                translatedText: ""
            )
            subtitles.append(subtitle)

            progressCallback(
                "Parsed subtitle \(index + 1)/\(lines.count)",
                Double(index + 1) / Double(lines.count))
        }

        return subtitles
    }

    private func parseTimecode(_ timecode: String) -> TimeInterval? {
        let components = timecode.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: ":,"))

        guard components.count == 4,
            let hours = Double(components[0]),
            let minutes = Double(components[1]),
            let seconds = Double(components[2]),
            let milliseconds = Double(components[3])
        else {
            return nil
        }

        return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000
    }

    public func detectLanguage(audioFile: URL) async throws -> Language {
        logger.log("Detecting language for audio file: \(audioFile.lastPathComponent)")
        var context: OpaquePointer?

        // Initialize whisper context with CoreML model
        // Only initialize context if it hasn't been initialized yet
        if context == nil {
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true

            context = whisper_init_from_file_with_params(modelPath, params)
        }

        if context == nil {
            logger.log("Couldn't load model at \(modelPath)", level: .error)
            throw WhisperServiceError.contextCreationFailed(modelPath)
        }

        // Load audio samples
        let samples = try loadAudioSamples(from: audioFile)

        // Use whisper_auto_detect_language API
        return samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                whisper_free(context!)
                return .English  // Default to English if we can't get buffer
            }

            // Setup default params for language detection
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_progress = false
            params.print_timestamps = false
            params.print_realtime = false
            params.print_special = false
            params.translate = false
            params.language = nil
            params.n_threads = 1

            // Process a small segment for language detection
            let sampleCount = min(Int32(samples.count), 8000 * 30)  // Use at most 30 seconds
            let result = whisper_full(context!, params, baseAddress, sampleCount)

            if result != 0 {
                whisper_free(context!)
                logger.log("Language detection failed with code \(result)", level: .warning)
                return .English
            }

            // Get the detected language
            if let langStr = whisper_lang_str(whisper_full_lang_id(context!)) {
                let code = String(cString: langStr)
                let language = Language.fromCode(code)
                logger.log("Detected language: \(language.displayName) (\(code))")
                whisper_free(context!)
                return language
            }

            return .English
        }
    }

    public func transcribe(
        audioFile: URL,
        sourceLanguage: Language,
        targetLanguage: Language,
        progressCallback: @escaping (String, Double) -> Void
    ) async throws -> [Subtitle] {
        logger.log("Starting transcription process...")

        progressCallback("Detecting language...", 0.1)
        var realSourceLanguage: Language = sourceLanguage
        if realSourceLanguage == .None {
            realSourceLanguage = try await detectLanguage(audioFile: audioFile)
        }

        progressCallback(
            "Generating subtitles in source language (\(realSourceLanguage.displayName))...", 0.3)
        let sourceSubtitles = try await transcribeAudio(
            audioFile: audioFile, language: realSourceLanguage
        ) { message, sub_progress in
            progressCallback(message, 0.1 + 0.5 * sub_progress)
        }

        progressCallback(
            "Preparing to translate \(realSourceLanguage.displayName) to \(targetLanguage.displayName)...",
            0.6)

        let translatedSubtitles = try await TranslationService.shared.translateSubtitles(
            sourceSubtitles,
            fromLanguage: realSourceLanguage.target,
            toLanguage: targetLanguage.target,
            model: Settings.shared.llmService.chatModel,
            progressCallback: { subProgress, message in
                progressCallback(message, 0.6 + 0.4 * subProgress)
            })

        progressCallback("Transcription \(translatedSubtitles.count) complete!", 1.0)

        // Check if arrays have matching lengths
        guard sourceSubtitles.count == translatedSubtitles.count else {
            logger.log(
                "Warning: Mismatch in subtitle counts - source: \(sourceSubtitles.count), translated: \(translatedSubtitles.count)",
                level: .warning)
            throw NSError(
                domain: "WhisperService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Mismatch in subtitle counts - source: \(sourceSubtitles.count), translated: \(translatedSubtitles.count)"
                ]
            )
        }

        // If translation failed or wasn't needed, return original bilingual subtitles
        return zip(sourceSubtitles, translatedSubtitles).enumerated().map {
            (index, tuple) -> Subtitle in
            let (en, src) = tuple
            return Subtitle(
                startTime: src.startTime,
                endTime: src.endTime,
                sourceText: en.sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                translatedText: src.translatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                index: index
            )
        }
    }

    public func extractAudio(from videoURL: URL, to audioURL: URL) async throws {
        do {
            try await extractAudioFfmpeg(from: videoURL, to: audioURL)
        } catch {
            logger.log(
                "Extracting audio with FFmpeg failed, using native method instead", level: .warning)
            try await extractAudioNative(from: videoURL, to: audioURL)
        }
    }

    private func extractAudioNative(from videoURL: URL, to audioURL: URL) async throws {
        logger.log("Extracting audio natively from video: \(videoURL.lastPathComponent)")

        if FileManager.default.fileExists(atPath: audioURL.path) {
            try FileManager.default.removeItem(at: audioURL)
        }

        let asset = AVAsset(url: videoURL)

        // Create asset reader
        guard let assetReader = try? AVAssetReader(asset: asset) else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create asset reader")
        }

        // Setup audio output settings
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        // Create asset writer
        guard let assetWriter = try? AVAssetWriter(outputURL: audioURL, fileType: .wav) else {
            throw WhisperServiceError.audioExtractionFailed("Failed to create asset writer")
        }

        // Setup audio input
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw WhisperServiceError.audioExtractionFailed("No audio track found")
        }

        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,
            ]
        )

        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        writerInput.expectsMediaDataInRealTime = false

        // Add outputs and inputs
        assetReader.add(readerOutput)
        assetWriter.add(writerInput)

        // Start reading/writing
        guard assetReader.startReading(), assetWriter.startWriting() else {
            throw WhisperServiceError.audioExtractionFailed("Failed to start reading/writing")
        }

        assetWriter.startSession(atSourceTime: .zero)

        return try await withCheckedThrowingContinuation { continuation in
            writerInput.requestMediaDataWhenReady(on: .global()) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(buffer) {
                            assetReader.cancelReading()
                            continuation.resume(
                                throwing: WhisperServiceError.audioExtractionFailed(
                                    "Failed to write audio buffer"))
                            return
                        }
                    } else {
                        writerInput.markAsFinished()
                        assetWriter.finishWriting {
                            if let error = assetWriter.error {
                                continuation.resume(
                                    throwing: WhisperServiceError.audioExtractionFailed(
                                        error.localizedDescription))
                                return
                            }

                            // Verify the output file
                            guard FileManager.default.fileExists(atPath: audioURL.path),
                                let attributes = try? FileManager.default.attributesOfItem(
                                    atPath: audioURL.path),
                                let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
                                fileSize > 0
                            else {
                                continuation.resume(
                                    throwing: WhisperServiceError.audioExtractionFailed(
                                        "Exported audio file is empty or missing"))
                                return
                            }

                            self.logger.log(
                                "Audio extraction completed successfully: \(audioURL.lastPathComponent)"
                            )
                            self.logger.log(
                                "Output file size: \(Double(fileSize) / 1024.0 / 1024.0) MB")
                            continuation.resume()
                        }
                        break
                    }
                }
            }
        }
    }

    private func extractAudioFfmpeg(from videoURL: URL, to audioURL: URL) async throws {
        logger.log("Extracting audio from video: \(videoURL.lastPathComponent)")

        if FileManager.default.fileExists(atPath: audioURL.path) {
            try FileManager.default.removeItem(at: audioURL)
        }

        // let escapedVideoPath = videoURL.path.replacingOccurrences(of: "'", with: "\\'")
        let escapedVideoPath = videoURL.path

        // FFmpeg arguments for audio extraction
        let arguments = [
            "-i", "\"\(escapedVideoPath)\"",
            "-ar", "16000",
            "-ac", "1",
            "-af", "volume=5dB",
            "-c:a", "pcm_s16le",
            "'\(audioURL.path)'",
        ]

        logger.log("Executing FFmpeg with arguments: \(arguments)")

        return try await withCheckedThrowingContinuation { continuation in
            FFmpegKit.executeAsync(arguments.joined(separator: " ")) { session in
                guard let returnCode = session?.getReturnCode() else {
                    let error = session?.getFailStackTrace() ?? "Unknown error"
                    let output = session?.getOutput() ?? ""
                    self.logger.log(
                        "FFmpeg failed with error: \(error)\nOutput: \(output)", level: .error)
                    continuation.resume(
                        throwing: WhisperServiceError.audioExtractionFailed(output)
                    )
                    return
                }

                if ReturnCode.isSuccess(returnCode) {
                    guard FileManager.default.fileExists(atPath: audioURL.path),
                        let attributes = try? FileManager.default.attributesOfItem(
                            atPath: audioURL.path),
                        let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
                        fileSize > 0
                    else {
                        continuation.resume(
                            throwing: WhisperServiceError.audioExtractionFailed(
                                "Exported audio file is empty or missing"))
                        return
                    }

                    self.logger.log(
                        "Audio extraction completed successfully: \(audioURL.lastPathComponent)")
                    self.logger.log("Output file size: \(Double(fileSize) / 1024.0 / 1024.0) MB")
                    continuation.resume()
                } else {
                    let error = session?.getFailStackTrace() ?? "Unknown error"
                    let outputLines = (session?.getOutput() ?? "").split(separator: "\n").suffix(3)
                        .joined(separator: "\n")

                    self.logger.log(
                        "FFmpeg failed with error: \(error) \nOutput: \(outputLines)", level: .error
                    )
                    continuation.resume(
                        throwing: WhisperServiceError.audioExtractionFailed(
                            "\(outputLines)")
                    )
                }
            }
        }
    }
}

extension Array where Element == Subtitle {
    static func mergeBilingual(english: [Subtitle], chinese: [Subtitle]) -> [Subtitle] {
        // Implement merging logic here
        // For now, just return the English subtitles
        return english
    }
}
