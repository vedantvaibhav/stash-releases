import AppKit
import Combine
import SwiftUI

// MARK: - Pill mode

enum PillMode: Equatable {
    case recording(durationSeconds: Int)
    case processing
    case completion(message: String)
}

/// Stable animation key: identical across timer ticks so the HStack doesn't
/// cross-fade every second while recording.
private enum PillPhaseKey: Equatable {
    case recording
    case processing
    case completion(String)

    init(_ mode: PillMode) {
        switch mode {
        case .recording:            self = .recording
        case .processing:           self = .processing
        case .completion(let msg):  self = .completion(msg)
        }
    }
}

// MARK: - SwiftUI pill body (matches Figma node 280-981)

struct TranscriptionPillView: View {
    let mode: PillMode
    let onStop: () -> Void

    var body: some View {
        Group {
            if case .processing = mode {
                // Compact circle: just the icon disc + spinner. AppKit
                // panel resizes to 32×32 around it; SwiftUI fills that
                // space and centers the iconDisc.
                iconDisc
            } else {
                // Full pill: iconDisc, label, dot — no middle Spacer so
                // both gaps stay at contentSpacing. Outer alignment .center
                // (set on the surrounding .frame below) absorbs leftover
                // pillWidth equally on both sides.
                HStack(spacing: DesignTokens.Pill.contentSpacing) {
                    iconDisc
                    label
                    trailing
                }
                .padding(.leading, DesignTokens.Pill.leadingPadding)
                .padding(.trailing, DesignTokens.Pill.trailingPadding)
                .padding(.vertical, DesignTokens.Pill.verticalPadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.black, in: Capsule())
        // Single cross-fade for content swaps. AppKit panel handles the
        // frame size animation in parallel via NSAnimationContext.
        .animation(.easeInOut(duration: DesignTokens.Pill.contentCrossfadeDuration), value: PillPhaseKey(mode))
    }

    // MARK: Icon disc (24×24 with 14pt inner glyph / spinner)

    private var iconDisc: some View {
        ZStack {
            Circle().fill(DesignTokens.Icon.backgroundRest)
            iconGlyph
        }
        .frame(width: DesignTokens.Pill.iconDiscSize, height: DesignTokens.Pill.iconDiscSize)
    }

    @ViewBuilder
    private var iconGlyph: some View {
        switch mode {
        case .recording:
            glyph("waveform")
        case .processing:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(DesignTokens.Icon.tintMuted)
                .transition(.opacity)
        case .completion(let message):
            if isPastedCompletion(message) {
                Image("PastedConfirm")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: DesignTokens.Pill.iconGlyphSize,
                        height: DesignTokens.Pill.iconGlyphSize
                    )
                    // .foregroundColor (not .foregroundStyle) — the latter
                    // doesn't always propagate through .renderingMode(.template)
                    // for custom-asset Images on macOS 13/14, leaving the
                    // glyph at full opacity. .foregroundColor + .tint together
                    // covers both old and new SwiftUI tint paths.
                    .foregroundColor(DesignTokens.Icon.tintMuted)
                    .tint(DesignTokens.Icon.tintMuted)
                    .transition(.opacity)
            } else {
                glyph(completionSymbol(for: message))
            }
        }
    }

    /// True iff the message represents a paste-success state. Paste states use
    /// a custom asset (`PastedConfirm`) instead of an SF Symbol so the glyph
    /// matches the design language.
    private func isPastedCompletion(_ message: String) -> Bool {
        message == "Pasted ✓"
    }

    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: DesignTokens.Pill.iconGlyphSize, weight: .regular))
            .foregroundStyle(DesignTokens.Icon.tintMuted)
            .transition(.opacity)
    }

    /// Mirrors the strings emitted by `TranscriptionService.showCompletion(_:)`.
    /// `"Pasted ✓"` uses the custom `PastedConfirm` asset (handled above).
    /// Non-verified paste outcomes do not show a pill at all (the dictation
    /// is recoverable in Notes → Recent dictations) so there's no "Saved"
    /// case here.
    private func completionSymbol(for message: String) -> String {
        switch message {
        case "Copied":      return "checkmark"
        case "Note saved":  return "note.text"
        case "Failed":      return "xmark"
        case "No audio":    return "mic.slash"
        default:            return "checkmark"
        }
    }

    // MARK: Label (SF Pro 14 regular #A3A3A3)

    @ViewBuilder
    private var label: some View {
        switch mode {
        case .recording(let seconds):
            pillLabel(formatPillDuration(seconds), tabularDigits: true)
        case .processing:
            // Unreachable: the outer body switch renders just the icon disc
            // for .processing, so this branch never builds. Kept exhaustive
            // for the compiler.
            EmptyView()
        case .completion(let message):
            pillLabel(message)
        }
    }

    /// `tabularDigits: true` keeps SF Pro but forces equal-width digits so the
    /// timer doesn't jitter between seconds. `.fixedSize(horizontal:)` stops
    /// the HStack from compressing the label into an ellipsis.
    private func pillLabel(_ text: String, tabularDigits: Bool = false) -> some View {
        let base = Font.system(size: 14, weight: .regular)
        return Text(text)
            .font(tabularDigits ? base.monospacedDigit() : base)
            .foregroundStyle(DesignTokens.Typography.itemColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            // The pill body's `.animation(_:value: PillPhaseKey(mode))` opens
            // an animated transaction every second of recording (PillMode's
            // .recording associated value carries durationSeconds). Without
            // this transaction wrap, the implicit Text content swap inside
            // that transaction cross-fades — visible as a dissolve on the
            // timer. Pin the timer label to no-animation; other call sites
            // ("Processing", completion text) keep their default behavior.
            .transaction { transaction in
                if tabularDigits { transaction.animation = nil }
            }
    }

    // MARK: Trailing element

    @ViewBuilder
    private var trailing: some View {
        switch mode {
        case .recording:
            StopRecordingButton(onStop: onStop)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        case .processing, .completion:
            EmptyView()
        }
    }
}

