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
                // panel resizes to 32×32 around it.
                iconDisc
                    .frame(
                        width: DesignTokens.Pill.height,
                        height: DesignTokens.Pill.height
                    )
                    .transition(asymmetricContentTransition)
            } else {
                // Full pill with asymmetric spacing: icon→timer is tighter
                // than timer→dot. HStack uses spacing: 0 and the gaps come
                // from the label's leading/trailing padding. In completion
                // mode (trailing is EmptyView), the label's trailing padding
                // becomes extra right-side breathing room for the message
                // text. Pill auto-sizes to content via the controller's
                // dynamic sizeForCurrentMode (using NSString.size on the
                // label text), so any state — recording, "No audio",
                // "Failed", "Note saved" — gets just enough pillWidth to
                // fit, with no leftover slack.
                HStack(spacing: 0) {
                    iconDisc
                    label
                        .padding(.leading, DesignTokens.Pill.iconToTimerSpacing)
                        .padding(.trailing, DesignTokens.Pill.timerToDotSpacing)
                    trailing
                }
                .padding(.leading, DesignTokens.Pill.leadingPadding)
                .padding(.trailing, DesignTokens.Pill.trailingPadding)
                .padding(.vertical, DesignTokens.Pill.verticalPadding)
                .transition(asymmetricContentTransition)
            }
        }
        // Mode-aware alignment: processing centers the icon in its 32×32
        // circle; everything else leading-aligns so message text and icons
        // stick to the left edge rather than centering inside the pill.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignmentForMode)
        .background(Color.black, in: Capsule())
        // Clip to the capsule so content can't overflow the rounded ends
        // while the AppKit panel is mid-resize.
        .clipShape(Capsule())
        // Triggers the asymmetric .transition modifiers. The actual
        // durations come from the per-transition .animation chains; this
        // just opens the animation transaction.
        .animation(.default, value: PillPhaseKey(mode))
    }

    /// Old content fades out fast; new content fades in after a delay so the
    /// AppKit panel-frame animation has time to morph the capsule's rounded
    /// corners to their target before text appears inside.
    private var asymmetricContentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(
                .easeInOut(duration: DesignTokens.Pill.contentInsertionDuration)
                    .delay(DesignTokens.Pill.contentInsertionDelay)
            ),
            removal: .opacity.animation(
                .easeInOut(duration: DesignTokens.Pill.contentRemovalDuration)
            )
        )
    }

    /// Processing mode centers (the iconDisc sits in the middle of the
    /// 32×32 circle); every other mode leading-aligns content to the
    /// pill's left edge.
    private var alignmentForMode: Alignment {
        if case .processing = mode { return .center }
        return .leading
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

/// Sibling panel to PillPanel carrying error / warning text. Same
/// borderless + nonactivating config so it never steals focus or
/// activates the app. Sized and positioned by the controller; the
/// hosting view is a plain NSHostingView (no drag, no
/// mouseDownCanMoveWindow override).
private final class ToastPanel: NSPanel {
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

    // Toast — separate sibling panel beneath the pill. Independent of the
    // pill's phase machine: showing / hiding the toast must NOT call
    // applyPhaseFrame, must NOT touch the pill panel, must NOT cancel
    // completionWorkItem.
    private var toastPanel: ToastPanel?
    private var toastHosting: NSHostingView<TranscriptionToastRootView>?
    private let toastState = TranscriptionToastDisplayState()
    private var toastAnimationToken: UInt64 = 0
    private var toastExitWorkItem: DispatchWorkItem?

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

    var onOpenTranscription: (() -> Void)?

    func attach(transcription: TranscriptionService) {
        // One-time cleanup of the snap-zone key persisted by prior builds
        // that tried to support drag-to-snap on the pill. The pill is now
        // fixed at top-center and nothing reads this key.
        UserDefaults.standard.removeObject(forKey: "TranscriptionPillSnapZone")

        self.transcription = transcription
        transcription.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        transcription.$pendingToast
            .compactMap { $0 }
            .sink { [weak self, weak transcription] toast in
                guard let self else { return }
                self.showToast(toast)
                // Clear so a repeat assignment fires Combine again.
                Task { @MainActor in transcription?.pendingToast = nil }
            }
            .store(in: &cancellables)
        sync()
    }

    deinit {
        completionWorkItem?.cancel()
        toastExitWorkItem?.cancel()
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
                // updateHosted FIRST so displayState.mode reflects the new
                // mode by the time applyPhaseFrame measures content for
                // dynamic sizing. applyPhaseFrame still runs before
                // showCollapsedPanelIfNeeded so the slide-in animation
                // captures the canonical phase target.
                updateHosted(mode: .recording(durationSeconds: ts.duration))
                applyPhaseFrame(animated: oldPhase != .none)
                showCollapsedPanelIfNeeded()
            }
            return
        }

        if let msg = ts.completionMessage {
            let oldPhase = phase
            cancelAllPendingWork(except: .completion)
            phase = .completion
            updateHosted(mode: .completion(message: msg))
            applyPhaseFrame(animated: oldPhase != .none)
            showCollapsedPanelIfNeeded()

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
            updateHosted(mode: .processing)
            applyPhaseFrame(animated: oldPhase != .none)
            showCollapsedPanelIfNeeded()
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
        let size = sizeForCurrentMode()
        applyPhaseAwareFrame(
            size: size,
            animated: animated,
            duration: DesignTokens.Pill.phaseAnimationDuration,
            timingFunction: CAMediaTimingFunction(name: .easeInEaseOut)
        )
    }

    /// Pill width is dynamic — measured per displayed mode using NSString
    /// font sizing so the AppKit panel auto-fits whatever message is being
    /// shown. "Failed" gets a small pill, "Saved (raw)" gets a larger pill,
    /// no slack on either side regardless of message length.
    ///
    /// Reads `displayState.mode` (which `sync()` sets via `updateHosted`
    /// BEFORE calling applyPhaseFrame), so the size always reflects the
    /// content that's about to be displayed.
    private func sizeForCurrentMode() -> NSSize {
        let height = DesignTokens.Pill.height
        switch displayState.mode {
        case .processing:
            return NSSize(width: height, height: height)
        case .recording(let seconds):
            let labelW = measureLabelWidth(formatPillDuration(seconds), font: Self.recordingLabelFont)
            let width = Self.basePillFixedWidth + labelW + DesignTokens.Pill.recordingDotSize + Self.measurementSafetyMargin
            return NSSize(width: width, height: height)
        case .completion(let message):
            let labelW = measureLabelWidth(message, font: Self.completionLabelFont)
            let width = Self.basePillFixedWidth + labelW + Self.measurementSafetyMargin
            return NSSize(width: width, height: height)
        }
    }

    /// Sum of all fixed-width contributions to the pill (paddings + iconDisc
    /// + the two label-padding gaps). The variable-width contribution is
    /// the label text and, for recording mode, the red stop dot.
    private static var basePillFixedWidth: CGFloat {
        DesignTokens.Pill.leadingPadding
            + DesignTokens.Pill.iconDiscSize
            + DesignTokens.Pill.iconToTimerSpacing
            + DesignTokens.Pill.timerToDotSpacing
            + DesignTokens.Pill.trailingPadding
    }

    /// SwiftUI's Text rendering can disagree with NSString.size by a sub-pt
    /// fraction; a 2pt safety margin avoids the very-last character being
    /// clipped by the capsule's rounded right end.
    private static let measurementSafetyMargin: CGFloat = 2

    /// Fonts that match what the SwiftUI body uses for each mode's label.
    /// Recording timer uses `.system(size: 14, weight: .regular).monospacedDigit()`;
    /// completion messages use `.system(size: 14, weight: .regular)`. Both
    /// have direct AppKit equivalents below.
    private static let recordingLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    private static let completionLabelFont = NSFont.systemFont(ofSize: 14, weight: .regular)

    private func measureLabelWidth(_ text: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attrs).width)
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

    /// Position the panel at its fixed top-center anchor using the given size.
    /// The pill is not draggable; this is the only zone it ever uses.
    private func applyPhaseAwareFrame(
        size: CGSize,
        animated: Bool,
        duration: TimeInterval = DesignTokens.Pill.frameAnimationDuration,
        timingFunction: CAMediaTimingFunction? = nil
    ) {
        guard let screen = NSScreen.main else { return }
        let target = PanelSnapZone.topCenter.visibleFrame(size: size, screen: screen.visibleFrame)
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
    }

    /// Position the pill at its fixed top-center anchor. The pill is not
    /// draggable; there's no per-user position to restore.
    private func restorePosition() {
        let size = NSSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        applyPhaseAwareFrame(size: size, animated: false)
    }

    // MARK: - Toast

    /// Build the toast panel lazily on first show. Mirrors `buildPanel()`'s
    /// shape: borderless + nonactivating, transparent background, no shadow,
    /// same window level as the pill (so it sits on top of normal app
    /// windows but doesn't fight the pill for z-order).
    private func buildToastPanel() {
        guard toastPanel == nil else { return }
        let h = DesignTokens.Pill.height
        // Initial width is a placeholder — the controller resizes the panel
        // to fit each message before showing it.
        let w: CGFloat = 200
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)

        let p = ToastPanel(
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
        p.ignoresMouseEvents = true  // toast is passive — never intercepts clicks

        let root = TranscriptionToastRootView(state: toastState)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.autoresizingMask = [.width, .height]

        p.contentView = host
        toastHosting = host
        toastPanel = p
    }

    /// Measure the text width using the same NSString sizing trick the pill
    /// uses, then add symmetric horizontal padding so the capsule has visible
    /// breathing room around the text.
    private func sizeForToast(_ message: TranscriptionToastMessage) -> NSSize {
        let labelW = measureLabelWidth(message.text, font: Self.completionLabelFont)
        // Horizontal padding mirrors the pill's leading+trailing (4+8) plus an
        // extra 12pt total breathing room because the toast has no leading
        // glyph to balance the text. Total: 12 + labelW + 12.
        let width = labelW + 24 + Self.measurementSafetyMargin
        let height = DesignTokens.Pill.height
        return NSSize(width: width, height: height)
    }

    /// Compute where the toast should sit. Centered horizontally on the
    /// pill's centerX, fixed gap below the pill's bottom edge. Falls back
    /// to flipping above the pill if there isn't room below (e.g., the pill
    /// is near the bottom of the visible frame).
    private func targetToastFrame(toastSize: NSSize) -> NSRect? {
        guard let panel, let screen = NSScreen.main else { return nil }
        let vf = screen.visibleFrame
        let pillFrame = panel.frame
        let centerX = pillFrame.midX
        let gap = DesignTokens.Pill.toastGapBelow

        // Default: below the pill.
        var originY = pillFrame.minY - gap - toastSize.height
        // If that goes below the visible frame, flip above the pill.
        if originY < vf.minY {
            originY = pillFrame.maxY + gap
        }
        let originX = centerX - toastSize.width / 2
        // Clamp horizontally so the toast doesn't run off-screen on narrow displays.
        let clampedX = max(vf.minX + 4, min(originX, vf.maxX - toastSize.width - 4))
        return NSRect(x: clampedX, y: originY, width: toastSize.width, height: toastSize.height)
    }

    /// Show a toast. If a previous toast is still visible, slide it out fast
    /// and slide the new one in (stacking-by-replacement). Each call schedules
    /// its own dismiss via `toastExitWorkItem`; the token guard inside the
    /// dismiss closure makes a stale dismiss a no-op.
    func showToast(_ message: TranscriptionToastMessage) {
        buildToastPanel()
        guard let toastPanel else { return }

        // Cancel any pending exit; we're going to show a new toast.
        toastExitWorkItem?.cancel()
        toastExitWorkItem = nil
        toastAnimationToken &+= 1
        let token = toastAnimationToken

        // Size + position for the new message. We compute these now so the
        // panel frame is ready, but defer the SwiftUI text swap until the
        // panel is invisible (see "text swap timing" note below).
        let size = sizeForToast(message)
        guard let target = targetToastFrame(toastSize: size) else { return }

        let alreadyVisible = toastPanel.isVisible && toastPanel.alphaValue > 0.01

        if alreadyVisible {
            // Stacking. Text swap timing — IMPORTANT:
            //
            // The naive approach (set toastState.current = message BEFORE the
            // half-exit) lets SwiftUI's .transition(.opacity) cross-fade the
            // old text into the new text at toastEnterDuration (150ms) while
            // AppKit is fading the panel's alpha at toastExitDuration/2 (100ms).
            // Two simultaneous fades at different rates = visible stutter.
            //
            // Instead we drive the SwiftUI swap from the AppKit completion
            // handler: panel goes fully transparent first, THEN we update the
            // text (invisible swap), THEN we fade the panel back in with the
            // new text. SwiftUI never cross-fades; AppKit owns the visual
            // transition end-to-end.
            let startFrame = target.offsetBy(dx: 0, dy: DesignTokens.Pill.toastSlideOffset)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = DesignTokens.Pill.toastExitDuration / 2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                toastPanel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.toastAnimationToken == token else { return }
                // Panel is now invisible — swap the text behind it.
                self.toastState.current = message
                toastPanel.setFrame(startFrame, display: false)
                toastPanel.alphaValue = 0
                toastPanel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = DesignTokens.Pill.toastEnterDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    toastPanel.animator().setFrame(target, display: true)
                    toastPanel.animator().alphaValue = 1
                }, completionHandler: { [weak self] in
                    guard let self, self.toastAnimationToken == token else { return }
                    self.scheduleToastDismiss(after: message.hold, token: token)
                })
            })
        } else {
            // Fresh show — no previous content, no cross-fade risk. Set the
            // SwiftUI state upfront so the first frame of the AppKit fade-in
            // already has the correct text.
            toastState.current = message
            let startFrame = target.offsetBy(dx: 0, dy: DesignTokens.Pill.toastSlideOffset)
            toastPanel.setFrame(startFrame, display: false)
            toastPanel.alphaValue = 0
            toastPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = DesignTokens.Pill.toastEnterDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toastPanel.animator().setFrame(target, display: true)
                toastPanel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                guard let self, self.toastAnimationToken == token else { return }
                self.scheduleToastDismiss(after: message.hold, token: token)
            })
        }
    }

    /// Schedule the slide-up + fade-out exit. The token guard ensures that
    /// a `showToast` arriving during the hold cancels the stale dismiss.
    private func scheduleToastDismiss(after hold: TimeInterval, token: UInt64) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.toastAnimationToken == token else { return }
            self.hideToast(token: token)
        }
        toastExitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    /// Animate the toast out and clear `toastState.current`.
    private func hideToast(token: UInt64) {
        guard let toastPanel, toastPanel.isVisible else {
            toastState.current = nil
            return
        }
        let endFrame = toastPanel.frame.offsetBy(dx: 0, dy: -DesignTokens.Pill.toastSlideOffset)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Pill.toastExitDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            toastPanel.animator().setFrame(endFrame, display: true)
            toastPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.toastAnimationToken == token else { return }
            toastPanel.orderOut(nil)
            self.toastState.current = nil
        })
    }
}
