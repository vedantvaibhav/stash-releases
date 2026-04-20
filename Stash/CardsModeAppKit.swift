import AppKit
import SwiftUI
import Combine

// MARK: - Card identity (used by AppKit stack)

enum QuickPanelCardKind: Int, CaseIterable {
    case clipboard
    case notes
    case files

    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .notes: return "Notes"
        case .files: return "Files"
        }
    }

    var symbolName: String {
        switch self {
        case .clipboard: return "clock"
        case .notes: return "note.text"
        case .files: return "folder"
        }
    }
}

// MARK: - Shared panel interaction (notes editor + delete alerts) for Panel + Cards AppKit

final class PanelInteractionState: ObservableObject {
    @Published var editingNoteId: String?
    @Published var noteToDelete: NoteItem?
    @Published var fileToDelete: DroppedFileItem?
    /// When true, notes column shows the live transcription page (shared between panel + cards + floating widget).
    @Published var showTranscriptionPage: Bool = false
    /// Set externally (e.g. after transcription completes) to switch the panel to a specific tab.
    /// `PanelContentView` consumes this via `.onChange` and clears it back to nil.
    @Published var requestedTab: PanelMainTab? = nil
}

// MARK: - SwiftUI roots (ObservedObject so NSHostingView refreshes on model changes)

private struct CardsClipboardRoot: View {
    @ObservedObject var clipboard: ClipboardManager

