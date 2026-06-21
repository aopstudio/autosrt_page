import XCTest

@testable import AutoSRT

class VideoServiceTests: XCTestCase {
    var videoService: VideoService!
    var resourcesURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        videoService = VideoService.shared
        
        // Get the test bundle's resource path
        let testBundle = Bundle(for: type(of: self))
        if let resourcePath = testBundle.resourcePath {
            resourcesURL = URL(fileURLWithPath: resourcePath)
            print("Test resources path: \(resourcePath)")
        } else {
            XCTFail("Could not find test bundle resources")
        }
    }

    override func tearDownWithError() throws {
        videoService = nil
        resourcesURL = nil
        try super.tearDownWithError()
    }

    func testVideoQualityPresets() {
        XCTAssertEqual(VideoQuality.high.presetName, "-preset slow")
        XCTAssertEqual(VideoQuality.medium.presetName, "-preset medium")
        XCTAssertEqual(VideoQuality.low.presetName, "-preset fast")
    }

    func testVideoQualityEncoderOptions() {
        XCTAssertEqual(VideoQuality.high.encoderOption, "-crf 14")
        XCTAssertEqual(VideoQuality.medium.encoderOption, "-crf 23")
        XCTAssertEqual(VideoQuality.low.encoderOption, "-crf 28")
    }
    
    func testRenderSubtitledVideoWithComplexFilename() async throws {
        let testVideoURL = resourcesURL.appendingPathComponent("Resources/test_video.mp4")
        let complexAssURL = resourcesURL.appendingPathComponent("Resources/test.ass")
        
        // Verify test files exist
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: testVideoURL.path), "test_video.mp4 not found")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: complexAssURL.path), "Complex ASS file not found")
        
        let complexOutputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "output_complex.mp4")
        
        var progressUpdates: [Double] = []
        let progressHandler: (Double) -> Void = { progress in
            progressUpdates.append(progress)
        }
        
        // Test rendering with complex filename
        try await videoService.renderSubtitledVideo(
            videoURL: testVideoURL,
            subtitlesURL: complexAssURL,
            outputURL: complexOutputURL,
            quality: .medium,
            progressHandler: progressHandler
        )
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: complexOutputURL.path))
        XCTAssertGreaterThan(progressUpdates.count, 0)
        XCTAssertGreaterThanOrEqual(progressUpdates.last!, 0.99)
        
        // Cleanup
        try? FileManager.default.removeItem(at: complexOutputURL)
        try? FileManager.default.removeItem(at: complexAssURL)
    }
}
