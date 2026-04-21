# Transcription Pill Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the floating transcription widget's pill body with a pure-SwiftUI view that matches the Figma redesign (node 280-981) across three states — Recording, Processing, Copied — with identical fixed width/height, a larger invisible tap target for stop, and smooth state transitions.

**Architecture:** Keep the existing `NSPanel` + `TranscriptionFloatingWidgetController` (owns lifecycle, positioning, Combine subscription to `TranscriptionService`). Replace the AppKit `PillContentView` implementation with a SwiftUI view `TranscriptionPillView` hosted via `NSHostingView`. Fixed 180×32 pill so all three states share identical dimensions; content is left-aligned with the recording state's red dot pushed to the right edge. Window drag-to-move handled by `panel.isMovableByWindowBackground = true` (replaces the manual mouseDown/Drag/Up implementation). Auto-dismiss preserved: service sets `completionMessage`, clears at 1.5 s; controller hides panel at 1.6 s.

**Tech Stack:** Swift 6+ (per CLAUDE.md), SwiftUI (macOS 13+), AppKit (`NSPanel`, `NSHostingView`), `Combine` (observe `TranscriptionService.objectWillChange`).

---

## Key decisions (read before executing)

1. **Pure SwiftUI pill body** — CLAUDE.md: "Prefer SwiftUI over UIKit/AppKit bridging unless there is no SwiftUI native option." The pill body is pure SwiftUI hosted in `NSHostingView`. Panel/controller stay AppKit (no native SwiftUI equivalent for a borderless floating non-activating panel).

2. **Fixed size 180×32 for all three states** — user explicitly requested same width/height across states. 180pt comfortably holds the recording state (24 disc + 12 gap + ~72pt for `HH:MM:SS` monospaced 14pt + spacer + 10 dot + 12 trailing + 4 leading).

3. **Drag-to-move via `isMovableByWindowBackground`** — replaces the manual `mouseDown`/`mouseDragged`/`mouseUp` override that the old `PillContentView` implemented. `NSHostingView` doesn't forward mouse events to its superview by default, so this is the clean path. Verified: non-activating panels support this flag.

4. **Stop tap target** — visible red dot is 10×10 (Figma-exact). Tap target expanded to 32×32 via `.contentShape(Rectangle())` wrapped in a `Button` at the trailing edge.

5. **Completion mapping** — `TranscriptionService.completionMessage` has three values: `"Copied"`, `"Note saved"`, `"Failed"`. Map by string:
   - `"Copied"` → `doc.on.doc` (Figma spec)
   - `"Note saved"` → `note.text`
   - `"Failed"` → `xmark`
   - Any other → `checkmark` (defensive fallback — should not hit in practice)

6. **Text tint** — Figma uses `#A3A3A3`, already in `DesignTokens.Typography.itemColor`. Reuse it.

7. **Icon glyph tint** — white 72% (mid-range of the 60–80% spec band). Not a design token because this disc style is currently only used by the pill; avoid premature abstraction.

8. **Pulse animation** — 10×10 red dot pulses opacity `0.4 ↔ 1.0`, 0.9 s ease-in-out, auto-reverse, repeat forever. Scale held at 1.0 so the dot doesn't appear to grow against the fixed spacer.

9. **Spinner** — `ProgressView().progressViewStyle(.circular).controlSize(.small).tint(Color.white.opacity(0.72))`. Rendered inside the same 24×24 disc so the Processing icon slot visually matches Recording and Copied.

10. **@MainActor** — `TranscriptionFloatingWidgetController` is already `@MainActor`. `TranscriptionPillView` is a SwiftUI `View` (main-actor-isolated by default). No new `@MainActor` annotations required.

11. **Animation-key separation from timer tick** — `PillMode.recording(durationSeconds:)` changes every second. Animating `value: mode` would cross-fade the whole HStack on every tick. Introduce a separate `PillPhase` enum (`.recording | .processing | .completion(String)`) that ignores the duration, and bind `.animation(…, value: phase)` to that. Timer digits then tick crisply without a cross-fade.

12. **Stop via `.onTapGesture`, not `Button`** — `panel.isMovableByWindowBackground = true` lets the window drag from anywhere. A `Button` hit-tests click-and-drag as "button press + drag," then fires the action on mouse-up — so a user who starts a drag near the red dot would accidentally stop recording. `.onTapGesture` only fires on a true tap and yields to drag gestures, preserving drag-to-move behavior over the stop region.

13. **Timer font** — use `.font(.system(size: 14, weight: .regular, design: .monospaced))`. `.monospacedDigit()` on SF Pro keeps digits equal-width but not colons, which jitter. A fully monospaced design also reads as "timer" and matches the Figma.

14. **Hosting** — set `panel.contentView = hostingView` directly. No NSView wrapper; the pill is fixed-size and the panel is fixed-size, so Auto Layout gains nothing.

