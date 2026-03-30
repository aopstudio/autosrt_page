import Combine
import Foundation

public class TranslationService: ObservableObject {
    public static let shared = TranslationService()
    private let logger = LoggerService.shared

    private init() {}

    private func doTranslate(
        batch: [Subtitle],
        fromLanguage: String, toLanguage: String,
        model: String,
        progressCallback: @escaping (Double, String) -> Void,
    ) async throws -> [String: String] {
        if batch.isEmpty {
            throw NSError(domain: "No subtitles provided", code: 0, userInfo: nil)
        }

        let systemPrompt = """
            You are a professional video subtitle translator specializing in \(fromLanguage) to \(toLanguage) translation.
              1. Translate the following subtitles into natural, fluent \(toLanguage). Each translation should be concise, accurate, and contextually appropriate.
              2. Preserve the original meaning and subtitle structure as much as possible.
              3. Output a valid JSON dict.

            Response format:
            ```json
            {
                data: {
                    "":"",
                    ...
                }
            }
            ```

            Response examples:
            ```json
            {
                data: {
                    "Hello ": "您好 ",
                    "let's start. ": "让我们开始吧。"
                }
            }
            ```

            """
        let systemMessage = ChatMessage(role: .system, content: systemPrompt)

        // convert batch to json string
        let sourceTextList = batch.map { $0.sourceText }
        let batchJson = try JSONEncoder().encode(sourceTextList)
        let batchJsonString = String(data: batchJson, encoding: .utf8) ?? ""

        let userPrompt = """
            Translate the following text list:

            ```json
            \(batchJsonString)
            ```
            """
        let userMessage = ChatMessage(role: .user, content: userPrompt)

        let messages: [ChatMessage] = [systemMessage, userMessage]

        let assistMessage = try await LLMServiceFactory.createService().chat(
            messages: messages, model: model, tools: nil, formatter: nil)

        // extract json, convert to array
        guard let jsonDict = await LLMServiceFactory.extractJSONs(from: assistMessage.content).first
        else {
            progressCallback(
                1.0,
                "Failed to parse JSON response"
            )
            logger.log(
                "Failed to parse JSON response from: \(assistMessage.content)", level: .warning)
            return [:]
        }
        guard let items = jsonDict["data"] as? [String: String] else {
            progressCallback(
                1.0,
                "Failed to get data"
            )
            throw NSError(
                domain: "Invalid JSON format", code: 0,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to extract array from the JSON response of the assistant."
                ])
        }
        // convert items to dict
        var translatedTexts: [String: String] = [:]
        for (source, translated) in items {
            let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTranslated = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            translatedTexts[cleanSource] = cleanTranslated
            progressCallback(
                1.0,
                "\(source) -> \(translated)"
            )
        }
        
