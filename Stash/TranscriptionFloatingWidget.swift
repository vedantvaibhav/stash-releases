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

// MARK: - Display state + root view

/// Copy for the long-running notification card. Equatable (Strings only) so
/// the controller can morph the copy in place; the button actions live on the
/// controller as closures (not here) since closures aren't Equatable.
struct NotificationContent: Equatable {
    var title: String
    var message: String
    var primaryLabel: String
    var secondaryLabel: String
}

final class PillDisplayState: ObservableObject {
    @Published var mode: PillMode = .processing
    /// When non-nil, the widget renders the notification card instead of the
    /// pill (the "toast morphs into the notification" state).
    @Published var notification: NotificationContent? = nil
}

struct PillRootView: View {
    @ObservedObject var state: PillDisplayState
    let onStop: () -> Void
    let onNotificationPrimary: () -> Void
    let onNotificationSecondary: () -> Void
    let onNotificationDismiss: () -> Void

    var body: some View {
        if let n = state.notification {
            TranscriptionStatusNotification(
                title: n.title,
                message: n.message,
                primaryLabel: n.primaryLabel,
                primaryAction: onNotificationPrimary,
                secondaryLabel: n.secondaryLabel,
                secondaryAction: onNotificationSecondary,
                onDismiss: onNotificationDismiss
            )
        } else {
            TranscriptionPillView(mode: state.mode, onStop: onStop)
        }
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

    private enum Phase { case none, recording, processing, completion, notification }
    private var phase: Phase = .none

    /// True once the user dismisses the long-running notification (X / Hide)
    /// or the 5-min auto-hide fires. Suppresses re-showing until the wait
    /// resets (isWaitingOnRetry → false), at which point it clears.
    private var notificationDismissed = false
    /// 5-minute hard cap: auto-hide the notification regardless of state.
    private var notificationAutoHideWork: DispatchWorkItem?
    private var completionWorkItem: DispatchWorkItem?
    /// The completion message currently being held by `completionWorkItem`.
    /// Used to avoid re-scheduling the hide timer on every sync() tick while
    /// the same message stays in `ts.completionMessage` — important for
    /// mid-recording warnings where duration ticks would otherwise reset the
    /// hold indefinitely.
    private var heldCompletionMessage: String?

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
    /// "Open Notes" action for the long-running notification — set by
    /// PanelController.setup to open the panel on the Notes tab with the
    /// Transcriptions filter applied.
    var onOpenNotes: (() -> Void)?

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
        sync()
    }

    deinit {
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

        // Completion supersedes recording so mid-recording warnings (85-min,
        // 20-MB) can briefly flash on the pill, then return to recording mode
        // when their hold expires (see expireCompletion). End-of-recording
        // completions ("Note saved", "No audio", "Failed") work the same way,
        // they just see isRecording==false at expiry and hide instead.
        //
        // Ghost-flash guard: residual completion state at the start of a new
        // recording is cleared in TranscriptionService.startRecording
        // (completionMessage = nil), so this ordering does not introduce
        // a stale-completion flash when a new recording begins.
        if let msg = ts.completionMessage {
            let oldPhase = phase
            cancelAllPendingWork(except: .completion)
            phase = .completion
            updateHosted(mode: .completion(message: msg))
            applyPhaseFrame(animated: oldPhase != .none)
            showCollapsedPanelIfNeeded()

            // Only schedule the hide timer when entering completion for a NEW
            // message. Without this guard, every sync() tick (e.g., duration
            // ticking during a mid-recording warning) would re-arm the timer
            // and the completion would never expire.
            if heldCompletionMessage != msg {
                heldCompletionMessage = msg
                completionWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.expireCompletion()
                }
                completionWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
            }
            return
        }

        // Recording supersedes everything below. The takeover runs inside a
        // single Transaction with `disablesAnimations` so SwiftUI sees the
        // mode mutation as one atomic non-animated change — without the wrap,
        // a residual completion-state pill would cross-fade out as the
        // recording view fades in (the user-visible "ghost flash").
        // Subsequent mutations (recording → processing → completion) animate
        // normally.
        if ts.isRecording {
            let oldPhase = phase
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                cancelAllPendingWork(except: .recording)
                phase = .recording
                heldCompletionMessage = nil
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

        if ts.isProcessing {
            let oldPhase = phase
            cancelAllPendingWork(except: .processing)
            phase = .processing
            heldCompletionMessage = nil
            updateHosted(mode: .processing)
            applyPhaseFrame(animated: oldPhase != .none)
            showCollapsedPanelIfNeeded()
            return
        }

        // Long-running stall: nothing else is showing and the upload is
        // waiting on a retry. Morph the pill into the notification card.
        // A user dismiss / 5-min auto-hide suppresses it until the wait
        // resets (handled by `notificationDismissed`).
        if ts.isWaitingOnRetry {
            if notificationDismissed {
                // Dismissed but still waiting — keep the pill hidden; the
                // inline "Waiting" shimmer in the filter bar is the indicator.
                if phase != .completion { hidePanel(); phase = .none }
                return
            }
            enterNotificationPhase(attempt: ts.waitingRetryAttempt)
            return
        }

        // Not waiting anymore — clear any notification state.
        if phase == .notification || displayState.notification != nil {
            clearNotification()
        }

        if phase != .completion {
            hidePanel()
            phase = .none
            heldCompletionMessage = nil
        }
    }

