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
            glyph(completionSymbol(for: message))
        case .expanded:
            EmptyView()
        }
    }

    private func glyph(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: DesignTokens.Pill.iconGlyphSize, weight: .regular))
            .foregroundStyle(DesignTokens.Icon.tintMuted)
            .transition(.opacity)
    }

    /// Mirrors the strings emitted by `TranscriptionService.showCompletion(_:)`
    /// (see TranscriptionService.swift — `"Copied" | "Note saved" | "Failed"`).
    /// A service string we don't recognise falls back to a neutral checkmark.
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

// MARK: - Controller

@MainActor
final class TranscriptionFloatingWidgetController: NSObject {

    private weak var transcription: TranscriptionService?
    private var panel: PillPanel?
    private var hosting: NSHostingView<TranscriptionPillView>?
    private var cancellables = Set<AnyCancellable>()
    private var panelOpenForWidget = false

    private enum Phase { case none, recording, processing, completion, expanded }
    private var phase: Phase = .none
    private var completionWorkItem: DispatchWorkItem?

    // MARK: Expanded-state state
    /// Currently-expanded result. `nil` means we're not in `.expanded` phase.
    private var activeExpandedResult: ShortTranscriptResult?
    /// Hosting view for the expanded SwiftUI root, kept in a SEPARATE ivar from
    /// `hosting: NSHostingView<TranscriptionPillView>?` so the typed collapsed-host
    /// reference stays valid across the lifecycle. Nil when not expanded.
    /// Type-erased to `AnyView` because the controller wraps the inner view in
    /// `.onHover` (which changes the static type).
    private var expandedHosting: NSHostingView<AnyView>?
    /// Auto-dismiss timer (30s default; reset on hover-end and on interaction).
    private var autoDismissWorkItem: DispatchWorkItem?
    /// Global monitor: clicks landing in OTHER applications. Installed on expand.
    private var globalClickOutsideMonitor: Any?
    /// Local monitor: clicks landing in OUR application (whether on the pill or
    /// another window of ours). Installed on expand.
    private var localClickOutsideMonitor: Any?
    /// Local monitor for ⌘C and Esc while expanded. Installed on expand.
    private var expandedKeyMonitor: Any?
    /// Non-nil for ~1.2s after Copy is clicked — drives the "Copied ✓" flash.
    /// Used as the source of truth: `copyFlashWorkItem != nil` ⇒ flashing.
    private var copyFlashWorkItem: DispatchWorkItem?
    /// Change-detection guard — `TranscriptionService.audioLevel` ticks ~10×/s,
    /// firing `objectWillChange`. We only need to rebuild the hosted SwiftUI tree
    /// when the displayed `PillMode` actually changes (duration seconds, phase,
    /// or completion text).
    private var lastMode: PillMode?

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
        // DispatchWorkItem closures use weak self so they're benign, but
        // explicit cancellation is cheap and aids reasoning.
        if let m = globalClickOutsideMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickOutsideMonitor { NSEvent.removeMonitor(m) }
        if let m = expandedKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = dragMonitor { NSEvent.removeMonitor(m) }
        autoDismissWorkItem?.cancel()
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
            // If we're expanded, tear down monitors/timers/host before hiding —
            // otherwise NSEvent monitors and the expanded NSHostingView leak.
            if phase == .expanded { collapseExpansion(clearResultOnService: true, animated: false) }
            cancelAllPendingWork()
            hidePanel()
            phase = .none
            return
        }

        // Recording supersedes everything else: a new recording while the pill
        // is expanded must collapse it immediately and hand the transcript
        // back to the service so it isn't re-triggered.
        if ts.isRecording {
            if phase == .expanded { collapseExpansion(clearResultOnService: true, animated: false) }
            cancelAllPendingWork(except: .recording)
            phase = .recording
            showCollapsedPanelIfNeeded()
            updateHosted(mode: .recording(durationSeconds: ts.duration))
            return
        }

        // Short-recording handoff — present the expanded pill.
        if let result = ts.shortTranscriptResult {
            if phase != .expanded || activeExpandedResult?.id != result.id {
                presentExpansion(for: result)
            }
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

        if phase != .completion && phase != .expanded {
            hidePanel()
            phase = .none
        }
    }

    private func cancelAllPendingWork(except keep: Phase = .none) {
        if keep != .completion {
            completionWorkItem?.cancel()
            completionWorkItem = nil
        }
        if keep != .expanded {
            autoDismissWorkItem?.cancel()
            autoDismissWorkItem = nil
            copyFlashWorkItem?.cancel()
            copyFlashWorkItem = nil
        }
    }

    private func updateHosted(mode: PillMode) {
        guard let hosting else { return }
        if lastMode == mode { return }
        lastMode = mode
        hosting.rootView = TranscriptionPillView(
            mode: mode,
            onStop: { [weak self] in self?.transcription?.stopRecording() }
        )
    }

    private func showCollapsedPanelIfNeeded() {
        if panel == nil { buildPanel() }
        // No resize here: the panel was either built at collapsed size, or has
        // already been resized to collapsed by `collapseExpansion` before sync()
        // calls back into us. Computing an `animated` flag from `phase` here is
        // racy — sync() mutates `phase` BEFORE invoking us, so the flag would
        // always be wrong by the time it's read.
        panel?.orderFrontRegardless()
    }

    /// Resize the panel back to capsule dimensions. Called explicitly by
    /// `collapseExpansion` (the only path that ever needs this).
    private func resizePanelToCollapsed(animated: Bool) {
        guard let panel else { return }
        let target = NSRect(
            origin: keepWithinScreen(
                origin: panel.frame.origin,
                size: NSSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
            ),
            size: NSSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        )
        applyPanelFrame(target, animated: animated)
    }

    /// Resize the panel to host the expanded view. Reads `fittingSize` from
    /// `expandedHosting` (NOT the typed-collapsed `hosting` ivar). Caller MUST
    /// have already assigned `expandedHosting` as `panel.contentView` and
    /// applied a width-fixed frame so AppKit can compute a real fittingSize
    /// (an unattached NSHostingView reports `.zero`).
    private func resizePanelToExpanded(animated: Bool) {
        guard let panel, let host = expandedHosting else { return }
        host.frame = NSRect(
            x: 0, y: 0,
            width: DesignTokens.Pill.expandedWidth,
            height: DesignTokens.Pill.expandedMaxHeight
        )
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize.height
        let cap = DesignTokens.Pill.expandedMaxHeight
        let h = min(max(fitted, DesignTokens.Pill.height), cap)
        let w = DesignTokens.Pill.expandedWidth
        let target = NSRect(
            origin: keepWithinScreen(
                origin: panel.frame.origin,
                size: NSSize(width: w, height: h)
            ),
            size: NSSize(width: w, height: h)
        )
        applyPanelFrame(target, animated: animated)
    }

    /// Clamp `origin` so a window of `size` stays within the current screen's
    /// `visibleFrame`. Prevents the expanded pill from rendering off-screen
    /// when the user has snapped the collapsed pill to a corner.
    private func keepWithinScreen(origin: NSPoint, size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return origin }
        let vf = screen.visibleFrame
        var x = origin.x
        var y = origin.y
        if x + size.width > vf.maxX { x = vf.maxX - size.width }
        if x < vf.minX { x = vf.minX }
        if y + size.height > vf.maxY { y = vf.maxY - size.height }
        if y < vf.minY { y = vf.minY }
        return NSPoint(x: x, y: y)
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
        lastMode = nil
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

        let initial = TranscriptionPillView(
            mode: .processing,
            onStop: { [weak self] in self?.transcription?.stopRecording() }
        )
        let host = NSHostingView(rootView: initial)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.autoresizingMask = [.width, .height]

        p.contentView = host
        hosting = host
        panel = p

        restorePosition()
        installDragMonitor()
    }

    /// First launch uses the menu-bar default (8 pt below the bar). Subsequent
    /// launches restore whichever corner the user last snapped the pill into.
    private func restorePosition() {
        if let raw = UserDefaults.standard.string(forKey: Self.snapZoneDefaultsKey),
           let zone = PanelSnapZone(rawValue: raw) {
            applySnapZone(zone, animated: false)
        } else {
            positionAtMenuBar()
        }
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
        let size = CGSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        let zone = PanelSnapZone.nearest(to: panel.frame, size: size, screen: vf)
        UserDefaults.standard.set(zone.rawValue, forKey: Self.snapZoneDefaultsKey)
        applySnapZone(zone, animated: true)
    }

    private func applySnapZone(_ zone: PanelSnapZone, animated: Bool) {
        guard let panel, let screen = NSScreen.main else { return }
        let size = CGSize(width: DesignTokens.Pill.width, height: DesignTokens.Pill.height)
        let target = zone.visibleFrame(size: size, screen: screen.visibleFrame)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.3, 0.64, 1.0) // springy, matches tray
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: false)
        }
    }

    // MARK: - Expanded phase

    /// Build (or rebuild) the expanded host, attach as contentView, lay out,
    /// then animate the panel frame to the measured fitting size.
    private func presentExpansion(for result: ShortTranscriptResult) {
        autoDismissWorkItem?.cancel(); autoDismissWorkItem = nil
        copyFlashWorkItem?.cancel(); copyFlashWorkItem = nil
        completionWorkItem?.cancel(); completionWorkItem = nil

        if panel == nil { buildPanel() }
        guard let panel else { return }

        activeExpandedResult = result
        phase = .expanded
        lastMode = nil

        // Order matters: build host → assign as contentView → resize (which
        // measures fittingSize on the now-attached host).
        let expanded = makeExpandedRootView(result: result)
        let host = NSHostingView(rootView: expanded)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        expandedHosting = host

        // Allow keyDown delivery to the pill while expanded so the local
        // NSEvent monitor for ⌘C/Esc actually receives them.
        panel.allowsKeyStatus = true
        panel.orderFrontRegardless()
        panel.makeKey()

        resizePanelToExpanded(animated: true)
        installClickOutsideMonitors()
        installExpandedKeyMonitor()
        scheduleAutoDismiss()
    }

    /// Build the expanded root + apply `.onHover` for auto-dismiss reset.
    /// Returns `AnyView` because `.onHover` changes the static View type and
    /// the host needs a stable type across rebuilds.
    private func makeExpandedRootView(result: ShortTranscriptResult) -> AnyView {
        let inner = TranscriptionPillExpandedView(
            result: result,
            onCopy: { [weak self] in self?.handleCopy() },
            onDismiss: { [weak self] in self?.handleDismiss() },
            copyFlashActive: copyFlashWorkItem != nil
        )
        return AnyView(
            inner.onHover { [weak self] hovering in self?.handleHoverChanged(hovering) }
        )
    }

    /// Push a fresh root view into the expanded NSHostingView (no panel resize).
    /// Used for in-place updates like the Copy → "Copied ✓" flash.
    private func updateExpandedHostedRootIfPresent() {
        guard phase == .expanded, let result = activeExpandedResult, let host = expandedHosting else { return }
        host.rootView = makeExpandedRootView(result: result)
    }

    private func handleCopy() {
        guard phase == .expanded, let result = activeExpandedResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.text, forType: .string)
        copyFlashWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseExpansion(clearResultOnService: true, animated: true)
        }
        copyFlashWorkItem = work
        // Push the "Copied ✓" label into the SwiftUI tree now that the work
        // item exists (so `copyFlashWorkItem != nil` ⇒ flashing).
        updateExpandedHostedRootIfPresent()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DesignTokens.Pill.expandedCopyFlashSeconds,
            execute: work
        )
    }

    private func handleDismiss() {
        guard phase == .expanded else { return }
        collapseExpansion(clearResultOnService: true, animated: true)
    }

    private func scheduleAutoDismiss() {
        autoDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseExpansion(clearResultOnService: true, animated: true)
        }
        autoDismissWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DesignTokens.Pill.expandedAutoDismissSeconds,
            execute: work
        )
    }

    private func handleHoverChanged(_ hovering: Bool) {
        guard phase == .expanded else { return }
        if hovering {
            autoDismissWorkItem?.cancel()
            autoDismissWorkItem = nil
        } else {
            scheduleAutoDismiss()
        }
    }

    /// Tear down expanded state and rebuild the collapsed pill hosting view.
    /// `clearResultOnService` should be true unless `sync()` is collapsing us
    /// because a new recording is starting (in which case sync() also clears
    /// the published result on the next tick).
    private func collapseExpansion(clearResultOnService: Bool, animated: Bool) {
        autoDismissWorkItem?.cancel(); autoDismissWorkItem = nil
        copyFlashWorkItem?.cancel(); copyFlashWorkItem = nil
        removeClickOutsideMonitors()
        removeExpandedKeyMonitor()

        // Flip phase out of `.expanded` synchronously so a new
        // shortTranscriptResult landing during the collapse animation can call
        // presentExpansion cleanly (it gates on `phase != .expanded`).
        phase = .none
        activeExpandedResult = nil
        expandedHosting = nil
        lastMode = nil

        if let panel {
            panel.allowsKeyStatus = false
            let initial = TranscriptionPillView(
                mode: .processing,
                onStop: { [weak self] in self?.transcription?.stopRecording() }
            )
            let host = NSHostingView(rootView: initial)
            host.frame = NSRect(
                x: 0, y: 0,
                width: DesignTokens.Pill.width,
                height: DesignTokens.Pill.height
            )
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
            hosting = host
        }

        resizePanelToCollapsed(animated: animated)

        // Hide the panel after the resize completes if no other phase claimed
        // it during the animation window.
        let delay = animated ? DesignTokens.Pill.expandedAnimationDuration : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.phase == .none else { return }
            self.hidePanel()
        }

        if clearResultOnService {
            transcription?.clearShortTranscriptResult()
        }
    }

    // MARK: Click-outside detection
    //
    // Local monitors only fire for events delivered to OUR application. A click
    // in Safari or Finder triggers no local monitor — we need a global monitor
    // for those. Global monitors can't return events (can't swallow), but for
    // dismissal that's fine: we only need to know the click happened.

    private func installClickOutsideMonitors() {
        if globalClickOutsideMonitor == nil {
            globalClickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.handleDismiss()
            }
        }
        if localClickOutsideMonitor == nil {
            localClickOutsideMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self, let panel = self.panel else { return event }
                if event.window !== panel {
                    self.handleDismiss()
                } else {
                    self.scheduleAutoDismiss()
                }
                return event
            }
        }
    }

    private func removeClickOutsideMonitors() {
        if let m = globalClickOutsideMonitor {
            NSEvent.removeMonitor(m)
            globalClickOutsideMonitor = nil
        }
        if let m = localClickOutsideMonitor {
            NSEvent.removeMonitor(m)
            localClickOutsideMonitor = nil
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
            guard let self, self.phase == .expanded, let panel = self.panel else { return event }
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
            PillGhostButton(title: "Dismiss", action: onDismiss)
            PillFilledButton(
                title: copyFlashActive ? "Copied ✓" : "Copy",
                action: onCopy,
                isFlashing: copyFlashActive
            )
        }
        .frame(height: DesignTokens.Pill.expandedButtonHeight)
    }
}

// MARK: - Expanded-pill button styles (filled primary + ghost secondary)

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

private struct PillGhostButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.Pill.expandedGhostFont)
                .foregroundStyle(DesignTokens.Pill.expandedGhostForeground)
                .padding(.horizontal, DesignTokens.Pill.expandedButtonHorizontalPadding)
                .frame(height: DesignTokens.Pill.expandedButtonHeight)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Pill.expandedButtonCornerRadius, style: .continuous)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var background: Color {
        isHovering
            ? DesignTokens.Pill.expandedGhostBackgroundHover
            : DesignTokens.Pill.expandedGhostBackgroundRest
    }
}
