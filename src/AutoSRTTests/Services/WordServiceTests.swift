import Foundation
import XCTest
import ZIPFoundation

@testable import AutoSRT

final class WordServiceTests: XCTestCase {
    var wordService: WordService!
    var translationService: TranslationService!
    var logger: LoggerService!
    var testBundle: Bundle!

    override func setUpWithError() throws {
        super.setUp()
        wordService = WordService.shared
        translationService = TranslationService.shared
        logger = LoggerService.shared
        testBundle = Bundle(for: type(of: self))
    }

    override func tearDownWithError() throws {
        wordService = nil
        testBundle = nil
        super.tearDown()
    }

    func testDetectLanguage() {
        // Test Asian languages
        XCTAssertEqual(wordService.detectLanguage(from: "你好世界"), .SimplifiedChinese)
        XCTAssertEqual(wordService.detectLanguage(from: "こんにちは"), .Japanese)
        XCTAssertEqual(wordService.detectLanguage(from: "안녕하세요"), .Korean)

        // Test Arabic and Russian
        XCTAssertEqual(wordService.detectLanguage(from: "مرحبا بالعالم"), .Arabic)
        XCTAssertEqual(wordService.detectLanguage(from: "Привет мир"), .Russian)

        // Test Latin-based languages
        XCTAssertEqual(wordService.detectLanguage(from: "¡Hola señor!"), .Spanish)
        XCTAssertEqual(wordService.detectLanguage(from: "Bonjour à tous"), .French)
        XCTAssertEqual(wordService.detectLanguage(from: "Schöne Grüße"), .German)
        XCTAssertEqual(wordService.detectLanguage(from: "Olá, como você está?"), .Portuguese)
        XCTAssertEqual(wordService.detectLanguage(from: "Ciao, come stai?"), .Italian)

        // Test English (default for basic Latin)
        XCTAssertEqual(wordService.detectLanguage(from: "Hello world"), .English)

        // Test mixed content
        XCTAssertEqual(wordService.detectLanguage(from: "Hello 你好"), .SimplifiedChinese)  // Should detect Chinese due to priority
        XCTAssertEqual(wordService.detectLanguage(from: "123 456"), .English)  // Should default to English for numbers

        // Test empty and whitespace
        XCTAssertEqual(wordService.detectLanguage(from: ""), .English)
        XCTAssertEqual(wordService.detectLanguage(from: "   "), .English)

        // Test numbers and special characters
        XCTAssertEqual(wordService.detectLanguage(from: "12345!@#$%"), .English)
    }