    var body: some View {
        SharedClipboardColumn(clipboard: clipboard, forCardsMode: true, maxEntries: 6)
            .frame(width: ExpandableCardView.innerWidth)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CardsNotesRoot: View {
    var makePanelKey: () -> Void
    @ObservedObject var notes: NotesStorage
    @ObservedObject var interaction: PanelInteractionState
    @ObservedObject var transcription: TranscriptionService

    var body: some View {
        SharedNotesColumn(
            makePanelKey: makePanelKey,
            notesStorage: notes,
            transcription: transcription,
            showTranscriptionPage: Binding(
                get: { interaction.showTranscriptionPage },
                set: { interaction.showTranscriptionPage = $0 }
            ),
            editingNoteId: Binding(
                get: { interaction.editingNoteId },
                set: { interaction.editingNoteId = $0 }
            ),
            noteToDelete: Binding(
                get: { interaction.noteToDelete },
                set: { interaction.noteToDelete = $0 }
            ),
            forCardsMode: true,
            maxListNotes: 5
        )
        .frame(width: ExpandableCardView.innerWidth)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Delete note?", isPresented: Binding(
            get: { interaction.noteToDelete != nil },
            set: { if !$0 { interaction.noteToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { interaction.noteToDelete = nil }
            Button("Delete", role: .destructive) {
                if let n = interaction.noteToDelete {
                    notes.deleteNote(id: n.id)
                    interaction.noteToDelete = nil
                }
            }
        } message: {
            Text("This note will be permanently deleted.")
        }
    }
}

private struct CardsFilesRoot: View {
    @ObservedObject var fileStorage: FileDropStorage
    @ObservedObject var interaction: PanelInteractionState
    @ObservedObject var fileSelection: FileSelectionState
    @ObservedObject var fileGridHover: FileGridHoverState
    @ObservedObject var fileQuickLook: FileQuickLookController

    var body: some View {
        SharedFilesColumn(
            fileDropStorage: fileStorage,
            fileToDelete: Binding(
                get: { interaction.fileToDelete },
                set: { interaction.fileToDelete = $0 }
            ),
            forCardsMode: true,
            maxFileItems: 4,
            fileSelection: fileSelection,
            fileGridHover: fileGridHover,
            fileQuickLook: fileQuickLook
        )
        .frame(width: ExpandableCardView.innerWidth)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Delete file?", isPresented: Binding(
            get: { interaction.fileToDelete != nil },
            set: { if !$0 { interaction.fileToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { interaction.fileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let f = interaction.fileToDelete {
                    fileStorage.removeFile(f)
                    interaction.fileToDelete = nil
                }
            }
        } message: {
            Text("The file will be removed from the list and deleted from your Mac.")
        }
    }
}

// MARK: - Expansion coordinator (one card open; sequential collapse → expand)

final class CardsExpansionCoordinator {
    weak var panelController: PanelController?
    private(set) weak var expandedCard: ExpandableCardView?

    func requestExpand(_ card: ExpandableCardView) {
        if expandedCard === card, card.isCardExpanded { return }

        if let ex = expandedCard, ex !== card {
            ex.collapse(animated: true) { [weak self] in
                guard let self else { return }
                self.expandedCard = card
                card.expand(animated: true)
            }
        } else {
            expandedCard = card
            card.expand(animated: true)
        }
    }

    func requestCollapse(_ card: ExpandableCardView) {
        guard expandedCard === card else { return }
        card.collapse(animated: true) { [weak self] in
            if self?.expandedCard === card { self?.expandedCard = nil }
        }
    }

    func expandFilesForDrag(_ card: ExpandableCardView) {
        guard card.kind == .files else { return }
        if expandedCard === card, card.isCardExpanded { return }

        if let ex = expandedCard, ex !== card {
            ex.collapse(animated: true) { [weak self] in
                guard let self else { return }
                self.expandedCard = card
                card.expand(animated: true)
            }
        } else {
            expandedCard = card
            card.expand(animated: true)
        }
    }

}

// MARK: - ExpandableCardView

final class ExpandableCardView: NSView {

    static let headerHeight: CGFloat = 52
    static let cardWidth: CGFloat = 420
    static let innerWidth: CGFloat = 396

    let kind: QuickPanelCardKind
    weak var coordinator: CardsExpansionCoordinator?

    private let headerBar = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")

    private let bodyContainer = NSView()
    private let effectView = NSVisualEffectView()
    /// Spec: white ~6% over blur material.
    private let tintOverlay = NSView()
    private let hostingContainer = NSView()

    private var hostingView: NSHostingView<AnyView>!
    private var heightConstraint: NSLayoutConstraint!
    private var bodyHeightConstraint: NSLayoutConstraint!

    private var hoverIntentToken = UUID()
    private(set) var isCardExpanded = false
    /// True while an external file drag session targets this card (Files only).
    private var isFileDragOverCard = false

    /// Measured content height (below header).
    private var targetBodyHeight: CGFloat = 0

    init(kind: QuickPanelCardKind, rootView: AnyView) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        setupHeader()
        setupBody(rootView: rootView)
        setupConstraints()

        if kind == .files {
            registerForDraggedTypes([.fileURL])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupHeader() {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        let tint = NSColor.white.withAlphaComponent(0.9)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = tint
        if let img = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            iconView.image = img.withSymbolConfiguration(config)
        }
        headerBar.addSubview(iconView)

        titleLabel.stringValue = kind.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = tint
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.backgroundColor = .clear
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(titleLabel)

        badgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        badgeLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        badgeLabel.isEditable = false
        badgeLabel.isBordered = false
        badgeLabel.backgroundColor = .clear
        badgeLabel.alignment = .right
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            badgeLabel.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -14),
            badgeLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
        ])
    }

    private func setupBody(rootView: AnyView) {
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bodyContainer)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        effectView.alphaValue = 0
        bodyContainer.addSubview(effectView)

        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.cornerRadius = 14
        tintOverlay.layer?.masksToBounds = true
        tintOverlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        tintOverlay.alphaValue = 0
        bodyContainer.addSubview(tintOverlay)

        hostingContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(hostingContainer)

        hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.wantsLayer = true
        hostingContainer.addSubview(hostingView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

            tintOverlay.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

            hostingContainer.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            hostingContainer.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            hostingContainer.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            hostingContainer.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),

            hostingView.leadingAnchor.constraint(equalTo: hostingContainer.leadingAnchor, constant: 6),
            hostingView.trailingAnchor.constraint(equalTo: hostingContainer.trailingAnchor, constant: -6),
            hostingView.topAnchor.constraint(equalTo: hostingContainer.topAnchor, constant: 4),
            hostingView.bottomAnchor.constraint(equalTo: hostingContainer.bottomAnchor, constant: -6)
        ])
    }

    private func setupConstraints() {
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.headerHeight)
        bodyHeightConstraint = bodyContainer.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.cardWidth),
            heightConstraint,

            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.topAnchor.constraint(equalTo: topAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyContainer.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            bodyHeightConstraint
        ])
    }

    func remeasureContentHeight() {
        layoutSubtreeIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let targetWidth = Self.innerWidth
        hostingView.setFrameSize(NSSize(width: targetWidth, height: 800))
        hostingView.layoutSubtreeIfNeeded()

        let h = hostingView.fittingSize.height
        targetBodyHeight = min(max(h, 1), 520)
    }

    /// After data changes while expanded, animate only if measured height actually changed.
    func syncExpandedHeightIfNeeded(animated: Bool) {
        guard isCardExpanded else { return }
        remeasureContentHeight()
        let newBodyH = targetBodyHeight
        guard abs(bodyHeightConstraint.constant - newBodyH) > 0.5 else { return }

        let newTotal = Self.headerHeight + newBodyH
        let apply = {
            self.bodyHeightConstraint.constant = newBodyH
            self.heightConstraint.constant = newTotal
            self.layoutSubtreeIfNeeded()
            self.coordinator?.panelController?.applyCardsPanelFrameFromStack(animated: animated, duration: 0.24)
        }

        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                apply()
            }, completionHandler: nil)
        } else {
            apply()
        }
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard kind != .files || !isFileDragOverCard else { return }
        let token = UUID()
        hoverIntentToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, self.hoverIntentToken == token else { return }
            self.coordinator?.requestExpand(self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverIntentToken = UUID()
        if !isFileDragOverCard {
            coordinator?.requestCollapse(self)
        }
    }

    // MARK: - Drag (Files only)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard kind == .files else { return [] }
        isFileDragOverCard = true
        coordinator?.expandFilesForDrag(self)
        startDragBorderPulse()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        kind == .files ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard kind == .files else { return }
        isFileDragOverCard = false
        stopDragBorderPulse()
        layer?.borderWidth = 0
        layer?.cornerRadius = 0
        coordinator?.requestCollapse(self)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

    private func startDragBorderPulse() {
        guard kind == .files else { return }
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1
        let a = CABasicAnimation(keyPath: "borderColor")
        a.fromValue = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        a.toValue = NSColor.controlAccentColor.cgColor
        a.duration = 0.6
        a.autoreverses = true
        a.repeatCount = .greatestFiniteMagnitude
        layer?.add(a, forKey: "pulseBorder")
    }

    private func stopDragBorderPulse() {
        layer?.removeAnimation(forKey: "pulseBorder")
    }

    // MARK: - Expand / collapse

    func expand(animated: Bool) {
        if isCardExpanded { return }

        remeasureContentHeight()
        let newBodyH = targetBodyHeight
        let newTotal = Self.headerHeight + newBodyH
        isCardExpanded = true

        let applyHeights = {
            self.bodyHeightConstraint.constant = newBodyH
            self.heightConstraint.constant = newTotal
        }

        let showChrome: () -> Void = {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.effectView.animator().alphaValue = 1
                self.tintOverlay.animator().alphaValue = 1
            }
        }

        let showContent: () -> Void = {
            guard let layer = self.hostingView.layer else { return }
            layer.opacity = 0
            layer.transform = CATransform3DMakeTranslation(0, 4, 0)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
            }
        }

        if !animated {
            applyHeights()
            effectView.alphaValue = 1
            tintOverlay.alphaValue = 1
            hostingView.layer?.opacity = 1
            hostingView.layer?.transform = CATransform3DIdentity
            layoutSubtreeIfNeeded()
            coordinator?.panelController?.applyCardsPanelFrameFromStack(animated: false, duration: 0)
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            applyHeights()
            self.layoutSubtreeIfNeeded()
            self.panelWindowResizeSynchronized(duration: 0.24)
        }, completionHandler: nil)

        showChrome()
        showContent()
    }

    func collapse(animated: Bool, completion: (() -> Void)? = nil) {
        guard isCardExpanded else {
            completion?()
            return
        }
        isCardExpanded = false

        let hideContent: () -> Void = {
            guard let layer = self.hostingView.layer else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                layer.opacity = 0
                layer.transform = CATransform3DMakeTranslation(0, 4, 0)
            }
        }

        let hideChrome: () -> Void = {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.effectView.animator().alphaValue = 0
                self.tintOverlay.animator().alphaValue = 0
            }
        }

        hideContent()
        hideChrome()

        if !animated {
            bodyHeightConstraint.constant = 0
            heightConstraint.constant = Self.headerHeight
            layoutSubtreeIfNeeded()
            coordinator?.panelController?.applyCardsPanelFrameFromStack(animated: false, duration: 0)
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            self.bodyHeightConstraint.constant = 0
            self.heightConstraint.constant = Self.headerHeight
            self.layoutSubtreeIfNeeded()
            self.panelWindowResizeSynchronized(duration: 0.15)
        }, completionHandler: { [weak self] in
            completion?()
        })
    }

    private func panelWindowResizeSynchronized(duration: TimeInterval) {
        coordinator?.panelController?.applyCardsPanelFrameFromStack(animated: true, duration: duration)
    }

    func currentTotalHeight() -> CGFloat {
        heightConstraint.constant
    }

    func updateBadge(text: String) {
        badgeLabel.stringValue = text
    }
}

