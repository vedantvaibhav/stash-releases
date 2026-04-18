import AppKit
import SwiftUI

// MARK: - Rich single-note editor (NSTextView + RTF) + compact formatting bar

struct SingleNoteEditorView: NSViewRepresentable {
    let noteId: String
    let notesStorage: NotesStorage

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 2
        toolbar.distribution = .fill
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        func formatButton(symbolName: String, accessibility: String, action: Selector) -> NSButton {
            let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibility)!
            img.isTemplate = true
            let b = NSButton(image: img, target: context.coordinator, action: action)
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.controlSize = .small
            b.toolTip = accessibility
            return b
        }

        toolbar.addArrangedSubview(formatButton(symbolName: "bold", accessibility: "Bold", action: #selector(Coordinator.toggleBold)))
        toolbar.addArrangedSubview(formatButton(symbolName: "italic", accessibility: "Italic", action: #selector(Coordinator.toggleItalic)))
        toolbar.addArrangedSubview(formatButton(symbolName: "underline", accessibility: "Underline", action: #selector(Coordinator.toggleUnderline)))
        toolbar.addArrangedSubview(NSView()) // spacer

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

        scrollView.documentView = textView

        context.coordinator.noteId = noteId
        context.coordinator.notesStorage = notesStorage
        context.coordinator.textView = textView
        context.coordinator.boundNoteId = noteId
        context.coordinator.didRequestFocus = false
        context.coordinator.isApplyingBulkChange = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: "", attributes: Self.defaultTypingAttributes())
        )
        context.coordinator.isApplyingBulkChange = false
        context.coordinator.scheduleLoad(noteId: noteId, storage: notesStorage)

        container.addSubview(toolbar)
        container.addSubview(scrollView)

        context.coordinator.setupPlaceholder(in: container)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.constrainPlaceholder(in: container, below: toolbar)

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

    private static func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.7
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraphStyle
        ]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var noteId: String = ""
        var notesStorage: NotesStorage!
        weak var textView: NSTextView?
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

        func textDidChange(_ notification: Notification) {
            if isApplyingBulkChange { return }
            guard let textView = textView else { return }
            let attr = textView.attributedString()
            notesStorage.saveNoteAttributed(id: noteId, attributed: attr)
            updatePlaceholderVisibility()
        }

        func setupPlaceholder(in container: NSView) {
            let label = NSTextField(labelWithString: "Start writing...")
            label.font = NSFont.systemFont(ofSize: 14)
            label.textColor = NSColor.white.withAlphaComponent(0.3)
            label.backgroundColor = .clear
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            placeholderField = label
        }

        func constrainPlaceholder(in container: NSView, below toolbar: NSView) {
            guard let label = placeholderField else { return }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 25),
                label.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 18)
            ])
        }

        func updatePlaceholderVisibility() {
            guard let tv = textView else { return }
            placeholderField?.isHidden = tv.string.isEmpty == false
        }

        // MARK: Formatting (selection or typing attributes)

        private func ensureFirstResponder() {
            guard let tv = textView else { return }
            tv.window?.makeKeyAndOrderFront(nil)
            tv.window?.makeFirstResponder(tv)
        }

        @objc func toggleBold() {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            if range.length == 0 {
                let font = (tv.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let traits = font.fontDescriptor.symbolicTraits
                let hasBold = traits.contains(.bold)
                let fm = NSFontManager.shared
                tv.typingAttributes[.font] = hasBold
                    ? fm.convert(font, toNotHaveTrait: .boldFontMask)
                    : fm.convert(font, toHaveTrait: .boldFontMask)
                notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
                return
            }
            storage.applyFontTraits(.boldFontMask, range: range)
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        @objc func toggleItalic() {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            if range.length == 0 {
                let font = (tv.typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let traits = font.fontDescriptor.symbolicTraits
                let hasItalic = traits.contains(.italic)
                let fm = NSFontManager.shared
                tv.typingAttributes[.font] = hasItalic
                    ? fm.convert(font, toNotHaveTrait: .italicFontMask)
                    : fm.convert(font, toHaveTrait: .italicFontMask)
                notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
                return
            }
            storage.applyFontTraits(.italicFontMask, range: range)
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        @objc func toggleUnderline() {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()

            if range.length == 0 {
                let cur = tv.typingAttributes[.underlineStyle] as? Int ?? 0
                let newVal = cur == 0 ? NSUnderlineStyle.single.rawValue : 0
                tv.typingAttributes[.underlineStyle] = newVal
                notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
                return
            }

            guard NSMaxRange(range) <= storage.length else { return }

            var hasUnderline = false
            storage.enumerateAttribute(.underlineStyle, in: range, options: []) { value, _, stop in
                if let n = value as? Int, n != 0 { hasUnderline = true; stop.pointee = true }
            }
            let newVal = hasUnderline ? 0 : NSUnderlineStyle.single.rawValue
            storage.beginEditing()
            storage.addAttribute(.underlineStyle, value: newVal, range: range)
            storage.endEditing()
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }
    }
}