/// Pill duration format. Default MM:SS (zero-padded minutes); only expand to
/// H:MM:SS once a recording crosses one hour.
fileprivate func formatPillDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}

// MARK: - Stop button (10×10 solid red dot, tap = visible)
//
// Tap target = visible dot. The earlier 18pt invisible-tap-area produced an
// asymmetric label→dot gap (the tap area's invisible left side ate into the
// gap), making the pill look unbalanced relative to the iconDisc→label gap.
//
// Uses `.onTapGesture` (not `Button`) so the parent panel's window-drag
// (`isMovableByWindowBackground = true`) is still reachable from the trailing
// region — a Button would swallow click-and-drag and fire its action on
// mouse-up, accidentally stopping recording when the user tried to drag.

private struct StopRecordingButton: View {
    let onStop: () -> Void

    var body: some View {
        Circle()
            .fill(DesignTokens.Icon.tintRecording)
            .frame(
                width: DesignTokens.Pill.recordingDotSize,
                height: DesignTokens.Pill.recordingDotSize
            )
            .contentShape(Rectangle())
            .onTapGesture { onStop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stop recording")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Floating panel
//
// Always-non-key. The pill is a passive status surface — no keyboard input,
// no focus stealing.

private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

// MARK: - Display state + root view

final class PillDisplayState: ObservableObject {
    @Published var mode: PillMode = .processing
}

struct PillRootView: View {
    @ObservedObject var state: PillDisplayState
    let onStop: () -> Void

    var body: some View {
        TranscriptionPillView(mode: state.mode, onStop: onStop)
    }
}

// MARK: - Controller

@MainActor
final class TranscriptionFloatingWidgetController: NSObject {

    private weak var transcription: TranscriptionService?
    private var panel: PillPanel?
    /// One persistent NSHostingView. Driven by `displayState.mode`; never
    /// replaced across phase transitions.
    private var hosting: NSHostingView<PillRootView>?
    private let displayState = PillDisplayState()
    private var cancellables = Set<AnyCancellable>()
    private var panelOpenForWidget = false

    private enum Phase { case none, recording, processing, completion }
    private var phase: Phase = .none
    private var completionWorkItem: DispatchWorkItem?

    /// Bumped on every show/hide animation start. The completion handler of
    /// each animation checks the token: a stale completion (e.g., hide's
    /// orderOut after a new show has started) is skipped.
    private var visibilityAnimationToken: UInt64 = 0
    /// True from the moment hidePanel commits its slide-out animation until
    /// either (a) the animation completes and orderOut runs, or (b) a new
    /// show supersedes it. Distinguishes "panel currently hiding" from
    /// "panel mid slide-in" — both have isVisible=true and possibly
    /// alpha < 1, but only the hiding case wants a re-entrance from a new
    /// show.
    private var hideInFlight = false

    /// Drag-to-snap state (mirrors the main tray's `snapToNearestZone` behavior).
    /// `isMovableByWindowBackground` handles the live drag; this monitor observes
    /// mouseDown / mouseUp on our panel to decide when a drag actually ended.
    private static let snapZoneDefaultsKey = "TranscriptionPillSnapZone"
    private var dragStartOrigin: NSPoint?
    private var dragMonitor: Any?

    var onOpenTranscription: (() -> Void)?

    func attach(transcription: TranscriptionService) {
        self.transcription = transcription
        transcription.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        sync()
    }

    deinit {
        // NSEvent monitors are NOT auto-removed on deallocation; they hold
        // references to their handler closure and stay live until removed.
        if let m = dragMonitor { NSEvent.removeMonitor(m) }
        completionWorkItem?.cancel()
    }

    func setPanelOpenForWidget(_ open: Bool) {
        panelOpenForWidget = open
        sync()
    }

    private func sync() {
        guard let ts = transcription else { hidePanel(); return }

        if panelOpenForWidget {
            cancelAllPendingWork()
            hidePanel()
            phase = .none
            return
        }

        // Recording supersedes everything. The takeover runs inside a single
        // Transaction with `disablesAnimations` so SwiftUI sees the mode
        // mutation as one atomic non-animated change — without the wrap, a
        // residual completion-state pill would cross-fade out as the recording
        // view fades in (the user-visible "ghost flash"). Subsequent mutations
        // (recording → processing → completion) animate normally.
        if ts.isRecording {
            let oldPhase = phase
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cancelAllPendingWork(except: .recording)
                phase = .recording
                // Order: applyPhaseFrame BEFORE showCollapsedPanelIfNeeded so
                // the panel.frame is at the canonical phase target before
                // the slide-in animation captures it as the destination.
                // showCollapsedPanelIfNeeded short-circuits on already-visible
                // panels (no slide+fade re-entrance), so applyPhaseFrame's
                // animator runs undisturbed for in-place phase changes.
                applyPhaseFrame(animated: oldPhase != .none)
                showCollapsedPanelIfNeeded()
                updateHosted(mode: .recording(durationSeconds: ts.duration))
            }
            return
        }

        if let msg = ts.completionMessage {
            let oldPhase = phase
            cancelAllPendingWork(except: .completion)
            phase = .completion
            applyPhaseFrame(animated: oldPhase != .none)
            showCollapsedPanelIfNeeded()
            updateHosted(mode: .completion(message: msg))

            let work = DispatchWorkItem { [weak self] in
                self?.hidePanel()
                self?.phase = .none
                self?.completionWorkItem = nil
            }
            completionWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
            return
        }

        if ts.isProcessing {
            let oldPhase = phase
            cancelAllPendingWork(except: .processing)
            phase = .processing
            applyPhaseFrame(animated: oldPhase != .none)
            showCollapsedPanelIfNeeded()
            updateHosted(mode: .processing)
            return
        }

        if phase != .completion {
            hidePanel()
            phase = .none
        }
    }

    /// Resize the panel frame to match the current `phase`. Animated when
    /// transitioning between visible phases (e.g., recording → processing),
    /// non-animated on first show (oldPhase == .none) so the panel doesn't
    /// briefly render at a stale size before snapping.
    ///
    /// `.processing` shrinks to a 32×32 square (visually a circle once the
    /// capsule background applies); every other phase expands back to the
    /// full pill width. Ease-in-out timing pairs with the SwiftUI side's
    /// staggered fade-out / pause / fade-in so the AppKit frame
    /// "slows down" through the middle of the transition just as the
    /// SwiftUI cross-fade is between layers.
    private func applyPhaseFrame(animated: Bool) {
        let size = sizeForCurrentPhase()
        applyPhaseAwareFrame(
            size: size,
            animated: animated,
            duration: DesignTokens.Pill.phaseAnimationDuration,
            timingFunction: CAMediaTimingFunction(name: .easeInEaseOut)
        )
    }

    private func sizeForCurrentPhase() -> NSSize {
        switch phase {
        case .processing:
            return NSSize(width: DesignTokens.Pill.height, height: DesignTokens.Pill.height)
        default:
            return NSSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        }
    }

    private func cancelAllPendingWork(except keep: Phase = .none) {
        if keep != .completion {
            completionWorkItem?.cancel()
            completionWorkItem = nil
        }
    }

    private func updateHosted(mode: PillMode) {
        if displayState.mode != mode { displayState.mode = mode }
    }

    private func showCollapsedPanelIfNeeded() {
        if panel == nil { buildPanel() }
        guard let panel else { return }

        // Already showing AND not in the middle of a hide → just keep it on
        // top. CRITICAL: do NOT enter the slide+fade entrance here, even if
        // alpha is mid-animation. A phase transition (e.g., recording →
        // processing) has applyPhaseFrame committing an animator.setFrame
        // for the shrink JUST before us; if we then call panel.setFrame
        // directly (as part of slide+fade entrance), we cancel that
        // in-flight animator and the processing-shrink visibly breaks.
        // The earlier (alpha == 1) check was the bug — false during slide-in
        // tail, triggering exactly that cancellation.
        if panel.isVisible && !hideInFlight {
            panel.orderFrontRegardless()
            return
        }

        // Either fully hidden, or mid-hide. Run slide+fade entrance from
        // `openSlideOffset` above the canonical target. `panel.frame` reflects
        // the just-set phase target because `sync()` calls `applyPhaseFrame`
        // immediately before this.
        visibilityAnimationToken &+= 1
        hideInFlight = false
        let token = visibilityAnimationToken

        let target = panel.frame
        let startFrame = target.offsetBy(dx: 0, dy: DesignTokens.PanelAnimation.openSlideOffset)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.PanelAnimation.openDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            // Token guard: if a hide superseded this show, ignore.
            guard let self, self.visibilityAnimationToken == token else { return }
        })
    }