15. **Position once** — `buildPanel` calls `positionAtMenuBar` once. After that, a user drag is preserved (the controller never re-snaps). The old `positionIfNeeded` guard (`frame.origin == .zero`) is unreachable under the new flow; drop the method.

## File structure

- **Modify: `Stash/DesignTokens.swift`** — add a small `Pill` namespace with fixed width, height, and internal padding constants used only by the pill. Reuses `Icon.backgroundRest`, `Icon.tintRecording`, `Typography.itemColor`.
- **Modify: `Stash/TranscriptionFloatingWidget.swift`** — full rewrite:
  - Remove `PillWaveformIcon`, `PillWaveformCircleView`, `PillContentView` (AppKit view tree).
  - Add SwiftUI `TranscriptionPillView` with `PillMode` enum and `onStop` closure.
  - Replace controller's `contentView: PillContentView?` with `hosting: NSHostingView<TranscriptionPillView>?` and a `@Published`-free state cache so we can refresh the hosted view's `rootView`.
  - Remove `resizePillToFitContent` and `naturalWidth` — pill is fixed 180×32.
  - Keep `buildPanel`, `positionAtMenuBar`, `showPanelIfNeeded`, `hidePanel`, `sync`, `setPanelOpenForWidget`, `attach`. Drop `positionIfNeeded` (unreachable under the new flow; see decision 15).
  - Set `panel.isMovableByWindowBackground = true` and rely on it for drag-to-move.

**Do NOT touch:**
- `Stash/TranscriptionService.swift` — read `isRecording`, `isProcessing`, `duration`, `completionMessage` only.
- `Stash/GlobalHotKey.swift`
- `Stash/PanelController.swift` — only references the controller via `transcriptionFloatingWidget.attach(...)` and `setPanelOpenForWidget(...)`; API is unchanged.

---

### Task 1: Add pill layout tokens to `DesignTokens.swift`

**Files:**
- Modify: `Stash/DesignTokens.swift`

- [ ] **Step 1: Add `Pill` namespace**

Edit `Stash/DesignTokens.swift`. Insert a new `Pill` enum inside `enum DesignTokens { ... }`, directly after `enum Row { ... }`:

```swift
    /// Floating transcription pill (redesign 2026-04-21). Fixed dimensions so Recording,
    /// Processing and Copied states share identical width/height per Figma node 280-981.
    enum Pill {
        static let width: CGFloat = 180
        static let height: CGFloat = 32
        static let cornerRadius: CGFloat = 16   // fully rounded capsule
        static let iconDiscSize: CGFloat = 24
        static let iconGlyphSize: CGFloat = 14
        static let leadingPadding: CGFloat = 4
        static let trailingPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 4
        static let contentSpacing: CGFloat = 12
        static let recordingDotSize: CGFloat = 10
        static let stopTapTargetSize: CGFloat = 32
        static let iconGlyphTint: Color = Color.white.opacity(0.72)
    }
```

- [ ] **Step 2: Verify the file still parses**

