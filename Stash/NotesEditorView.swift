import AppKit
import Combine
import SwiftUI

// MARK: - Rich single-note editor (NSTextView + RTF)

struct SingleNoteEditorView: NSViewRepresentable {
    let noteId: String
    let notesStorage: NotesStorage

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.typingAttributes = Self.defaultTypingAttributes()
        textView.insertionPointColor = .white

        // Swap in our inline-code-aware layout manager using the documented
        // container-side replacement path. `replaceLayoutManager` re-wires
        // NSTextView.layoutManager automatically and avoids leaving the
        // container bound ambiguously during the swap.
        if let existingContainer = textView.textContainer {
            existingContainer.replaceLayoutManager(NotesInlineCodeLayoutManager())
        }

        scrollView.documentView = textView

        context.coordinator.noteId = noteId
        context.coordinator.notesStorage = notesStorage
        context.coordinator.textView = textView
        context.coordinator.toolbarController.attach(to: textView)

        context.coordinator.toolbarController.onCommand = { [weak coordinator = context.coordinator] command in
            guard let coordinator else { return }
            switch command {
            case .bold:          coordinator.applyBold()
            case .italic:        coordinator.applyItalic()
            case .underline:     coordinator.applyUnderline()
            case .strikethrough: coordinator.applyStrikethrough()
            case .inlineCode:    coordinator.applyInlineCode()
            case .heading(let level):
                coordinator.applyHeading(level)
            case .link:
                let initial = coordinator.currentSelectionURL()
                coordinator.toolbarController.presentLinkPopover(initialURL: initial) { url in
                    coordinator.applyLink(url)
                }
            case .color, .more:  break    // v1 stubs
            }
        }

        NotificationCenter.default
            .publisher(for: NSTextView.didEndEditingNotification, object: textView)
            .sink { [weak coordinator = context.coordinator] _ in
                coordinator?.toolbarController.hide()
            }
            .store(in: &context.coordinator.notificationSubscriptions)

