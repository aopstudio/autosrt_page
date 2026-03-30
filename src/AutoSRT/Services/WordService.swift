import AppKit
// Add CFString for GBK encoding
import CoreFoundation
import Foundation
import OSLog
import ZIPFoundation

enum WordServiceError: Error {
    case fileNotFound
    case invalidFormat
    case processingError(String)
    case emptyDocument

    var localizedDescription: String {
        switch self {
        case .fileNotFound:
            return "Word document not found"
        case .invalidFormat:
            return "Invalid Word document format"
        case .processingError(let message):
            return "Processing error: \(message)"
        case .emptyDocument:
            return "Document is empty"
        }
    }
}

class WordService {
    static let shared = WordService()
    private let logger = LoggerService.shared
    private let translationService = TranslationService.shared
    private let embeddingService = EmbeddingService.shared
    private let cacheLock = NSLock()
    private var sentenceEmbeddings = [String: [Float]]()

    private init() {
    }

    private func getEmbedding(text: String) async throws -> [Float] {
        // Thread-safe cache access
        cacheLock.lock()
        if let cached = sentenceEmbeddings[text] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // Get new embedding
        let embedding = try await embeddingService.getEmbedding(for: text)

        // Thread-safe cache update
        cacheLock.lock()
        sentenceEmbeddings[text] = embedding
        cacheLock.unlock()

        return embedding
    }

