import AppKit
import SwiftUI

// MARK: - Panel UI tokens (All tab, Clipboard, Notes — one visual language)

/// Section labels: “Pinned”, “Recent Files”, “Recent Notes”, and date groups in the Notes list.
enum PanelSectionHeaderStyle {
    static let font = Font.system(size: 12, weight: .regular)
    static let foreground = Color(red: 82 / 255, green: 82 / 255, blue: 82 / 255) // #525252
}

/// Inline list rows (notes list, clipboard list): same hover wash, radius, and timing.
enum PanelListRowHoverStyle {
    static let highlightOpacity: Double = 0.10
    static let cornerRadius: CGFloat = 10
    static let duration: Double = 0.12

    static var animation: Animation { .easeInOut(duration: duration) }

    static var hoverFill: Color { Color.white.opacity(highlightOpacity) }
}

/// Pinned / preview cards on dark background (All tab + clipboard column).
enum PanelCardChromeStyle {
    static let bgDefault = Color(red: 38 / 255, green: 38 / 255, blue: 38 / 255)
    static let bgHover = Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255)
    static let cornerRadius: CGFloat = 10
}

// MARK: - Waveform (single level → 5 bars)

struct WaveformView: View {
    var audioLevel: Float

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let jitter = Float(i) * 0.05 - 0.1
                let level = max(0.04, min(1, audioLevel + jitter))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 4)
                    .frame(height: max(4, CGFloat(level) * 30))
                    .animation(.easeInOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 32)
    }
}

// MARK: - Transcription page (Groq via TranscriptionService)

struct TranscriptionPageView: View {
    @ObservedObject var transcription: TranscriptionService
    var onBack: () -> Void

    @State private var pulseLow = false
    @State private var cursorVisible = true

    private var durationFormatted: String {
        let s = transcription.duration
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                if !transcription.isProcessing {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 13))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 44, height: 1)
                }

                Spacer()

                Text(transcription.isProcessing ? "Generating notes…" : "Transcribing…")
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                if transcription.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(width: 44)
                } else {
                    Button {
                        transcription.stopRecording()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let err = transcription.errorMessage {
                HStack(spacing: 8) {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.leading)
                    if err.range(of: "microphone", options: .caseInsensitive) != nil {
                        Button("Settings") { transcription.openMicrophonePrivacySettings() }
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            Divider()

            if transcription.isProcessing {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text("Building structured notes…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 48, height: 48)
                        .opacity(pulseLow ? 0.35 : 1.0)
                        .shadow(color: .red.opacity(0.5), radius: 10)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulseLow)
                        .onAppear { pulseLow = true }
                        .padding(.top, 12)

                    Text(durationFormatted)
                        .font(.system(size: 22, weight: .medium).monospacedDigit())

                    WaveformView(audioLevel: transcription.audioLevel)
                }

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            let displayText = transcription.liveTranscript.isEmpty
                                ? (cursorVisible ? "▌" : " ")
                                : transcription.liveTranscript + (cursorVisible ? "▌" : "")

                            Text(displayText)
                                .font(.system(size: 13))
                                .foregroundColor(.primary.opacity(0.85))
                                .lineSpacing(7.8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)

                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .onChange(of: transcription.liveTranscript) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            cursorVisible.toggle()
        }
    }
}

// MARK: - Clipboard column

struct SharedClipboardColumn: View {
    @ObservedObject var clipboard: ClipboardManager
    var forCardsMode: Bool
    var maxEntries: Int? = nil

    private let sectionGap: CGFloat = 12

    var body: some View {
        let all: [ClipboardEntry] = {
            guard let cap = maxEntries else { return clipboard.entries }
            return Array(clipboard.entries.prefix(cap))
        }()
        let pinned   = all.filter(\.isPinned)
        let unpinned = all.filter { !$0.isPinned }

        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                // Pinned cards section
                if !pinned.isEmpty {
                    ClipboardPinnedSection(pinned: pinned, clipboard: clipboard)
                        .padding(.bottom, sectionGap)
                }

                // Scrollable unpinned list
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(unpinned) { entry in
                            ClipboardListRow(entry: entry, clipboard: clipboard)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Toast overlay
            if let toast = clipboard.transientMessage {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(white: 0.15, opacity: 0.92))
                    )
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: clipboard.transientMessage)
    }
}

// MARK: Pinned cards section

private struct ClipboardPinnedSection: View {
    let pinned: [ClipboardEntry]
    @ObservedObject var clipboard: ClipboardManager