// MARK: - Stack container

final class CardsModeContainerView: NSView {

    private let stack = NSStackView()
    private var cards: [ExpandableCardView] = []
    private var cancellables = Set<AnyCancellable>()

    let coordinator = CardsExpansionCoordinator()

    init(
        clipboard: ClipboardManager,
        notes: NotesStorage,
        fileStorage: FileDropStorage,
        interaction: PanelInteractionState,
        transcription: TranscriptionService,
        makePanelKey: @escaping () -> Void,
        panelController: PanelController,
        fileSelection: FileSelectionState,
        fileGridHover: FileGridHoverState,
        fileQuickLook: FileQuickLookController
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        coordinator.panelController = panelController

        let clipRoot = AnyView(CardsClipboardRoot(clipboard: clipboard))
        let notesRoot = AnyView(CardsNotesRoot(makePanelKey: makePanelKey, notes: notes, interaction: interaction, transcription: transcription))
        let filesRoot = AnyView(CardsFilesRoot(
            fileStorage: fileStorage,
            interaction: interaction,
            fileSelection: fileSelection,
            fileGridHover: fileGridHover,
            fileQuickLook: fileQuickLook
        ))

        let c0 = ExpandableCardView(kind: .clipboard, rootView: clipRoot)
        let c1 = ExpandableCardView(kind: .notes, rootView: notesRoot)
        let c2 = ExpandableCardView(kind: .files, rootView: filesRoot)
        c0.coordinator = coordinator
        c1.coordinator = coordinator
        c2.coordinator = coordinator
        cards = [c0, c1, c2]

        stack.orientation = .vertical
        stack.spacing = 10
        stack.alignment = .leading
        stack.distribution = .gravityAreas
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for c in cards { stack.addArrangedSubview(c) }
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        refreshAll(clipboard: clipboard, notes: notes, files: fileStorage)
        clipboard.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAll(clipboard: clipboard, notes: notes, files: fileStorage) }
            .store(in: &cancellables)
        notes.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAll(clipboard: clipboard, notes: notes, files: fileStorage) }
            .store(in: &cancellables)
        fileStorage.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshAll(clipboard: clipboard, notes: notes, files: fileStorage) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refreshAll(clipboard: ClipboardManager, notes: NotesStorage, files: FileDropStorage) {
        let n0 = clipboard.entries.count
        cards[0].updateBadge(text: n0 == 1 ? "1 item" : "\(n0) items")
        let n1 = notes.notes.count
        cards[1].updateBadge(text: n1 == 1 ? "1 note" : "\(n1) notes")
        let n2 = files.files.count
        cards[2].updateBadge(text: n2 == 1 ? "1 file" : "\(n2) files")

        for c in cards {
            c.syncExpandedHeightIfNeeded(animated: true)
        }
    }

    func totalStackHeight() -> CGFloat {
        let inner = cards.reduce(0) { $0 + $1.currentTotalHeight() } + CGFloat(max(0, cards.count - 1)) * stack.spacing
        return inner + stack.edgeInsets.top + stack.edgeInsets.bottom
    }
}
