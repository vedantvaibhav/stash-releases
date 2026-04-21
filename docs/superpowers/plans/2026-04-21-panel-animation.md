# Panel Open/Close Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the main `KeyablePanel`'s existing snap-zone-edge slide animation with a subtle 8pt fade-and-slide "drop in / float up" motion, tokenize the timing in `DesignTokens.swift`, and add an in-flight guard so rapid toggles don't corrupt panel state.

**Architecture:** Two `NSAnimationContext.runAnimationGroup` calls — one in `showPanel`, one in `hidePanel` — animating `alphaValue` and `setFrame(_:display:)` together. Ease-out for open (0.18s), ease-in for close (0.14s). A `@MainActor` monotonically-increasing `animationToken` discriminates which completion handler is still "live", letting rapid toggles safely interrupt without leaking `orderOut` into an in-flight open (or vice versa).

**Tech Stack:** AppKit, `NSAnimationContext`, `CAMediaTimingFunction`. Deployment target is macOS 13 — `NSAnimationContext.animate(_:_:)` spring API (macOS 14+) is not used.

---

## Scope & constraints

- **In scope:** `Stash/DesignTokens.swift`, `Stash/PanelController.swift`. Both `showPanel()` and `hidePanel()` are modified. Idle auto-hide timer routes through `hidePanel()` so it gets the new close animation for free.
- **Out of scope this PR:** Tab-switch animations, card expand/collapse animation, `TranscriptionFloatingWidget` pill animation, Settings window animation, `snapToNearestZone` drag-snap animation (already independent of open/close).
- **CardsModeAppKit.swift:** Confirmed no separate window lifecycle — cards-mode is an alternate content view inside the same `contentPanel`. `alphaValue` animations inside it are hover effects, not window show/hide. No change needed there.
- **CLAUDE.md landmine lifted:** "Panel open/close animation timing" is under "Things NOT to touch unless explicitly asked" — the user explicitly approved this change. Post-merge, that line must be removed from `CLAUDE.md` (Task 7).

## Design intent (recap from spec)

- **Open:** alpha 0 → 1 with vertical slide from `y + 8 → y` (8 pt above final position, settles down). Duration 0.18s, `CAMediaTimingFunction(name: .easeOut)`.
- **Close:** alpha 1 → 0 with vertical slide from `y → y + 6` (floats up 6 pt as it fades). Duration 0.14s, `CAMediaTimingFunction(name: .easeIn)`.
- **AppKit y-axis reminder:** in window coordinates, y **increases upward**. "Slide down 8 pt" = start y is 8 higher → `hiddenFrame.y = targetFrame.y + 8`, animates down to `targetFrame.y`. "Slide up 6 pt" on close = animates from `targetFrame.y` to `targetFrame.y + 6`.
- **No bounce.** Standard ease-out / ease-in only.
- **Rapid toggle:** if user hits hotkey during an animation, the new animation starts immediately; stale completion handlers must not run.

## File structure

| File | Change |
|---|---|
| `Stash/DesignTokens.swift` | **Modify** — add `PanelAnimation` enum with the four tokens (`openDuration`, `closeDuration`, `openSlideOffset`, `closeSlideOffset`). |
| `Stash/PanelController.swift` | **Modify** — (a) add `private var animationToken: Int = 0` on `PanelController`; (b) rewrite `showPanel()` animation block; (c) rewrite `hidePanel()` animation block. All other logic (`orderFrontRegardless`, `transcriptionFloatingWidget` calls, click-outside monitor, `fileQuickLook` cleanup, idle timer, `QuickLook` key monitor install, etc.) stays byte-for-byte identical. |
| `CLAUDE.md` | **Modify (post-merge, Task 7)** — remove the "Panel open/close animation timing" line from "Things NOT to touch unless explicitly asked". |

## A note on testing

There is no practical unit-test harness for `NSWindow` / `NSAnimationContext` animation timing or perceptual feel in this codebase — Swift Testing / XCTest don't reach into AppKit animation state usefully, and Stash ships no existing test target. Verification for each task is therefore:

1. Clean build: `xcodebuild -scheme Stash -configuration Debug build` returns `** BUILD SUCCEEDED **`.
2. Run the app and use the manual QA checklist at the end.

This is the honest fit for the domain. Do not fabricate unit tests for timing tokens — it adds noise without catching bugs.

---

## Task 1: Add `PanelAnimation` tokens to `DesignTokens.swift`

**Files:**
- Modify: `Stash/DesignTokens.swift`

- [ ] **Step 1: Open `Stash/DesignTokens.swift` and add a new nested enum after the `Typography` enum (before the closing `}` of `DesignTokens`).**