Run:

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -30
```

Expected: Build succeeds (or fails only in `TranscriptionFloatingWidget.swift` with "cannot find ... in scope" — we're about to fix that in Task 2). Do NOT commit yet — we commit once the pill compiles.

---

### Task 2: Replace `TranscriptionFloatingWidget.swift` with the SwiftUI pill

**Files:**
- Modify: `Stash/TranscriptionFloatingWidget.swift` (full rewrite of body; controller API preserved)

- [ ] **Step 1: Overwrite the file with the new implementation**

Replace the entire contents of `Stash/TranscriptionFloatingWidget.swift` with:

```swift
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

    @ViewBuilder
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
            Image(systemName: "waveform")
                .font(.system(size: DesignTokens.Pill.iconGlyphSize, weight: .regular))
                .foregroundStyle(DesignTokens.Pill.iconGlyphTint)
                .transition(.opacity)
        case .processing:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(DesignTokens.Pill.iconGlyphTint)
                .transition(.opacity)
        case .completion(let message):
            Image(systemName: completionSymbol(for: message))
                .font(.system(size: DesignTokens.Pill.iconGlyphSize, weight: .regular))
                .foregroundStyle(DesignTokens.Pill.iconGlyphTint)
                .transition(.opacity)
        }
    }

    private func completionSymbol(for message: String) -> String {
        switch message {
        case "Copied":     return "doc.on.doc"
        case "Note saved": return "note.text"
        case "Failed":     return "xmark"
        default:           return "checkmark"
        }
    }

    // MARK: Label (SF Pro 14 regular #A3A3A3)

    @ViewBuilder
    private var label: some View {
        switch mode {
        case .recording(let seconds):
            Text(formatDuration(seconds))
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(DesignTokens.Typography.itemColor)
        case .processing:
            Text("Processing")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(DesignTokens.Typography.itemColor)
        case .completion(let message):
            Text(message)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(DesignTokens.Typography.itemColor)
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
            // Keep the pill width fixed — trailing slot is empty but reserves no extra width;
            // the leading Spacer consumes the remainder.
            EmptyView()
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Stop button (10×10 red dot, 32×32 tap target, pulsing)
//
// Uses `.onTapGesture` (not `Button`) so the parent panel's window-drag
// (`isMovableByWindowBackground = true`) is still reachable from the trailing
// region — a Button would swallow click-and-drag and fire its action on
// mouse-up, accidentally stopping recording when the user tried to drag.

private struct StopRecordingButton: View {
    let onStop: () -> Void
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(DesignTokens.Icon.tintRecording)
            .frame(
                width: DesignTokens.Pill.recordingDotSize,
                height: DesignTokens.Pill.recordingDotSize
            )
            .opacity(pulse ? 1.0 : 0.4)
            .frame(
                width: DesignTokens.Pill.stopTapTargetSize,
                height: DesignTokens.Pill.stopTapTargetSize
            )
            .contentShape(Rectangle())
            .onTapGesture { onStop() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stop recording")
            .accessibilityAddTraits(.isButton)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
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
}
```

- [ ] **Step 2: Build and confirm compile**

Run:

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -40
```

Expected: `** BUILD SUCCEEDED **`. If it fails, read the error and fix in-place — do not commit until green.

- [ ] **Step 3: Run the app and visually verify all three states**

Run:

```bash
xcodebuild -scheme Stash -configuration Debug -derivedDataPath build -quiet build 2>&1 | tail -5
open build/Build/Products/Debug/Stash.app
```

Then trigger the transcription hotkey (the user's global shortcut) and verify in order:
- **Recording (hold for >10 s)**: pill appears below the menu bar, black capsule, 24×24 disc with waveform on the left, monospaced timer counting `00:00:00 → 00:00:01 → …`. Pulsing red dot on the right. Pill width is stable — does not grow as digits change. Timer digits tick crisply with no cross-fade every second (if they dissolve, the `PillPhaseKey` indirection was wired incorrectly).
- **Processing**: on stop, icon disc shows a small circular spinner, "Processing" label, pill width unchanged from recording.
- **Copied**: pill flips to `doc.on.doc` glyph + "Copied" label, then fades away after ~1 s.

Verify the stop tap target: tapping anywhere in the ~32×32 trailing region (not just on the 10×10 dot) stops recording.

Verify drag-to-move from the body: click-and-drag anywhere on the left two-thirds of the pill; it follows the cursor.

Verify drag-to-move from the stop region: while recording, click-and-drag starting on the red dot; the window should move and recording should **not** stop (this confirms `.onTapGesture` yields to drag, unlike `Button`).

- [ ] **Step 4: Run swiftformat and swiftlint**

Run (from repo root):

```bash
swiftformat Stash/TranscriptionFloatingWidget.swift Stash/DesignTokens.swift
swiftlint lint --path Stash/TranscriptionFloatingWidget.swift Stash/DesignTokens.swift 2>&1 | tail -20
```

Expected: swiftformat either makes zero changes or only whitespace normalisation. swiftlint reports no violations on the modified files. If lint flags a rule, fix it before committing (do not add `// swiftlint:disable` unless the rule is genuinely wrong for this context).

- [ ] **Step 5: Commit**

First check that only the intended files are staged — the working tree already has unrelated dirty paths (`LAUNCH_BACKLOG.md`, possibly others). Do **not** use `git add -A`.

Run:

```bash
git status --short
git add Stash/TranscriptionFloatingWidget.swift Stash/DesignTokens.swift
git diff --cached --stat
```

Expected: `git diff --cached --stat` shows exactly two files staged. Then:

```bash
git commit -m "feat(transcription): redesign floating pill to match Figma 280-981

Replace AppKit PillContentView with SwiftUI TranscriptionPillView.
Fixed 180x32 capsule so Recording, Processing, Copied share identical
dimensions; icon + text left-aligned, pulsing red dot on the right for
Recording with 32x32 invisible tap target. Drag-to-move via panel
isMovableByWindowBackground. Controller API unchanged; consumes
TranscriptionService published state as before."
```

---

### Task 3: `/simplify` pass and pre-PR sanity check

**Files:**
- Review: `Stash/TranscriptionFloatingWidget.swift`, `Stash/DesignTokens.swift`

- [ ] **Step 1: Invoke the `/simplify` skill**

Invoke the `simplify` skill. Let it review the two changed files. Apply any recommended tightening (dead code, redundant modifiers, unused `import`s). Common candidates that may get flagged:

- `Combine` import is still needed (used for `cancellables`).
- `completionSymbol(for:)` with a `default:` branch — keep it; it's a defensive fallback, not dead code.
- `Spacer(minLength: 0)` — required so the trailing slot hugs the trailing edge even when the label is short.

- [ ] **Step 2: Re-run build after simplify changes**

Run:

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-verify visuals if any rendering code changed**

If the simplify pass touched `TranscriptionPillView`'s body, re-run the app and re-confirm the three states. If it only touched the controller, skip.

- [ ] **Step 4: Commit simplify pass (only if changes were made)**

Run:

```bash
git status --short
```

If there are tracked-file changes:

```bash
git add Stash/TranscriptionFloatingWidget.swift Stash/DesignTokens.swift
git commit -m "refactor(transcription): simplify pass on pill view"
```

If `git status` is clean, skip — no empty commit.

---

## Self-review

**Spec coverage:**

| Spec item | Task |
|-----------|------|
| Pill height 32, capsule radius, black background | Task 1 (tokens) + Task 2 (view) |
| Icon disc 24×24, 14pt glyph, white 6–8% bg, white 60–80% tint | Task 1 (tokens) + Task 2 (view) |
| Text SF Pro 14 regular `#A3A3A3`, 12pt gap to icon, 12pt right padding | Task 2 |
| Recording: waveform + HH:mm:ss monospaced, pulsing 10×10 `#DC2626` dot | Task 2 (view + `StopRecordingButton`) |
| Processing: spinner + "Processing" | Task 2 |
| Copied: `doc.on.doc` + "Copied", auto-dismiss | Task 2 (view) + preserved controller timing (1.6s) |
| State transitions smooth | Task 2 (`.animation(.easeInOut(duration: 0.18), value: PillPhaseKey(mode))` so timer ticks don't cross-fade the HStack; per-glyph `.transition(.opacity)`) |
| All three pills same width/height | Task 1 (fixed 180×32) + Task 2 (`.frame`) |
| Bigger stop tap target, visual dot small | Task 2 (`StopRecordingButton`: 10×10 dot in 32×32 `.contentShape(Rectangle())`) |
| Preserve panel setup / positioning / dismissal | Task 2 (controller's `buildPanel`, `positionAtMenuBar`, `sync` preserved) |
| No new SPM deps | Confirmed — uses only AppKit, SwiftUI, Combine |
| No force unwraps in new code | Confirmed |
| No sprinkled `@MainActor` | Controller was already `@MainActor`; view is main-actor by default — no new annotations |
| Build green + swiftformat + swiftlint clean | Task 2 steps 2, 4 |
| `/simplify` pass | Task 3 |
| Conventional Commits on feature branch | Task 2 step 5, Task 3 step 4 (on existing `feature/file-quick-look` per user) |

**Placeholder scan:** No TBDs, no "add error handling," no "similar to Task N." All code blocks contain the actual code. Every referenced identifier (`DesignTokens.Pill.*`, `PillMode`, `TranscriptionPillView`, `StopRecordingButton`, `completionSymbol(for:)`) is defined in the plan.

**Type consistency:** `PillMode` defined once in Task 2 and referenced by `TranscriptionPillView` and `TranscriptionFloatingWidgetController.updateHosted(mode:)`. `DesignTokens.Pill.*` names match between Task 1 definitions and Task 2 usage. `onStop` signature `() -> Void` consistent across `TranscriptionPillView` and `StopRecordingButton`.

**Risk items (execution should watch for):**
- `isMovableByWindowBackground` on `.nonactivatingPanel` — supported; the panel was draggable via manual mouseDown before, so parity is expected.
- `NSHostingView.rootView` reassignment on every `sync()` — inexpensive, and the CLAUDE.md landmine note ("`NSHostingView.rootView` must be updated in `updateNSView` or SwiftUI bindings go stale") is about `NSViewRepresentable` wrappers, not standalone `NSHostingView` usage. Still, `updateHosted` reassigns `rootView` on every state change — this is the supported pattern.
- **Timer re-render cadence:** `TranscriptionService.duration` increments once per second; each increment triggers `objectWillChange` → `sync()` → `updateHosted(mode: .recording(...))` → new `rootView`. This is fine for 180×32 of content but worth verifying during Step 3 that the timer ticks crisply (no cross-fade — the `PillPhaseKey` indirection ensures this).
- **Drag over stop region:** with `.onTapGesture` instead of `Button`, dragging from the red-dot area should move the window and NOT fire `onStop`. Verify this explicitly in Step 3.
- **Unrelated dirty working tree:** current branch has uncommitted changes in `LAUNCH_BACKLOG.md` (and possibly more). Task 2 Step 5 uses targeted `git add` and includes a `--stat` check; do not use `git add -A` or `git add .`.
