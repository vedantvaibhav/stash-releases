import AppKit
import Combine
import SwiftUI

// MARK: - Pill mode

enum PillMode: Equatable {
    case recording(durationSeconds: Int)
    case processing
    case completion(message: String)
    case expanded(ShortTranscriptResult)
}

/// Stable animation key: identical across timer ticks so the HStack doesn't
/// cross-fade every second while recording.
private enum PillPhaseKey: Equatable {
    case recording
    case processing
    case completion(String)
    case expanded(UUID)

    init(_ mode: PillMode) {
        switch mode {
        case .recording:            self = .recording
        case .processing:           self = .processing
        case .completion(let msg):  self = .completion(msg)
        case .expanded(let result): self = .expanded(result.id)
        }
    }
}

// MARK: - SwiftUI pill body (matches Figma node 280-981)

struct TranscriptionPillView: View {
    let mode: PillMode
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Pill.contentSpacing) {
            iconDisc
            label
            Spacer(minLength: 0)
            trailing
        }
        .padding(.leading, DesignTokens.Pill.leadingPadding)
        .padding(.trailing, DesignTokens.Pill.trailingPadding)
        .padding(.vertical, DesignTokens.Pill.verticalPadding)
        .frame(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        .background(Color.black, in: Capsule())
        .animation(.easeInOut(duration: 0.18), value: PillPhaseKey(mode))
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
                    .foregroundStyle(DesignTokens.Icon.tintMuted)
                    .transition(.opacity)
            } else {
                glyph(completionSymbol(for: message))
            }
        case .expanded:
            EmptyView()
        }
    }

    /// True iff the message represents a paste-success state. Paste states use
    /// a custom asset (`PastedConfirm`) instead of an SF Symbol so the glyph
    /// matches the design language. The raw-vs-clean distinction stays in the
    /// label text — both share the icon.
    private func isPastedCompletion(_ message: String) -> Bool {
        message == "Pasted ✓" || message == "Pasted (raw)"
    }

    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: DesignTokens.Pill.iconGlyphSize, weight: .regular))
            .foregroundStyle(DesignTokens.Icon.tintMuted)
            .transition(.opacity)
    }

    /// Mirrors the strings emitted by `TranscriptionService.showCompletion(_:)`
    /// (see TranscriptionService.swift — `"Copied" | "Note saved" | "Failed"`).
    /// `"Pasted ✓"` / `"Pasted (raw)"` are handled in `iconGlyph` directly via
    /// the custom `PastedConfirm` asset. A string we don't recognise falls
    /// back to a neutral checkmark.
    private func completionSymbol(for message: String) -> String {
        switch message {
        case "Copied":        return "checkmark"
        case "Note saved":    return "note.text"
        case "Failed":        return "xmark"
        case "No audio":      return "mic.slash"
        case "Copied (raw)":  return "checkmark"
        case "Saved (raw)":   return "note.text"
        default:              return "checkmark"
        }
    }

    // MARK: Label (SF Pro 14 regular #A3A3A3)

    @ViewBuilder
    private var label: some View {
        switch mode {
        case .recording(let seconds):
            pillLabel(formatDuration(seconds), tabularDigits: true)
        case .processing:
            pillLabel("Processing")
        case .completion(let message):
            pillLabel(message)
        case .expanded:
            EmptyView()
        }
    }

    /// `tabularDigits: true` keeps SF Pro but forces equal-width digits so the
    /// timer doesn't jitter between seconds — no change to the typeface itself.
    /// `.fixedSize(horizontal:)` stops the HStack from compressing the label into
    /// an ellipsis when the pill is near its minimum width.
    private func pillLabel(_ text: String, tabularDigits: Bool = false) -> some View {
        let base = Font.system(size: 14, weight: .regular)
        return Text(text)
            .font(tabularDigits ? base.monospacedDigit() : base)
            .foregroundStyle(DesignTokens.Typography.itemColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            // PillRootView's outer `.animation(_:value: state.mode)` opens an
            // animated transaction every second of recording (state.mode's
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
        case .processing, .completion, .expanded:
            EmptyView()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        formatPillDuration(seconds)
    }
}

