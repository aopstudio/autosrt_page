import XCTest

@testable import AutoSRT

final class TranslationServiceTests: XCTestCase {
    var translationService: TranslationService!

    override func setUp() {
        super.setUp()
        translationService = TranslationService.shared
    }

    override func tearDown() {
        translationService = nil
        super.tearDown()
    }

    func testTranslateSubtitles() async throws {
        // Given
        let fromLanguage = "English"
        let toLanguage = "Chinese"
        let subtitles = [
            Subtitle(startTime: 0.0, endTime: 2.0, sourceText: "Hello, welcome to", translatedText: ""),
            Subtitle(startTime: 2.0, endTime: 4.0, sourceText: "our presentation about", translatedText: ""),
            Subtitle(startTime: 4.0, endTime: 6.0, sourceText: "artificial intelligence", translatedText: ""),
            Subtitle(startTime: 6.0, endTime: 8.0, sourceText: "and its applications", translatedText: "")
        ]
        let model = Settings.shared.llmService.chatModel
        var progressUpdates: [(Double, String)] = []

        // When
        let translatedSubtitles = try await translationService.translateSubtitles(
            subtitles,
            fromLanguage: fromLanguage,
            toLanguage: toLanguage,
            model: model
        ) { progress, message in
            progressUpdates.append((progress, message))
        }

        // Then
        XCTAssertEqual(translatedSubtitles.count, subtitles.count)
        for (index, subtitle) in translatedSubtitles.enumerated() {
            XCTAssertEqual(subtitle.startTime, subtitles[index].startTime)
            XCTAssertEqual(subtitle.endTime, subtitles[index].endTime)
            XCTAssertEqual(subtitle.sourceText, subtitles[index].sourceText)
            XCTAssertFalse(subtitle.translatedText.isEmpty)
            XCTAssertNotEqual(subtitle.translatedText, subtitle.sourceText)
        }

        // Verify progress updates
        XCTAssertTrue(progressUpdates.count >= subtitles.count)
        XCTAssertEqual(progressUpdates.last?.0, 1.0) // Final progress should be 1.0
        XCTAssertTrue(progressUpdates.last?.1.contains("Translation completed") ?? false)
    }

    func testTranslateSubtitlesWithContext() async throws {
        // Given
        let fromLanguage = "English"
        let toLanguage = "Chinese"
        var startTime = 0.0
        let subtitles = [
            "William Ury is a co-founder ",
            "of Harvard's program On Negotiation ",
            "and is one of the world's ",
            "leading experts on ",
            "negotiation and meditation. ",
            "William is co-author of ",
            "Getting to Yes, a 15 million ",
            "copy bestseller translated "
        ].enumerated().map { index, text in
            let start = startTime
            startTime += 2.0  // Each subtitle is 2 seconds long
            return Subtitle(startTime: start, endTime: startTime, sourceText: text, translatedText: "")
        }

        let model = Settings.shared.llmService.chatModel
        var progressUpdates: [(Double, String)] = []

        // When
        let translatedSubtitles = try await translationService.translateSubtitles(
            subtitles,
            fromLanguage: fromLanguage,
            toLanguage: toLanguage,
            model: model
        ) { progress, message in
            progressUpdates.append((progress, message))
        }

        // Then
        XCTAssertEqual(translatedSubtitles.count, subtitles.count)

        // Verify each subtitle
        for (index, subtitle) in translatedSubtitles.enumerated() {

            // Check content
            XCTAssertEqual(subtitle.sourceText, subtitles[index].sourceText)
            XCTAssertFalse(subtitle.translatedText.isEmpty)
            XCTAssertNotEqual(subtitle.translatedText, subtitle.sourceText)
        }

        // Verify progress tracking
        XCTAssertTrue(progressUpdates.count >= subtitles.count)
        XCTAssertEqual(progressUpdates.last?.0, 1.0)
        XCTAssertTrue(progressUpdates.last?.1.contains("Translation completed") ?? false)

        // Verify some progress updates contain the actual translation text
        let translationUpdates = progressUpdates.filter { $0.1.contains("->") }
        XCTAssertEqual(translationUpdates.count, subtitles.count)
    }

    func testSplitText() {
        // Test simple text splitting
        let longText = "This is a very long text that should be split into multiple lines because it exceeds the maximum characters per line limit."
        let split = translationService.splitText(longText, maxCharactersPerLine: 40)
        let lines = split.components(separatedBy: "\n")
        XCTAssertTrue(lines.count > 1, "Long text should be split into multiple lines")
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 40, "Each line should not exceed max characters")
        }
    }

    func testSplitTextShortText() {
        // Short text should not be split
        let shortText = "Hello world"
        let split = translationService.splitText(shortText, maxCharactersPerLine: 40)
        XCTAssertEqual(split, shortText, "Short text should not be split")
    }
}
