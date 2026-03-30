import SwiftUI

struct SummaryView: View {
    @StateObject var viewModel: SummaryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedText = ""
    @State private var showCopiedAlert = false

    init(viewModel: SummaryViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedText = text
        showCopiedAlert = true

        // Hide the alert after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedAlert = false
        }
    }

    private func textWithLength(_ text: String) -> some View {

        VStack {
            HStack {
                Button {
                    copyToClipboard(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy to clipboard")

                Text("\(text.count) chars")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("\(viewModel.estimateTokenCount(text)) tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)

            }

            Text(text)
                .padding()
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            if viewModel.isGenerating {
                ProgressView(viewModel.progressMessage, value: viewModel.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .padding()
            }

            ScrollView {
                if viewModel.isLoadingText {
                    VStack {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text("Loading text...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        // Titles Section
                        Group {
                            Text("Titles")
                                .font(.headline)

                            HStack(alignment: .top, spacing: 20) {
                                // Source Title
                                VStack(alignment: .leading) {
                                    Text("Source")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    textWithLength(viewModel.sourceTitle)
                                }

                                // Translated Title
                                VStack(alignment: .leading) {
                                    Text("Translated")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    textWithLength(viewModel.translatedTitle)
                                }
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)

                        // Summaries Section
                        Group {
                            Text("Summaries")
                                .font(.headline)

                            HStack(alignment: .top, spacing: 20) {
                                // Source Summary
                                VStack(alignment: .leading) {
                                    Text("Source")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    textWithLength(viewModel.sourceSummary)
                                }

                                // Translated Summary
                                VStack(alignment: .leading) {
                                    Text("Translated")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    textWithLength(viewModel.translatedSummary)
                                }
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)

                        // Full Text Section
                        Group {
                            Text("Full Text")
                                .font(.headline)

                            HStack(alignment: .top, spacing: 20) {
                                // Source Text
                                VStack(alignment: .leading) {
                                    Text("Source")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    textWithLength(viewModel.sourceText)
                                }

                                // Translated Text
                                VStack(alignment: .leading) {
                                    Text("Translated")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    textWithLength(viewModel.translatedText)
                                }
                            }
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .padding()
                }
            }

            // Action Buttons
            HStack {
                Button("Generate Summary") {
                    Task {
                        await viewModel.generateSummary { message, value in
                            Task { @MainActor in
                                viewModel.progressMessage = message
                                viewModel.progress = value
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isGenerating || viewModel.isLoadingText)

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isGenerating)
            }
            .padding()
        }
        .onAppear {
            Task {
                AnalyticsService.shared.trackEvent(.summaryViewOpened)
            }
        }
        .alert("Copied to Clipboard", isPresented: $showCopiedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(copiedText.prefix(50) + (copiedText.count > 50 ? "..." : ""))
        }
    }
}