Insert this block immediately after the `Typography` enum's closing `}` (line 34) and before the outer `}` of `DesignTokens` (line 35):

```swift
    enum PanelAnimation {
        /// Open: fade 0 → 1 with an 8 pt downward settle. Ease-out.
        static let openDuration: CFTimeInterval = 0.18
        /// Close: fade 1 → 0 with a 6 pt upward lift. Ease-in. Slightly faster than open.
        static let closeDuration: CFTimeInterval = 0.14
        /// Panel starts 8 pt above its final y on open.
        static let openSlideOffset: CGFloat = 8
        /// Panel ends 6 pt above its start y on close.
        static let closeSlideOffset: CGFloat = 6
    }
```

- [ ] **Step 2: Save, then verify the file compiles in isolation.**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`

Expected last line: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit.**

```bash
git add Stash/DesignTokens.swift
git commit -m "$(cat <<'EOF'
feat(tokens): add PanelAnimation timing + offset tokens

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the in-flight animation token to `PanelController`

**Files:**
- Modify: `Stash/PanelController.swift` (around line 200, in the property block of `PanelController`)

**Why:** Rapid toggles during an animation must not leak stale completion-handler side-effects. The open completion does chrome reapply; the hide completion does `orderOut`, state wipe, and monitor teardown. If a hide starts mid-open, the open's completion (running after the hide) would re-enable chrome on a panel that just got ordered out. A monotonically-increasing token, captured by each completion block, lets stale completions bail out early.

- [ ] **Step 1: Locate the `PanelController` class property block.**

Run: `grep -n "final class PanelController" Stash/PanelController.swift`

Expected: `191:final class PanelController: NSObject {`

- [ ] **Step 2: Read the first ~20 lines of the class to find a clean insertion spot for the new stored property.**

Use the Read tool on `Stash/PanelController.swift` starting at line 191, limit 40. Find a private stored-property section (near other `private var` declarations — typically `idleTimer`, `mouseInsidePanel`, etc.).

- [ ] **Step 3: Add the token property in that private-var block.**

Insert this line alongside the other private vars (exact location depends on what Step 2 revealed — pick the block that already holds animation/idle-timer state). Note: `PanelController` is already `@MainActor`-annotated at the class level (line 190), so no property-level actor annotation is needed — CLAUDE.md bans sprinkled `@MainActor`.

```swift
    /// Incremented before every show/hide animation; completion handlers capture the
    /// value they started with and bail if another animation has superseded them.
    /// Guards against rapid-toggle leaks (e.g. hide completion calling orderOut
    /// after a new show has already started).
    private var animationToken: Int = 0
```

- [ ] **Step 4: Verify the file still compiles.**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`

Expected last line: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Do NOT commit yet.** The token is unused until Tasks 3 and 4 wire it up — committing a dead property would land broken-looking history. Tasks 3 and 4 produce a single commit.

---

## Task 3: Rewrite `showPanel()` animation to use the 8 pt fade + drop

**Files:**
- Modify: `Stash/PanelController.swift:739-785` (the `showPanel` function)

**What changes:**

- Replace the `contentPanelHiddenFrame` start position with `targetFrame.offsetBy(dx: 0, dy: PanelAnimation.openSlideOffset)`.
- Replace `duration = 0.3` with `PanelAnimation.openDuration` (0.18).
- Replace `timingFunction = CAMediaTimingFunction(controlPoints: 0.0, 0.0, 0.2, 1.0)` with `CAMediaTimingFunction(name: .easeOut)`.
- Remove the `panel.contentView?.animator().frame = contentRect` line — the new animation only translates the window by 8 pt, so the content view size doesn't change and doesn't need animating.
- Remove the local `contentRect` variable once it's no longer referenced.
- Capture a local `token` before the animation starts; inside the completion handler, compare `self.animationToken == token` before running the completion side-effects.

- [ ] **Step 1: Read the current `showPanel` function to confirm exact line numbers before editing.**

Use the Read tool on `Stash/PanelController.swift` lines 737-786.

Current shape (for reference):

```swift
    // MARK: - Show / hide

    func showPanel() {
        guard let panel = contentPanel else { return }
        NSApp.activate(ignoringOtherApps: true)
        cancelDeferredClose()

        transcriptionFloatingWidget.setPanelOpenForWidget(true)
        applyPanelChromeForLayoutStyle()

        isDragInProgress = false

        let targetFrame = contentPanelVisibleFrame
        mouseInsidePanel = targetFrame.contains(NSEvent.mouseLocation)

        panel.level = .floating
        panel.orderFrontRegardless()

        // Slide in from the screen edge nearest to the snap zone.
        let startFrame = contentPanelHiddenFrame
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        let contentRect = NSRect(origin: .zero, size: targetFrame.size)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.0, 0.0, 0.2, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.contentView?.animator().frame = contentRect
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.applyPanelChromeForLayoutStyle()
            }
        })

        // Don't start the click-outside monitor immediately; allow the opening click
        // to complete without accidentally closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard self.contentPanel?.isVisible ?? false else { return }
            self.startClickOutsideMonitor()
        }
        if let panel = contentPanel {
            fileQuickLook.installKeyMonitor(on: panel)
        }
        resetPanelIdleTimer()
    }