    /// Read the persisted snap zone, falling back to `.topCenter`.
    private func currentSnapZone() -> PanelSnapZone {
        if let raw = UserDefaults.standard.string(forKey: Self.snapZoneDefaultsKey),
           let zone = PanelSnapZone(rawValue: raw) {
            return zone
        }
        return .topCenter
    }

    /// Position the panel at the persisted snap zone using the given size.
    /// `duration` defaults to drag-snap's settle timing; phase changes
    /// override with their own value. `timingFunction` lets phase changes
    /// pass an ease-in-out curve while drag-snap keeps the heavier ease-out
    /// cubic-bezier.
    private func applyPhaseAwareFrame(
        size: CGSize,
        animated: Bool,
        duration: TimeInterval = DesignTokens.Pill.frameAnimationDuration,
        timingFunction: CAMediaTimingFunction? = nil
    ) {
        guard let screen = NSScreen.main else { return }
        let target = currentSnapZone().visibleFrame(size: size, screen: screen.visibleFrame)
        applyPanelFrame(target, animated: animated, duration: duration, timingFunction: timingFunction)
    }

    /// Animate panel frame over the given duration. When `timingFunction`
    /// is nil, falls back to the cubic-bezier from DesignTokens (heavy
    /// ease-out, used by drag-snap settle).
    private func applyPanelFrame(
        _ frame: NSRect,
        animated: Bool,
        duration: TimeInterval = DesignTokens.Pill.frameAnimationDuration,
        timingFunction: CAMediaTimingFunction? = nil
    ) {
        guard let panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = timingFunction ?? CAMediaTimingFunction(controlPoints:
                    Float(DesignTokens.Pill.frameAnimationCurveCP1x),
                    Float(DesignTokens.Pill.frameAnimationCurveCP1y),
                    Float(DesignTokens.Pill.frameAnimationCurveCP2x),
                    Float(DesignTokens.Pill.frameAnimationCurveCP2y)
                )
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func hidePanel() {
        guard let panel, panel.isVisible else { return }

        // Slide+fade exit: lift the panel `closeSlideOffset` upward as it
        // fades to alpha=0, then orderOut. `hideInFlight` lets a subsequent
        // show distinguish "panel currently hiding" from "panel mid slide-in"
        // and re-run slide+fade entrance only for the former.
        visibilityAnimationToken &+= 1
        hideInFlight = true
        let token = visibilityAnimationToken

        let endFrame = panel.frame.offsetBy(dx: 0, dy: DesignTokens.PanelAnimation.closeSlideOffset)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.PanelAnimation.closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            // Token guard: if a show superseded this hide, don't orderOut —
            // the show animation is bringing the panel back.
            guard let self, self.visibilityAnimationToken == token else { return }
            panel?.orderOut(nil)
            self.hideInFlight = false
        })
    }

    private func buildPanel() {
        let w = DesignTokens.Pill.width
        let h = DesignTokens.Pill.height
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
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = PillRootView(
            state: displayState,
            onStop: { [weak self] in self?.transcription?.stopRecording() }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.autoresizingMask = [.width, .height]

        p.contentView = host
        hosting = host
        panel = p

        restorePosition()
        installDragMonitor()
    }

    /// First launch uses the menu-bar default (top-center). Subsequent
    /// launches restore whichever corner the user last snapped the pill into.
    private func restorePosition() {
        let size = NSSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        applyPhaseAwareFrame(size: size, animated: false)
    }

    // MARK: Drag-to-snap

    private func installDragMonitor() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handleDragEvent(event)
            return event
        }
    }

    private func handleDragEvent(_ event: NSEvent) {
        guard let panel, event.window === panel else { return }
        switch event.type {
        case .leftMouseDown:
            dragStartOrigin = panel.frame.origin
        case .leftMouseUp:
            guard let start = dragStartOrigin else { return }
            dragStartOrigin = nil
            // Let AppKit finish processing `isMovableByWindowBackground` before
            // we read the final origin.
            DispatchQueue.main.async { [weak self] in
                guard let self, let panel = self.panel else { return }
                let moved = hypot(panel.frame.origin.x - start.x, panel.frame.origin.y - start.y) > 4
                if moved { self.snapToNearestZone() }
            }
        default:
            break
        }
    }

    private func snapToNearestZone() {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let zone = PanelSnapZone.nearest(to: panel.frame, size: size, screen: vf)
        UserDefaults.standard.set(zone.rawValue, forKey: Self.snapZoneDefaultsKey)
        applyPhaseAwareFrame(size: size, animated: true)
    }
}
