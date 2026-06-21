import Combine
import Foundation
import System
import os

public final class DownloadService: ObservableObject, @unchecked Sendable {
    // MARK: - Singleton
    public static let shared = DownloadService()

    private let logger = LoggerService.shared
    private var progressDelegate: ProgressDelegate?  // Store the delegate to prevent it from being deallocated
    private var session: URLSession?

    // MARK: - Published Properties
    @Published public var isDownloading = false
    @Published public var downloadProgress: Double = 0
    @Published public var currentModelName: String = ""
    @Published public var currentStatus: DownloadProgress.DownloadStatus = .downloading

    // MARK: - Download Progress
    public struct DownloadProgress {
        public let modelName: String
        public let bytesDownloaded: Int64
        public let totalBytes: Int64
        public let progress: Double
        public let status: DownloadStatus
        public let downloadSpeed: Double  // bytes per second
        public let estimatedTimeRemaining: Double?  // seconds, nil if not yet calculable

        public enum DownloadStatus: String {
            case downloading
            case validating
            case completed
            case failed
        }
    }

    // MARK: - Constants
    private static let maxDownloadRetries = 100
    private static let downloadRetryBaseDelay: TimeInterval = 3

    // MARK: - Initialization
    init() {
    }

    // MARK: - Public Methods

    /// Download a model from a URL
    /// - Parameters:
    ///   - url: The URL to download the model from
    ///   - modelName: The name to save the model as
    ///   - destinationDirectory: The directory to save the model to
    ///   - progressHandler: Optional handler for download progress updates
    /// - Returns: URL to the downloaded file or directory (if unzipped)
    public func downloadModel(
        from url: URL,
        modelName: String,
        destinationDirectory: URL,
        progressHandler: ((DownloadProgress) -> Void)? = nil
    ) async throws -> URL {
        guard !isDownloading else {
            throw NSError(
                domain: "DownloadService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "A download is already in progress"]
            )
        }

        await MainActor.run {
            self.isDownloading = true
            self.downloadProgress = 0
            self.currentModelName = modelName
            self.currentStatus = .downloading
        }

        // Create destination directory if it doesn't exist
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        // Create destination file URL
        let fileExtension = url.pathExtension.isEmpty ? "bin" : url.pathExtension
        let destinationURL = destinationDirectory.appendingPathComponent(
            "\(modelName).\(fileExtension)")

        // Temp file for atomic move on success
        let tempURL = destinationURL.appendingPathExtension("tmp")

        // Retry loop for resilient downloads (auto-resume on connection loss)
        let maxRetries = Self.maxDownloadRetries
        let baseDelay = Self.downloadRetryBaseDelay

        for attempt in 0..<maxRetries {
            // Check for partial download from previous failed attempt (on retry)
            var partialBytes: Int64 = 0
            if FileManager.default.fileExists(atPath: tempURL.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: tempURL.path)
                partialBytes = attrs?[.size] as? Int64 ?? 0
                logger.log("Resuming from partial download: \(partialBytes) bytes")
            }
            do {
                // Log the download start
                logger.log("Starting download for \(modelName) from \(url.absoluteString)")

                // Create a URLRequest with appropriate settings
                var request = URLRequest(url: url)
                var timeout = Settings.shared.llmService.timeout
                if timeout < 3600 * 24 * 7 {
                    timeout = 3600 * 24 * 7
                }
                request.httpMethod = "GET"
                request.timeoutInterval = timeout

                // Send Range header to ask server to resume from partial download
                if partialBytes > 0 {
                    request.setValue("bytes=\(partialBytes)-", forHTTPHeaderField: "Range")
                    logger.log("Requesting resume from byte \(partialBytes)")
                }

                // Create a URLSession with default configuration that follows redirects
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = timeout
                config.timeoutIntervalForResource = timeout
                let downloadSession = URLSession(configuration: config)
                self.session = downloadSession

                // Start the data task
                let (asyncBytes, response) = try await downloadSession.bytes(for: request)

                // Validate response
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(
                        domain: "DownloadService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
                    )
                }

                // Handle 200 OK (full download) vs 206 Partial Content (resumed)
                let isResumed = httpResponse.statusCode == 206
                let totalBytes: Int64
                if isResumed {
                    // Server supports resumption — expectedContentLength is remaining bytes
                    totalBytes =
                        httpResponse.expectedContentLength > 0
                        ? partialBytes + httpResponse.expectedContentLength
                        : partialBytes + 1_000_000  // Fallback estimate
                    logger.log("Server resumed download from byte \(partialBytes)")
                } else if httpResponse.statusCode == 200 {
                    // Server ignores Range — full download will be sent
                    if partialBytes > 0 {
                        logger.log("Server doesn't support Range, restarting from beginning")
                        try FileManager.default.removeItem(at: tempURL)
                        partialBytes = 0
                    }
                    totalBytes =
                        httpResponse.expectedContentLength > 0
                        ? httpResponse.expectedContentLength : 1_000_000
                } else {
                    throw NSError(
                        domain: "DownloadService",
                        code: httpResponse.statusCode,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Download failed with status code: \(httpResponse.statusCode)"
                        ]
                    )
                }

                // Create or open temp file for writing
                let fileHandle: FileHandle
                if partialBytes > 0 {
                    // Resume from existing temp file
                    fileHandle = try FileHandle(forWritingTo: tempURL)
                    try fileHandle.seekToEnd()
                } else {
                    // Fresh download — create empty temp file
                    try Data().write(to: tempURL)
                    fileHandle = try FileHandle(forWritingTo: tempURL)
                }
                defer {
                    try? fileHandle.close()
                }