/// Pill duration format. Default MM:SS (zero-padded minutes); only expand to
/// H:MM:SS once a recording crosses one hour. Shared by the collapsed
/// `TranscriptionPillView` and the expanded `TranscriptionPillExpandedView`
/// so both surfaces agree on `02:31` vs `2:31`.
fileprivate func formatPillDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
}

// MARK: - Stop button (10×10 solid red dot, 32×32 tap target)
//
// Visible dot is trailing-aligned inside the tap zone so the gap to the pill's
// right edge matches the 12 pt trailing padding — the tap area extends leftward
// (invisibly) into the label region for a generous hit box.
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
            .frame(
                width: DesignTokens.Pill.stopTapTargetSize,
                height: DesignTokens.Pill.stopTapTargetSize,
                alignment: .trailing
            )
            .contentShape(Rectangle())
            .onTapGesture { onStop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stop recording")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Floating panel

private final class PillPanel: NSPanel {
    /// Controller flips this true while the expanded short-transcript handoff is
    /// visible (so ⌘C/Esc keyDowns reach our local NSEvent monitor) and back to
    /// false on collapse so the recording/processing pill never steals focus.
    var allowsKeyStatus: Bool = false
    override var canBecomeKey: Bool { allowsKeyStatus }
}

// MARK: - Unified display state + root view
//
// The previous design swapped `panel.contentView` between three different
// NSHostingView trees (collapsed pill, expanded card, minimized Ready pill).
// Each swap caused a visible content discontinuity that no overlay/snapshot
// could fully hide — the SwiftUI tree is rebuilt from scratch on every swap,
// so SwiftUI sees no continuity to animate against.
//
// This redesign keeps ONE persistent NSHostingView<PillRootView>. The root
// branches on `PillDisplayState.mode`, and a single `.animation(_:value:)`
// modifier triggers a SwiftUI cross-fade whenever the mode changes. The
// AppKit panel frame still animates separately — but with matching duration
// and easing, the two read as a single coordinated morph.

final class PillDisplayState: ObservableObject {
    enum Mode: Equatable {
        case collapsed(PillMode)
        case expandedReady(ShortTranscriptResult)
        case minimizedReady(ShortTranscriptResult)
    }
    @Published var mode: Mode = .collapsed(.processing)
    @Published var copyFlashActive: Bool = false
    /// Mirrors the AppKit-side snap zone so SwiftUI can align mode-content
    /// to the same edge AppKit anchors the panel to. Without this, an
    /// expanded view (520×280) inside a small host (130×32) would center its
    /// content visually — making it appear to "slide" sideways during the
    /// morph rather than expanding from the snap-corner.
    @Published var snapZone: PanelSnapZone = .topCenter
}

struct PillRootView: View {
    @ObservedObject var state: PillDisplayState
    let onStop: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: alignmentForSnapZone) {
            switch state.mode {
            case .collapsed(let pillMode):
                TranscriptionPillView(mode: pillMode, onStop: onStop)
                    .transition(.opacity)
            case .expandedReady(let result):
                TranscriptionPillExpandedView(
                    result: result,
                    onCopy: onCopy,
                    onDismiss: onDismiss,
                    copyFlashActive: state.copyFlashActive
                )
                .transition(.opacity)
            case .minimizedReady:
                MinimizedReadyPillView(onHoverEnter: {})
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: DesignTokens.Pill.expandedAnimationDuration), value: state.mode)
    }

    /// Match SwiftUI ZStack alignment to the AppKit snap zone so content
    /// edges line up across the morph (no horizontal/vertical glide).
    private var alignmentForSnapZone: Alignment {
        switch state.snapZone {
        case .topLeft:      return .topLeading
        case .topCenter:    return .top
        case .topRight:     return .topTrailing
        case .bottomLeft:   return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight:  return .bottomTrailing
        }
    }
}

// MARK: - AppKit hover tracking
//
// SwiftUI's `.onHover` is unreliable when the cursor is already inside the
// view's tracking area at the moment the view is rendered (common during
// our morph: cursor lands on the pill before the SwiftUI tree has its first
// hover event). NSTrackingArea with `.assumeInside` correctly reports the
// initial-hover state and fires reliably across mode changes.

