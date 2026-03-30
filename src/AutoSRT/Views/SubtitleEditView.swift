import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit

    extension NSTextView {
        var selectedText: String? {
            if let range = selectedRanges.first as? NSRange {
                return (string as NSString).substring(with: range)
            }
            return nil
        }
    }
#endif

struct KeyboardShortcutModifier: ViewModifier {
    @State private var localEventMonitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if event.modifierFlags.contains(.command) {
                        if let window = NSApp.keyWindow,
                            let textView = window.firstResponder as? NSTextView
                        {
                            if event.characters == "v" {
                                if let pasteString = NSPasteboard.general.string(forType: .string) {
                                    textView.insertText(
                                        pasteString, replacementRange: textView.selectedRange())
                                }
                                return nil
                            } else if event.characters == "c" {
                                if let selectedText = textView.selectedText {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(selectedText, forType: .string)
                                }
                                return nil
                            }
                        }
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor = localEventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }
    }
}

extension View {
    func withKeyboardShortcuts() -> some View {
        modifier(KeyboardShortcutModifier())
    }
}

struct SubtitleEditView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    @Environment(\.dismiss) private var dismiss
    let onDismiss: () -> Void
    @State private var searchText: String = ""
    @State private var replaceText: String = ""
    @State private var editCount: Int = 0
    @State private var filteredSubtitles: [Subtitle] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var showReplaceAlert: Bool = false
    @State private var replaceCount: Int = 0
    @State private var selectedSubtitleIndex: Int?
    @State private var scrollProxy: ScrollViewProxy?
    private let analytics = AnalyticsService.shared

    init(viewModel: SubtitleViewModel, onDismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDismiss = onDismiss
        self._editCount = State(
            initialValue: viewModel.editingSubtitles.filter {
                $0.isSourceEdited || $0.isTranslatedEdited
            }
            .count)
        self._filteredSubtitles = State(initialValue: viewModel.editingSubtitles)
        self.selectedSubtitleIndex = viewModel.editingSubtitles.firstIndex {
            $0.isSourceEdited || $0.isTranslatedEdited
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            if viewModel.isProcessing {
                VStack(spacing: 8) {
                    ProgressView(viewModel.statusMessage, value: viewModel.progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }

            if let errorMsg = viewModel.errorMessage {
                Text(errorMsg)
                    .foregroundColor(.red)
                    .padding()
            }

            HStack(spacing: 8) {
                if let player = viewModel.player {
                    VideoPlayerContainer(player: player, fontSize: viewModel.selectedFontSize)
                        .frame(
                            minWidth: Settings.shared.ui.videoPlayerMinWidth,
                            minHeight: Settings.shared.ui.videoPlayerMinHeight)
                } else {
                    Color.black
                        .frame(
                            minWidth: Settings.shared.ui.videoPlayerMinWidth,
                            minHeight: Settings.shared.ui.videoPlayerMinHeight)
                }

                VStack(spacing: 2) {
                    HStack {
                        Text(
                            "Subtitles: \(filteredSubtitles.count)/\(viewModel.editingSubtitles.count)"
                        )
                        .font(.headline)

                        VStack(spacing: 5) {
                            TextField("Search subtitles...", text: $searchText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 300)
                                .searchable(text: $searchText)
                                .onChange(of: searchText) { _ in
                                    Task {
                                        await performSearch()
                                    }
                                }

                            if !searchText.isEmpty {
                                HStack {
                                    TextField("Replace with...", text: $replaceText)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 300)

                                    Button(action: {
                                        if !searchText.isEmpty {
                                            showReplaceAlert = true
                                        }
                                    }) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }
                                    .help("Replace in filtered subtitles")
                                    .disabled(searchText.isEmpty || filteredSubtitles.isEmpty)
                                }

                            }
                        }
                    }
                    .padding(.top, 8)
                    .alert("Replace Confirmation", isPresented: $showReplaceAlert) {
                        Button("Cancel", role: .cancel) {}
                        Button("Replace All", role: .destructive) {
                            Task {
                                await replaceInSubtitles()
                            }
                        }
                    } message: {
                        Text(
                            "Replace '\(searchText)' with '\(replaceText)' in \(filteredSubtitles.count) subtitles?"
                        )
                    }

                    ScrollView {
                        ScrollViewReader { proxy in
                            LazyVStack(spacing: 8) {
                                ForEach(Array(filteredSubtitles.enumerated()), id: \.element.id) {
                                    index, subtitle in
                                    SubtitleItemView(
                                        viewModel: viewModel,
                                        subtitleIndex: index,
                                        isSelected: selectedSubtitleIndex == index,
                                        editCount: $editCount,
                                        editedSubtitles: viewModel.editingSubtitles
                                    )
                                    .onTapGesture {
                                        selectedSubtitleIndex = index
                                    }
                                    .disabled(viewModel.isProcessing)
                                }
                            }
                            .onAppear {
                                scrollProxy = proxy
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)

                    HStack {
                        Button("Cancel") {
                            onDismiss()
                        }
                        .disabled(viewModel.isProcessing)

                        Spacer()

                        Button(action: {
                            navigateToPreviousEditedSubtitle()
                        }) {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(viewModel.isProcessing || !hasPreviousEditedSubtitle())
                        .help("Go to previous edited subtitle")

                        Button(action: {
                            navigateToNextEditedSubtitle()
                        }) {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(viewModel.isProcessing || !hasNextEditedSubtitle())
                        .help("Go to next edited subtitle")

                        Spacer()

                        Text("Edited: \(checkEditedSubtitleCount())")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.trailing, 8)

                        Button("Save") {
                            viewModel.updateSubtitles()
                            Task {
                                analytics.trackEvent(
                                    .subtitleEditViewSaved,
                                    parameters: [
                                        "subtitle_count": viewModel.editingSubtitles.count,
                                        "edited_count": checkEditedSubtitleCount(),
                                    ])
                            }
                            dismiss()
                        }
                        .disabled(viewModel.isProcessing || checkEditedSubtitleCount() == 0)
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()

                    HStack {
                        //display statusMessage here
                        Menu {
                            Button("Align subtitles from Document") {
                                let panel = NSOpenPanel()
                                panel.allowsMultipleSelection = false
                                panel.canChooseDirectories = false
                                panel.allowedContentTypes = [
                                    UTType(filenameExtension: "docx")!,
                                    UTType.plainText,
                                    UTType.rtf,
                                    UTType(filenameExtension: "odt")!,
                                    UTType(filenameExtension: "srt")!,
                                ]
                                panel.begin { response in
                                    if response == .OK, let url = panel.url {
                                        Task {
                                            analytics.trackEvent(
                                                .subtitleDocumentUploaded,
                                                parameters: [
                                                    "file_name": url.lastPathComponent,
                                                    "file_size":
                                                        (try? FileManager.default.attributesOfItem(
                                                            atPath: url.path)[.size]) as? Int64
                                                        ?? 0,
                                                ])

                                            do {
                                                let processedSubtitles =
                                                    try await viewModel.uploadDocument(
                                                        url,
                                                        currentSubtitles: viewModel.editingSubtitles
                                                    )

                                                await MainActor.run {
                                                    viewModel.editingSubtitles = processedSubtitles
                                                    filteredSubtitles = processedSubtitles
                                                    selectedSubtitleIndex =
                                                        processedSubtitles
                                                        .firstIndex {
                                                            $0.isSourceEdited
                                                                || $0.isTranslatedEdited
                                                        }
                                                }
                                            } catch {
                                                LoggerService.shared.log(
                                                    "Error uploading document: \(error.localizedDescription)",
                                                    level: .error
                                                )
                                                analytics.trackError(
                                                    error,
                                                    context: "subtitle_document_upload")
                                            }
                                        }
                                    }
                                }
                            }

                        } label: {
                            Image(systemName: "doc.badge.plus")
                        }
                    }
                }

            }
            .frame(
                minWidth: Settings.shared.ui.editorMinWidth,
                minHeight: Settings.shared.ui.editorMinHeight
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }

                provider.loadObject(ofClass: URL.self) { reading, error in
                    guard error == nil,
                        let url = reading as? URL,
                        url.pathExtension.lowercased() == "srt"
                    else {
                        return
                    }

                    Task {
                        let success = await handleDroppedFile(url)
                        if success {
                            // Handle success if needed
                        }
                    }
                }
                return true
            }

        }
        .onAppear {
            Task {
                AnalyticsService.shared.trackEvent(.subtitleEditViewOpened)
            }
        }
        .withKeyboardShortcuts()
    }

    private func performSearch() async {
        // send analytics event
        analytics.trackEvent(
            .subtitleSearchStarted,
            parameters: [
                "search_text": searchText,
                "filtered_subtitles": filteredSubtitles.count,
            ])

        // Cancel any existing search task
        searchTask?.cancel()

        // Add a small delay for debouncing
        try? await Task.sleep(nanoseconds: 300_1000)

        // Check if task was cancelled during the delay
        if Task.isCancelled { return }

        // Perform the search in background
        if searchText.isEmpty {
            await MainActor.run {
                filteredSubtitles = viewModel.editingSubtitles
            }
            return
        }

        let filtered = viewModel.editingSubtitles.filter { subtitle in
            subtitle.sourceText.localizedCaseInsensitiveContains(searchText)
                || subtitle.translatedText.localizedCaseInsensitiveContains(searchText)
        }

        // Update UI on main thread
        await MainActor.run {
            filteredSubtitles = filtered
            analytics.trackEvent(
                .subtitleSearchCompleted,
                parameters: [
                    "search_text": searchText,
                    "filtered_subtitles": filtered.count,
                ])
        }
    }

    private func handleDroppedFile(_ url: URL) async -> Bool {
        do {
            let processedSubtitles = try await viewModel.uploadDocument(
                url, currentSubtitles: viewModel.editingSubtitles)
            await MainActor.run {
                viewModel.editingSubtitles = processedSubtitles
                filteredSubtitles = processedSubtitles
            }
            return true
        } catch {
            print("Error processing dropped file: \(error)")
            return false
        }
    }

    private func checkEditedSubtitleCount() -> Int {
        return viewModel.editingSubtitles.filter { $0.isSourceEdited || $0.isTranslatedEdited }
            .count
    }

    private func replaceInSubtitles() async {
        analytics.trackEvent(
            .subtitleReplaceStarted,
            parameters: [
                "search_text": searchText,
                "replace_text": replaceText,
                "filtered_subtitles": filteredSubtitles.count,
            ])

        var replacedCount = 0

        for subtitle in filteredSubtitles {
            if let index = viewModel.editingSubtitles.firstIndex(where: { $0.id == subtitle.id }) {
                let sourceText = viewModel.editingSubtitles[index].sourceText
                let translatedText = viewModel.editingSubtitles[index].translatedText

                let newSourceText = sourceText.replacingOccurrences(
                    of: searchText, with: replaceText, options: .caseInsensitive)
                let newTranslatedText = translatedText.replacingOccurrences(
                    of: searchText, with: replaceText, options: .caseInsensitive)

                if newSourceText != sourceText || newTranslatedText != translatedText {
                    viewModel.editingSubtitles[index].sourceText = newSourceText
                    viewModel.editingSubtitles[index].translatedText = newTranslatedText
                    replacedCount += 1
                }
            }
        }

        // Update filtered subtitles
        await performSearch()

        // Update edit count
        editCount = checkEditedSubtitleCount()

        // Show result
        replaceCount = replacedCount

        analytics.trackEvent(
            .subtitleReplaceCompleted,
            parameters: [
                "search_text": searchText,
                "replace_text": replaceText,
                "filtered_subtitles": filteredSubtitles.count,
                "replaced_count": replacedCount,
            ])
    }

    private func hasPreviousEditedSubtitle() -> Bool {
        guard let currentIndex = selectedSubtitleIndex else { return false }
        if currentIndex == 0 { return false }
        let ret = filteredSubtitles.prefix(currentIndex).contains {
            $0.isSourceEdited || $0.isTranslatedEdited
        }
        return ret
    }

    private func hasNextEditedSubtitle() -> Bool {
        guard let currentIndex = selectedSubtitleIndex else { return false }
        if currentIndex >= filteredSubtitles.count - 1 { return false }
        let ret = filteredSubtitles.suffix(from: currentIndex + 1).contains {
            $0.isSourceEdited || $0.isTranslatedEdited
        }
        return ret
    }

    private func navigateToPreviousEditedSubtitle() {
        guard let currentIndex = selectedSubtitleIndex else { return }
        for index in (0..<currentIndex).reversed() {
            if filteredSubtitles[index].isSourceEdited
                || filteredSubtitles[index].isTranslatedEdited
            {
                selectedSubtitleIndex = index
                scrollProxy?.scrollTo(filteredSubtitles[index].id, anchor: .center)
                break
            }
        }
    }

    private func navigateToNextEditedSubtitle() {
        guard let currentIndex = selectedSubtitleIndex else { return }
        for index in (currentIndex + 1)..<filteredSubtitles.count {
            if filteredSubtitles[index].isSourceEdited
                || filteredSubtitles[index].isTranslatedEdited
            {
                selectedSubtitleIndex = index
                scrollProxy?.scrollTo(filteredSubtitles[index].id, anchor: .center)
                break
            }
        }
    }
}

struct SubtitleItemView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    let subtitleIndex: Int
    let isSelected: Bool
    @Binding var editCount: Int
    let editedSubtitles: [Subtitle]
    @FocusState private var sourceTextInFocus: Bool
    @FocusState private var translatedTextInFocus: Bool

    private var subtitle: Subtitle {
        viewModel.editingSubtitles[subtitleIndex]
    }

    #if os(macOS)
        private let copyCommand = KeyboardShortcut("c", modifiers: .command)
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("#\(subtitle.index + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(action: {
                    viewModel.player?.seek(
                        to: CMTime(seconds: subtitle.startTime, preferredTimescale: 1000))
                }) {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(
                    "\(formatTimeInterval(subtitle.startTime)) → \(formatTimeInterval(subtitle.endTime))"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if subtitle.index >= 0,
                let originalSubtitle = viewModel.subtitles.indices.contains(subtitle.index)
                    ? viewModel.subtitles[subtitle.index] : nil,
                !originalSubtitle.sourceText.isEmpty
            {
                Text(originalSubtitle.sourceText)
                    .frame(minHeight: 30)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            TextEditor(
                text: Binding(
                    get: { self.subtitle.sourceText },
                    set: { newValue in
                        viewModel.editingSubtitles[subtitleIndex].sourceText = newValue
                        viewModel.editingSubtitles[subtitleIndex].isSourceEdited = true
                    }
                )
            )
            .focused($sourceTextInFocus)
            .onChange(of: sourceTextInFocus) { isFocused in
                if !isFocused {
                    editCount =
                        editedSubtitles.filter { $0.isSourceEdited || $0.isTranslatedEdited }.count
                    viewModel.persistState()
                }
            }
            .textFieldStyle(.automatic)
            .frame(minHeight: 30)
            .foregroundColor(subtitle.isSourceEdited ? .red : .primary)

            if subtitle.index >= 0,
                let originalSubtitle = viewModel.subtitles.indices.contains(subtitle.index)
                    ? viewModel.subtitles[subtitle.index] : nil,
                !originalSubtitle.translatedText.isEmpty
            {
                Text(originalSubtitle.translatedText)
                    .frame(minHeight: 30)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            TextEditor(
                text: Binding(
                    get: { self.subtitle.translatedText },
                    set: { newValue in
                        viewModel.editingSubtitles[subtitleIndex].translatedText = newValue
                        viewModel.editingSubtitles[subtitleIndex].isTranslatedEdited = true
                    }
                )
            )
            .focused($translatedTextInFocus)
            .onChange(of: translatedTextInFocus) { isFocused in
                if !isFocused {
                    editCount =
                        editedSubtitles.filter { $0.isSourceEdited || $0.isTranslatedEdited }.count
                    viewModel.persistState()
                }
            }
            .textFieldStyle(.automatic)
            .frame(minHeight: 30)
            .foregroundColor(subtitle.isTranslatedEdited ? .red : .primary)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(8)
    }

    private func formatTimeInterval(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }
}
