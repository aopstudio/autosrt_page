import Foundation
import SwiftUI

public class SummaryService: ObservableObject {
    public static let shared = SummaryService()
    private let logger = LoggerService.shared
    private let settings = Settings.shared
    private let ollamaService = OllamaService.shared
    private let wordService = WordService.shared
    private let bert = BertTokenizer()

    private var maxTokensPerChunk = 4096 - 100  // Adjust based on model's context window

    private init() {
        self.maxTokensPerChunk = Settings.LLMService.maxTokenLength - 100
    }

    public func estimateTokens(_ text: String) -> Int {
        let tokens = bert.tokenize(text)
        return tokens.count
    }

    private func splitIntoChunks(_ text: String, maxTokensPerChunk: Int) -> [String] {
        // Split into sentences first
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".,!?。，！？"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0 + "." }  // Add back the period

        var chunks: [String] = []
        var currentChunkSentences: [String] = []
        var currentTokenCount = 0

        for sentence in sentences {
            let sentenceTokens = estimateTokens(sentence)

            // If a single sentence exceeds the limit, split it into smaller parts
            if sentenceTokens > maxTokensPerChunk {
                // First, add the current chunk if not empty
                if !currentChunkSentences.isEmpty {
                    chunks.append(currentChunkSentences.joined(separator: " "))
                    currentChunkSentences = []
                    currentTokenCount = 0
                }

                // Split long sentence into smaller chunks
                let words = sentence.components(separatedBy: .whitespaces)
                var currentPart: [String] = []
                var partTokenCount = 0

                for word in words {
                    let wordTokens = estimateTokens(word + " ")
                    if partTokenCount + wordTokens > maxTokensPerChunk {
                        if !currentPart.isEmpty {
                            chunks.append(currentPart.joined(separator: " ") + ".")
                            currentPart = []
                            partTokenCount = 0
                        }
                    }
                    currentPart.append(word)
                    partTokenCount += wordTokens
                }

                // Add remaining part
                if !currentPart.isEmpty {
                    chunks.append(currentPart.joined(separator: " ") + ".")
                }
            }
            // If adding this sentence would exceed the limit, create a new chunk
            else if currentTokenCount + sentenceTokens > maxTokensPerChunk {
                if !currentChunkSentences.isEmpty {
                    chunks.append(currentChunkSentences.joined(separator: " "))
                    currentChunkSentences = [sentence]
                    currentTokenCount = sentenceTokens
                }
            }
            // Add to current chunk
            else {
                currentChunkSentences.append(sentence)
                currentTokenCount += sentenceTokens
            }
        }

        // Add the last chunk if there's anything remaining
        if !currentChunkSentences.isEmpty {
            chunks.append(currentChunkSentences.joined(separator: " "))
        }

        // Log chunk information
        logger.log("Split text into \(chunks.count) chunks:")
        for (index, chunk) in chunks.enumerated() {
            let tokens = estimateTokens(chunk)
            logger.log("Chunk \(index + 1): \(tokens) tokens, \(chunk.count) chars")
        }