        context.coordinator.boundNoteId = noteId
        context.coordinator.didRequestFocus = false
        context.coordinator.isApplyingBulkChange = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: "", attributes: Self.defaultTypingAttributes())
        )
        context.coordinator.isApplyingBulkChange = false
        context.coordinator.scheduleLoad(noteId: noteId, storage: notesStorage)

        container.addSubview(scrollView)

        context.coordinator.setupPlaceholder(in: container)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.constrainPlaceholder(in: container)

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if context.coordinator.boundNoteId != noteId {
            context.coordinator.boundNoteId = noteId
            context.coordinator.noteId = noteId
            context.coordinator.notesStorage = notesStorage
            context.coordinator.didRequestFocus = false
            context.coordinator.isApplyingBulkChange = true
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: "", attributes: Self.defaultTypingAttributes())
            )
            context.coordinator.isApplyingBulkChange = false
            context.coordinator.scheduleLoad(noteId: noteId, storage: notesStorage)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = DesignTokens.Typography.bodyLineHeight
        paragraphStyle.maximumLineHeight = DesignTokens.Typography.bodyLineHeight
        return [
            .font: DesignTokens.Typography.bodyNSFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraphStyle
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteId: String = ""
        var notesStorage: NotesStorage!
        weak var textView: NSTextView?
        let toolbarController = NotesSelectionToolbarController()
        var notificationSubscriptions: Set<AnyCancellable> = []
        var boundNoteId: String = ""
        var didRequestFocus = false
        var isApplyingBulkChange = false
        private var loadGeneration = 0
        private weak var placeholderField: NSTextField?

        func scheduleLoad(noteId: String, storage: NotesStorage) {
            loadGeneration += 1
            let generation = loadGeneration
            let id = noteId
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let attr = storage.loadNoteAttributed(id: id)
                DispatchQueue.main.async {
                    guard let self, let tv = self.textView else { return }
                    guard generation == self.loadGeneration, self.boundNoteId == id else { return }
                    self.isApplyingBulkChange = true
                    tv.textStorage?.setAttributedString(attr)
                    self.isApplyingBulkChange = false
                    self.updatePlaceholderVisibility()
                    self.didRequestFocus = false
                    self.requestInitialFocus()
                }
            }
        }

        func requestInitialFocus() {
            guard let textView else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                textView.window?.makeKeyAndOrderFront(nil)
                textView.window?.makeFirstResponder(textView)
                self.didRequestFocus = true
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            toolbarController.syncWithSelection()
        }

        func textDidChange(_ notification: Notification) {
            if isApplyingBulkChange { return }
            guard let textView = textView else { return }
            let attr = textView.attributedString()
            notesStorage.saveNoteAttributed(id: noteId, attributed: attr)
            updatePlaceholderVisibility()
        }

        func setupPlaceholder(in container: NSView) {
            let label = NSTextField(labelWithString: "Start writing...")
            label.font = DesignTokens.Typography.bodyNSFont
            label.textColor = NSColor.white.withAlphaComponent(0.3)
            label.backgroundColor = .clear
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            placeholderField = label
        }

        func constrainPlaceholder(in container: NSView) {
            guard let label = placeholderField else { return }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 25),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 18)
            ])
        }

        func updatePlaceholderVisibility() {
            guard let tv = textView else { return }
            placeholderField?.isHidden = tv.string.isEmpty == false
        }

        // MARK: - Formatting

        func ensureFirstResponder() {
            guard let tv = textView else { return }
            tv.window?.makeKeyAndOrderFront(nil)
            tv.window?.makeFirstResponder(tv)
        }

        func applyBold()   { applyFontTrait(.boldFontMask) }
        func applyItalic() { applyFontTrait(.italicFontMask) }

        func applyUnderline() {
            applyUnderlineLike(attribute: .underlineStyle)
        }

        func applyStrikethrough() {
            applyUnderlineLike(attribute: .strikethroughStyle)
        }

        func applyInlineCode() {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }

            // Detect "already inline code" via the monospaced font trait — this
            // survives RTF serialization (unlike a custom attribute key, which
            // Apple's RTF serializer silently drops on round-trip).
            var alreadyCoded = false
            storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                if let f = value as? NSFont,
                   f.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                    alreadyCoded = true
                    stop.pointee = true
                }
            }

            let defaultFgColor = NSColor.white.withAlphaComponent(0.9)
            let inlineCodeFgColor = NSColor(Color(hex: "#A3A3A3"))
            let inlineCodeBgColor = NSColor.white.withAlphaComponent(0.08)

            storage.beginEditing()
            if alreadyCoded {
                // Preserve bold/italic traits from each run while swapping the
                // monospaced face back to the body face. Assigning bodyNSFont
                // wholesale (a single flat font) would silently strip bold/italic
                // inside mixed runs.
                storage.removeAttribute(.backgroundColor, range: range)
                storage.addAttribute(.foregroundColor, value: defaultFgColor, range: range)
                let fm = NSFontManager.shared
                storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                    let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                    var mask: NSFontTraitMask = []
                    if traits.contains(.bold)   { mask.insert(.boldFontMask) }
                    if traits.contains(.italic) { mask.insert(.italicFontMask) }
                    let newFont = mask.isEmpty
                        ? DesignTokens.Typography.bodyNSFont
                        : fm.convert(DesignTokens.Typography.bodyNSFont, toHaveTrait: mask)
                    storage.addAttribute(.font, value: newFont, range: subRange)
                }
            } else {
                storage.addAttribute(.backgroundColor, value: inlineCodeBgColor, range: range)
                storage.addAttribute(.font, value: DesignTokens.Typography.inlineCodeNSFont, range: range)
                storage.addAttribute(.foregroundColor, value: inlineCodeFgColor, range: range)
            }
            storage.endEditing()
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        func applyLink(_ urlString: String) {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            guard let url = URL(string: urlString) else { return }

            if range.length == 0 {
                // No selection — insert the URL string and link it.
                let attr = NSAttributedString(string: urlString, attributes: [
                    .link: url,
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: DesignTokens.Typography.bodyNSFont
                ])
                storage.beginEditing()
                storage.replaceCharacters(in: range, with: attr)
                storage.endEditing()
            } else {
                guard NSMaxRange(range) <= storage.length else { return }
                storage.beginEditing()
                storage.addAttribute(.link, value: url, range: range)
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                storage.endEditing()
            }
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        func currentSelectionURL() -> String? {
            guard let tv = textView, let storage = tv.textStorage else { return nil }
            let range = tv.selectedRange()
            guard range.location < storage.length else { return nil }
            if let url = storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL {
                return url.absoluteString
            }
            return nil
        }

        func applyHeading(_ level: HeadingLevel) {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let nsString = tv.string as NSString
            let selectedRange = tv.selectedRange()
            let paragraphRange = nsString.paragraphRange(for: selectedRange)
            guard paragraphRange.length > 0, NSMaxRange(paragraphRange) <= storage.length else { return }

            let font: NSFont
            switch level {
            case .paragraph: font = DesignTokens.Typography.bodyNSFont
            case .h1:        font = DesignTokens.Typography.h1NSFont
            case .h2:        font = DesignTokens.Typography.h2NSFont
            case .h3:        font = DesignTokens.Typography.h3NSFont
            }

            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: paragraphRange)
            // Strip inline-code chrome — background color + the #A3A3A3
            // foreground — so a paragraph that was previously inline-coded
            // reads clean after promotion to a heading. The overwriting
            // `.font` assignment above already clears the monospaced trait.
            storage.removeAttribute(.backgroundColor, range: paragraphRange)
            storage.addAttribute(
                .foregroundColor,
                value: NSColor.white.withAlphaComponent(0.9),
                range: paragraphRange
            )
            storage.endEditing()

            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        // MARK: Shared helpers

        private func applyFontTrait(_ trait: NSFontTraitMask) {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            let fm = NSFontManager.shared
            let symTrait = symbolicTrait(for: trait)

            if range.length == 0 {
                let font = (tv.typingAttributes[.font] as? NSFont) ?? DesignTokens.Typography.bodyNSFont
                let hasTrait = font.fontDescriptor.symbolicTraits.contains(symTrait)
                tv.typingAttributes[.font] = hasTrait
                    ? fm.convert(font, toNotHaveTrait: trait)
                    : fm.convert(font, toHaveTrait: trait)
                return
            }
            guard NSMaxRange(range) <= storage.length else { return }

            // Toggle semantics: if any run in the selection lacks the trait, add
            // it everywhere; otherwise remove it everywhere. Mirrors the cursor-
            // only branch and matches Notion/Word's Bold button behavior.
            // `NSTextStorage.applyFontTraits(_:range:)` only ADDS the trait, so
            // we hand-roll the toggle with per-run convert().
            var allHaveTrait = true
            storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                let font = (value as? NSFont) ?? DesignTokens.Typography.bodyNSFont
                if !font.fontDescriptor.symbolicTraits.contains(symTrait) {
                    allHaveTrait = false
                    stop.pointee = true
                }
            }

            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                let font = (value as? NSFont) ?? DesignTokens.Typography.bodyNSFont
                let newFont = allHaveTrait
                    ? fm.convert(font, toNotHaveTrait: trait)
                    : fm.convert(font, toHaveTrait: trait)
                storage.addAttribute(.font, value: newFont, range: subRange)
            }
            storage.endEditing()
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        private func symbolicTrait(for mask: NSFontTraitMask) -> NSFontDescriptor.SymbolicTraits {
            switch mask {
            case .boldFontMask:   return .bold
            case .italicFontMask: return .italic
            default:              return []
            }
        }

        private func applyUnderlineLike(attribute: NSAttributedString.Key) {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()

            if range.length == 0 {
                let cur = tv.typingAttributes[attribute] as? Int ?? 0
                tv.typingAttributes[attribute] = cur == 0 ? NSUnderlineStyle.single.rawValue : 0
                return
            }

            guard NSMaxRange(range) <= storage.length else { return }
            var hasIt = false
            storage.enumerateAttribute(attribute, in: range, options: []) { value, _, stop in
                if let n = value as? Int, n != 0 { hasIt = true; stop.pointee = true }
            }
            let newVal = hasIt ? 0 : NSUnderlineStyle.single.rawValue
            storage.beginEditing()
            storage.addAttribute(attribute, value: newVal, range: range)
            storage.endEditing()
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

    }
}
