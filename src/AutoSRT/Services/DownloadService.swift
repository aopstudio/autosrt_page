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

        public enum DownloadStatus: String {
            case downloading
            case validating
            case extracting
            case completed
            case failed
        }
    }

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

        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            // Log the download start
            logger.log("Starting download for \(modelName) from \(url.absoluteString)")
            // clear session
            self.cancelDownload()

            // Create a URLRequest with appropriate settings
            var request = URLRequest(url: url)
            var timeout = Settings.shared.llmService.timeout
            if timeout < 3600 * 24 * 7 {
                timeout = 3600 * 24 * 7
            }
            request.httpMethod = "GET"
            request.timeoutInterval = timeout

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

            if httpResponse.statusCode != 200 {
                throw NSError(
                    domain: "DownloadService",
                    code: httpResponse.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Download failed with status code: \(httpResponse.statusCode)"
                    ]
                )
            }

            // Get content length
            let totalBytes =
                httpResponse.expectedContentLength > 0
                ? httpResponse.expectedContentLength : 1_000_000  // Default to 1MB if unknown

            // Create a file handle for writing
            try Data().write(to: destinationURL)  // Create an empty file
            let fileHandle = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? fileHandle.close()
            }

            // Download the file in chunks and report progress
            var bytesDownloaded: Int64 = 0
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
                        status: .downloading
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
                    status: .downloading
                )

                progressHandler?(downloadProgress)
            }

            // Close the file handle
            try fileHandle.close()

            // Check if the file is a zip archive
            if fileExtension.lowercased() == "zip" {
                await MainActor.run {
                    self.currentStatus = .extracting
                }

                // Update progress handler with extracting status
                let extractingProgress = DownloadProgress(
                    modelName: modelName,
                    bytesDownloaded: totalBytes,
                    totalBytes: totalBytes,
                    progress: 1.0,
                    status: .extracting
                )
                progressHandler?(extractingProgress)

                // Create extraction directory
                let extractionDir = destinationDirectory.appendingPathComponent(
                    modelName, isDirectory: true)

                // Remove existing extraction directory if it exists
                if FileManager.default.fileExists(atPath: extractionDir.path) {
                    try FileManager.default.removeItem(at: extractionDir)
                }

                // Create the extraction directory
                try FileManager.default.createDirectory(
                    at: extractionDir,
                    withIntermediateDirectories: true
                )

                // Unzip the file
                try await unzipFile(at: destinationURL, to: extractionDir)

                // Delete the zip file after extraction
                try FileManager.default.removeItem(at: destinationURL)

                // Notify completion
                let finalProgress = DownloadProgress(
                    modelName: modelName,
                    bytesDownloaded: totalBytes,
                    totalBytes: totalBytes,
                    progress: 1.0,
                    status: .completed
                )
                progressHandler?(finalProgress)

                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.currentStatus = .completed
                }

                logger.log("Successfully downloaded and extracted model: \(modelName)")
                return extractionDir
            } else {
                // Notify completion for non-zip files
                let finalProgress = DownloadProgress(
                    modelName: modelName,
                    bytesDownloaded: totalBytes,
                    totalBytes: totalBytes,
                    progress: 1.0,
                    status: .completed
                )
                progressHandler?(finalProgress)

                await MainActor.run {
                    self.isDownloading = false
                    self.downloadProgress = 1.0
                    self.currentStatus = .completed
                }

                logger.log("Successfully downloaded model: \(modelName)")
                return destinationURL
            }
        } catch {
            await MainActor.run {
                self.isDownloading = false
                self.currentStatus = .failed
            }

            logger.log(
                "Failed to download model from \(url): \(error.localizedDescription)", level: .error
            )
            throw error
        }
    }

    /// Unzip a file to a destination directory
    /// - Parameters:
    ///   - fileURL: The URL of the zip file
    ///   - destinationURL: The directory to extract to
    private func unzipFile(at fileURL: URL, to destinationURL: URL) async throws {
        let fileManager = FileManager.default

        // Check if the file exists
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw NSError(
                domain: "DownloadService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Zip file does not exist at path: \(fileURL.path)"
                ]
            )
        }

        // Create the destination directory if it doesn't exist
        if !fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: true
            )
        }

        // Use Process to run unzip command
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                    process.arguments = ["-o", fileURL.path, "-d", destinationURL.path]

                    let outputPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = outputPipe

                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        DispatchQueue.main.async {
                            self.logger.log(
                                "Successfully extracted zip file to \(destinationURL.path)")
                            continuation.resume()
                        }
                    } else {
                        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        let output = String(data: outputData, encoding: .utf8) ?? "Unknown error"

                        DispatchQueue.main.async {
                            self.logger.log("Failed to extract zip file: \(output)", level: .error)
                            continuation.resume(
                                throwing: NSError(
                                    domain: "DownloadService",
                                    code: Int(process.terminationStatus),
                                    userInfo: [
                                        NSLocalizedDescriptionKey:
                                            "Failed to extract zip file: \(output)"
                                    ]
                                ))
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.logger.log(
                            "Failed to extract zip file: \(error.localizedDescription)",
                            level: .error)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
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
