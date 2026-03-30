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

    func testTranslateText() async throws {
        // Given
        let fromLanguage = "English"
        let toLanguage = "Spanish"
        let inputText = "Hello, how are you?"
        let model = "mistral"

        translationService.clearChatHistory()
        // When
        let translatedText = try await translationService.translateText(
            fromLanguage: fromLanguage,
            toLanguage: toLanguage,
            inputText,
            model: model
        )

        // Then
        XCTAssertFalse(translatedText.isEmpty)
        XCTAssertNotEqual(translatedText, inputText)
    }

    func testTranslateTextWithEmptyInput() async {
        // Given
        let fromLanguage = "English"
        let toLanguage = "Spanish"
        let inputText = ""
        let model = "mistral"

        // When/Then
        do {
            _ = try await translationService.translateText(
                fromLanguage: fromLanguage,
                toLanguage: toLanguage,
                inputText,
                model: model
            )
            XCTFail("Expected error for empty input")
        } catch {
            // Success - error was thrown as expected
        }
    }

    func testTranslateTextMaintainsChatHistory() async throws {
        // Given
        let fromLanguage = "English"
        let toLanguage = "Spanish"
        let inputText = "Hello, how are you?"
        let model = "mistral"

        translationService.clearChatHistory()
        // When
        let translatedText = try await translationService.translateText(
            fromLanguage: fromLanguage,
            toLanguage: toLanguage,
            inputText,
            model: model
        )

        // Then
        XCTAssertEqual(translationService.chatHistory.count, 2)  // User message + Assistant message
        XCTAssertEqual(translationService.chatHistory[0].role, .user)
        XCTAssertEqual(translationService.chatHistory[0].content, inputText)
        XCTAssertEqual(translationService.chatHistory[1].role, .assistant)
        XCTAssertEqual(translationService.chatHistory[1].content, translatedText)
    }

    func testTranslateSubtitleText() async throws {
        // Given
        let fromLanguage = "English"
        let toLanguage = "Chinese"
        let inputTexts = [
            "William Ury is a co-founder ",
            "of Harvard's program On Negotiation ",
            "and is one of the world's ",
            "leading experts on ",
            "negotiation and meditation. ",
            "William is co-author of ",
            "Getting to Yes, a 15 million ",
            "copy bestseller translated "
        ]
        let model = Settings.shared.translationService.model

        translationService.clearChatHistory()
        for (idx, inputText) in inputTexts.enumerated() {
            let translatedText = try await translationService.translateText(
                fromLanguage: fromLanguage,
                toLanguage: toLanguage,
                inputText,
                model: model
            )

            // Then
            XCTAssertFalse(translatedText.isEmpty)
            XCTAssertNotEqual(translatedText, inputText)
        } 
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
        let model = Settings.shared.translationService.model
        var progressUpdates: [(String, Double)] = []

        // When
        let translatedSubtitles = try await translationService.translateSubtitles(
            subtitles,
            fromLanguage: fromLanguage,
            toLanguage: toLanguage,
            model: model
        ) { message, progress in
            progressUpdates.append((message, progress))
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
        XCTAssertEqual(progressUpdates.last?.1, 1.0) // Final progress should be 1.0
        XCTAssertTrue(progressUpdates.last?.0.contains("Translation completed") ?? false)
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
        
        let model = Settings.shared.translationService.model
        var progressUpdates: [(String, Double)] = []

        // When
        let translatedSubtitles = try await translationService.translateSubtitles(
            subtitles,
            fromLanguage: fromLanguage,
            toLanguage: toLanguage,
            model: model
        ) { message, progress in
            progressUpdates.append((message, progress))
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
        XCTAssertEqual(progressUpdates.last?.1, 1.0)
        XCTAssertTrue(progressUpdates.last?.0.contains("Translation completed") ?? false)
        
        // Verify some progress updates contain the actual translation text
        let translationUpdates = progressUpdates.filter { $0.0.contains("->") }
        XCTAssertEqual(translationUpdates.count, subtitles.count)
    }
}