    private let cardGap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pinned")
                .font(PanelSectionHeaderStyle.font)
                .foregroundStyle(PanelSectionHeaderStyle.foreground)

            if pinned.count <= 6 {
                // Up to 2 rows — 3-column vertical grid
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: cardGap
                ) {
                    ForEach(pinned) { entry in
                        ClipboardPinnedCard(entry: entry, clipboard: clipboard)
                    }
                }
            } else {
                // More than 6 — fixed 2 rows, scroll horizontally
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [GridItem(.flexible(minimum: 34)), GridItem(.flexible(minimum: 34))],
                        spacing: cardGap
                    ) {
                        ForEach(pinned) { entry in
                            ClipboardPinnedCard(entry: entry, clipboard: clipboard)
                        }
                    }
                }
                .frame(height: 96) // 2 × ~44px card + 8px gap
            }
        }
    }
}

// MARK: Shimmer modifier (shared by pinned card and list row)

/// Applies a left-to-right sweeping highlight when `isActive` turns true.
/// Renders two copies of the content: solid base underneath, gradient on top with animated opacity
/// so both entry and exit are smooth (no abrupt snap back to base colour).
private struct CopyShimmerModifier: ViewModifier {
    var isActive: Bool
    let baseColor: Color
    @State private var phase: CGFloat = 0
    @State private var shimmerAlpha: Double = 0

    private let sweepDuration: Double = 0.50
    private let fadeIn: Double  = 0.10
    private let fadeOut: Double = 0.28

    func body(content: Content) -> some View {
        content
            .foregroundColor(baseColor)          // always-visible base layer
            .overlay(
                content                          // gradient layer, fades in and out
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: Color(white: 0.44), location: 0),
                                .init(color: Color(white: 0.90), location: phase),
                                .init(color: Color(white: 0.44), location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .opacity(shimmerAlpha)
            )
            .onChange(of: isActive) { active in
                if active {
                    phase = 0
                    // Fade gradient layer in, sweep, then fade it back out smoothly
                    withAnimation(.easeIn(duration: fadeIn))  { shimmerAlpha = 1 }
                    withAnimation(.linear(duration: sweepDuration)) { phase = 1 }
                    let fadeStart = sweepDuration - fadeOut * 0.4
                    DispatchQueue.main.asyncAfter(deadline: .now() + fadeStart) {
                        withAnimation(.easeOut(duration: fadeOut)) { shimmerAlpha = 0 }
                    }
                } else {
                    shimmerAlpha = 0
                    phase = 0
                }
            }
    }
}

// MARK: Pinned card

private struct ClipboardPinnedCard: View {
    let entry: ClipboardEntry
    @ObservedObject var clipboard: ClipboardManager
    @State private var isHovered = false
    @State private var copied = false

    private let textColor = Color(red: 163/255, green: 163/255, blue: 163/255)

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(entry.text)
                .font(.system(size: 11.6, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(CopyShimmerModifier(isActive: copied, baseColor: textColor))
                .contentShape(Rectangle())
                .onTapGesture { copyCard() }

            Button { _ = clipboard.togglePinned(for: entry) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.45))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Unpin")
            .opacity(isHovered ? 1 : 0)
            .animation(PanelListRowHoverStyle.animation, value: isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: PanelCardChromeStyle.cornerRadius, style: .continuous)
                .fill(isHovered ? PanelCardChromeStyle.bgHover : PanelCardChromeStyle.bgDefault)
        )
        .contentShape(Rectangle())
        .animation(PanelListRowHoverStyle.animation, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func copyCard() {
        clipboard.copyToPasteboard(entry: entry)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { copied = false }
    }
}

// MARK: Clipboard list row

private struct ClipboardListRow: View {
    let entry: ClipboardEntry
    @ObservedObject var clipboard: ClipboardManager
    @State private var isHovered = false
    @State private var copied = false

    private let textColor = Color(red: 163/255, green: 163/255, blue: 163/255) // #A3A3A3
    private let iconColor = Color(red: 102/255, green: 102/255, blue: 102/255) // #666666

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(clipboard.preview(for: entry.text))
                .font(.system(size: 11.6, weight: .regular))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(CopyShimmerModifier(isActive: copied, baseColor: textColor))