    func processDocument(
        wordURL: URL, subtitles: [Subtitle],
        progressCallback: @escaping (String, Double) -> Void = { _, _ in }
    ) async throws -> [Subtitle] {
        logger.log("Processing document: \(wordURL.lastPathComponent)")
        let startTime = Date()
        progressCallback("Processing document...", 0.0)

        // Verify files exist
        guard FileManager.default.fileExists(atPath: wordURL.path) else {
            logger.log("Document not found at: \(wordURL.path)")
            throw WordServiceError.fileNotFound
        }

        // load model
        try await embeddingService.loadModel()

        do {
            // Extract text from Word document
            progressCallback("Extracting text from document...", 0.1)
            var paragraphs: [String] = []
            if wordURL.pathExtension.lowercased() == "docx" {
                paragraphs = try await parseWordDocument(wordURL)
            } else {
                paragraphs = try await parseTextDocument(wordURL)
            }
            let extractTime = Date().timeIntervalSince(startTime)
            logger.log(
                "Extracted \(paragraphs.count) paragraphs from Word document \(wordURL.lastPathComponent) (Time: \(String(format: "%.1fs", extractTime)))"
            )
            progressCallback(
                "Extracted \(paragraphs.count) paragraphs (Time: \(String(format: "%.1fs", extractTime)))",
                0.4)

            // Generate source and translated subtitles
            progressCallback("Aligning subtitles with paragraphs...", 0.2)
            let editedSubtitles = try await alignmentSubtitles(
                from: paragraphs, subtitles: subtitles
            ) { subtitle, progress in
                let overallProgress = 0.2 + (0.8 * progress)
                let currentTime = Date().timeIntervalSince(startTime)
                progressCallback(
                    "Alignment \(subtitle.index + 1)/\(subtitles.count) (\((subtitle.index + 1) * 100 / subtitles.count)%) (Time: \(String(format: "%.1fs", currentTime))): \(subtitle.sourceText)(\(subtitle.translatedText)) ",
                    overallProgress)
            }

            // Return the subtitles
            let totalTime = Date().timeIntervalSince(startTime)
            progressCallback(
                "Processing completed (Total time: \(String(format: "%.1fs", totalTime)))", 1.0)
            logger.log(
                "Document processing completed in \(String(format: "%.1fs", totalTime))")

            // Show completion notification
            let notification = NSUserNotification()
            notification.title = "Subtitle aligment."
            notification.subtitle = "Time spent: \(String(format: "%.1fs", totalTime))"
            notification.informativeText = "Next to edit it or render Video."
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)

            return editedSubtitles
        } catch {
            let errorTime = Date().timeIntervalSince(startTime)
            logger.log(
                "Error processing document: \(error.localizedDescription) (Time: \(String(format: "%.1fs", errorTime)))"
            )
            throw WordServiceError.processingError(error.localizedDescription)
        }
    }

    public func parseTextDocument(_ url: URL) async throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.log("Text document not found at: \(url.path)")
            throw WordServiceError.fileNotFound
        }

        var content: String = ""

        // Try different encodings in order of likelihood
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            .ascii,
            .isoLatin1,
        ]
        var lastError: Error? = nil

        for encoding in encodings {
            do {
                content = try String(contentsOf: url, encoding: encoding)
                // If we got here, we successfully read the file
                break
            } catch {
                lastError = error
                if encoding == encodings.last {
                    throw WordServiceError.processingError(
                        "Failed to read file with any encoding: \(error.localizedDescription)")
                }
                continue
            }
        }

        // Split content into paragraphs
        let paragraphs = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if paragraphs.isEmpty {
            throw WordServiceError.emptyDocument
        }

        return paragraphs
    }

    public func parseWordDocument(_ url: URL) async throws -> [String] {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("docx")
        var paragraphs: [String] = []

        // Ensure the input file exists
        guard fileManager.fileExists(atPath: url.path) else {
            throw WordServiceError.fileNotFound
        }

        do {
            // Clean up existing temp directory if it exists
            if fileManager.fileExists(atPath: tempDir.path) {
                try fileManager.removeItem(at: tempDir)
            }

            // Create temporary directory
            try fileManager.createDirectory(
                at: tempDir, withIntermediateDirectories: true, attributes: nil)
            defer {
                try? fileManager.removeItem(at: tempDir)
            }

            // Extract the .docx file
            guard let archive = Archive(url: url, accessMode: .read) else {
                throw WordServiceError.invalidFormat
            }

            var foundDocument = false
            // Find and extract document.xml
            for entry in archive {
                if entry.path == "word/document.xml" {
                    foundDocument = true
                    let documentXMLPath = tempDir.appendingPathComponent("document.xml")
                    _ = try archive.extract(entry, to: documentXMLPath)

                    // Parse XML
                    let xmlData = try Data(contentsOf: documentXMLPath)
                    let parser = XMLParser(data: xmlData)
                    let delegate = WordXMLParserDelegate()
                    parser.delegate = delegate

                    if parser.parse() {
                        paragraphs = delegate.paragraphs
                    } else if let error = parser.parserError {
                        throw WordServiceError.processingError(
                            "XML parsing failed: \(error.localizedDescription)")
                    }

                    break
                }
            }

            if !foundDocument {
                throw WordServiceError.invalidFormat
            }

            if paragraphs.isEmpty {
                throw WordServiceError.processingError("No paragraphs found in document")
            }

        } catch let error as WordServiceError {
            throw error
        } catch {
            throw WordServiceError.processingError(
                "Failed to process document: \(error.localizedDescription)")
        }

        return paragraphs
    }

    public func importSubtitles(
        srtURL: URL, language: Language,
        progressCallback: @escaping (String, Double) -> Void
    )
        async throws -> [Subtitle]
    {
        guard FileManager.default.fileExists(atPath: srtURL.path) else {
            throw WordServiceError.fileNotFound
        }

        // Try to read the file content with different encodings
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            .ascii,
            .isoLatin1,
        ]
        var content: String?
        var usedEncoding: String.Encoding?

        for encoding in encodings {
            if let data = try? Data(contentsOf: srtURL),
                let text = String(data: data, encoding: encoding)
            {
                content = text
                usedEncoding = encoding
                break
            }
        }

        guard let srtContent = content else {
            throw WordServiceError.invalidFormat
        }

        // Split content into subtitle blocks
        var blocks: [String]
        if srtContent.contains("\r\n") {
            blocks = srtContent.components(separatedBy: "\r\n\r\n").filter { !$0.isEmpty }
        } else {
            blocks = srtContent.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        }
        if blocks.isEmpty {
            throw WordServiceError.emptyDocument
        }

        var subtitles: [Subtitle] = []
        var index = 0

        for block in blocks {
            let lines = block.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard lines.count >= 2 else { continue }

            // Parse timecode line (format: 00:00:00,000 --> 00:00:00,000)
            let timecodeLine = lines[1]
            let timecodes = timecodeLine.components(separatedBy: " --> ")
            guard timecodes.count == 2,
                let startTime = parseTimecode(timecodes[0]),
                let endTime = parseTimecode(timecodes[1])
            else {
                continue
            }

            // Get text content (could be multiple lines)
            let textContent = Array(lines[2...]).joined(separator: "\n")

            // Create subtitle
            let subtitle = Subtitle(
                startTime: startTime,
                endTime: endTime,
                sourceText: textContent,
                translatedText: "",
                index: index
            )
            subtitles.append(subtitle)
            index += 1
        }

        if subtitles.isEmpty {
            return []
        }

        //to translate
        let sourceLanguage = detectLanguage(from: subtitles.first!.sourceText)
        var translatedSubtitles = subtitles
        // If source is English and Ollama is configured, translate to Chinese
        if await OllamaService.shared.checkAvailability() {
            progressCallback("Preparing to translate to Chinese...", 0.2)

            if let translated = try? await TranslationService.shared.translateSubtitles(
                subtitles,
                fromLanguage: sourceLanguage.rawValue,
                toLanguage: language.rawValue,
                model: Settings.shared.llmService.chatModel,
                progressCallback: { sub_progress, message in
                    progressCallback(message, 0.2 + 0.8 * sub_progress)
                })
            {
                // Use the translated Chinese text
                translatedSubtitles = translated
            }
        }

        progressCallback("Translated complete!", 1.0)

        // If translation failed or wasn't needed, return original bilingual subtitles
        return zip(subtitles, translatedSubtitles).map { src, translation in
            Subtitle(
                startTime: src.startTime,
                endTime: src.endTime,
                sourceText: src.sourceText,
                translatedText: translation.translatedText,
                index: src.index
            )
        }

    }

    private func parseTimecode(_ timecode: String) -> TimeInterval? {
        // Format: 00:00:00,000
        let components = timecode.components(separatedBy: CharacterSet(charactersIn: ":,"))
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

    private class WordXMLParserDelegate: NSObject, XMLParserDelegate {
        var currentElement = ""
        var currentText = ""
        var paragraphs: [String] = []
        var isInTextElement = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            currentElement = elementName
            if elementName == "w:t" {
                isInTextElement = true
            } else if elementName == "w:p" {
                currentText = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isInTextElement {
                currentText += string
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName == "w:t" {
                isInTextElement = false
            } else if elementName == "w:p"
                && !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                paragraphs.append(currentText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    public func detectLanguage(from text: String) -> Language {
        let text = text.lowercased()

        // Check for languages with unique character ranges
        if text.range(of: "[\u{4e00}-\u{9fa5}]", options: .regularExpression) != nil {
            // Count Traditional Chinese specific characters
            let traditionalOnlyPattern = "[\u{F900}-\u{FAFF}]|[\u{2F800}-\u{2FA1F}]"
            if let traditionalMatches = text.range(
                of: traditionalOnlyPattern, options: .regularExpression)
            {
                return .TraditionalChinese
            }
            return .SimplifiedChinese
        }
        if text.range(of: "[\u{3040}-\u{309F}\u{30A0}-\u{30FF}]", options: .regularExpression)
            != nil
        {
            return .Japanese
        }
        if text.range(of: "[\u{ac00}-\u{d7af}\u{1100}-\u{11FF}]", options: .regularExpression)
            != nil
        {
            return .Korean
        }
        if text.range(of: "[\u{0621}-\u{064A}\u{0660}-\u{0669}]", options: .regularExpression)
            != nil
        {
            return .Arabic
        }
        if text.range(of: "[\u{0400}-\u{04FF}]", options: .regularExpression) != nil {
            return .Russian
        }

        // For Latin-based languages, check for common patterns and characters
        // German - Check for specific German characters first
        if text.range(of: "[äöüß]", options: .regularExpression) != nil {
            return .German
        }
        // Spanish - Look for ñ specifically, as it's unique to Spanish
        if text.range(of: "ñ", options: .regularExpression) != nil {
            return .Spanish
        }
        // Portuguese - Check for unique Portuguese characters first
        if text.range(of: "[ãõ]", options: .regularExpression) != nil {
            return .Portuguese
        }
        // Additional Portuguese check for common combinations
        if text.range(of: "[áéíóúâêô]", options: .regularExpression) != nil
            && text.range(of: "você|está|não|então", options: .regularExpression) != nil
        {
            return .Portuguese
        }
        // French - Check for unique French characters and combinations
        if text.range(of: "[àèùçëïœ]", options: .regularExpression) != nil {
            return .French
        }
        // Italian - Check for unique Italian patterns and common words
        if text.range(of: "[ìù]", options: .regularExpression) != nil {
            return .Italian
        }
        if text.range(
            of: "\\b(ciao|come|stai|sono|questo|che|chi|cosa|perché)\\b",
            options: [.regularExpression, .caseInsensitive]) != nil
        {
            return .Italian
        }

        // Secondary checks for less unique characters
        if text.range(of: "[áéíóú]", options: .regularExpression) != nil {
            // These characters are common in Spanish
            return .Spanish
        }

        // Default to English if no specific patterns are found
        if text.range(of: "[a-z]", options: .regularExpression) != nil {
            return .English
        }

        // If no clear pattern is found, default to English
        return .English
    }

    public func alignmentSubtitles(
        from paragraphs: [String], subtitles: [Subtitle],
        progressCallback: @escaping (Subtitle, Double) -> Void = { _, _ in }
    ) async throws -> [Subtitle] {
        // Get languages from first subtitle or use English as default
        let sourceLanguage = detectLanguage(from: subtitles.first?.sourceText ?? "") ?? .English
        let translatedLanguage =
            detectLanguage(from: subtitles.first?.translatedText ?? "") ?? .English
        logger.log(
            "Detected languages - Source: \(sourceLanguage.rawValue), Translated: \(translatedLanguage.rawValue)"
        )

        let sourceText = paragraphs.filter { detectLanguage(from: $0) == sourceLanguage }.joined(
            separator: "\n")
        let sourceSentences = textToSentences(text: sourceText, language: sourceLanguage)
        let translatedText = paragraphs.filter { detectLanguage(from: $0) == translatedLanguage }
            .joined(separator: "\n")
        let translatedSentences = textToSentences(
            text: translatedText, language: translatedLanguage)

        var sourceOffset = 0
        var translationOffset = 0
        let sourceContextLength =
            Settings.shared.wordService.contextLength
        let translationContextLength =
            Settings.shared.wordService.contextLength
        var editedSubtitles: [Subtitle] = []
        let alignment = Settings.shared.wordService.alignment

        for (index, subtitle) in subtitles.enumerated() {
            let progress = Double(index) / Double(subtitles.count)
            progressCallback(subtitle, progress)

            logger.log("\n--- Processing subtitle #\(subtitle.index + 1) ---")

            var newSubtitle = Subtitle(
                startTime: subtitle.startTime,
                endTime: subtitle.endTime,
                sourceText: subtitle.sourceText,
                translatedText: subtitle.translatedText,
                index: subtitle.index
            )

            // ready to replace source text
            if alignment == .source
                || alignment == .all
            {
                if let matched = try await getSimilarSentences(
                    query: subtitle.sourceText,
                    sentences: sourceSentences,
                    offset: sourceOffset,
                    contextLength: sourceContextLength,
                    language: sourceLanguage,
                    minSimilarity: Settings.shared.wordService.minSimilarity
                ) {
                    newSubtitle.sourceText = matched.1.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    sourceOffset = matched.0 + 1
                }
            }

            // ready to replace translated text
            if alignment == .translation
                || alignment == .all
            {
                if let matched = try await getSimilarSentences(
                    query: subtitle.translatedText,
                    sentences: translatedSentences,
                    offset: translationOffset,
                    contextLength: translationContextLength,
                    language: translatedLanguage,
                    minSimilarity: Settings.shared.wordService.minSimilarity
                ) {
                    newSubtitle.translatedText = matched.1.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    translationOffset = matched.0 + 1
                }
            }

            editedSubtitles.append(newSubtitle)
        }

        logger.log(
            "Alignment \(alignment) completed - Processed \(editedSubtitles.count) subtitles")
        return editedSubtitles
    }

    public func getSimilarSentences(
        query: String, sentences: [String], offset: Int, contextLength: Int,
        language: Language, minSimilarity: Double = 0.5, nTop: Int? = 5
    ) async throws -> (Int, String)? {
        let windows = max(contextLength, 3)
        // Pre-allocate array with capacity
        var scoreSentences = [(Int, Double, String)]()
        scoreSentences.reserveCapacity(sentences.count)

        // Create sentence chunks in parallel
        await withTaskGroup(of: (Int, Double, String).self) { group in
            for i in 0...sentences.count - 1 {
                group.addTask {
                    let end = min(i + windows, sentences.count)
                    var start = i

                    // Find start index which previous char is punctuation
                    for k in i..<end where k > 0 {
                        if sentences[k - 1].last?.isPunctuation == true
                            && Settings.WordService.seperators.contains(sentences[k - 1].last!)
                        {
                            start = k
                            break
                        }
                    }

                    // Initialize with capacity to avoid reallocations
                    var longSentence = String()
                    longSentence.reserveCapacity(windows * sentences[i].count)
                    var longSentenceMaxScore = 0.0
                    var longSentenceBestDistance = Int.max
                    var bestLongSentence = String()

                    for j in start..<end {
                        if language == .English {
                            longSentence += " " + sentences[j]
                        } else {
                            longSentence += sentences[j]
                        }

                        let toCheck =
                            language == .English
                            ? true
                            : (longSentence.last?.isPunctuation == true
                                && Settings.WordService.seperators.contains(longSentence.last!))

                        if longSentence.count >= query.count && toCheck {
                            let score = try? await self.similarScore(
                                query,
                                longSentence,
                                language: language,
                                use_embedding: Settings.shared.wordService.useEmbedding
                            )

                            if let score = score {
                                let distance = self.levenshteinDistance(query, longSentence)
                                if score > longSentenceMaxScore
                                    && distance < longSentenceBestDistance
                                {
                                    longSentenceMaxScore = score
                                    bestLongSentence = longSentence
                                    longSentenceBestDistance = distance
                                } else {
                                    break
                                }
                            }
                        }
                    }
                    return (i, longSentenceMaxScore, bestLongSentence)
                }
            }

            // Collect results
            for await result in group {
                scoreSentences.append(result)
            }
        }

        // Filter and sort in one pass
        let candidates =
            scoreSentences
            .enumerated()
            .map { (index, element) -> (Int, Double, String) in
                let (_, score, sentence) = element
                let prevScore = index > 0 ? scoreSentences[index - 1].1 : 0.0
                let nextScore = index + 1 < scoreSentences.count ? scoreSentences[index + 1].1 : 0.0

                let finalScore = (prevScore * 0.05) + (nextScore * 0.05) + (score * 0.9)
                return (index, finalScore, sentence)
            }
            .filter { $0.1 > minSimilarity }
            .sorted { $0.1 > $1.1 }

        return candidates.first.map { ($0.0, $0.2) }
    }

    public func similarScore(
        _ text1: String, _ text2: String, language: Language,
        use_embedding: Bool = true
    ) async throws -> Double {
        if text1.isEmpty || text1.isEmpty {
            return 0.0
        }
        do {
            if use_embedding {
                // Get embeddings for both texts
                let embedding1 = try await getEmbedding(text: text1)
                let embedding2 = try await getEmbedding(text: text2)

                // Compute cosine similarity
                var dotProduct: Float = 0.0
                var norm1: Float = 0.0
                var norm2: Float = 0.0

                for i in 0..<min(embedding1.count, embedding2.count) {
                    dotProduct += embedding1[i] * embedding2[i]
                    norm1 += embedding1[i] * embedding1[i]
                    norm2 += embedding2[i] * embedding2[i]
                }

                let similarity = dotProduct / (sqrt(norm1) * sqrt(norm2))
                return Double(similarity)
            } else {
                // Use character-based similarity for CJK languages
                if language == .SimplifiedChinese || language == .TraditionalChinese
                    || language == .Japanese
                {
                    return characterBasedSimilarity(text1, text2)
                }

                // Use word-based similarity for other languages
                return wordBasedSimilarity(text1, text2)
            }
        } catch {
            logger.log(
                "Error calculating embedding similarity: \(error.localizedDescription)",
                level: .error)

            // Fall back to character-based similarity for CJK languages
            if language == .SimplifiedChinese || language == .TraditionalChinese
                || language == .Japanese
            {
                return characterBasedSimilarity(text1, text2)
            }

            // Fall back to word-based similarity for other languages
            return wordBasedSimilarity(text1, text2)
        }
    }

    private func characterBasedSimilarity(_ text1: String, _ text2: String) -> Double {
        let set1 = Set(text1)
        let set2 = Set(text2)
        let intersection = set1.intersection(set2)
        let union = set1.union(set2)
        let unionCount = max(set1.count, set2.count)
        return Double(intersection.count) / Double(unionCount)
    }

    private func wordBasedSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let words2 = Set(text2.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        let unionCount = max(words1.count, words2.count)
        return Double(intersection.count) / Double(unionCount)
    }

    // Helper Function: Levenshtein Distance Algorithm
    func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        // Handle empty string cases first
        if s1.isEmpty { return s2.count }
        if s2.isEmpty { return s1.count }

        let s1 = Array(s1)
        let s2 = Array(s2)
        let len1 = s1.count
        let len2 = s2.count

        // Create matrix
        var dp = [[Int]](repeating: [Int](repeating: 0, count: len2 + 1), count: len1 + 1)

        // Initialize first row and column
        for i in 0...len1 {
            dp[i][0] = i
        }
        for j in 0...len2 {
            dp[0][j] = j
        }

        // Fill in the rest of the matrix
        for i in 1...len1 {
            for j in 1...len2 {
                if s1[i - 1] == s2[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]  // No operation needed
                } else {
                    dp[i][j] = min(
                        dp[i - 1][j] + 1,  // Deletion
                        dp[i][j - 1] + 1,  // Insertion
                        dp[i - 1][j - 1] + 1  // Substitution
                    )
                }
            }
        }

        return dp[len1][len2]
    }

    public func textToSentences(text: String, language: Language) -> [String] {
        // Remove extra whitespace and newlines
        let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // Handle empty or single character text
        guard cleanedText.count > 1 else {
            return cleanedText.isEmpty ? [] : [cleanedText]
        }

        // Define sentence terminators based on language
        var terminators = [".", "!", "?", "。", "！", "？", ",", "，", ":", "："]

        // Add language-specific terminators
        switch language {
        case .SimplifiedChinese, .TraditionalChinese, .Japanese:
            terminators.append(contentsOf: ["；", "…"])
        default:
            terminators.append(contentsOf: [";"])
        }

        // Split text into sentences
        var sentences: [String] = []
        var currentSentence = ""

        let characters = Array(cleanedText)
        var i = 0

        while i < characters.count {
            let char = String(characters[i])
            currentSentence += char

            // Check for ellipsis
            if char == "." && i + 2 < characters.count {
                let nextTwo = String(characters[i + 1]) + String(characters[i + 2])
                if nextTwo == ".." {
                    currentSentence += nextTwo
                    i += 2
                    i += 1
                    continue
                }
            }

            // Check if current character is a sentence terminator
            if terminators.contains(char) {
                // Look ahead for multiple terminators, but skip if we just handled ellipsis
                if char != "." {
                    var nextIndex = i + 1
                    while nextIndex < characters.count
                        && terminators.contains(String(characters[nextIndex]))
                    {
                        currentSentence += String(characters[nextIndex])
                        nextIndex += 1
                    }
                    i = nextIndex - 1
                }

                // Add the sentence if it's not empty
                let trimmedSentence = currentSentence.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if !trimmedSentence.isEmpty {
                    sentences.append(trimmedSentence)
                }
                currentSentence = ""
            }

            i += 1
        }

        // Add any remaining text as a sentence
        let remainingSentence = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainingSentence.isEmpty {
            sentences.append(remainingSentence)
        }

        return sentences
    }

    public func textToWords(text: String, language: Language) -> [String] {
        let sentences = textToSentences(text: text, language: language)
        var words: [String] = []

        for sentence in sentences {
            let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if language == .SimplifiedChinese || language == .TraditionalChinese {
                // For Chinese, treat each character as a word
                words.append(contentsOf: trimmedSentence.map { String($0) })
            } else {
                // For other languages, split by whitespace
                let components = trimmedSentence.components(separatedBy: .whitespacesAndNewlines)
                let cleanWords =
                    components
                    .filter { x in
                        x.isEmpty == false
                    }
                words.append(contentsOf: cleanWords)
            }
        }

        return words
    }
}
