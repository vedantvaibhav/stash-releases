import AppKit
import Combine
import QuartzCore

// MARK: - Shimmer label (CAGradientLayer + text mask)

private final class ShimmerLabelView: NSView {

    private let gradient = CAGradientLayer()
    private let textLayer = CATextLayer()
    private var lastSize = CGSize.zero
    private var lastString = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        gradient.colors = [
            NSColor.white.withAlphaComponent(0.6).cgColor,
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.6).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.locations = [-0.3, -0.1, 0.1] as [NSNumber]
        layer?.addSublayer(gradient)

        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        textLayer.fontSize = 13
        gradient.mask = textLayer

        startShimmerAnimation()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func startShimmerAnimation() {
        let anim = CABasicAnimation(keyPath: "locations")
        anim.fromValue = [-0.3, -0.1, 0.1] as [NSNumber]
        anim.toValue = [0.9, 1.1, 1.3] as [NSNumber]
        anim.duration = 1.8
        anim.repeatCount = .greatestFiniteMagnitude
        anim.isRemovedOnCompletion = false
        gradient.add(anim, forKey: "shimmer")
    }

    func setText(_ string: String, shimmerEnabled: Bool) {
        lastString = string
        textLayer.string = string
        if shimmerEnabled {
            startShimmerAnimation()
            gradient.isHidden = false
        } else {
            gradient.removeAnimation(forKey: "shimmer")
            gradient.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        gradient.frame = bounds
        textLayer.frame = CGRect(x: 0, y: (h - 18) / 2, width: w, height: 20)
        if lastSize != bounds.size || lastString != (textLayer.string as? String ?? "") {
            lastSize = bounds.size
        }
    }
}

// MARK: - Pulsing dot

private final class PulsingDotView: NSView {

    private let dot = CALayer()
    private var pulseColor: NSColor = .systemRed

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        dot.frame = CGRect(x: 0, y: 0, width: 8, height: 8)
        dot.cornerRadius = 4
        layer?.addSublayer(dot)
        applyColor()
        startPulse()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPulseColor(_ color: NSColor) {
        pulseColor = color
        applyColor()
    }

    private func applyColor() {
        dot.backgroundColor = pulseColor.cgColor
    }

    private func startPulse() {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.4
        anim.toValue = 1.0
        anim.duration = 1.0
        anim.autoreverses = true
        anim.repeatCount = .greatestFiniteMagnitude
        anim.isRemovedOnCompletion = false
        dot.add(anim, forKey: "pulse")
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        dot.position = CGPoint(x: 4, y: h / 2)
    }
}

// MARK: - Widget content (pill)

private final class TranscriptionFloatingWidgetContentView: NSView {

    var onTap: (() -> Void)?

    private let effectView = NSVisualEffectView()
    private let tintOverlay = NSView()
    private let shadowContainer = NSView()
    private let hStack = NSStackView()
    private let pulsingDot = PulsingDotView(frame: .zero)
    private let shimmerLabel = ShimmerLabelView(frame: .zero)
    private let plainCenterLabel = NSTextField(labelWithString: "")
    private let durationLabel = NSTextField(labelWithString: "0:00")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: 4)

        shadowContainer.translatesAutoresizingMaskIntoConstraints = false
        shadowContainer.wantsLayer = true
        shadowContainer.layer?.cornerRadius = 18
        shadowContainer.layer?.masksToBounds = true

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .hudWindow
        effectView.blendingMode = .withinWindow
        effectView.state = .active

        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        tintOverlay.wantsLayer = true
        tintOverlay.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor

        hStack.orientation = .horizontal
        hStack.alignment = .centerY
        hStack.spacing = 8
        hStack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        hStack.translatesAutoresizingMaskIntoConstraints = false

        pulsingDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pulsingDot.widthAnchor.constraint(equalToConstant: 8),
            pulsingDot.heightAnchor.constraint(equalToConstant: 8)
        ])

        shimmerLabel.translatesAutoresizingMaskIntoConstraints = false
        shimmerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        shimmerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        plainCenterLabel.translatesAutoresizingMaskIntoConstraints = false
        plainCenterLabel.font = .systemFont(ofSize: 13, weight: .medium)
        plainCenterLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        plainCenterLabel.alignment = .center
        plainCenterLabel.isEditable = false
        plainCenterLabel.isBordered = false
        plainCenterLabel.backgroundColor = .clear
        plainCenterLabel.isHidden = true

        durationLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        durationLabel.alignment = .right
        durationLabel.isEditable = false
        durationLabel.isBordered = false
        durationLabel.backgroundColor = .clear
        durationLabel.setContentHuggingPriority(.required, for: .horizontal)

        hStack.addArrangedSubview(pulsingDot)
        hStack.addArrangedSubview(shimmerLabel)
        hStack.addArrangedSubview(plainCenterLabel)
        hStack.addArrangedSubview(durationLabel)

        // Outer self carries the soft shadow; inner pill clips blur + content.
        addSubview(shadowContainer)
        shadowContainer.addSubview(effectView)
        shadowContainer.addSubview(tintOverlay)
        shadowContainer.addSubview(hStack)

        NSLayoutConstraint.activate([
            shadowContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            shadowContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            shadowContainer.topAnchor.constraint(equalTo: topAnchor),
            shadowContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            effectView.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor),

            tintOverlay.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
            tintOverlay.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor),

            hStack.leadingAnchor.constraint(equalTo: shadowContainer.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: shadowContainer.trailingAnchor),
            hStack.topAnchor.constraint(equalTo: shadowContainer.topAnchor),
            hStack.bottomAnchor.constraint(equalTo: shadowContainer.bottomAnchor)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleClick() {
        onTap?()
    }

    enum DisplayMode {
        case recording
        case processing
        case noteReady
    }

    func apply(mode: DisplayMode, durationSeconds: Int) {
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        durationLabel.stringValue = String(format: "%d:%02d", m, s)

        switch mode {
        case .recording:
            pulsingDot.isHidden = false
            pulsingDot.setPulseColor(.systemRed)
            shimmerLabel.isHidden = false
            plainCenterLabel.isHidden = true
            shimmerLabel.setText("Transcribing...", shimmerEnabled: true)
            durationLabel.isHidden = false
        case .processing:
            pulsingDot.isHidden = false
            pulsingDot.setPulseColor(.systemBlue)
            shimmerLabel.isHidden = true
            plainCenterLabel.isHidden = false
            plainCenterLabel.stringValue = "Processing..."
            plainCenterLabel.textColor = NSColor.white.withAlphaComponent(0.6)
            durationLabel.isHidden = false
        case .noteReady:
            pulsingDot.isHidden = true
            shimmerLabel.isHidden = true
            plainCenterLabel.isHidden = false
            plainCenterLabel.stringValue = "Note ready ✓"
            plainCenterLabel.textColor = NSColor.systemGreen
            durationLabel.isHidden = true
        }
    }
}

// MARK: - Floating panel

private final class TranscriptionFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Granola-style pill when the main QuickPanel is hidden during transcription / processing.
@MainActor
final class TranscriptionFloatingWidgetController: NSObject {

    private weak var transcription: TranscriptionService?
    private var panelOpenForWidget: Bool = false
    private var lastWidgetMode: WidgetMode = .none
    private var isShowingNoteReadyBanner = false
    private var noteReadyWorkItem: DispatchWorkItem?

    private var panel: TranscriptionFloatingPanel?
    private var contentView: TranscriptionFloatingWidgetContentView?
    private var cancellables = Set<AnyCancellable>()

    private enum WidgetMode {
        case none
        case recording
        case processing
        case noteReady
    }

    var onOpenTranscription: (() -> Void)?

    func attach(transcription: TranscriptionService) {
        self.transcription = transcription
        transcription.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.sync()
            }
            .store(in: &cancellables)
        sync()
    }

    func setPanelOpenForWidget(_ open: Bool) {
        panelOpenForWidget = open
        sync()
    }

    private func sync() {
        guard let transcription else { return }

        noteReadyWorkItem?.cancel()
        noteReadyWorkItem = nil

        if panelOpenForWidget {
            noteReadyWorkItem?.cancel()
            noteReadyWorkItem = nil
            hidePanel()
            lastWidgetMode = .none
            isShowingNoteReadyBanner = false
            return
        }

        let recording = transcription.isRecording
        let processing = transcription.isProcessing

        if recording {
            isShowingNoteReadyBanner = false
            noteReadyWorkItem?.cancel()
            noteReadyWorkItem = nil
            lastWidgetMode = .recording
            showPanelIfNeeded()
            contentView?.apply(mode: .recording, durationSeconds: transcription.duration)
            return
        }

        if processing {
            isShowingNoteReadyBanner = false
            noteReadyWorkItem?.cancel()
            noteReadyWorkItem = nil
            lastWidgetMode = .processing
            showPanelIfNeeded()
            contentView?.apply(mode: .processing, durationSeconds: transcription.duration)
            return
        }

        if isShowingNoteReadyBanner {
            return
        }

        if lastWidgetMode == .processing {
            lastWidgetMode = .noteReady
            isShowingNoteReadyBanner = true
            showPanelIfNeeded()
            contentView?.apply(mode: .noteReady, durationSeconds: transcription.duration)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hidePanel()
                self.lastWidgetMode = .none
                self.isShowingNoteReadyBanner = false
                self.noteReadyWorkItem = nil
            }
            noteReadyWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return
        }

        hidePanel()
        lastWidgetMode = .none
        isShowingNoteReadyBanner = false
    }

    private func showPanelIfNeeded() {
        if panel == nil {
            buildPanel()
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let w: CGFloat = 220
        let h: CGFloat = 36
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)

        let p = TranscriptionFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = level
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = TranscriptionFloatingWidgetContentView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.translatesAutoresizingMaskIntoConstraints = true
        root.autoresizingMask = [.width, .height]
        root.onTap = { [weak self] in
            self?.onOpenTranscription?()
        }

        p.contentView = root
        contentView = root
        panel = p
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let w: CGFloat = 220
        let h: CGFloat = 36
        let x = vf.midX - w / 2
        let y = vf.maxY - 12 - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}