final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .assumeInside],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    /// Pass clicks through to subviews; this view only observes hover.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit !== self { return hit }
        return nil
    }
}

// MARK: - Controller

@MainActor
final class TranscriptionFloatingWidgetController: NSObject {

    private weak var transcription: TranscriptionService?
    private var panel: PillPanel?
    /// One persistent NSHostingView. Driven by `displayState`; never replaced
    /// across phase transitions, so SwiftUI sees mode changes as in-place
    /// state mutations and animates them with `.animation(_:value:)`.
    private var hosting: NSHostingView<PillRootView>?
    /// Mode/state binding for the persistent hosting view.
    private let displayState = PillDisplayState()
    private var cancellables = Set<AnyCancellable>()
    private var panelOpenForWidget = false

    private enum Phase { case none, recording, processing, completion, expandedReady, minimizedReady }
    private var phase: Phase = .none
    private var completionWorkItem: DispatchWorkItem?

    // MARK: Expanded / minimized state
    /// Currently-attached result. Non-nil for both `.expandedReady` and
    /// `.minimizedReady`; nil otherwise.
    private var activeExpandedResult: ShortTranscriptResult?
    /// Auto-minimize timer (30s). Resets on hover-end and on interaction.
    private var autoMinimizeWorkItem: DispatchWorkItem?
    /// Local NSEvent monitor for ⌘C and Esc while expanded.
    private var expandedKeyMonitor: Any?
    /// Non-nil for ~1.2s after Copy is clicked — drives the "Copied ✓" flash.
    /// `copyFlashWorkItem != nil` ⇒ flashing (mirrored to `displayState.copyFlashActive`).
    private var copyFlashWorkItem: DispatchWorkItem?
    /// True if the current `.expandedReady` was triggered by hovering the
    /// minimized pill (vs. the initial post-recording auto-expansion). When
    /// true, hover-leave collapses immediately back to `.minimizedReady`. When
    /// false, hover-leave schedules the 30s auto-minimize timer.
    private var expandedViaHover: Bool = false

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
        if let m = expandedKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = dragMonitor { NSEvent.removeMonitor(m) }
        autoMinimizeWorkItem?.cancel()
        copyFlashWorkItem?.cancel()
        completionWorkItem?.cancel()
    }

    func setPanelOpenForWidget(_ open: Bool) {
        panelOpenForWidget = open
        sync()
    }

    private func sync() {
        guard let ts = transcription else { hidePanel(); return }

        if panelOpenForWidget {
            // Tear down any expansion / minimized state; full hide.
            if phase == .expandedReady || phase == .minimizedReady {
                hideAllResultPhases(clearResultOnService: true, animated: false)
            }
            cancelAllPendingWork()
            hidePanel()
            phase = .none
            return
        }

        // Recording supersedes everything: a new recording while the pill is
        // expanded or minimized must hide that state immediately.
        if ts.isRecording {
            if phase == .expandedReady || phase == .minimizedReady {
                hideAllResultPhases(clearResultOnService: true, animated: false)
            }
            cancelAllPendingWork(except: .recording)
            phase = .recording
            showCollapsedPanelIfNeeded()
            updateHosted(mode: .recording(durationSeconds: ts.duration))
            return
        }

        // Short-recording handoff — present (or re-present) the expanded pill.
        // No-op when we're already showing this exact result in either result
        // phase (the user's interaction drives transitions from there).
        if let result = ts.shortTranscriptResult {
            let alreadyShowing = activeExpandedResult?.id == result.id
                && (phase == .expandedReady || phase == .minimizedReady)
            if !alreadyShowing { presentExpansion(for: result) }
            return
        }

        if let msg = ts.completionMessage {
            cancelAllPendingWork(except: .completion)
            phase = .completion
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
            cancelAllPendingWork(except: .processing)
            phase = .processing
            showCollapsedPanelIfNeeded()
            updateHosted(mode: .processing)
            return
        }

        // No state claimed us; if we're in expandedReady/minimizedReady,
        // leave them alone (they're driven by interaction, not service state).
        if phase != .completion && phase != .expandedReady && phase != .minimizedReady {
            hidePanel()
            phase = .none
        }
    }

    private func cancelAllPendingWork(except keep: Phase = .none) {
        if keep != .completion {
            completionWorkItem?.cancel()
            completionWorkItem = nil
        }
        if keep != .expandedReady && keep != .minimizedReady {
            autoMinimizeWorkItem?.cancel()
            autoMinimizeWorkItem = nil
            copyFlashWorkItem?.cancel()
            copyFlashWorkItem = nil
        }
    }

    /// Update the SwiftUI tree's mode. SwiftUI's `.animation(_:value:)` on
    /// PillRootView triggers a cross-fade if the new mode is a different
    /// branch (collapsed ↔ expandedReady ↔ minimizedReady). For inner-pill
    /// changes (recording → processing → completion), TranscriptionPillView's
    /// own `.animation(.easeInOut(duration: 0.18), value:)` handles them.
    private func updateHosted(mode: PillMode) {
        let new: PillDisplayState.Mode = .collapsed(mode)
        if displayState.mode != new { displayState.mode = new }
    }

    private func showCollapsedPanelIfNeeded() {
        if panel == nil { buildPanel() }
        // No resize here: the panel was either built at collapsed size, or has
        // already been resized to collapsed by `hideAllResultPhases` /
        // `collapseToMinimizedReady` before sync() calls back into us.
        panel?.orderFrontRegardless()
    }

    /// Resize the panel back to capsule dimensions, anchored at the persisted
    /// snap zone. Called by `hideAllResultPhases` and `collapseToMinimizedReady`.
    private func resizePanelToCollapsed(animated: Bool) {
        let size = NSSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        applyPhaseAwareFrame(size: size, animated: animated)
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
    /// Used by every phase transition (collapsed/expanded/minimized resize)
    /// and by `restorePosition` on launch.
    private func applyPhaseAwareFrame(size: CGSize, animated: Bool) {
        guard let screen = NSScreen.main else { return }
        let target = currentSnapZone().visibleFrame(size: size, screen: screen.visibleFrame)
        applyPanelFrame(target, animated: animated)
    }

    /// Animate panel frame using the spec's cubic-bezier curve over 280ms.
    private func applyPanelFrame(_ frame: NSRect, animated: Bool) {
        guard let panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = DesignTokens.Pill.expandedAnimationDuration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints:
                    Float(DesignTokens.Pill.expandedAnimationCurveCP1x),
                    Float(DesignTokens.Pill.expandedAnimationCurveCP1y),
                    Float(DesignTokens.Pill.expandedAnimationCurveCP2x),
                    Float(DesignTokens.Pill.expandedAnimationCurveCP2y)
                )
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
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
            onStop: { [weak self] in self?.transcription?.stopRecording() },
            onCopy: { [weak self] in self?.handleCopy() },
            onDismiss: { [weak self] in self?.handleDismiss() }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.autoresizingMask = [.width, .height]

        // Wrap the SwiftUI host in an AppKit tracking view so cursor enter/exit
        // is detected reliably even when the cursor was already inside at the
        // moment the SwiftUI tree changed mode.
        let wrapper = HoverTrackingView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        wrapper.autoresizesSubviews = true
        wrapper.addSubview(host)
        wrapper.onHoverChanged = { [weak self] hovering in
            self?.handleAppKitHover(hovering)
        }

        p.contentView = wrapper
        hosting = host
        panel = p

        restorePosition()
        installDragMonitor()
    }

    /// First launch uses the menu-bar default (top-center). Subsequent
    /// launches restore whichever corner the user last snapped the pill into.
    private func restorePosition() {
        let size = NSSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        // Seed SwiftUI alignment to match the persisted (or default) zone so
        // the very first render aligns correctly.
        displayState.snapZone = currentSnapZone()
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
        // Use the panel's CURRENT size so dragging the expanded form snaps to
        // a corner that fits the expanded form, not a hardcoded 130×32.
        let size = panel.frame.size
        let zone = PanelSnapZone.nearest(to: panel.frame, size: size, screen: vf)
        UserDefaults.standard.set(zone.rawValue, forKey: Self.snapZoneDefaultsKey)
        // Mirror to SwiftUI so ZStack alignment follows the new corner.
        displayState.snapZone = zone
        applyPhaseAwareFrame(size: size, animated: true)
    }

    // MARK: - Expanded / minimized phase
    //
    // All three transitions (present, collapse-to-minimized, hide) mutate
    // `displayState.mode` to drive the SwiftUI cross-fade, then animate the
    // AppKit panel frame in parallel. The SwiftUI animation duration matches
    // `expandedAnimationDuration`, so the two read as one coordinated morph.

    private func presentExpansion(for result: ShortTranscriptResult) {
        autoMinimizeWorkItem?.cancel(); autoMinimizeWorkItem = nil
        copyFlashWorkItem?.cancel(); copyFlashWorkItem = nil
        completionWorkItem?.cancel(); completionWorkItem = nil

        if panel == nil { buildPanel() }
        guard let panel else { return }

        // Default to false; `handleMinimizedHoverEnter` flips true after
        // calling presentExpansion when triggered by a hover on the minimized
        // pill (so subsequent hover-leave collapses immediately).
        expandedViaHover = false
        activeExpandedResult = result
        phase = .expandedReady

        // Drive the SwiftUI cross-fade.
        displayState.copyFlashActive = false
        displayState.mode = .expandedReady(result)

        // Allow keyDown delivery for ⌘C/Esc.
        panel.allowsKeyStatus = true
        panel.orderFrontRegardless()
        panel.makeKey()

        // Animate the panel to the expanded size in sync with SwiftUI's
        // cross-fade. Height is computed from a probe layout of the SwiftUI
        // tree; falls back to `expandedMaxHeight` if the probe yields zero.
        let targetHeight = measuredExpandedHeight(for: result)
        let targetSize = NSSize(width: DesignTokens.Pill.expandedWidth, height: targetHeight)
        applyPhaseAwareFrame(size: targetSize, animated: true)

        installExpandedKeyMonitor()
        scheduleAutoMinimize()
    }

    /// One-off layout probe for the expanded view's preferred height. Builds
    /// a throwaway NSHostingView at the target width, lays out, and reads
    /// `fittingSize.height`. Capped at `expandedMaxHeight`.
    private func measuredExpandedHeight(for result: ShortTranscriptResult) -> CGFloat {
        let probe = NSHostingView(rootView: TranscriptionPillExpandedView(
            result: result,
            onCopy: {},
            onDismiss: {},
            copyFlashActive: false
        ))
        probe.frame = NSRect(
            x: 0, y: 0,
            width: DesignTokens.Pill.expandedWidth,
            height: DesignTokens.Pill.expandedMaxHeight
        )
        probe.layoutSubtreeIfNeeded()
        let h = probe.fittingSize.height
        return min(max(h, DesignTokens.Pill.height), DesignTokens.Pill.expandedMaxHeight)
    }

    private func handleCopy() {
        guard phase == .expandedReady, let result = activeExpandedResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.text, forType: .string)
        copyFlashWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideAllResultPhases(clearResultOnService: true, animated: true)
        }
        copyFlashWorkItem = work
        // SwiftUI re-renders the footer to show "Copied ✓" because PillRootView
        // observes `displayState.copyFlashActive`.
        displayState.copyFlashActive = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DesignTokens.Pill.expandedCopyFlashSeconds,
            execute: work
        )
    }

    private func handleDismiss() {
        guard phase == .expandedReady else { return }
        hideAllResultPhases(clearResultOnService: true, animated: true)
    }

    private func scheduleAutoMinimize() {
        autoMinimizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseToMinimizedReady()
        }
        autoMinimizeWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DesignTokens.Pill.expandedAutoMinimizeSeconds,
            execute: work
        )
    }

    /// Single AppKit-driven hover handler. Routes to the right per-phase
    /// behavior based on `phase`. Replaces SwiftUI .onHover (which was
    /// unreliable across the morph because the cursor was often already
    /// inside when the new SwiftUI tree mounted).
    private func handleAppKitHover(_ hovering: Bool) {
        switch phase {
        case .expandedReady:
            if hovering {
                autoMinimizeWorkItem?.cancel()
                autoMinimizeWorkItem = nil
            } else if expandedViaHover {
                // Cursor leaving an expansion that was triggered by hover →
                // collapse immediately back to minimized.
                collapseToMinimizedReady()
            } else {
                // Initial post-recording expansion: cursor leaving restarts
                // the 30s grace.
                scheduleAutoMinimize()
            }
        case .minimizedReady:
            if hovering {
                handleMinimizedHoverEnter()
            }
            // Hover-exit on minimized is a no-op; the pill stays.
        default:
            break
        }
    }

    /// Kept for the internal call sites that already invoke handleHoverChanged
    /// (none after this refactor, but the function name is referenced in
    /// historical code paths if any survive).
    private func handleHoverChanged(_ hovering: Bool) {
        handleAppKitHover(hovering)
    }

    private func collapseToMinimizedReady() {
        guard phase == .expandedReady, let result = activeExpandedResult else { return }
        autoMinimizeWorkItem?.cancel(); autoMinimizeWorkItem = nil
        copyFlashWorkItem?.cancel(); copyFlashWorkItem = nil
        removeExpandedKeyMonitor()

        phase = .minimizedReady
        panel?.allowsKeyStatus = false

        // Drive the SwiftUI cross-fade + animate the panel frame to small.
        displayState.copyFlashActive = false
        displayState.mode = .minimizedReady(result)
        resizePanelToCollapsed(animated: true)

        // Service-side result stays — hovering the minimized pill re-expands
        // via `handleMinimizedHoverEnter` → `presentExpansion`.
    }

    private func handleMinimizedHoverEnter() {
        guard phase == .minimizedReady, let result = activeExpandedResult else { return }
        presentExpansion(for: result)
        // Mark the lifecycle as cursor-driven from here on: hover-leave will
        // collapse immediately back to .minimizedReady.
        expandedViaHover = true
    }

    /// Full hide. Used by Copy / Dismiss / Esc / new-recording.
    private func hideAllResultPhases(clearResultOnService: Bool, animated: Bool) {
        autoMinimizeWorkItem?.cancel(); autoMinimizeWorkItem = nil
        copyFlashWorkItem?.cancel(); copyFlashWorkItem = nil
        removeExpandedKeyMonitor()

        phase = .none
        activeExpandedResult = nil
        panel?.allowsKeyStatus = false

        // Cross-fade back to a neutral collapsed mode while the panel shrinks.
        // The panel is then ordered out after the resize animation completes.
        displayState.copyFlashActive = false
        displayState.mode = .collapsed(.processing)
        resizePanelToCollapsed(animated: animated)

        let delay = animated ? DesignTokens.Pill.expandedAnimationDuration : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.phase == .none else { return }
            self.hidePanel()
        }

        if clearResultOnService {
            transcription?.clearShortTranscriptResult()
        }
    }

    // MARK: Keyboard shortcuts (⌘C, Esc)
    //
    // PillPanel.canBecomeKey is flipped to true while expanded, and the panel
    // is made key in presentExpansion. Local monitors then receive keyDown
    // events delivered to our key panel.

    private static let escKeyCode: UInt16 = 53

    private func installExpandedKeyMonitor() {
        guard expandedKeyMonitor == nil else { return }
        expandedKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.phase == .expandedReady, let panel = self.panel else { return event }
            guard event.window === panel else { return event }
            if event.keyCode == Self.escKeyCode {
                self.handleDismiss()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                self.handleCopy()
                return nil
            }
            return event
        }
    }

    private func removeExpandedKeyMonitor() {
        if let m = expandedKeyMonitor {
            NSEvent.removeMonitor(m)
            expandedKeyMonitor = nil
        }
    }
}

