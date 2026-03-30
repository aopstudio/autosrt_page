import AVFoundation
import AVKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class SummaryViewModel: ObservableObject {
    private let summaryService = SummaryService.shared
    private let settings = Settings.shared
    private let wordService = WordService.shared
    private let logger = LoggerService.shared
    private let analyticsService = AnalyticsService.shared

    private var sourceLanguage: Language = .English
    private var translatedLanguage: Language = .SimplifiedChinese

    @Published private(set) var sourceText: String = ""
    @Published private(set) var translatedText: String = ""
    @Published var sourceSummary: String = ""
    @Published var translatedSummary: String = ""
    @Published var sourceTitle: String = ""
    @Published var translatedTitle: String = ""
    @Published var isGenerating = false
    @Published var isLoadingText = true
    @Published var progress: Double = 0
    @Published var progressMessage = ""

    var subtitles: [Subtitle] = []

    init(subtitles: [Subtitle] = []) {
        self.subtitles = subtitles
        if let firstSubtitle = subtitles.first {
            self.sourceLanguage = wordService.detectLanguage(from: firstSubtitle.sourceText)
            self.translatedLanguage = wordService.detectLanguage(from: firstSubtitle.translatedText)
        }

        Task {
            await generateSummary { message, value in
                Task { @MainActor in
                    self.progressMessage = message
                    self.progress = value
                }
            }
        }
    }

    private func processTexts() {
        guard !subtitles.isEmpty else { return }

        let chunkSize = 500  // Process 500 subtitles at a time
        var sourceResult = ""

        for i in stride(from: 0, to: subtitles.count, by: chunkSize) {
            let endIndex = min(i + chunkSize, subtitles.count)
            let chunk = subtitles[i..<endIndex]

            let sourceChunk = chunk.map { $0.sourceText }.joined(separator: "\n")

            sourceResult += sourceChunk

            if endIndex < subtitles.count {
                sourceResult += "\n"
            }

            Task { @MainActor() in
                sourceText = sourceResult
                isLoadingText = false
            }
        }

    }

    func generateSummary(progressCallback: @escaping (String, Double) -> Void) async {
        guard !subtitles.isEmpty else { return }

        processTexts()

        isGenerating = true
        progress = 0
        progressMessage = ""

        do {
            analyticsService.trackEvent(
                .summaryGenerationStarted,
                parameters: [
                    "source_language": sourceLanguage.rawValue,
                    "translated_language": translatedLanguage.rawValue,
                ])

            // Generate source summary
            progressCallback("Generating source summary...", 0.0)
            sourceSummary = try await summaryService.summarizeSubtitles(
                subtitles,
                language: sourceLanguage.rawValue,
                model:  Settings.shared.llmService.chatModel
            ) { message, progress in
                progressCallback(message, progress * 0.25)
            }

            // Generate source title
            progressCallback("Generating source title...", 0.25)
            sourceTitle = try await summaryService.generateTitle(
                text: sourceSummary,
                language: sourceLanguage.rawValue,
                model:  Settings.shared.llmService.chatModel
            )

            // Generate translated summary
            progressCallback("Generating translated summary...", 0.5)
            translatedSummary = try await summaryService.translateText(
                sourceSummary,
                sourceLanguage: sourceLanguage.rawValue,
                targetLanguage: translatedLanguage.rawValue,
                model:  Settings.shared.llmService.chatModel
            ) { message, progress in
                progressCallback(message, 0.5 + progress * 0.25)
            }

            // Generate translated title
            progressCallback("Generating translated title...", 0.75)
            translatedTitle = try await summaryService.translateText(
                sourceTitle,
                sourceLanguage: sourceLanguage.rawValue,
                targetLanguage: translatedLanguage.rawValue,
                model: Settings.shared.llmService.chatModel,
                progressCallback: progressCallback
            )

            // Translate source text
            progressCallback("Translating source text...", 0.9)
            translatedText = try await summaryService.translateText(
                sourceText,
                sourceLanguage: sourceLanguage.rawValue,
                targetLanguage: translatedLanguage.rawValue,
                model: Settings.shared.llmService.chatModel,
                progressCallback: progressCallback
            )

            progressCallback("Summary generation complete", 1.0)

            isGenerating = false

            analyticsService.trackEvent(
                .summaryGenerationCompleted,
                parameters: [
                    "source_language": sourceLanguage.rawValue,
                    "translated_language": translatedLanguage.rawValue,
                ])

        } catch {
            isGenerating = false
            logger.log("Failed to generate summary: \(error)", level: .error)
            analyticsService.trackEvent(
                .summaryGenerationFailed,
                parameters: [
                    "error": error.localizedDescription,
                    "source_language": sourceLanguage.rawValue,
                    "translated_language": translatedLanguage.rawValue,
                ])
        }

    }

    func estimateTokenCount(_ text: String) -> Int {
        return summaryService.estimateTokens(text)
    }

    func clear() {
        sourceSummary = ""
        translatedSummary = ""
        sourceTitle = ""
        translatedTitle = ""
    }
}
