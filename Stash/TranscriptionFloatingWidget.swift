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
        case .processing, .completion:
            EmptyView()
        }
    }

    /// Default MM:SS; only expand to H:MM:SS once a recording crosses one hour
    /// (rare for voice notes — no point padding a leading zero for the common case).
    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
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
    override var canBecomeKey: Bool { false }
}

// MARK: - Controller

@MainActor
final class TranscriptionFloatingWidgetController: NSObject {

    private weak var transcription: TranscriptionService?
    private var panel: PillPanel?
    private var hosting: NSHostingView<TranscriptionPillView>?
    private var cancellables = Set<AnyCancellable>()
    private var panelOpenForWidget = false

    private enum Phase { case none, recording, processing, completion }
    private var phase: Phase = .none
    private var completionWorkItem: DispatchWorkItem?
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

    func setPanelOpenForWidget(_ open: Bool) {
        panelOpenForWidget = open
        sync()
    }

    private func sync() {
        guard let ts = transcription else { hidePanel(); return }

        if panelOpenForWidget {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            hidePanel()
            phase = .none
            return
        }

        if let msg = ts.completionMessage {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            phase = .completion
            showPanelIfNeeded()
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

        if ts.isRecording {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            phase = .recording
            showPanelIfNeeded()
            updateHosted(mode: .recording(durationSeconds: ts.duration))
            return
        }

        if ts.isProcessing {
            completionWorkItem?.cancel()
            completionWorkItem = nil
            phase = .processing
            showPanelIfNeeded()
            updateHosted(mode: .processing)
            return
        }

        if phase != .completion {
            hidePanel()
            phase = .none
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

    private func showPanelIfNeeded() {
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
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
}