            // Right icons: always in layout — opacity drives visibility (no layout shift)
            HStack(spacing: 6) {
                Button { clipboard.togglePinned(for: entry) } label: {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundColor(iconColor)
                }
                .buttonStyle(.plain)

                Button(action: copyRow) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundColor(iconColor)
                }
                .buttonStyle(.plain)
            }
            .opacity(isHovered || copied ? 1 : 0)
            .animation(PanelListRowHoverStyle.animation, value: isHovered)
            .animation(PanelListRowHoverStyle.animation, value: copied)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: PanelListRowHoverStyle.cornerRadius, style: .continuous)
                .fill(isHovered ? PanelListRowHoverStyle.hoverFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { copyRow() }
        .animation(PanelListRowHoverStyle.animation, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func copyRow() {
        clipboard.copyToPasteboard(entry: entry)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { copied = false }
    }
}

// MARK: - Notes column

struct SharedNotesColumn: View {
    var makePanelKey: () -> Void
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var transcription: TranscriptionService
    @Binding var showTranscriptionPage: Bool
    @Binding var editingNoteId: String?
    @Binding var noteToDelete: NoteItem?
    var forCardsMode: Bool
    var maxListNotes: Int? = nil

    @State private var showNewNoteChoiceMenu = false
    @State private var noteCopyFeedback = false
    @State private var hoveredNoteId: String? = nil
    @State private var deleteConfirmNote: NoteItem? = nil
    @State private var quickNoteHovered = false

    var body: some View {
        Group {
            if showTranscriptionPage && editingNoteId == nil {
                TranscriptionPageView(transcription: transcription) {
                    if transcription.isRecording {
                        transcription.stopRecording()
                    }
                    showTranscriptionPage = false
                }
            } else if let id = editingNoteId {
                noteEditorView(noteId: id)
            } else {
                notesListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Delete this note?", isPresented: Binding(
            get: { deleteConfirmNote != nil },
            set: { if !$0 { deleteConfirmNote = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteConfirmNote = nil }
            Button("Delete", role: .destructive) {
                guard let note = deleteConfirmNote else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    notesStorage.deleteNote(id: note.id)
                }
                deleteConfirmNote = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
        .onAppear {
            notesStorage.refreshNotes()
            transcription.onNoteCreated = { id in
                editingNoteId = id
                showTranscriptionPage = false
            }
        }
    }

    // MARK: Notes list

    private var notesListView: some View {
        let menuTopPadding: CGFloat = forCardsMode ? 40 : 94

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                quickNoteTouchpoint
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                // List or empty state
                if notesStorage.notes.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("No notes yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    let listed: [NoteItem] = {
                        guard let cap = maxListNotes else { return notesStorage.notes }
                        return Array(notesStorage.notes.prefix(cap))
                    }()
                    let groups = Self.groupedNotes(listed)
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.0) { dateStr, notesInGroup in
                                Text(dateStr)
                                    .font(PanelSectionHeaderStyle.font)
                                    .foregroundStyle(PanelSectionHeaderStyle.foreground)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                                    .padding(.top, 12)
                                    .padding(.bottom, 6)

                                VStack(spacing: 4) {
                                    ForEach(notesInGroup) { note in
                                        notesRow(note: note)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(!showNewNoteChoiceMenu)

            if showNewNoteChoiceMenu {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        withAnimation(.easeIn(duration: 0.15)) {
                            showNewNoteChoiceMenu = false
                        }
                    }
            }

            if showNewNoteChoiceMenu {
                newNoteChoiceCard
                    .padding(.top, menuTopPadding)
                    .padding(.trailing, 6)
                    .transition(
                        .scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity)
                    )
            }
        }
        .animation(.easeIn(duration: 0.15), value: showNewNoteChoiceMenu)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Opens a new blank note with the editor focused (transcription remains on the tab-bar mic).
    private var quickNoteTouchpoint: some View {
        Button {
            let id = notesStorage.createNewNote()
            notesStorage.createEmptyNoteFile(id: id)
            editingNoteId = id
            makePanelKey()
            DispatchQueue.main.async { makePanelKey() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Quick note")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: PanelListRowHoverStyle.cornerRadius, style: .continuous)
                    .fill(quickNoteHovered ? PanelListRowHoverStyle.hoverFill : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .animation(PanelListRowHoverStyle.animation, value: quickNoteHovered)
        .onHover { quickNoteHovered = $0 }
    }

    private var newNoteChoiceCard: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeIn(duration: 0.15)) {
                    showNewNoteChoiceMenu = false
                }
                let id = notesStorage.createNewNote()
                notesStorage.createEmptyNoteFile(id: id)
                editingNoteId = id
                makePanelKey()
                DispatchQueue.main.async { makePanelKey() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write note")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Start with a blank note")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 44)

            Button {
                withAnimation(.easeIn(duration: 0.15)) {
                    showNewNoteChoiceMenu = false
                }
                showTranscriptionPage = true
                transcription.startRecording()
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.red)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcribe meeting")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Record and generate notes")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 232)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func notesRow(note: NoteItem) -> some View {
        let isHovered = hoveredNoteId == note.id

        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: note.origin.listIconSystemName)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.55))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(white: 0.14))
                )

            Text(note.title)
                .font(.system(size: 13))
                .foregroundColor(Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                Button {
                    deleteConfirmNote = note
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity.animation(PanelListRowHoverStyle.animation))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: PanelListRowHoverStyle.cornerRadius, style: .continuous)
                .fill(isHovered ? PanelListRowHoverStyle.hoverFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { editingNoteId = note.id }
        .animation(PanelListRowHoverStyle.animation, value: isHovered)
        .onHover { hovered in
            withAnimation(PanelListRowHoverStyle.animation) {
                hoveredNoteId = hovered ? note.id : nil
            }
        }
    }

    // MARK: Note editor

    private func noteEditorView(noteId: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Button("← Back") {
                    notesStorage.refreshNotes()
                    editingNoteId = nil
                }
                .buttonStyle(.plain)
                .font(.subheadline)

                Spacer()

                // Copy button
                Button {
                    let text = notesStorage.loadNote(id: noteId)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    noteCopyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        noteCopyFeedback = false
                    }
                } label: {
                    Image(systemName: noteCopyFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15))
                        .foregroundColor(noteCopyFeedback ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy note")
            }
            .padding(.horizontal, 8)
            .padding(.top, forCardsMode ? 4 : 6)

            SingleNoteEditorView(noteId: noteId, notesStorage: notesStorage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { makePanelKey() }
        .onChange(of: noteId) { _ in noteCopyFeedback = false }
    }

    private static func groupedNotes(_ notes: [NoteItem]) -> [(String, [NoteItem])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        var groups: [(String, [NoteItem])] = []
        var seenKeys: [String: Int] = [:]
        for note in notes {
            let key = formatter.string(from: note.lastEdited)
            if let idx = seenKeys[key] {
                groups[idx].1.append(note)
            } else {
                seenKeys[key] = groups.count
                groups.append((key, [note]))
            }
        }
        return groups
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

// MARK: - Files column (unchanged)

struct SharedFilesColumn: View {
    @ObservedObject var fileDropStorage: FileDropStorage
    @Binding var fileToDelete: DroppedFileItem?
    var forCardsMode: Bool
    var maxFileItems: Int? = nil

    var body: some View {
        FileDropZoneRepresentable(
            content: AnyView(FileDropListContent(
                storage: fileDropStorage,
                onRequestDelete: { fileToDelete = $0 },
                maxItems: maxFileItems
            )),
            onDrop: { fileDropStorage.addFiles($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, forCardsMode ? 4 : 0)
        .padding(.bottom, forCardsMode ? 4 : 0)
    }
}

// MARK: - All tab combined view

struct AllCombinedView: View {
    @ObservedObject var clipboard: ClipboardManager
    @ObservedObject var notesStorage: NotesStorage
    @ObservedObject var fileDropStorage: FileDropStorage
    @Binding var fileToDelete: DroppedFileItem?
    var makePanelKey: () -> Void
    @ObservedObject var transcription: TranscriptionService
    @Binding var showTranscriptionPage: Bool
    @Binding var editingNoteId: String?
    @Binding var noteToDelete: NoteItem?
    var switchToNotesTab: () -> Void = {}

    @StateObject private var fileSelection = FileSelectionState()
    @StateObject private var fileGridHover = FileGridHoverState()

    private let fileCardWidth: CGFloat = 100
    private let fileCardHeight: CGFloat = 88

    private var pinnedEntries: [ClipboardEntry] {
        clipboard.entries.filter(\.isPinned)
    }

    var body: some View {
        let isEmpty = pinnedEntries.isEmpty && notesStorage.notes.isEmpty && fileDropStorage.files.isEmpty
        return scrollContent(isEmpty: isEmpty)
    }

    private func scrollContent(isEmpty: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Pinned
                if !pinnedEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pinned")
                            .font(PanelSectionHeaderStyle.font)
                            .foregroundStyle(PanelSectionHeaderStyle.foreground)

                        if pinnedEntries.count <= 3 {
                            HStack(spacing: 8) {
                                ForEach(pinnedEntries) { entry in
                                    AllPinnedCard(entry: entry, clipboard: clipboard)
                                }
                            }
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(pinnedEntries) { entry in
                                        AllPinnedCard(entry: entry, clipboard: clipboard)
                                            .frame(width: 180)
                                    }
                                }
                            }
                        }
                    }
                }

                // MARK: Recent Files — uses the exact same FileDropCardRepresentable as the Files tab
                if !fileDropStorage.files.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Files")
                            .font(PanelSectionHeaderStyle.font)
                            .foregroundStyle(PanelSectionHeaderStyle.foreground)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(Array(fileDropStorage.files.prefix(12))) { file in
                                    FileDropCardRepresentable(
                                        storage: fileDropStorage,
                                        item: file,
                                        fileURL: fileDropStorage.fileURL(for: file),
                                        exists: fileDropStorage.fileExists(file),
                                        relativeTime: fileDropRelativeTime(since: file.dateDropped),
                                        isNewlyAdded: fileDropStorage.newlyAddedIDs.contains(file.id),
                                        isSelected: fileSelection.isSelected(file.id),
                                        selection: fileSelection,
                                        hoverState: fileGridHover,
                                        onTap: {
                                            if fileDropStorage.fileExists(file) { fileDropStorage.openFile(file) }
                                        },
                                        onRequestDelete: { fileToDelete = file },
                                        onDragSessionEnded: {
                                            fileDropStorage.handleDragOutSessionEnded(item: file, operation: $0)
                                        }
                                    )
                                    .frame(width: fileCardWidth, height: fileCardHeight)
                                }
                            }
                            .padding(.vertical, 2) // room for selection outline
                        }
                    }
                }

                // MARK: Recent Notes
                if !notesStorage.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Notes")
                            .font(PanelSectionHeaderStyle.font)
                            .foregroundStyle(PanelSectionHeaderStyle.foreground)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(Array(notesStorage.notes.prefix(8))) { note in
                                    AllNoteCard(
                                        note: note,
                                        notesStorage: notesStorage,
                                        onOpen: {
                                            editingNoteId = note.id
                                            switchToNotesTab()
                                        },
                                        onDelete: { noteToDelete = note }
                                    )
                                }
                            }
                        }
                    }
                }

                if isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("Nothing here yet")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: - All tab: Pinned clipboard card