```

- [ ] **Step 2: Apply the edit.**

Replace the block from `// Slide in from the screen edge nearest to the snap zone.` through the closing `})` of the `NSAnimationContext.runAnimationGroup` call with the new implementation. Use the Edit tool with:

**`old_string`:**
```swift
        // Slide in from the screen edge nearest to the snap zone.
        let startFrame = contentPanelHiddenFrame
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        let contentRect = NSRect(origin: .zero, size: targetFrame.size)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.0, 0.0, 0.2, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.contentView?.animator().frame = contentRect
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.applyPanelChromeForLayoutStyle()
            }
        })
```

**`new_string`:**
```swift
        // Start 8 pt above final position, fade + settle down into place.
        let startFrame = targetFrame.offsetBy(dx: 0, dy: DesignTokens.PanelAnimation.openSlideOffset)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        animationToken &+= 1
        let token = animationToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.PanelAnimation.openDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self, self.animationToken == token else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyPanelChromeForLayoutStyle()
            }
        })
```

- [ ] **Step 3: Also update the `DispatchQueue.main.asyncAfter` delay that gates the click-outside monitor.**

The old delay was `0.3` (matched the old animation duration). It must now match the new open duration. Use the Edit tool:

**`old_string`:**
```swift
        // Don't start the click-outside monitor immediately; allow the opening click
        // to complete without accidentally closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
```

**`new_string`:**
```swift
        // Don't start the click-outside monitor immediately; allow the opening click
        // to complete without accidentally closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignTokens.PanelAnimation.openDuration) { [weak self] in
```

- [ ] **Step 4: Build.**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`

Expected last line: `** BUILD SUCCEEDED **`

If you get "Cannot find 'DesignTokens'" — confirm `DesignTokens.swift` is in the build target. It is, but double-check Task 1 landed.

- [ ] **Step 5: Do NOT commit yet.** Task 4 finishes the paired hide animation; commit after both are green.

---

## Task 4: Rewrite `hidePanel()` animation to use the 6 pt fade + lift

**Files:**
- Modify: `Stash/PanelController.swift:787-812` (the `hidePanel` function)

**What changes:**

- Replace `setFrame(contentPanelHiddenFrame, display: true)` with `setFrame(currentFrame.offsetBy(dx: 0, dy: PanelAnimation.closeSlideOffset), display: true)` where `currentFrame = panel.frame`.
- Replace `duration = 0.25` with `PanelAnimation.closeDuration` (0.14).
- Replace `timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)` with `CAMediaTimingFunction(name: .easeIn)`.
- In the completion handler, bail if `animationToken` has moved on (i.e., a show started mid-hide). This is the critical guard that prevents `orderOut` from firing on a panel the user just re-opened.
- After `orderOut`, **also restore the panel's frame to the canonical visible target** (`contentPanelVisibleFrame`) so the next `showPanel` doesn't compute its start frame from a translated position. Using the canonical target instead of a captured `preHideFrame` makes intent explicit and is safe even if hides ever stack.

- [ ] **Step 1: Apply the edit.**

Use the Edit tool on `Stash/PanelController.swift`:

**`old_string`:**
```swift
    func hidePanel() {
        guard let panel = contentPanel, panel.isVisible else { return }

        // Quick Look and the key monitor must go BEFORE the animation — otherwise
        // QL lingers on-screen for ~250ms after the slide-out starts, and a
        // spacebar press during that window can retrigger the monitor.
        fileQuickLook.closeQuickLookIfVisible()
        fileQuickLook.removeKeyMonitor()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().setFrame(contentPanelHiddenFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.transcriptionFloatingWidget.setPanelOpenForWidget(false)
            self.stopClickOutsideMonitor()
            self.idleTimer?.invalidate()
            self.idleTimer = nil
            // State wipe comes last: UI is already gone, nothing else to see.
            self.fileQuickLook.clearSelection()
        })
    }