// MARK: - Expanded pill (short-recording handoff)

/// Vertical layout: eyebrow + duration row, scrollable selectable text,
/// Copy / Dismiss footer. Width fixed by `DesignTokens.Pill.expandedWidth`;
/// height grows with content up to `expandedMaxHeight`, then scrolls.
struct TranscriptionPillExpandedView: View {
    let result: ShortTranscriptResult
    let onCopy: () -> Void
    let onDismiss: () -> Void
    /// True for ~1.2s after the user clicks Copy. Replaces the Copy button
    /// label with a "Copied ✓" affordance before the pill collapses.
    let copyFlashActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow
                .padding(.bottom, DesignTokens.Pill.expandedEyebrowToTextGap)
            transcriptText
                .padding(.bottom, DesignTokens.Pill.expandedTextToFooterGap)
            footer
        }
        .padding(DesignTokens.Pill.expandedPadding)
        .frame(width: DesignTokens.Pill.expandedWidth, alignment: .topLeading)
        .frame(maxHeight: DesignTokens.Pill.expandedMaxHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Pill.expandedCornerRadius, style: .continuous)
                .fill(Color.black)
        )
    }

    private var eyebrow: some View {
        HStack(spacing: 0) {
            Text(result.isRaw ? "Voice note — raw" : "Voice note")
                .font(DesignTokens.Pill.expandedEyebrowFont)
                .foregroundStyle(DesignTokens.Pill.expandedEyebrowColor)
            Spacer(minLength: 8)
            Text(formatPillDuration(result.durationSeconds))
                .font(DesignTokens.Pill.expandedEyebrowFont.monospacedDigit())
                .foregroundStyle(DesignTokens.Pill.expandedEyebrowColor)
        }
    }

    private var transcriptText: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(result.text)
                .font(DesignTokens.Pill.expandedTextFont)
                .foregroundStyle(DesignTokens.Pill.expandedTextColor)
                .lineSpacing(DesignTokens.Pill.expandedTextLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Pill.expandedButtonGap) {
            Spacer()
            PillIconButton(systemSymbol: "xmark", action: onDismiss)
            PillFilledButton(
                title: copyFlashActive ? "Copied ✓" : "Copy",
                action: onCopy,
                isFlashing: copyFlashActive
            )
        }
        .frame(height: DesignTokens.Pill.expandedButtonHeight)
    }
}