    func testParseWordDocument() async throws {
        // Create test directory
        let tempDirectory = FileManager.default.temporaryDirectory
        let testDocxPath = tempDirectory.appendingPathComponent("autogen_test.docx")

        // Create a simple Word document with known content
        let documentXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <pkg:package xmlns:pkg="http://schemas.microsoft.com/office/2006/xmlPackage">
                <pkg:part pkg:name="/word/document.xml" pkg:contentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml">
                    <pkg:xmlData>
                        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                            <w:body>
                                <w:p>
                                    <w:r>
                                        <w:t>First paragraph</w:t>
                                    </w:r>
                                </w:p>
                                <w:p>
                                    <w:r>
                                        <w:t>Second paragraph with </w:t>
                                    </w:r>
                                    <w:r>
                                        <w:t>multiple runs</w:t>
                                    </w:r>
                                </w:p>
                                <w:p>
                                    <w:r>
                                        <w:t>Third paragraph</w:t>
                                    </w:r>
                                </w:p>
                            </w:body>
                        </w:document>
                    </pkg:xmlData>
                </pkg:part>
            </pkg:package>
            """

        // Create a ZIP archive (docx) with the document.xml
        guard let archive = Archive(url: testDocxPath, accessMode: .create) else {
            XCTFail("Failed to create archive")
            return
        }

        let documentData = documentXML.data(using: .utf8)!
        try archive.addEntry(
            with: "word/document.xml", type: .file,
            uncompressedSize: UInt32(Int64(documentData.count)),
            provider: { position, size in
                return documentData.subdata(in: position..<position + size)
            })

        // Test parsing
        do {
            let paragraphs = try await wordService.parseWordDocument(testDocxPath)

            // Verify number of paragraphs
            XCTAssertEqual(paragraphs.count, 3, "Should have extracted 3 paragraphs")

            // Verify content of paragraphs
            XCTAssertEqual(paragraphs[0], "First paragraph")
            XCTAssertEqual(paragraphs[1], "Second paragraph with multiple runs")
            XCTAssertEqual(paragraphs[2], "Third paragraph")

        } catch let error as WordServiceError {
            switch error {
            case .fileNotFound:
                XCTFail("File not found: \(testDocxPath)")
            case .invalidFormat:
                XCTFail("Invalid format: Archive could not be read")
            case .processingError(let message):
                XCTFail("Processing error: \(message)")
            default:
                break
            }

        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Test invalid document
        let invalidPath = tempDirectory.appendingPathComponent("invalid.docx")
        do {
            _ = try await wordService.parseWordDocument(invalidPath)
            XCTFail("Should have thrown an error for invalid document")
        } catch WordServiceError.fileNotFound {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error.localizedDescription)")
        }

        // Clean up
        try? FileManager.default.removeItem(at: testDocxPath)
    }

    func testAlignmentSubtitles() async throws {
        
        Settings.shared.wordService.alignment = .all

        // Prepare test data with real paragraphs
        let paragraphs = [
            "William Ury is the co-founder of Harvard's Program on Negotiation, is one of the world's leading experts on negotiation and mediation.",
            "威廉·尤里是哈佛大学谈判项目联合创始人，也是世界权威谈判与调解专家之一。",
            "William is co-author of Getting to Yes, a fifteen-million-copy bestseller translated into over thirty-five languages, and the recent author of Getting to Yes with Yourself. Over the past four decades, William has served as a negotiation adviser and mediator in conflicts ranging from the Cold War to Venezuela to the Middle East. Recently, William has served as a senior advisor to Colombian President Juan Manuel Santos in helping to bring an end to the last and longest-running war in the Americas.",
            "威廉是《谈判力》（Getting to Yes）的作者之一，这本畅销书已售出1500万册，被翻译成超过35种语言。不久前，威廉又出版了新书《内向谈判力》（Getting to Yes with Yourself）。在过去40年里，威廉一直担任谈判顾问与调解人角色，处理过各类冲突，包括冷战、委内瑞拉和中东问题。最近，威廉作为哥伦比亚总统胡安·曼努埃尔·桑托斯的高级顾问，帮助结束了美洲持续时间最长的一场战争。",
        ]

        let subtitles = [
            Subtitle(
                startTime: 0,
                endTime: 2000,
                sourceText:
                    "William Urey is a co-founder of Harvard's program",
                translatedText: "威廉·尤里（William Urey）是联合创始人",
                index: 0),
            Subtitle(
                startTime: 2000,
                endTime: 4000,
                sourceText:
                    "the world's leading experts on negotiation and meditation. William is co-author",
                translatedText: "哈佛大学的谈判课程的联合创始人",
                index: 1),
            Subtitle(
                startTime: 4000,
                endTime: 6000,
                sourceText:
                    "of Getting to Yes, a 15 million copy bestseller translated into over 35",
                translatedText: "和世界上的一位著名的人物",
                index: 2),
            Subtitle(
                startTime: 4000,
                endTime: 6000,
                sourceText:
                    "of Getting to Yes, a 15 million copy bestseller translated into over 35",
                translatedText: "在谈判领域的领先专家",
                index: 3),
            Subtitle(
                startTime: 4000,
                endTime: 6000,
                sourceText:
                    "of Getting to Yes, a 15 million copy bestseller translated into over 35",
                translatedText: "谈判和冥想",
                index: 4),
        ]

        // Test alignment
        Settings.shared.wordService.minSimilarity = 0.2
        let alignedSubtitles = try await wordService.alignmentSubtitles(
            from: paragraphs, subtitles: subtitles)

        // Verify results
        XCTAssertEqual(alignedSubtitles.count, 5)

        // Test first subtitle
        XCTAssertTrue(alignedSubtitles[0].sourceText.contains("William Ury"))
        XCTAssertTrue(alignedSubtitles[0].translatedText.contains("威廉"))

        // Test second subtitle
        XCTAssertTrue(
            alignedSubtitles[1].sourceText.contains("world's leading experts on negotiation"))
        XCTAssertTrue(alignedSubtitles[1].translatedText.contains("谈判"))

        // Test third subtitle
        XCTAssertTrue(alignedSubtitles[2].sourceText.contains("Getting to Yes"))
        XCTAssertTrue(alignedSubtitles[2].translatedText.contains("作者"))

    }

    func testProcessWordDocument() async throws {
        
        // Create test subtitles
        let subtitles = [
            Subtitle(
                startTime: 0,
                endTime: 2000,
                sourceText: "William Ury is the co-founder of Harvard's Program on Negotiation",
                translatedText: "威廉·尤里是哈佛大学谈判项目联合创始人",
                index: 0),
            Subtitle(
                startTime: 2000,
                endTime: 4000,
                sourceText: "William is co-author of Getting to Yes",
                translatedText: "威廉是《谈判力》（Getting to Yes）的作者之一",
                index: 1),
        ]

        // Test with non-existent file
        let nonExistentURL = URL(fileURLWithPath: "/non/existent/path/test.docx")
        do {
            _ = try await wordService.processDocument(
                wordURL: nonExistentURL, subtitles: subtitles)
            XCTFail("Expected error for non-existent file")
        } catch WordServiceError.fileNotFound {
            // Expected error
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // Test with actual Word document
        guard let testDocxURL = testBundle.url(forResource: "Resources/test", withExtension: "docx") else {
            XCTFail("Test Word document not found in bundle")
            return
        }

        do {
            let processedSubtitles = try await wordService.processDocument(
                wordURL: testDocxURL, subtitles: subtitles)

            // Verify results
            XCTAssertEqual(processedSubtitles.count, subtitles.count)

            // Verify first subtitle
            XCTAssertEqual(processedSubtitles[0].startTime, subtitles[0].startTime)
            XCTAssertEqual(processedSubtitles[0].endTime, subtitles[0].endTime)
            XCTAssertEqual(processedSubtitles[0].index, subtitles[0].index)
            XCTAssertTrue(processedSubtitles[0].sourceText.contains("William"))
            XCTAssertTrue(processedSubtitles[0].translatedText.contains("威廉"))

            // Verify second subtitle
            XCTAssertEqual(processedSubtitles[1].startTime, subtitles[1].startTime)
            XCTAssertEqual(processedSubtitles[1].endTime, subtitles[1].endTime)
            XCTAssertEqual(processedSubtitles[1].index, subtitles[1].index)
            XCTAssertTrue(processedSubtitles[1].sourceText.contains("Getting to Yes"))
            XCTAssertTrue(processedSubtitles[1].translatedText.contains("谈判力"))

        } catch {
            XCTFail("Failed to process Word document: \(error)")
        }
    }

    func testParseTextDocument() async throws {
        // Create test directory
        let tempDirectory = FileManager.default.temporaryDirectory
        let testTextPath = tempDirectory.appendingPathComponent("test.txt")

        // Create test content
        let testContent = """
            First paragraph

            Second paragraph with
            multiple lines

            Third paragraph


            """

        // Write test content to file
        try testContent.write(to: testTextPath, atomically: true, encoding: .utf8)

        // Test parsing
        do {
            let paragraphs = try await wordService.parseTextDocument(testTextPath)

            // Verify number of paragraphs
            XCTAssertEqual(paragraphs.count, 4, "Should have extracted 4 paragraphs")

            // Verify content of paragraphs
            XCTAssertEqual(paragraphs[0], "First paragraph")
            XCTAssertEqual(paragraphs[1], "Second paragraph with")
            XCTAssertEqual(paragraphs[2], "multiple lines")
            XCTAssertEqual(paragraphs[3], "Third paragraph")

        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Test invalid file
        let invalidPath = tempDirectory.appendingPathComponent("invalid.txt")
        do {
            _ = try await wordService.parseTextDocument(invalidPath)
            XCTFail("Should have thrown an error for invalid file")
        } catch WordServiceError.fileNotFound {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error.localizedDescription)")
        }

        // Test empty file
        let emptyPath = tempDirectory.appendingPathComponent("empty.txt")
        try "".write(to: emptyPath, atomically: true, encoding: .utf8)

        do {
            let paragraphs = try await wordService.parseTextDocument(emptyPath)
            XCTAssertEqual(paragraphs.count, 0, "Empty file should return empty array")
        } catch WordServiceError.emptyDocument {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error.localizedDescription)")
        }

        // Clean up
        try? FileManager.default.removeItem(at: testTextPath)
        try? FileManager.default.removeItem(at: emptyPath)
    }

    func testTextToSentences() {
        // Test English text
        let englishText = "Hello world! This is a test. How are you? This is... interesting."
        let englishSentences = wordService.textToSentences(text: englishText, language: .English)
        XCTAssertEqual(
            englishSentences,
            [
                "Hello world!",
                "This is a test.",
                "How are you?",
                "This is... interesting.",
            ])

        // Test Chinese text
        let chineseText = "你好世界。这是一个测试。你好吗？这很有趣……"
        let chineseSentences = wordService.textToSentences(text: chineseText, language: .SimplifiedChinese)
        XCTAssertEqual(
            chineseSentences,
            [
                "你好世界。",
                "这是一个测试。",
                "你好吗？",
                "这很有趣……",
            ])

        // Test empty and whitespace text
        XCTAssertEqual(wordService.textToSentences(text: "", language: .English), [])
        XCTAssertEqual(wordService.textToSentences(text: "   ", language: .English), [])

        // Test single sentence without terminator
        XCTAssertEqual(
            wordService.textToSentences(text: "Hello world", language: .English), ["Hello world"])

        // Test text with multiple spaces and newlines
        let messyText = "Hello   world!  \n\n  This is   a test.  \n  How are you?"
        let cleanSentences = wordService.textToSentences(text: messyText, language: .English)
        XCTAssertEqual(
            cleanSentences,
            [
                "Hello world!",
                "This is a test.",
                "How are you?",
            ])

        // Test Japanese text
        let japaneseText = "こんにちは！テストです。元気ですか？面白いですね。"
        let japaneseSentences = wordService.textToSentences(text: japaneseText, language: .Japanese)
        XCTAssertEqual(
            japaneseSentences,
            [
                "こんにちは！",
                "テストです。",
                "元気ですか？",
                "面白いですね。",
            ])

        // Test complex English text with titles and proper nouns
        let complexText =
            "William is co-author of Getting to Yes: a fifteen-million-copy bestseller translated into over thirty-five languages, and the recent author of Getting to Yes with Yourself! Over the past four decades, William has served as a negotiation adviser and mediator in conflicts ranging from the Cold War to Venezuela to the Middle East. Recently, William has served as a senior advisor to Colombian President Juan Manuel Santos in helping to bring an end to the last and longest-running war in the Americas."
        let complexSentences = wordService.textToSentences(text: complexText, language: .English)
        XCTAssertEqual(
            complexSentences,
            [
                "William is co-author of Getting to Yes:",
                "a fifteen-million-copy bestseller translated into over thirty-five languages,",
                "and the recent author of Getting to Yes with Yourself!",
                "Over the past four decades,",
                "William has served as a negotiation adviser and mediator in conflicts ranging from the Cold War to Venezuela to the Middle East.",
                "Recently,",
                "William has served as a senior advisor to Colombian President Juan Manuel Santos in helping to bring an end to the last and longest-running war in the Americas.",
            ])

        // Test Chinese text with mixed English content
        let mixedChineseText =
            "威廉是《谈判力》（Getting to Yes）的作者之一：这本畅销书已售出1500 万册，被翻译成超过 35 种语言。不久前，威廉又出版了新书《内向谈判力》（Getting to Yes with Yourself）！在过去40年里，威廉一直担任谈判顾问与调解人角色，处理过各类冲突：包括冷战、委内瑞拉和中东问题。最近，威廉作为哥伦比亚总统胡安·曼努埃尔·桑托斯的高级顾问，帮助结束了美洲持续时间最长的一场战争。"
        let mixedChineseSentences = wordService.textToSentences(
            text: mixedChineseText, language: .SimplifiedChinese)
        XCTAssertEqual(mixedChineseSentences.count, 12)
        for i in 0..<11 {
            XCTAssertEqual(
                mixedChineseSentences[i],
                [
                    "威廉是《谈判力》（Getting to Yes）的作者之一：",
                    "这本畅销书已售出1500 万册，",
                    "被翻译成超过 35 种语言。",
                    "不久前，",
                    "威廉又出版了新书《内向谈判力》（Getting to Yes with Yourself）！",
                    "在过去40年里，",
                    "威廉一直担任谈判顾问与调解人角色，",
                    "处理过各类冲突：",
                    "包括冷战、委内瑞拉和中东问题。",
                    "最近，",
                    "威廉作为哥伦比亚总统胡安·曼努埃尔·桑托斯的高级顾问，",
                    "帮助结束了美洲持续时间最长的一场战争。",
                ][i])
        }
    }

    func testTextToWords() {
        // Test English text
        let englishText = "Hello, world! This is a test... How are you?"
        let englishWords = wordService.textToWords(text: englishText, language: .English)
        XCTAssertEqual(
            englishWords, ["Hello,", "world!", "This", "is", "a", "test...", "How", "are", "you?"])

        // Test Chinese text
        let chineseText = "你好世界。这是一个测试！"
        let chineseWords = wordService.textToWords(text: chineseText, language: .SimplifiedChinese)
        XCTAssertEqual(chineseWords, ["你", "好", "世", "界", "。", "这", "是", "一", "个", "测", "试", "！"])

        // Test mixed text
        let mixedText = "Hello 你好 world!"
        let mixedChineseWords = wordService.textToWords(text: mixedText, language: .SimplifiedChinese)
        XCTAssertEqual(
            mixedChineseWords,
            ["H", "e", "l", "l", "o", " ", "你", "好", " ", "w", "o", "r", "l", "d", "!"])
        let mixedEnglishWords = wordService.textToWords(text: mixedText, language: .English)
        XCTAssertEqual(mixedEnglishWords, ["Hello", "你好", "world!"])

        // Test text with multiple spaces and newlines
        let spacedText = "  Hello   world  \n  test  "
        let spacedWords = wordService.textToWords(text: spacedText, language: .English)
        XCTAssertEqual(spacedWords, ["Hello", "world", "test"])

        // Test empty text
        let emptyText = ""
        let emptyWords = wordService.textToWords(text: emptyText, language: .English)
        XCTAssertEqual(emptyWords, [])
    }

    func testSimilarityScoreBasic() async throws {
        // Test empty strings
        let emptyScore = try await wordService.getSimilarityScore(text1: "", text2: "", language: .English)
        XCTAssertEqual(emptyScore, 0.0)

        // Test identical strings
        let identicalScore = try await wordService.getSimilarityScore(text1: "test", text2: "test", language: .English)
        XCTAssertEqual(identicalScore, 1.0)

        // Test simple English strings
        let englishScore = try await wordService.getSimilarityScore(text1: "hello world", text2: "hello earth", language: .English)
        XCTAssertGreaterThanOrEqual(englishScore, 0.5)

        // Test simple Chinese strings
        let chineseScore = try await wordService.getSimilarityScore(text1: "你好世界", text2: "你好地球", language: .SimplifiedChinese)
        XCTAssertGreaterThanOrEqual(chineseScore, 0.5)

        // Test mixed language strings
        let mixedScore = try await wordService.getSimilarityScore(text1: "Hello 世界", text2: "Hello 地球", language: .SimplifiedChinese)
        XCTAssertGreaterThan(mixedScore, 0.5)
    }

    func testSimilarityScoreWithEmbedding() async throws {

        // Test English sentences
        let englishSentences = [
            ("The cat sat on the mat.", "A cat is sitting on a mat."),
            ("I love programming in Swift.", "Swift programming is my passion."),
            ("This is a completely different sentence.", "The weather is nice today."),
            ("Hello world!", "Hello world."),
        ]

        for (text1, text2) in englishSentences {
            let score = try await wordService.getSimilarityScore(text1: text1, text2: text2, language: .English)
            XCTAssertGreaterThanOrEqual(score, 0.0, "Similarity score should be >= 0")
            XCTAssertLessThanOrEqual(score, 1.0, "Similarity score should be <= 1")

            // Similar sentences should have higher scores
            if text1.contains("cat") && text2.contains("cat") {
                XCTAssertGreaterThan(
                    score, 0.7, "Similar sentences about cats should have high similarity")
            }
            if text1 == "Hello world!" && text2 == "Hello world." {
                XCTAssertGreaterThan(
                    score, 0.9, "Nearly identical sentences should have very high similarity")
            }
            if text1.contains("different") && text2.contains("weather") {
                XCTAssertLessThan(score, 0.5, "Different sentences should have low similarity")
            }
        }

        // Test Chinese sentences
        let chineseSentences = [
            ("我喜欢编程", "我热爱写代码"),
            ("今天天气很好", "今天是个好天气"),
            ("这是完全不同的句子", "猫在垫子上"),
            ("你好世界！", "你好世界。"),
            ("在过去两年里", "在过去的七八年里"),
            ("在过去两年里", "过去两年的时间里"),
        ]
        
        var s1 = try await wordService.getSimilarityScore(text1: "在过去两年里", text2: "过去两年的时间里", language: .SimplifiedChinese)
        var s2 = try await wordService.getSimilarityScore(text1: "在过去两年里", text2: "在过去的七八年里", language: .SimplifiedChinese)
        XCTAssertGreaterThanOrEqual(s1, s2)
            

        for (text1, text2) in chineseSentences {
            let score = try await wordService.getSimilarityScore(text1: text1, text2: text2, language: .SimplifiedChinese)
            XCTAssertGreaterThanOrEqual(score, 0.0, "Similarity score should be >= 0")
            XCTAssertLessThanOrEqual(score, 1.0, "Similarity score should be <= 1")

            // Similar sentences should have higher scores
            if text1.contains("编程") && text2.contains("代码") {
                XCTAssertGreaterThan(
                    score, 0.7, "Similar sentences about programming should have high similarity")
            }
            if text1.contains("天气") && text2.contains("天气") {
                XCTAssertGreaterThan(
                    score, 0.8, "Similar sentences about weather should have high similarity")
            }
            if text1 == "你好世界！" && text2 == "你好世界。" {
                XCTAssertGreaterThan(
                    score, 0.9, "Nearly identical sentences should have very high similarity")
            }
            if text1.contains("不同") && text2.contains("猫") {
                XCTAssertLessThan(score, 0.5, "Different sentences should have low similarity")
            }
        }
    }

    func testSimilarityScoreWithoutEmbedding() async throws {
        // Test English sentences
        let englishSentences = [
            ("The cat sat on the mat.", "A cat is sitting on a mat."),
            ("Hello world!", "Hello world."),
            ("This is different.", "That is different."),
        ]

        for (text1, text2) in englishSentences {
            let score = try await wordService.getSimilarityScore(text1: text1, text2: text2, language: .English)
            XCTAssertGreaterThanOrEqual(score, 0.0, "Similarity score should be >= 0")
            XCTAssertLessThanOrEqual(score, 1.0, "Similarity score should be <= 1")
        }

        // Test Chinese sentences
        let chineseSentences = [
            ("我喜欢编程", "我热爱写代码"),
            ("你好世界！", "你好世界。"),
        ]

        for (text1, text2) in chineseSentences {
            let score = try await wordService.getSimilarityScore(text1: text1, text2: text2, language: .SimplifiedChinese)
            XCTAssertGreaterThanOrEqual(score, 0.0, "Similarity score should be >= 0")
            XCTAssertLessThanOrEqual(score, 1.0, "Similarity score should be <= 1")
        }
    }

    func testImportSubtitles() async throws {
        // Create a temporary SRT file
        let tempDir = FileManager.default.temporaryDirectory
        let srtURL = tempDir.appendingPathComponent("test.srt")

        // Sample SRT content with different formats and encodings
        let srtContent = """
            1
            00:00:01,000 --> 00:00:04,000
            First subtitle
            Second line

            2
            00:00:05,500 --> 00:00:07,800
            Second subtitle

            3
            00:01:00,000 --> 00:01:30,000
            Third subtitle
            With multiple
            Lines of text
            """

        try srtContent.write(to: srtURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: srtURL)
        }

        // Test successful import
        let subtitles = try await wordService.importSubtitles(srtURL: srtURL, language: .English) {
            _, _ in
        }

        // Verify subtitle count
        XCTAssertEqual(subtitles.count, 3, "Should have imported 3 subtitles")

        // Verify first subtitle
        XCTAssertEqual(subtitles[0].startTime, 1.0, "First subtitle should start at 1.0 seconds")
        XCTAssertEqual(subtitles[0].endTime, 4.0, "First subtitle should end at 4.0 seconds")
        XCTAssertEqual(
            subtitles[0].sourceText, "First subtitle\nSecond line",
            "First subtitle text should match")
        XCTAssertEqual(subtitles[0].index, 0, "First subtitle should have index 0")

        // Verify second subtitle
        XCTAssertEqual(subtitles[1].startTime, 5.5, "Second subtitle should start at 5.5 seconds")
        XCTAssertEqual(subtitles[1].endTime, 7.8, "Second subtitle should end at 7.8 seconds")
        XCTAssertEqual(
            subtitles[1].sourceText, "Second subtitle", "Second subtitle text should match")
        XCTAssertEqual(subtitles[1].index, 1, "Second subtitle should have index 1")

        // Verify third subtitle
        XCTAssertEqual(subtitles[2].startTime, 60.0, "Third subtitle should start at 60.0 seconds")
        XCTAssertEqual(subtitles[2].endTime, 90.0, "Third subtitle should end at 90.0 seconds")
        XCTAssertEqual(
            subtitles[2].sourceText, "Third subtitle\nWith multiple\nLines of text",
            "Third subtitle text should match")
        XCTAssertEqual(subtitles[2].index, 2, "Third subtitle should have index 2")

        // Test error cases
        // Non-existent file
        let nonExistentURL = tempDir.appendingPathComponent("nonexistent.srt")
        do {
            _ = try await wordService.importSubtitles(srtURL: nonExistentURL, language: .English) {
                _, _ in
            }
            XCTFail("Should throw error for non-existent file")
        } catch WordServiceError.fileNotFound {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Empty file
        let emptyURL = tempDir.appendingPathComponent("empty.srt")
        try "".write(to: emptyURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: emptyURL)
        }

        do {
            _ = try await wordService.importSubtitles(srtURL: emptyURL, language: .English) {
                _, _ in
            }
            XCTFail("Should throw error for empty file")
        } catch WordServiceError.emptyDocument {
            // Expected error
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        // Test with SRT file content
        let srtContent2 = """
            1
            00:00:05,900 --> 00:00:06,766
            William Yuri

            2
            00:00:06,766 --> 00:00:10,266
            is a co founder of Harvard's Program on negotiation

            3
            00:00:10,333 --> 00:00:11,666
            and is one of the world's

            4
            00:00:11,666 --> 00:00:13,600
            leading experts on negotiation

            5
            00:00:13,600 --> 00:00:14,700
            and meditation

            6
            00:00:15,066 --> 00:00:18,300
            William is co author of getting to yes
            """
        let srtURL2 = tempDir.appendingPathComponent("test2.srt")
        try srtContent2.write(to: srtURL2, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: srtURL2)
        }

        // Test successful import
        let subtitles2 = try await wordService.importSubtitles(srtURL: srtURL2, language: .English)
        { _, _ in }

        // Verify subtitle count
        XCTAssertEqual(subtitles2.count, 6, "Should have imported 6 subtitles")

    }

    func testLevenshteinDistance() {
        // Test identical strings
        XCTAssertEqual(
            wordService.levenshteinDistance("hello", "hello"), 0,
            "Identical strings should have distance 0")

        // Test single character differences
        XCTAssertEqual(wordService.levenshteinDistance("hello", "helo"), 1, "Single deletion")
        XCTAssertEqual(wordService.levenshteinDistance("hello", "helllo"), 1, "Single insertion")
        XCTAssertEqual(wordService.levenshteinDistance("hello", "hallo"), 1, "Single substitution")

        // Test multiple differences
        XCTAssertEqual(
            wordService.levenshteinDistance("kitten", "sitting"), 3, "Multiple operations")
        XCTAssertEqual(
            wordService.levenshteinDistance("saturday", "sunday"), 3, "Multiple operations")

        // Test empty strings
        XCTAssertEqual(
            wordService.levenshteinDistance("", ""), 0, "Empty strings should have distance 0")
        XCTAssertEqual(
            wordService.levenshteinDistance("hello", ""), 5,
            "Distance to empty string should equal length")
        XCTAssertEqual(
            wordService.levenshteinDistance("", "hello"), 5,
            "Distance from empty string should equal length")

        // Test case sensitivity
        XCTAssertEqual(
            wordService.levenshteinDistance("Hello", "hello"), 1, "Should be case sensitive")

        // Test strings with spaces
        XCTAssertEqual(
            wordService.levenshteinDistance("hello world", "hello  world"), 1, "Extra space")
        XCTAssertEqual(
            wordService.levenshteinDistance("hello world", "helloworld"), 1, "Missing space")

        // Test Chinese characters
        XCTAssertEqual(wordService.levenshteinDistance("你好", "你"), 1, "Chinese character deletion")
        XCTAssertEqual(
            wordService.levenshteinDistance("你好", "你好啊"), 1, "Chinese character insertion")
        XCTAssertEqual(
            wordService.levenshteinDistance("你好", "你们"), 1, "Chinese character substitution")

        // Test mixed language
        XCTAssertEqual(
            wordService.levenshteinDistance("hello你好", "hello你"), 1, "Mixed language deletion")
        XCTAssertEqual(
            wordService.levenshteinDistance("hello你好", "hello你好啊"), 1, "Mixed language insertion")

        // Test Levenshtein Distance on Chinese text
        var s1 = "威廉·尤里是联合创始人"
        var s2 =
            "威廉·尤里（William Urey）是哈佛大学谈判项目联合创始人，也是世界权威谈判与调解专家之一。他的著作《Getting to Yes》在全球广受欢迎，被誉为谈判圣经。"
        XCTAssertEqual(
            wordService.levenshteinDistance(s1, s2), 75,
            "Levenshtein distance of two Chinese strings should be 75")

        // Test Levenshtein Distance on Chinese text
        s1 = "内向"
        s2 =
            "判断力"
        let count = wordService.levenshteinDistance(s1, s2)
        XCTAssertGreaterThan(
            count, 2,
            "Levenshtein distance of two Chinese strings should be 7")

        // Test text with multiple typos
        let originalText = "What does it actually mean?"
        let misspelledText = "what doesitachualymean?"
        XCTAssertEqual(
            wordService.levenshteinDistance(originalText, misspelledText),
            6,
            "Text with multiple typos and missing spaces should have correct distance"
        )

        // Test longer text with multiple typos and missing spaces
        let originalLongText = "This text appears to be a poetic or philosophical passage and its meaning can be subjective."
        let misspelledLongText = "Thistetapeans tobe apoeticorphmlosophicalpeasage andis meanmng can besubecive."
        XCTAssertGreaterThanOrEqual(
            wordService.levenshteinDistance(originalLongText, misspelledLongText),
            19,
            "Long text with multiple typos should have significant Levenshtein distance"
        )
    }
}