```

**`new_string`:**
```swift
    func hidePanel() {
        guard let panel = contentPanel, panel.isVisible else { return }

        // Quick Look and the key monitor must go BEFORE the animation — otherwise
        // QL lingers on-screen for ~250ms after the slide-out starts, and a
        // spacebar press during that window can retrigger the monitor.
        fileQuickLook.closeQuickLookIfVisible()
        fileQuickLook.removeKeyMonitor()

        let endFrame = panel.frame.offsetBy(dx: 0, dy: DesignTokens.PanelAnimation.closeSlideOffset)
        let restoreFrame = contentPanelVisibleFrame

        animationToken &+= 1
        let token = animationToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DesignTokens.PanelAnimation.closeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            guard let self, let panel, self.animationToken == token else { return }
            panel.orderOut(nil)
            // Restore frame + alpha to the canonical visible target so the next
            // showPanel computes its start from the real target position, not the
            // translated close position.
            panel.setFrame(restoreFrame, display: false)
            panel.alphaValue = 1
            self.transcriptionFloatingWidget.setPanelOpenForWidget(false)
            self.stopClickOutsideMonitor()
            self.idleTimer?.invalidate()
            self.idleTimer = nil
            // State wipe comes last: UI is already gone, nothing else to see.
            self.fileQuickLook.clearSelection()
        })
    }
```

- [ ] **Step 2: Build.**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`

Expected last line: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Launch the app and run the manual QA checklist (see "Manual QA" section at the bottom). Do not proceed to commit until every box is ticked.**

Run: `open -a Stash` (or run from Xcode).

- [ ] **Step 4: Commit Tasks 2, 3, and 4 together.**

