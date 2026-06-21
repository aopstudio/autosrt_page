import XCTest
@testable import AutoSRT

final class DownloadServiceTests: XCTestCase {
    var downloadService: DownloadService!
    var tempDirectory: URL!
    var testFileURL: URL!
    var testLargeFileURL: URL!
    var pythonServerProcess: Process?
    var pythonServerPort: Int = 8765

    override func setUpWithError() throws {
        super.setUp()
        downloadService = DownloadService.shared
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AutoSRTTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true)

        // Create a small test file
        let smallContent = String(repeating: "Hello, this is a test file for download service testing.\n", count: 100)
        testFileURL = tempDirectory.appendingPathComponent("test_file.bin")
        try smallContent.write(to: testFileURL, atomically: true, encoding: .utf8)

        // Create a larger test file (~1MB) for resume testing
        let largeContent = Data(repeating: 0xAA, count: 1_048_576)  // 1MB
        testLargeFileURL = tempDirectory.appendingPathComponent("test_large_file.bin")
        try largeContent.write(to: testLargeFileURL)
    }

    override func tearDownWithError() throws {
        // Stop the Python HTTP server
        pythonServerProcess?.terminate()
        pythonServerProcess?.waitUntilExit()
        pythonServerProcess = nil

        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDirectory)

        downloadService = nil
        super.tearDown()
    }

    // MARK: - Helper Methods

    /// Start a Python HTTP server to serve test files
    @MainActor
    private func startPythonHTTPServer() async throws {
        // Cancel any existing download to free up the singleton
        downloadService.cancelDownload()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-m", "http.server",
            "\(pythonServerPort)",
            "-d", tempDirectory.path,
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        pythonServerProcess = process

        // Wait for server to be ready
        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms

        // Verify server is running
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: URL(
            string: "http://localhost:\(pythonServerPort)/")!)
        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            throw NSError(
                domain: "DownloadServiceTests", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start Python HTTP server"])
        }
        _ = data  // We don't need the content
    }

    /// Stop the Python HTTP server
    @MainActor
    private func stopPythonHTTPServer() {
        pythonServerProcess?.terminate()
        pythonServerProcess?.waitUntilExit()
        pythonServerProcess = nil
    }

    // MARK: - DownloadProgress Tests

    func testDownloadProgressCreation() {
        let progress = DownloadService.DownloadProgress(
            modelName: "test-model",
            bytesDownloaded: 500_000,
            totalBytes: 1_000_000,
            progress: 0.5,
            status: .downloading,
            downloadSpeed: 100_000,
            estimatedTimeRemaining: 5.0
        )

        XCTAssertEqual(progress.modelName, "test-model")
        XCTAssertEqual(progress.bytesDownloaded, 500_000)
        XCTAssertEqual(progress.totalBytes, 1_000_000)
        XCTAssertEqual(progress.progress, 0.5)
        XCTAssertEqual(progress.status, .downloading)
        XCTAssertEqual(progress.downloadSpeed, 100_000)
        XCTAssertEqual(progress.estimatedTimeRemaining, 5.0)
    }

    func testDownloadProgressCompletionStatus() {
        let progress = DownloadService.DownloadProgress(
            modelName: "test-model",
            bytesDownloaded: 1_000_000,
            totalBytes: 1_000_000,
            progress: 1.0,
            status: .completed,
            downloadSpeed: 0,
            estimatedTimeRemaining: nil
        )

        XCTAssertEqual(progress.status, .completed)
        XCTAssertEqual(progress.progress, 1.0)
        XCTAssertNil(progress.estimatedTimeRemaining)
    }

    func testDownloadProgressStatusCases() {
        let status = DownloadService.DownloadProgress.DownloadStatus.self
        XCTAssertEqual(status.downloading.rawValue, "downloading")
        XCTAssertEqual(status.validating.rawValue, "validating")
        XCTAssertEqual(status.extracting.rawValue, "extracting")
        XCTAssertEqual(status.completed.rawValue, "completed")
        XCTAssertEqual(status.failed.rawValue, "failed")
    }

    // MARK: - Single File Download Tests

    func testDownloadSingleFile() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_single")
        let resultURL = try await downloadService.downloadModel(
            from: URL(string: "http://localhost:\(pythonServerPort)/test_file.bin")!,
            modelName: "test_single",
            destinationDirectory: destinationDir
        ) { progress in
            // Track progress
            XCTAssertEqual(progress.modelName, "test_single")
            XCTAssertGreaterThan(progress.progress, 0)
            XCTAssertLessThanOrEqual(progress.progress, 1)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let fileSize = (attributes [.size] as? NSNumber)?.int64Value ?? 0
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: testFileURL.path)
        let expectedSizeValue = (expectedAttributes [.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(fileSize, expectedSizeValue, "Downloaded file size should match original")

        // Verify file content
        let downloadedData = try Data(contentsOf: resultURL)
        let originalData = try Data(contentsOf: testFileURL)
        XCTAssertEqual(downloadedData, originalData, "Downloaded content should match original")

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    func testDownloadProgressUpdates() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_progress")
        var progressValues: [Double] = []
        var progressLock = NSLock()

        _ = try await downloadService.downloadModel(
            from: URL(string: "http://localhost:\(pythonServerPort)/test_file.bin")!,
            modelName: "test_progress",
            destinationDirectory: destinationDir
        ) { progress in
            progressLock.lock()
            progressValues.append(progress.progress)
            progressLock.unlock()
        }

        // Progress should have multiple updates
        XCTAssertGreaterThan(progressValues.count, 1, "Should have multiple progress updates")

        // Progress should be monotonically increasing (mostly)
        for i in 1..<progressValues.count {
            XCTAssertGreaterThanOrEqual(
                progressValues[i], progressValues[i - 1],
                "Progress should not decrease")
        }

        // Final progress should be 1.0
        let finalProgress = progressValues.last!
        XCTAssertEqual(finalProgress, 1.0, accuracy: 0.01, "Final progress should be 100%")

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    func testDownloadETAReported() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_eta")
        var hasETA = false

        _ = try await downloadService.downloadModel(
            from: URL(string: "http://localhost:\(pythonServerPort)/test_file.bin")!,
            modelName: "test_eta",
            destinationDirectory: destinationDir
        ) { progress in
            if let eta = progress.estimatedTimeRemaining,
                eta.isFinite, eta > 0
            {
                hasETA = true
            }
        }

        XCTAssertTrue(hasETA, "Should report estimated time remaining during download")

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    // MARK: - Resume Download Tests

    func testResumeFromPartialTempFile() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_resume")
        let finalURL = destinationDir.appendingPathComponent("test_resume.bin")
        let tempURL = finalURL.appendingPathExtension("tmp")

        // Phase 1: Download part of the file by simulating a partial download
        // First, download the full file to use as a partial source
        let fullData = try Data(contentsOf: testLargeFileURL)
        let partialData = fullData.prefix(fullData.count / 2)  // Download half

        // Create a partial temp file
        try partialData.write(to: tempURL)

        // Phase 2: Resume the download
        let resultURL = try await downloadService.downloadModel(
            from: URL(string: "http://localhost:\(pythonServerPort)/test_large_file.bin")!,
            modelName: "test_resume",
            destinationDirectory: destinationDir
        ) { progress in
            // Progress should start from the partial amount
            if progress.status == .downloading, progress.bytesDownloaded > 0 {
                XCTAssertGreaterThanOrEqual(
                    progress.bytesDownloaded, Int64(partialData.count),
                    "Should resume from partial download")
            }
        }

        // Verify the final file is complete
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))
        let finalAttributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let finalSize = (finalAttributes [.size] as? NSNumber)?.int64Value ?? 0
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: testLargeFileURL.path)
        let expectedSize = (expectedAttributes [.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(finalSize, expectedSize, "Resumed file should be complete")

        // Verify content matches
        let downloadedData = try Data(contentsOf: resultURL)
        XCTAssertEqual(downloadedData, fullData, "Resumed file content should match original")

        // Temp file should not remain after successful download
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempURL.path),
            "Temp file should be removed after successful download")

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    func testResumeFromDestinationFile() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_dest_resume")

        // Phase 1: Complete the download first
        _ = try await downloadService.downloadModel(
            from: URL(string: "http://localhost:\(pythonServerPort)/test_file.bin")!,
            modelName: "test_dest_resume",
            destinationDirectory: destinationDir
        ) { _ in }

        // Verify file exists
        let finalURL = destinationDir.appendingPathComponent("test_dest_resume.bin")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: finalURL.path),
            "File should exist after first download")
        let firstSize = (try FileManager.default.attributesOfItem(atPath: finalURL.path) [.size]
            as? NSNumber)?.int64Value ?? 0

        // Phase 2: Try to download again - should detect existing file
        let resultURL = try await downloadService.downloadModel(
            from: URL(string: "http://localhost:\(pythonServerPort)/test_file.bin")!,
            modelName: "test_dest_resume",
            destinationDirectory: destinationDir
        ) { progress in
            // Progress should jump to 1.0 since file already exists
            if progress.progress == 1.0 {
                // File was already complete
            }
        }

        // The result should be the same file
        XCTAssertEqual(resultURL.path, finalURL.path)

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    // MARK: - Error Handling Tests

    func testDownloadInvalidURL() async {
        let destinationDir = tempDirectory.appendingPathComponent("downloads_invalid_url")

        do {
            _ = try await downloadService.downloadModel(
                from: URL(string: "http://localhost:99999/nonexistent")!,
                modelName: "test_invalid_url",
                destinationDirectory: destinationDir
            ) { _ in }
            XCTFail("Should throw error for invalid URL")
        } catch {
            // Expected error
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    func testDownloadNotFound() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_404")

        do {
            _ = try await downloadService.downloadModel(
                from: URL(string: "http://localhost:\(pythonServerPort)/nonexistent_file.bin")!,
                modelName: "test_404",
                destinationDirectory: destinationDir
            ) { _ in }
            XCTFail("Should throw error for 404 response")
        } catch {
            // Expected error
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    func testConcurrentDownloadPrevention() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_concurrent")

        // Start first download
        let firstTask = Task {
            try await downloadService.downloadModel(
                from: URL(string: "http://localhost:\(pythonServerPort)/test_file.bin")!,
                modelName: "test_concurrent_1",
                destinationDirectory: destinationDir
            ) { _ in }
        }

        // Wait a bit for first download to start
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        // Try to start second download - should fail
        do {
            _ = try await downloadService.downloadModel(
                from: URL(string: "http://localhost:\(pythonServerPort)/test_file.bin")!,
                modelName: "test_concurrent_2",
                destinationDirectory: destinationDir
            ) { _ in }
            XCTFail("Should throw error when download is already in progress")
        } catch let error as NSError {
            XCTAssertEqual(
                error.domain, "DownloadService",
                "Error domain should be DownloadService")
            XCTAssertEqual(error.code, -1, "Error code should be -1 (already downloading)")
        }

        // First download should still complete
        _ = try await firstTask.value

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    func testCancelDownload() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_cancel")
        var cancelled = false

        let downloadTask = Task {
            do {
                _ = try await downloadService.downloadModel(
                    from: URL(string: "http://localhost:\(pythonServerPort)/test_large_file.bin")!,
                    modelName: "test_cancel",
                    destinationDirectory: destinationDir
                ) { progress in
                    // Cancel after 20% progress
                    if progress.progress > 0.2 {
                        self.downloadService.cancelDownload()
                    }
                }
            } catch {
                cancelled = true
            }
        }

        // Wait for the task to complete (either success or cancellation)
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
        downloadTask.cancel()

        // Verify state was reset
        XCTAssertFalse(downloadService.isDownloading)
        XCTAssertEqual(downloadService.downloadProgress, 0)

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    // MARK: - Temp File Cleanup Tests

    func testTempFileCleanedUpOnFailure() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_cleanup")

        // Try to download a non-existent file
        do {
            _ = try await downloadService.downloadModel(
                from: URL(string: "http://localhost:\(pythonServerPort)/does_not_exist.bin")!,
                modelName: "test_cleanup",
                destinationDirectory: destinationDir
            ) { _ in }
            XCTFail("Should throw error")
        } catch {
            // Expected
        }

        // Verify no temp file was left behind
        let tempURL = destinationDir.appendingPathComponent("test_cleanup.bin.tmp")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempURL.path),
            "Temp file should be cleaned up after failed download")

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    func testStaleTempFileCleanedUpOnNewDownload() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_stale")
        let finalURL = destinationDir.appendingPathComponent("test_stale.bin")
        var tempURL = finalURL.appendingPathExtension("tmp")

        // Create a stale temp file
        let staleData = "stale data".data(using: .utf8)!
        try staleData.write(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        // Download should clean up the stale temp file and create a new one
        let resultURL = try await downloadService.downloadModel(
            from: URL(string: "http://localhost:\(pythonServerPort)/test_file.bin")!,
            modelName: "test_stale",
            destinationDirectory: destinationDir
        ) { _ in }

        // Verify the downloaded file is correct (not the stale data)
        let downloadedData = try Data(contentsOf: resultURL)
        let originalData = try Data(contentsOf: testFileURL)
        XCTAssertEqual(downloadedData, originalData, "Should contain fresh download, not stale data")

        // Temp file should be removed after success
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempURL.path),
            "Temp file should be removed after successful download")

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }

    // MARK: - File Content Verification Tests

    func testDownloadedFileMatchesSource() async throws {
        try await startPythonHTTPServer()

        let destinationDir = tempDirectory.appendingPathComponent("downloads_verify")

        let resultURL = try await downloadService.downloadModel(
            from: URL(string: "http://localhost:\(pythonServerPort)/test_large_file.bin")!,
            modelName: "test_verify",
            destinationDirectory: destinationDir
        ) { _ in }

        // Verify file size matches
        let resultAttributes = try FileManager.default.attributesOfItem(atPath: resultURL.path)
        let resultSize = (resultAttributes [.size] as? NSNumber)?.int64Value ?? 0
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: testLargeFileURL.path)
        let sourceSize = (sourceAttributes [.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertEqual(resultSize, sourceSize, "Downloaded file size should match source")

        // Verify file content byte-by-byte
        let resultData = try Data(contentsOf: resultURL)
        let sourceData = try Data(contentsOf: testLargeFileURL)
        XCTAssertEqual(resultData, sourceData, "Downloaded content should match source exactly")

        // Clean up
        try? FileManager.default.removeItem(at: destinationDir)
    }
}
