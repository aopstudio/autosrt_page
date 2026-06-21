import XCTest
@testable import AutoSRT

final class SummaryServiceTests: XCTestCase {
    var summaryService: SummaryService!
    var mockSubtitles: [Subtitle]!
    
    override func setUp() {
        super.setUp()
        summaryService = SummaryService.shared
        
        // Create mock subtitles
        mockSubtitles = [
            Subtitle(
                startTime: 0,
                endTime: 5,
                sourceText: "Hello, welcome to this video about Swift programming.",
                translatedText: ""
            ),
            Subtitle(
                startTime: 5,
                endTime: 10,
                sourceText: "Today we'll learn about async/await and how it makes concurrent programming easier.",
                translatedText: ""
            ),
            Subtitle(
                startTime: 10,
                endTime: 15,
                sourceText: "Let's start by looking at a simple example.",
                translatedText: ""
            )
        ]
    }
    
    override func tearDown() {
        mockSubtitles = nil
        super.tearDown()
    }
    
    func testSummarizeSubtitles() async throws {
        // Given
        let language = "English"
        let model = Settings.shared.llmService.chatModel
        var progressUpdates: [(String, Double)] = []
        
        // When
        let summary = try await summaryService.summarizeSubtitles(
            mockSubtitles,
            language: language,
            model: model
        ) { message, progress in
            progressUpdates.append((message, progress))
        }
        
        // Then
        XCTAssertFalse(summary.isEmpty, "Summary should not be empty")
        XCTAssertTrue(summary.contains("Swift"), "Summary should contain key content words")
        XCTAssertTrue(summary.contains("programming"), "Summary should contain key content words")
        
        // Verify progress updates
        XCTAssertFalse(progressUpdates.isEmpty, "Should receive progress updates")
        XCTAssertEqual(progressUpdates.first?.1, 0.5, "First progress update should be 0.5")
        XCTAssertEqual(progressUpdates.last?.1, 1.0, "Last progress update should be 1.0")
        XCTAssertEqual(progressUpdates.last?.0, "Summary generated", "Last message should indicate completion")
    }
    
    func testSummarizeEmptySubtitles() async {
        // Given
        let emptySubtitles: [Subtitle] = []
        
        // When/Then
        do {
            _ = try await summaryService.summarizeSubtitles(
                emptySubtitles,
                language: "English",
                model: Settings.shared.llmService.chatModel
            ) { _, _ in }
            XCTFail("Should throw an error for empty subtitles")
        } catch {
            // Expected to throw
            XCTAssertNotNil(error, "Should throw an error for empty subtitles")
        }
    }
    
    func testSummarizeWithInvalidModel() async {
        // Given
        let invalidModel = "nonexistent_model"
        
        // When/Then
        do {
            _ = try await summaryService.summarizeSubtitles(
                mockSubtitles,
                language: "English",
                model: invalidModel
            ) { _, _ in }
            XCTFail("Should throw an error for invalid model")
        } catch {
            // Expected to throw
            XCTAssertNotNil(error, "Should throw an error for invalid model")
        }
    }
    