```bash
git add Stash/PanelController.swift
git commit -m "$(cat <<'EOF'
feat(panel): add fade + slide open/close animation

Replace the snap-zone-edge slide with a subtle 8 pt fade-and-drop on
open (0.18s, ease-out) and a 6 pt fade-and-lift on close (0.14s,
ease-in). Tokenized in DesignTokens.PanelAnimation so future tweaks
stay visual-only.

An animationToken guards completion handlers so rapid toggles can
interrupt an in-flight animation without leaking orderOut / chrome
reapply onto the wrong state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Verify cards-mode is unaffected

**Files:**
- Read-only check: `Stash/CardsModeAppKit.swift`

**Why:** Confirm cards-mode doesn't have its own window show/hide that needs mirroring. This is an investigation task — no code changes expected, but it must be run.

- [ ] **Step 1: Grep for any window-lifecycle calls in cards-mode.**

Run: `grep -nE "orderFront|orderOut|makeKeyAndOrderFront|setFrame|NSPanel|NSWindow" Stash/CardsModeAppKit.swift | grep -v "effectView\|tintOverlay"`

Expected: **zero results**. The `effectView` and `tintOverlay` exclusions are safe: both are internal card hover-effect subviews, not windows — confirmed by reading `CardsModeAppKit.swift` where they're declared as `NSVisualEffectView` / `NSView` child views of the card. Anything outside those two names would indicate a new window path that needs mirroring. If this grep returns any result, stop and ask for guidance before continuing.

- [ ] **Step 2: Switch to cards layout in Settings and manually verify the new open/close animation still looks right.**

Open Settings (Cmd+,) → Layout Style → Cards. Close Settings. Toggle the main hotkey a few times and confirm cards-mode inherits the same fade+slide because it shares `contentPanel`.

---

## Task 6: Manual QA checklist (embed in PR body)

Copy this into the PR description. Every box must be ticked before merge.

- [ ] **Open via main hotkey** — panel fades in from 8 pt above final position; settles down. No stutter.
- [ ] **Open via menu-bar left-click** — same fade+drop behavior.
- [ ] **Close via main hotkey** — panel fades out while lifting 6 pt. Faster than open.
- [ ] **Close via clicking outside panel** — same close animation (routes through `hidePanel`).
- [ ] **Rapid double-toggle** — press hotkey twice in < 100 ms. Panel ends in the correct final state (whichever was the last press). No stuck alpha, no orphaned `orderOut`, no chrome re-applied to a hidden panel.
- [ ] **Auto-hide idle** — leave the panel open and idle. After `autoHideSeconds`, it closes with the new animation. Clean fade+lift.
- [ ] **Drag to snap zone** — drag the panel from its current snap zone to another. The existing snap animation fires, **not** the open/close animation. Open and close after the snap continue to use the new animation from the new zone.
- [ ] **Sign-out then re-open** — sign out via Settings, close panel, reopen. The auth gate renders inside the panel with the same fade+drop. No double-fade, no pre-gate flicker.
- [ ] **Full-screen app in front** — open a fullscreen app (Cmd+Ctrl+F in Safari or similar). Toggle the panel. Panel still fades in over the fullscreen space (`.canJoinAllSpaces` is preserved).
- [ ] **Quick-record hotkey (⌘⇧R) while panel closed** — only the floating pill appears; the main panel stays hidden. No stray open animation.
- [ ] **Transcription → long recording completes** — panel auto-opens via `onNoteCreated` callback with the new animation, then the editor opens inside.
- [ ] **Cards layout** — toggle between Panel and Cards in Settings. Cards layout open/close uses the same new animation (shared window).

---

## Task 7: Post-merge `CLAUDE.md` cleanup

**Files:**
- Modify: `CLAUDE.md`

**Why:** The "Panel open/close animation timing" entry under "Things NOT to touch unless explicitly asked" is stale once this ships. The system is now tokenized and safe for future tweaks.

- [ ] **Step 1: Ensure the main PR has merged to `main`.** This task runs after merge.

- [ ] **Step 2: Open `CLAUDE.md`, locate the "Things NOT to touch unless explicitly asked" section.**

Grep: `grep -n "Panel open/close animation timing" CLAUDE.md`

Expected: one match.

- [ ] **Step 3: Remove the line.**

Use the Edit tool to delete the bullet `- Panel open/close animation timing` (and keep the surrounding bullets intact).

- [ ] **Step 4: Commit.**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs(claude): drop panel-animation guard rail

The open/close animation is now tokenized in DesignTokens and safe
for future tweaks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

**Spec coverage:**

- ✅ Open: fade 0→1 + slide down 8 pt, 0.18s, ease-out — Task 3.
- ✅ Close: fade 1→0 + slide up 6 pt, 0.14s, ease-in — Task 4.
- ✅ No bounce — `.easeOut` / `.easeIn` named curves, no springs.
- ✅ `NSAnimationContext.runAnimationGroup` — both tasks.
- ✅ macOS 13 target respected — `NSAnimationContext.animate` (macOS 14+ spring) not used. `CAMediaTimingFunction(name: .easeOut | .easeIn)` is available since 10.7.
- ✅ `setFrame(_:display:)` inside animation group via `panel.animator().setFrame(...)` — both tasks.
- ✅ Set `alphaValue = 0` + offset frame **before** `orderFront`; animate to final after — Task 3.
- ✅ Animate to 0 + call `orderOut` in completion — Task 4.
- ✅ Rapid-toggle guard — `animationToken` in Tasks 2, 3, 4. Note: in addition to the token guarding completion side-effects, AppKit's `animator()` proxy coalesces to the latest target value when a property is animated concurrently — so an in-flight `setFrame` / `alphaValue` animation cleanly reroutes to the new target when the opposite action fires. This coalescing behavior is load-bearing for the "no stuck alpha / no orphaned position" QA item, not incidental.
- ✅ Snap zones don't conflict — `snapToNearestZone()` is a separate function and untouched by this plan. QA item 7 verifies.
- ✅ Auto-hide idle — routes through `hidePanel()` (line 284), gets the close animation for free. QA item 6.
- ✅ Auth gate — no double-fade because the gate transition is a SwiftUI state change inside `QuickPanelRootView`, not a window event. QA item 8.
- ✅ `NSHostingView.rootView` rebuild timing — no rebuild happens inside `showPanel`/`hidePanel` in current code (`applyPanelChromeForLayoutStyle` runs, but it reapplies chrome, not `rootView`). No new mid-fade flash risk introduced. Nothing to change.
- ✅ Spaces / full-screen — `.canJoinAllSpaces` collectionBehavior and `orderFrontRegardless` are untouched. QA item 9.
- ✅ Tokens in `DesignTokens.swift`, no hardcoded timing/offsets in `PanelController.swift` after edit — Tasks 1, 3, 4.
- ✅ Cards-mode investigation — Task 5.
- ✅ Out-of-scope items listed upfront.
- ✅ `CLAUDE.md` cleanup — Task 7.
- ✅ Conventional Commits — Tasks 1, 4, 7.

**Placeholder scan:** Zero TBDs, zero "add error handling", zero "similar to", zero stub tests — verified.

**Type / symbol consistency:**
- `DesignTokens.PanelAnimation.openDuration` / `closeDuration` / `openSlideOffset` / `closeSlideOffset` — introduced in Task 1, referenced in Tasks 3 and 4 with identical names.
- `animationToken` — introduced in Task 2, used in Tasks 3 and 4 with identical name and `&+= 1` wraparound-safe increment.
- `targetFrame` / `preHideFrame` / `endFrame` / `startFrame` — all local variables with scopes inside their respective functions; no cross-task assumptions.