// MARK: - Expanded-pill button styles

private struct PillIconButton: View {
    let systemSymbol: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Pill.expandedGhostForeground)
                .frame(
                    width: DesignTokens.Pill.expandedButtonHeight,
                    height: DesignTokens.Pill.expandedButtonHeight
                )
                .background(Circle().fill(background))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
        .accessibilityLabel("Dismiss")
    }

    private var background: Color {
        isHovering
            ? DesignTokens.Pill.expandedGhostBackgroundHover
            : DesignTokens.Pill.expandedGhostBackgroundRest
    }
}

private struct PillFilledButton: View {
    let title: String
    let action: () -> Void
    var isFlashing: Bool = false

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.Pill.expandedFilledFont)
                .foregroundStyle(DesignTokens.Pill.expandedFilledForeground)
                .padding(.horizontal, DesignTokens.Pill.expandedButtonHorizontalPadding)
                .frame(height: DesignTokens.Pill.expandedButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Pill.expandedButtonCornerRadius, style: .continuous)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .disabled(isFlashing)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var background: Color {
        isHovering
            ? DesignTokens.Pill.expandedFilledBackgroundHover
            : DesignTokens.Pill.expandedFilledBackgroundRest
    }
}

// MARK: - Minimized Ready pill (the resting form after auto-minimize)

/// Same 130×32 capsule geometry as TranscriptionPillView, but shows
/// `[✓] Ready` instead of recording/processing/completion content.
/// Hover triggers re-expansion via the controller's onHoverEnter callback.
struct MinimizedReadyPillView: View {
    let onHoverEnter: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.Pill.contentSpacing) {
            ZStack {
                Circle().fill(DesignTokens.Icon.backgroundRest)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.Pill.iconGlyphSize, weight: .regular))
                    .foregroundStyle(DesignTokens.Icon.tintMuted)
            }
            .frame(width: DesignTokens.Pill.iconDiscSize, height: DesignTokens.Pill.iconDiscSize)

            Text("Ready")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(DesignTokens.Typography.itemColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 0)
        }
        .padding(.leading, DesignTokens.Pill.leadingPadding)
        .padding(.trailing, DesignTokens.Pill.trailingPadding)
        .padding(.vertical, DesignTokens.Pill.verticalPadding)
        .frame(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        .background(Color.black, in: Capsule())
        .onHover { hovering in if hovering { onHoverEnter() } }
        .accessibilityLabel("Transcription ready — hover to view")
    }
}