    // MARK: - Long-running notification

    private func enterNotificationPhase(attempt: Int) {
        let oldPhase = phase
        let content: NotificationContent
        if attempt >= 3 {
            content = NotificationContent(
                title: "Still trying",
                message: "We'll keep retrying. Check your Notes panel anytime.",
                primaryLabel: "Open Notes",
                secondaryLabel: "Hide"
            )
        } else {
            content = NotificationContent(
                title: "Taking longer than usual",
                message: "Your transcript will appear in Notes when ready",
                primaryLabel: "Open Notes",
                secondaryLabel: "Dismiss"
            )
        }
        let firstShow = (phase != .notification)
        cancelAllPendingWork()   // notification is its own phase; drop any completion timer
        phase = .notification
        heldCompletionMessage = nil
        // Set the card content; sizeForCurrentMode reads displayState.notification.
        if displayState.notification != content { displayState.notification = content }
        applyPhaseFrame(animated: oldPhase != .none)
        showCollapsedPanelIfNeeded()
        if firstShow { startNotificationAutoHide() }
    }

    private func startNotificationAutoHide() {
        notificationAutoHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // 5-min cap: hide but keep the session retrying silently.
            self?.dismissNotification()
        }
        notificationAutoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60, execute: work)
    }

    /// Hide the notification and suppress re-show until the wait resets.
    /// Used by the X button, the "Dismiss"/"Hide" button, and the 5-min cap.
    /// Sets `notificationDismissed` so `sync()` won't re-show while the
    /// session is still waiting.
    func dismissNotification() {
        notificationDismissed = true
        notificationAutoHideWork?.cancel()
        notificationAutoHideWork = nil
        if displayState.notification != nil { displayState.notification = nil }
        hidePanel()
        phase = .none
    }

    /// Tear down the card content + auto-hide timer and reset the dismissed
    /// flag. Called when the wait resets (isWaitingOnRetry → false) so a
    /// future stall shows the notification again.
    private func clearNotification() {
        notificationAutoHideWork?.cancel()
        notificationAutoHideWork = nil
        notificationDismissed = false
        if displayState.notification != nil { displayState.notification = nil }
    }

    /// "Open Notes" action — deep-link, then dismiss the card.
    func openNotesFromNotification() {
        onOpenNotes?()
        dismissNotification()
    }

    /// Fires when the completion's hold timer expires. Returns the pill to
    /// the right downstream state:
    ///   - recording still active (mid-recording warning case) → recording
    ///   - processing still active (hard-stop completion before async work
    ///     finishes) → processing
    ///   - neither → hide
    /// Without this, the post-completion behaviour would always be "hide,"
    /// which is wrong for both warnings and hard-stop transitions.
    private func expireCompletion() {
        guard phase == .completion else { return }
        completionWorkItem = nil
        heldCompletionMessage = nil
        if let ts = transcription {
            if ts.isRecording {
                phase = .recording
                updateHosted(mode: .recording(durationSeconds: ts.duration))
                applyPhaseFrame(animated: true)
                return
            }
            if ts.isProcessing {
                phase = .processing
                updateHosted(mode: .processing)
                applyPhaseFrame(animated: true)
                return
            }
        }
        hidePanel()
        phase = .none
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
    /// shown. "Failed" gets a small pill, "Note saved" gets a larger pill,
    /// no slack on either side regardless of message length.
    ///
    /// Reads `displayState.mode` (which `sync()` sets via `updateHosted`
    /// BEFORE calling applyPhaseFrame), so the size always reflects the
    /// content that's about to be displayed.
    private func sizeForCurrentMode() -> NSSize {
        // Notification card supersedes the pill modes when active. Measure its
        // intrinsic height via a throwaway hosting view (width is fixed at 340
        // by the card's own .frame); actions are no-ops for measurement.
        if let n = displayState.notification {
            let probe = NSHostingView(rootView: TranscriptionStatusNotification(
                title: n.title, message: n.message,
                primaryLabel: n.primaryLabel, primaryAction: {},
                secondaryLabel: n.secondaryLabel, secondaryAction: {},
                onDismiss: {}
            ))
            return NSSize(width: 340, height: probe.fittingSize.height)
        }
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
            onStop: { [weak self] in self?.transcription?.stopRecording() },
            onNotificationPrimary: { [weak self] in self?.openNotesFromNotification() },
            onNotificationSecondary: { [weak self] in self?.dismissNotification() },
            onNotificationDismiss: { [weak self] in self?.dismissNotification() }
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
}