        return translatedTexts
    }

    private func doTranslateOne(
        subtitle: Subtitle,
        batch: [Subtitle],
        fromLanguage: String, toLanguage: String,
        model: String
    ) async throws -> String {
        if batch.isEmpty {
            return ""
        }

        let systemPrompt = """
            You are a professional video subtitle translator specializing in \(fromLanguage) to \(toLanguage) translation.
              1. Translate the following subtitle into natural, fluent \(toLanguage). Each translation should be concise, accurate, and contextually appropriate.
              2. The subtitle is in the context.
              3. Preserve the original meaning and subtitle structure as much as possible.
              4. Output a valid JSON dict.

            Response format:
            ```json
            {
                translation: ""
            }
            ```
            """
        let systemMessage = ChatMessage(role: .system, content: systemPrompt)

        // convert batch to json string
        let sourceTextList = batch.map { $0.sourceText }
        let batchJson = try JSONEncoder().encode(sourceTextList)
        let batchJsonString = String(data: batchJson, encoding: .utf8) ?? ""

        let userPrompt = """
            The subtitle of context is in the following json:
            ```json
            \(batchJsonString)
            ```
            
            Translate the following subtitle:
            \(subtitle.sourceText)

            """
        let userMessage = ChatMessage(role: .user, content: userPrompt)

        let messages: [ChatMessage] = [systemMessage, userMessage]

        let assistMessage = try await LLMServiceFactory.createService().chat(
            messages: messages, model: model, tools: nil, formatter: nil)

        // extract json, convert to array
        guard let jsonDict = await LLMServiceFactory.extractJSONs(from: assistMessage.content).first
        else {
            logger.log(
                "Failed to parse JSON response from: \(assistMessage.content)", level: .warning)
            return ""
        }
        guard let translation = jsonDict["translation"] as? String else {
            logger.log("Failed to extract translation from: \(jsonDict)", level: .warning)
            return ""
        }
        logger.log("Translate one subtitle: \(subtitle.sourceText) -> \(translation)")
        return translation
    }

    /// Translate subtitles using Ollama
    public func translateSubtitles(
        _ subtitles: [Subtitle], fromLanguage: String, toLanguage: String,
        model: String,
        progressCallback: @escaping (Double, String) -> Void
    ) async throws -> [Subtitle] {
        var translatedSubtitles: [Subtitle] = []
        let total = subtitles.count
        var translatedTexts: [String: String] = [:]

        // Process subtitles in batches
        let batchSize = Settings.shared.llmService.maxChatHistoryCount
        let batches = stride(from: 0, to: subtitles.count, by: batchSize).map {
            Array(subtitles[$0..<min($0 + batchSize, subtitles.count)])
        }

        var processedCount = 0
        var successCount = 0
        var exceptionCount: Int = 0
        let start = Date().timeIntervalSince1970

        for (batchIndex, batch) in batches.enumerated() {
            do {
                let translatedBatch = try await doTranslate(
                    batch: batch,
                    fromLanguage: fromLanguage,
                    toLanguage: toLanguage,
                    model: model,
                    progressCallback: { progress, message in
                        // Scale the progress to represent progress within the current batch
                        let overallProgress =
                            (Double(processedCount) + progress * Double(batch.count))
                            / Double(total)
                        let successRatio = Double(successCount) * 100.0 / Double(total)
                        let successRatioString = String(format: "%.2f", successRatio)
                        let spendTime = Date().timeIntervalSince1970 - start
                        let speed = Double(processedCount) / spendTime
                        let speedString = String(format: "%.2f", speed)
                        let leftTime = speed > 0 ? Int(Double(total - processedCount) / speed) : 0
                        progressCallback(
                            overallProgress.clamped(to: 0.0...1.0),
                            "Batch \(batchIndex + 1)/\(batches.count), left time \(leftTime)s, \(speedString) subtitles/s, success \(successRatioString)% \(successCount)/\(total), exception \(exceptionCount): \(message)"
                        )
                    }
                )

                // update translatedTexts
                translatedTexts.merge(translatedBatch) { (current, _) in current }
            } catch {
                exceptionCount += 1
                logger.log(
                    "Failed to translate batch \(batchIndex + 1)/\(batches.count): \(error.localizedDescription)",
                    level: .error)
            }

            // Map the translated texts back to subtitles with original metadata
            for (i, subtitle) in batch.enumerated() {
                // Is translation exists?
                var translation =
                    translatedTexts[
                        subtitle.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)]
                    ?? ""
                if translation.isEmpty {
                    logger.log(
                        "\(i)th subtitle translation not found: '\(subtitle.sourceText)'",
                        level: .info
                    )
                    // translate again
                    do {
                        translation = try await doTranslateOne(
                            subtitle: subtitle, batch: batch,
                            fromLanguage: fromLanguage, toLanguage: toLanguage, model: model)
                        if !translation.isEmpty {
                            successCount += 1
                            translatedTexts[
                                subtitle.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)]
                            = translation
                        }
                    } catch {
                        logger.log("Failed to translate '\(subtitle.sourceText)' again: \(error.localizedDescription)", level: .warning)
                    }
                } else {
                    successCount += 1
                }
                
                processedCount += 1

                let newSubtitle = Subtitle(
                    startTime: subtitle.startTime,
                    endTime: subtitle.endTime,
                    sourceText: subtitle.sourceText,
                    translatedText: translation.isEmpty ? subtitle.sourceText : translation,
                    index: subtitle.index
                )
                translatedSubtitles.append(newSubtitle)
            }
        }

        progressCallback(1.0, "Translation completed")
        return translatedSubtitles
    }

    /// Split text into multiple lines if characters exceed maxLength
    public func splitText(_ text: String, maxCharactersPerLine: Int = 40) -> String {
        if text.count <= maxCharactersPerLine {
            return text
        }

        // Split text into words/characters
        let components = text.map { String($0) }
        var lines: [String] = []
        var currentLine = ""

        for component in components {
            let newLine = currentLine + component
            if newLine.count > maxCharactersPerLine {
                lines.append(currentLine)
                currentLine = component
            } else {
                currentLine = newLine
            }
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines.joined(separator: "\n")
    }
}