private struct AllPinnedCard: View {
    let entry: ClipboardEntry
    @ObservedObject var clipboard: ClipboardManager
    @State private var isHovered = false
    @State private var copied = false

    private let textColor = Color(red: 163/255, green: 163/255, blue: 163/255)

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(entry.text)
                .font(.system(size: 11.6, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { copyCard() }

            // X to unpin — visible on hover
            Button {
                _ = clipboard.togglePinned(for: entry)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.45))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Unpin")
            .opacity(isHovered ? 1 : 0)
            .animation(PanelListRowHoverStyle.animation, value: isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: PanelCardChromeStyle.cornerRadius, style: .continuous)
                .fill(isHovered ? PanelCardChromeStyle.bgHover : PanelCardChromeStyle.bgDefault)
        )
        .contentShape(Rectangle())
        .animation(PanelListRowHoverStyle.animation, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private func copyCard() {
        clipboard.copyToPasteboard(entry: entry)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { copied = false }
    }
}

// MARK: - All tab: Note preview card

private struct AllNoteCard: View {
    let note: NoteItem
    @ObservedObject var notesStorage: NotesStorage
    var onOpen: () -> Void
    var onDelete: () -> Void
    @State private var isHovered = false
    @State private var previewText: String = ""

    private let cardWidth: CGFloat = 100
    private let cardHeight: CGFloat = 84
    private let textColor = Color(red: 163/255, green: 163/255, blue: 163/255)

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(previewText.isEmpty ? note.title : previewText)
                .font(.system(size: 10, weight: .regular))
                .lineLimit(5)
                .lineSpacing(2)
                .foregroundColor(textColor)
                .frame(width: cardWidth, height: cardHeight, alignment: .topLeading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: PanelCardChromeStyle.cornerRadius, style: .continuous)
                        .fill(isHovered ? PanelCardChromeStyle.bgHover : PanelCardChromeStyle.bgDefault)
                )
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }

            // X to delete — visible on hover
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(PanelListRowHoverStyle.hoverFill))
                }
                .buttonStyle(.plain)
                .padding(5)
                .transition(.opacity.animation(PanelListRowHoverStyle.animation))
            }
        }
        .animation(PanelListRowHoverStyle.animation, value: isHovered)
        .onHover { isHovered = $0 }
        .onAppear {
            let full = notesStorage.loadNote(id: note.id)
            previewText = String(full.prefix(300))
        }
    }
}