        return chunks
    }

    private func summarizeChunk(
        _ text: String,
        language: String,
        model: String
    ) async throws -> String {
        let systemMessage = """
            You are an expert in summarizing video content. Summarize the following text in \(language).
            Focus on the main points and key events while maintaining chronological order.
            The summary should be clear, coherent, and capture the essential information.
            Keep the summary concise and focused on key points only and avoid unnecessary details and incude some emojis.
            """

        var messages: [ChatMessage] = []
        messages.append(ChatMessage(role: .system, content: systemMessage))
        messages.append(ChatMessage(role: .user, content: text))

        let summary = try await LLMServiceFactory.createService().chat(
            messages: messages,
            model: model,
            tools: nil,
            formatter: nil
        )

        return summary.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Summarize a group of subtitles
    public func summarizeSubtitles(
        _ subtitles: [Subtitle],
        language: String,
        model: String,
        progressCallback: @escaping (String, Double) -> Void
    ) async throws -> String {
        if subtitles.isEmpty {
            throw NSError(domain: "No subtitles provided", code: 0, userInfo: nil)
        }

        // Combine subtitles into a single text
        var combinedText = ""
        for subtitle in subtitles {
            if wordService.detectLanguage(from: subtitle.sourceText).rawValue == language {
                combinedText += "\(subtitle.sourceText)\n"
            } else {
                combinedText += "\(subtitle.translatedText)\n"
            }
        }

        // Split into chunks if text is too long
        let chunks = splitIntoChunks(combinedText, maxTokensPerChunk: maxTokensPerChunk)
        var chunkSummaries: [String] = []

        // Summarize each chunk
        for (index, chunk) in chunks.enumerated() {
            let progress = chunks.count == 1 ? 0.5 : Double(index) / Double(chunks.count)
            progressCallback(
                "Generating summary for part \(index + 1)/\(chunks.count)...", progress)

            let chunkSummary = try await summarizeChunk(chunk, language: language, model: model)
            chunkSummaries.append(chunkSummary)
        }

        // If we have multiple chunks, create a final summary
        if chunkSummaries.count > 1 {
            progressCallback("Generating final summary...", 0.9)

            let combinedSummaries = chunkSummaries.joined(separator: "\n\n")
            let finalSummary = try await summarizeChunk(
                combinedSummaries, language: language, model: model)

            progressCallback("Summary generated", 1.0)
            return finalSummary
        } else {
            progressCallback("Summary generated", 1.0)
            return chunkSummaries.first ?? ""
        }
    }

    /// Translate text using chunk-based translation
    public func translateText(
        _ text: String,
        sourceLanguage: String,
        targetLanguage: String,
        model: String,
        progressCallback: @escaping (String, Double) -> Void
    ) async throws -> String {
        if text.isEmpty {
            throw NSError(domain: "No text provided", code: 0, userInfo: nil)
        }

        // Split text into lines and chunks
        let chunks = splitIntoChunks(text, maxTokensPerChunk: maxTokensPerChunk)
        var translatedTexts: [String] = []

        // Translate each chunk
        for (index, chunk) in chunks.enumerated() {
            let progress = Double(index) / Double(chunks.count)
            progressCallback(
                "Translating chunk \(index + 1)/\(chunks.count)...", progress)

            let translatedChunk = try await translateChunk(
                chunk,
                from: sourceLanguage,
                to: targetLanguage,
                model: model
            )

            translatedTexts.append(translatedChunk)
        }

        progressCallback("Translation completed", 1.0)
        return translatedTexts.joined(separator: "\n")
    }

    /// Translate a chunk of text
    private func translateChunk(
        _ text: String,
        from sourceLanguage: String,
        to targetLanguage: String,
        model: String
    ) async throws -> String {
        let prompt = text
        let messages: [ChatMessage] = [
            .init(
                role: .system,
                content: """
                    You are a professional translator specializing in \(sourceLanguage) to \(targetLanguage) translation.
                    - Translate text accurately while preserving its original structure
                    - Keep all formatting and line breaks intact
                    - Maintain consistent style throughout the translation
                    - Do not add explanations or notes
                    - Output only the translated text
                    - Please respect the original meaning, maintain the original format, and rewrite the following content in \(targetLanguage)
                    """
            ),
            .init(role: .user, content: prompt),
        ]

        let chatMessage = try await LLMServiceFactory.createService().chat(messages: messages, model: model, tools: nil, formatter: nil)
        return chatMessage.content
    }

    /// Generate a title from text with specified length
    public func generateTitle(
        text: String,
        language: String,
        model: String = "",
        maxLength: Int = 50
    ) async throws -> String {
        if text.isEmpty {
            throw NSError(domain: "No text provided", code: 0, userInfo: nil)
        }

        // Split text into chunks if it's too long
        let chunks = splitIntoChunks(text, maxTokensPerChunk: maxTokensPerChunk)
        if chunks.count > 1 {
            // Generate titles for each chunk in parallel
            let chunkTitles = try await withThrowingTaskGroup(of: String.self) { group in
                for chunk in chunks {
                    group.addTask {
                        return try await self.generateTitleFromText(
                            chunk,
                            language: language,
                            model: model,
                            prompt: "Suggest a title for this portion of the text:",
                            maxLength: maxLength
                        )
                    }
                }

                var titles: [String] = []
                for try await title in group {
                    titles.append(title)
                }
                return titles
            }

            // Combine titles into one final title
            let titlesText = chunkTitles.joined(separator: "\n- ")
            let combineTitlesPrompt = """
                Combine the following titles into one concise and accurate title that captures the main topic:
                - \(titlesText)
                """

            return try await generateTitleFromText(
                combineTitlesPrompt,
                language: language,
                model: model,
                prompt: "",
                maxLength: maxLength
            )
        } else {
            // For short text, generate title directly
            return try await generateTitleFromText(
                text,
                language: language,
                model: model,
                prompt: "Create a title for this text:",
                maxLength: maxLength
            )
        }
    }

    /// Internal helper to generate title from a single piece of text
    private func generateTitleFromText(
        _ text: String,
        language: String,
        model: String,
        prompt: String,
        maxLength: Int
    ) async throws -> String {
        let systemMessage = """
            You are an expert in creating titles. Please create a short, descriptive title in \(language) \
            that captures the main topic of the following text. The title must be no longer than \(maxLength) words. \
            Only output the title without any additional text or explanations. \
            The title should be clear, informative, attractive and engaging, include some emotional elements.
            """

        var messages: [ChatMessage] = []
        messages.append(ChatMessage(role: .system, content: systemMessage))
        if !prompt.isEmpty {
            messages.append(ChatMessage(role: .user, content: prompt))
        }
        messages.append(ChatMessage(role: .user, content: text))

        let chatMessage = try await LLMServiceFactory.createService().chat(
            messages: messages,
            model: settings.llmService.chatModel,
            tools: nil,
            formatter: nil
        )
        let title = chatMessage.content

        // Ensure the title doesn't exceed maxLength
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedTitle
    }
}