                // Download the file in chunks and report progress
                var bytesDownloaded: Int64 = partialBytes
                var lastProgressReport: Int = -1
                var buffer = Data()
                let bufferSize = 32768  // 32KB buffer

                // Process bytes in chunks for better performance
                for try await byte in asyncBytes {
                    buffer.append(byte)

                    // When buffer reaches desired size, write to file
                    if buffer.count >= bufferSize {
                        try fileHandle.write(contentsOf: buffer)
                        bytesDownloaded += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)

                        let progress = Double(bytesDownloaded) / Double(totalBytes)

                        // Update progress on main thread
                        await MainActor.run {
                            self.downloadProgress = progress
                        }

                        // Create progress update
                        let downloadProgress = DownloadProgress(
                            modelName: modelName,
                            bytesDownloaded: bytesDownloaded,
                            totalBytes: totalBytes,
                            progress: progress,
                            status: .downloading,
                            downloadSpeed: 0,
                            estimatedTimeRemaining: nil
                        )

                        // Call progress handler
                        progressHandler?(downloadProgress)

                        // Log progress periodically (every 10%)
                        let progressPercentage = Int(progress * 100)
                        if progressPercentage % 10 == 0 && progressPercentage > 0
                            && progressPercentage != lastProgressReport
                        {
                            lastProgressReport = progressPercentage
                            logger.log("Download progress for \(modelName): \(progressPercentage)%")
                        }
                    }
                }

                // Write any remaining data in the buffer
                if !buffer.isEmpty {
                    try fileHandle.write(contentsOf: buffer)
                    bytesDownloaded += Int64(buffer.count)

                    let progress = Double(bytesDownloaded) / Double(totalBytes)

                    await MainActor.run {
                        self.downloadProgress = progress
                    }

                    // Final progress update before completion
                    let downloadProgress = DownloadProgress(
                        modelName: modelName,
                        bytesDownloaded: bytesDownloaded,
                        totalBytes: totalBytes,
                        progress: progress,
                        status: .downloading,
                        downloadSpeed: 0,
                        estimatedTimeRemaining: nil
                    )

                    progressHandler?(downloadProgress)
                }

                // Close the file handle
                try fileHandle.close()

                // Atomically move temp file to final destination
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                logger.log("Downloaded file moved to \(destinationURL.path)")

                // Notify completion
                let finalProgress = DownloadProgress(
                    modelName: modelName,
                    bytesDownloaded: totalBytes,
                    totalBytes: totalBytes,
                    progress: 1.0,
                    status: .completed,
                    downloadSpeed: 0,
                    estimatedTimeRemaining: nil
                )
                progressHandler?(finalProgress)

                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.currentStatus = .completed
                }

                logger.log("Successfully downloaded model: \(modelName)")
                return destinationURL
                } catch {
                // Download failed — clean up session for retry
                self.cancelDownload()

                let isLastAttempt = attempt == maxRetries - 1
                if isLastAttempt {
                    // Exhausted all retries — clean up temp file and throw
                    try? FileManager.default.removeItem(at: tempURL)

                    await MainActor.run {
                        self.isDownloading = false
                        self.currentStatus = .failed
                    }

                    logger.log(
                        "Failed to download model from \(url): \(error.localizedDescription)",
                        level: .error
                    )
                    throw error
                }

                // Retry with exponential backoff
                let delay = baseDelay * Double(attempt)
                logger.log(
                    "Download failed (attempt \(attempt + 1)/\(maxRetries)), retrying in \(Int(delay))s...",
                    level: .warning
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        } // end retry loop

        // Should not reach here, but guard against unreachable-code warnings
        let fallbackError = NSError(
            domain: "DownloadService",
            code: -99,
            userInfo: [NSLocalizedDescriptionKey: "Download failed after \(maxRetries) attempts"]
        )
        await MainActor.run {
            self.isDownloading = false
            self.currentStatus = .failed
        }
        throw fallbackError
    }

    /// Cancel any ongoing downloads
    public func cancelDownload() {
        if let session = self.session {
            session.getAllTasks { tasks in
                tasks.forEach { $0.cancel() }
            }
        }

        Task { @MainActor in
            self.isDownloading = false
            self.downloadProgress = 0
            self.currentStatus = .failed
        }
    }

    // MARK: - Helper Classes

    /// URLSessionDownloadDelegate for tracking download progress
    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate,
        URLSessionTaskDelegate, @unchecked Sendable
    {
        private let modelName: String
        private let onProgress: @Sendable (Int64, Int64) -> Void
        private let logger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.autosrt", category: "DownloadService")

        init(modelName: String, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.modelName = modelName
            self.onProgress = onProgress
            super.init()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite totalBytes: Int64
        ) {
            // Log progress periodically (every 10%)
            let progressPercentage = Int(Double(totalBytesWritten) / Double(totalBytes) * 100)
            if progressPercentage % 10 == 0 && progressPercentage > 0 {
                self.logger.info("Download progress for \(self.modelName): \(progressPercentage)%")
            }

            // Call the progress handler on the main thread
            self.onProgress(totalBytesWritten, totalBytes)
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            self.logger.info("Download completed for \(self.modelName)")
            // This is handled in the main download function
        }
    }
}
