import AppKit
import Combine
import QuartzCore
import SwiftUI

// MARK: - Waveform icon (SwiftUI) — six live bars bouncing out of phase

struct PillWaveformIcon: View {
    @State private var pulse = false

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 18, weight: .medium))
            .foregroundColor(.white)
            .scaleEffect(pulse ? 1.18 : 0.82)
            .opacity(pulse ? 1.0 : 0.55)
            .animation(
                .easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

// MARK: - 28×28 circle wrapper hosting the SwiftUI bars

private final class PillWaveformCircleView: NSView {
    private let hosting = NSHostingView(rootView: PillWaveformIcon())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 36×36 circle background — same fill as HeaderIconButton rest state
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor

        // 18×18 SwiftUI SF-Symbol waveform, centred
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.widthAnchor.constraint(equalToConstant: 18),
            hosting.heightAnchor.constraint(equalToConstant: 18),
            hosting.centerXAnchor.constraint(equalTo: centerXAnchor),
            hosting.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Pill content view

private final class PillContentView: NSView {
    var onStop: (() -> Void)?

    // Waveform pinned left during recording; a single rightStack on the right
    // whose arranged subviews swap per mode (timer+stop / spinner+label / check+label).
    // During processing / completion the waveform is hidden and its positioning
    // constraints are deactivated so the pill shrinks around the rightStack.
    private let rightStack = NSStackView()
    private let waveform = PillWaveformCircleView(frame: .zero)
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let stopButton = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let checkmarkView = NSImageView()

    // Layout constraints that swap between recording vs processing/completion.
    private var waveformLeading: NSLayoutConstraint!
    private var rightStackLeadingWithWaveform: NSLayoutConstraint!
    private var rightStackLeadingNoWaveform: NSLayoutConstraint!

    private var dragStart: NSPoint?
    private var windowOriginAtDragStart: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // Solid black pill — no border, no shadow, no blur. All drawn on the layer.
        layer?.cornerRadius = 24
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 0
        layer?.shadowOpacity = 0

        // Waveform — 36×36 circle bounding box containing the 18×18 SF-Symbol
        waveform.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            waveform.widthAnchor.constraint(equalToConstant: 36),
            waveform.heightAnchor.constraint(equalToConstant: 36)
        ])

        // Timer — SF Pro Regular 20pt with monospaced digits so ticks don't jitter
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .regular)
        timerLabel.textColor = NSColor.white.withAlphaComponent(0.64)
        timerLabel.alignment = .center
        timerLabel.isBordered = false
        timerLabel.isEditable = false
        timerLabel.backgroundColor = .clear
        timerLabel.translatesAutoresizingMaskIntoConstraints = false
        timerLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Status label (for "Processing" / "Copied" / "Note saved" / "Failed") — muted gray.
        statusLabel.font = .systemFont(ofSize: 14, weight: .regular)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.64)
        statusLabel.isBordered = false
        statusLabel.isEditable = false
        statusLabel.backgroundColor = .clear
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Spinner
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isDisplayedWhenStopped = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14)
        ])

        // Checkmark (completion) — SF Symbol, 12pt medium, tinted #A3A3A3.
        let checkConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        checkmarkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(checkConfig)
        checkmarkView.contentTintColor = NSColor.white.withAlphaComponent(0.64)
        checkmarkView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            checkmarkView.widthAnchor.constraint(equalToConstant: 14),
            checkmarkView.heightAnchor.constraint(equalToConstant: 14)
        ])

        // Stop button — 14×14 solid red (#DC2626) dot; 4px from pill right edge.
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.wantsLayer = true
        stopButton.layer?.cornerRadius = 7
        stopButton.layer?.backgroundColor = NSColor(red: 220/255, green: 38/255, blue: 38/255, alpha: 1).cgColor
        NSLayoutConstraint.activate([
            stopButton.widthAnchor.constraint(equalToConstant: 14),
            stopButton.heightAnchor.constraint(equalToConstant: 14)
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(stopTapped))
        stopButton.addGestureRecognizer(click)

        // Waveform is pinned to the left; stays visible across all modes.
        addSubview(waveform)

        // rightStack sits at the pill's trailing edge; its arranged subviews
        // are rebuilt in apply(mode:) so only the right side of the pill
        // morphs between [timer + stop] / [spinner + label] / [check + label].
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 6
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rightStack)

        // Waveform: 6px from left edge, vertically centred.
        waveformLeading = waveform.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)

        // rightStack: 12px from right edge, vertically centred.
        // Leading differs per mode: during recording it sits after the waveform;
        // during processing/completion there's symmetric 12px padding instead.
        rightStackLeadingWithWaveform = rightStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: waveform.trailingAnchor, constant: 8
        )
        rightStackLeadingNoWaveform = rightStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: leadingAnchor, constant: 12
        )

        NSLayoutConstraint.activate([
            waveformLeading,
            waveform.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightStackLeadingWithWaveform
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func stopTapped() { onStop?() }

    // MARK: - State application

    enum Mode {
        case recording(durationSeconds: Int, audioLevel: Float)
        case processing
        case completion(message: String)
    }

    func apply(mode: Mode) {
        // Tear down the current right-side contents so we can rebuild.
        for v in rightStack.arrangedSubviews {
            rightStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        switch mode {
        case .recording(let secs, _):
            // Waveform visible on the left; timer + stop on the right.
            waveform.isHidden = false
            waveformLeading.isActive = true
            rightStackLeadingNoWaveform.isActive = false
            rightStackLeadingWithWaveform.isActive = true

            spinner.stopAnimation(nil)
            timerLabel.stringValue = formatDuration(secs)
            rightStack.addArrangedSubview(timerLabel)
            rightStack.addArrangedSubview(stopButton)

        case .processing:
            // No waveform during processing — pill shrinks around the status content.
            waveform.isHidden = true
            waveformLeading.isActive = false
            rightStackLeadingWithWaveform.isActive = false
            rightStackLeadingNoWaveform.isActive = true

            spinner.startAnimation(nil)
            statusLabel.stringValue = "Processing"
            rightStack.addArrangedSubview(spinner)
            rightStack.addArrangedSubview(statusLabel)

        case .completion(let msg):
            // No waveform during completion either — just the check + message.
            waveform.isHidden = true
            waveformLeading.isActive = false
            rightStackLeadingWithWaveform.isActive = false
            rightStackLeadingNoWaveform.isActive = true

            spinner.stopAnimation(nil)
            statusLabel.stringValue = msg
            rightStack.addArrangedSubview(checkmarkView)
            rightStack.addArrangedSubview(statusLabel)
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    /// Natural width the pill wants to occupy given its current mode — driven by the
    /// internal stack view's fitting size, clamped to a sensible minimum so brief
    /// mode labels ("Processing...") still look like a pill and not a circle.
    func naturalWidth() -> CGFloat {
        layoutSubtreeIfNeeded()
        let rightW = rightStack.fittingSize.width
        let contentW: CGFloat
        if waveform.isHidden {
            // Just the rightStack with 12px symmetric padding.
            contentW = 12 + rightW + 12
        } else {
            // Waveform (36) + 6 left pad + 8 gap + rightStack + 12 right pad.
            contentW = 6 + 36 + 8 + rightW + 12
        }
        return max(140, contentW)
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowOriginAtDragStart = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = windowOriginAtDragStart, let win = window else { return }
        let loc = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: origin.x + loc.x - start.x, y: origin.y + loc.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        windowOriginAtDragStart = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Floating panel

private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

// MARK: - Controller

@MainActor
final class TranscriptionFloatingWidgetController: NSObject {

    private weak var transcription: TranscriptionService?
    private var panel: PillPanel?
    private var contentView: PillContentView?
    private var cancellables = Set<AnyCancellable>()
    private var panelOpenForWidget = false

    private enum Phase { case none, recording, processing, completion }
    private var phase: Phase = .none
    private var completionWorkItem: DispatchWorkItem?

    var onOpenTranscription: (() -> Void)?

    func attach(transcription: TranscriptionService) {
        self.transcription = transcription
        transcription.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.sync() }
            }
            .store(in: &cancellables)
        sync()
    }

    func setPanelOpenForWidget(_ open: Bool) {
        panelOpenForWidget = open
        sync()
    }

    private func sync() {
        guard let ts = transcription else { hidePanel(); return }

        // While the main panel is open, don't show the pill.
        if panelOpenForWidget {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            hidePanel()
            phase = .none
            return
        }

        // Completion message (short-lived) takes priority.
        if let msg = ts.completionMessage {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            phase = .completion
            showPanelIfNeeded()
            contentView?.apply(mode: .completion(message: msg))
            resizePillToFitContent()

            let work = DispatchWorkItem { [weak self] in
                self?.hidePanel()
                self?.phase = .none
                self?.completionWorkItem = nil
            }
            completionWorkItem = work
            // Hide after the message disappears (ts.completionMessage clears at 1.5 s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
            return
        }

        if ts.isRecording {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            phase = .recording
            showPanelIfNeeded()
            contentView?.apply(mode: .recording(durationSeconds: ts.duration, audioLevel: ts.audioLevel))
            resizePillToFitContent()
            return
        }

        if ts.isProcessing {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            phase = .processing
            showPanelIfNeeded()
            contentView?.apply(mode: .processing)
            resizePillToFitContent()
            return
        }

        // Idle — only hide if we weren't waiting on a completion banner.
        if phase != .completion {
            hidePanel()
            phase = .none
        }
    }

    private func showPanelIfNeeded() {
        if panel == nil { buildPanel() }
        positionIfNeeded()
        panel?.orderFrontRegardless()
    }

    /// Resize the pill to its content's intrinsic width, keeping the centre x fixed so
    /// the pill visually "grows out from the middle" as modes swap — no jumpy origin.
    private func resizePillToFitContent() {
        guard let p = panel, let cv = contentView else { return }
        let targetW = cv.naturalWidth()
        guard targetW > 0 else { return }
        let current = p.frame
        let centre = current.midX
        let newFrame = NSRect(x: centre - targetW / 2,
                              y: current.minY,
                              width: targetW,
                              height: current.height)
        if newFrame == current { return }
        p.setFrame(newFrame, display: true)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    private func buildPanel() {
        let h: CGFloat = 48
        // Start wide enough to measure the content; we'll shrink to the real
        // intrinsic width immediately after the content view is installed.
        let w: CGFloat = 400
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)

        let p = PillPanel(
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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let cv = PillContentView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        cv.autoresizingMask = [.width, .height]
        cv.onStop = { [weak self] in
            self?.transcription?.stopRecording()
        }
        p.contentView = cv
        contentView = cv
        panel = p

        // Position: centred, 8px below menu bar
        positionAtMenuBar()
    }

    private func positionAtMenuBar() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let sf = screen.frame
        let w = p.frame.width
        let h = p.frame.height
        let menuBarHeight = sf.height - vf.maxY
        let x = sf.midX - w / 2
        let y = sf.maxY - menuBarHeight - 8 - h
        p.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func positionIfNeeded() {
        // Only snap to menu bar on first show; after that let user drag freely.
        if panel?.frame.origin == .zero { positionAtMenuBar() }
    }
}