    func testSummarizeLongSubtitles() async throws {
        // Given
        let longText = """
            In the beginning of computer programming, we wrote code in a very sequential way. Each instruction would wait for the previous one to complete before starting. This was simple to understand but not very efficient, especially when dealing with tasks that take a long time, like downloading files or making network requests.

            Then came the era of concurrent programming, where we could run multiple tasks at the same time. This made our programs faster, but it also made them more complex. We had to deal with concepts like threads, locks, and race conditions. It was easy to make mistakes that would cause our programs to crash or behave unpredictably.

            This is where async/await comes in. It's a modern way to write concurrent code that's both efficient and easy to understand. When you mark a function as async, you're telling Swift that this function might take some time to complete, and that other code can run while it's working.

            The 'await' keyword is used when calling an async function. It's like saying "wait here until this operation is done before continuing." But unlike traditional blocking code, other tasks can still run while we're waiting. This is particularly useful in user interfaces, where we want to keep the app responsive while doing heavy work in the background.

            Swift's async/await also introduces structured concurrency. This means we can better manage the lifetime of concurrent tasks and handle errors more gracefully. For example, if we start multiple concurrent operations, we can easily wait for all of them to complete or cancel them if something goes wrong.

            One of the best things about async/await is how it makes concurrent code look almost as simple as synchronous code. You don't need to deal with completion handlers or callback closures. The code reads from top to bottom, making it easier to understand and maintain.

            However, async/await isn't magic. You still need to think about concurrency and how different parts of your program interact. The difference is that the language now helps you express these concepts more clearly and with fewer opportunities for errors.

            Let's look at some common patterns. Task groups allow you to run multiple operations concurrently and collect their results. Actors help you manage shared state safely. And async sequences let you work with streams of values over time, like processing items in a collection one by one.

            Testing async code is also easier with async/await. You can write tests that look very similar to your production code, and Swift provides tools to help you control timing and simulate different scenarios.

            As we wrap up, remember that async/await is a powerful tool that makes concurrent programming more accessible. It's not about making everything async – it's about having better tools to handle operations that naturally take time to complete.
            """
        
        var longSubtitles: [Subtitle] = []
        let sentences = longText.components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        // Create subtitles with 5-second intervals
        for (index, sentence) in sentences.enumerated() {
            let subtitle = Subtitle(
                startTime: TimeInterval(index * 5),
                endTime: TimeInterval((index + 1) * 5),
                sourceText: sentence + ".",
                translatedText: ""
            )
            longSubtitles.append(subtitle)
        }
        
        // When
        var progressUpdates: [(String, Double)] = []
        let summary = try await summaryService.summarizeSubtitles(
            longSubtitles,
            language: "English",
            model: Settings.shared.llmService.chatModel
        ) { message, progress in
            progressUpdates.append((message, progress))
        }
        
        // Then
        XCTAssertFalse(summary.isEmpty, "Summary should not be empty")
        XCTAssertTrue(summary.contains("async"), "Summary should contain key content words")
        XCTAssertTrue(summary.contains("concurrent"), "Summary should contain key content words")
        
        // Verify chunking behavior through progress updates
        XCTAssertGreaterThan(progressUpdates.count, 2, "Should have multiple progress updates for chunks")
        
        // Verify we got updates for multiple parts
        let partUpdates = progressUpdates.filter { $0.0.contains("Generating summary for part") }
        XCTAssertGreaterThan(partUpdates.count, 1, "Should process multiple parts")
        
        // Verify final summary generation
        XCTAssertTrue(
            progressUpdates.contains { $0.0 == "Generating final summary..." },
            "Should generate final summary for multiple chunks"
        )
        
        // Verify completion
        XCTAssertEqual(progressUpdates.last?.0, "Summary generated", "Last message should indicate completion")
        XCTAssertEqual(progressUpdates.last?.1, 1.0, "Final progress should be 1.0")
    }
    
    func testGenerateTitle() async throws {
        // Given
        let text = """
            Swift's async/await introduces structured concurrency, making asynchronous programming more manageable. 
            It simplifies complex operations while maintaining performance. The new syntax eliminates callback hell 
            and makes error handling more straightforward.
            """
        let language = "English"
        let model = Settings.shared.llmService.chatModel
        
        // When
        let title = try await summaryService.generateTitle(
            text: text,
            language: language,
            model: model
        )
        
        // Then
        XCTAssertFalse(title.isEmpty, "Title should not be empty")
        XCTAssertLessThan(title.count, 50*4, "Title should not exceed default max length")
        XCTAssertTrue(
            title.contains("Swift") || title.contains("async"),
            "Title should contain relevant keywords"
        )
    }
    
    func testGenerateTitleWithCustomLength() async throws {
        // Given
        let text = "This is a test text that should generate a very short title."
        let maxLength = 20
        
        // When
        let title = try await summaryService.generateTitle(
            text: text,
            language: "English",
            model: Settings.shared.llmService.chatModel,
            maxLength: maxLength
        )
        
        // Then
        XCTAssertLessThanOrEqual(
            title.count,
            maxLength,
            "Title should not exceed specified max length"
        )
    }
    
    func testGenerateTitleWithEmptyText() async throws {
        // Given
        let emptyText = ""
        
        // When/Then
        do {
            _ = try await summaryService.generateTitle(
                text: emptyText,
                language: "English",
                model: Settings.shared.llmService.chatModel
            )
            XCTFail("Should throw an error for empty text")
        } catch {
            // Expected to throw
            XCTAssertNotNil(error, "Should throw an error for empty text")
        }
    }
    
    func testGenerateTitleInDifferentLanguages() async throws {
        // Given
        let text = "This is a sample text that should be titled in different languages."
        let languages = ["English", "Spanish", "French", "German"]
        let model = Settings.shared.llmService.chatModel
        
        // When/Then
        for language in languages {
            let title = try await summaryService.generateTitle(
                text: text,
                language: language,
                model: model
            )
            
            // Then
            XCTAssertFalse(title.isEmpty, "Title should not be empty for \(language)")
            XCTAssertTrue(title.count <= 50, "Title should not exceed max length for \(language)")
        }
    }
}
