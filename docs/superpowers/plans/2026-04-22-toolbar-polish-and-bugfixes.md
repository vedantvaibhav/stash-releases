# Toolbar Polish + Bugfixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 5 issues in the notes selection toolbar: darker background, no duplicate layer, heading menu doesn't dismiss toolbar, toolbar closes with main panel, and toolbar stays above the main panel.

**Architecture:** All changes are isolated to 4 files. Tasks A and B are independent (different files); Task C touches both controller files and is best done last so the notification name is already defined when the subscriber is written.

**Tech Stack:** Swift + AppKit + SwiftUI + Combine, macOS 13+, `DesignTokens.swift` for all colour constants.

---

## File Map

| File | Tasks | Change |
|------|-------|--------|
| `Stash/DesignTokens.swift` | A | Add `enum Toolbar { static let bg }` |
| `Stash/NotesSelectionToolbar.swift` | A | Use `DesignTokens.Toolbar.bg`, reduce border opacity, simplify to `.background` + `.overlay` |
| `Stash/NotesSelectionToolbarController.swift` | B, C | Debounce hide, elevate panel level, subscribe to `stashPanelDidHide` |
| `Stash/PanelController.swift` | C | Declare + post `stashPanelDidHide` notification |

---

## Task A: Toolbar appearance — darker bg, reduced border, single background layer

**Files:**
- Modify: `Stash/DesignTokens.swift`
- Modify: `Stash/NotesSelectionToolbar.swift`

### Context

Current toolbar background uses `PanelCardChromeStyle.bgDefault` (`#262626`). The spec wants `#141414` as a new design token, plus a simplified background structure (`.background` + `.overlay` instead of `.background` with nested `.overlay`).

Current background code in `NotesSelectionToolbar.swift` body (lines 42–49):
```swift
.background(
    RoundedRectangle(cornerRadius: DesignTokens.Spacing.toolbarCornerRadius)
        .fill(PanelCardChromeStyle.bgDefault)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.toolbarCornerRadius)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
)
```

- [ ] **Step 1: Add `DesignTokens.Toolbar` enum to DesignTokens.swift**

In `Stash/DesignTokens.swift`, after the closing `}` of `enum Spacing` (around line 32), add:

```swift
    enum Toolbar {
        static let bg = Color(red: 20/255, green: 20/255, blue: 20/255)
    }
```

- [ ] **Step 2: Replace toolbar background modifier in NotesSelectionToolbar.swift**

Replace the `.background(...)` block (lines 42–49) AND the `.fixedSize()` line with:

```swift
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.toolbarCornerRadius)
                .fill(DesignTokens.Toolbar.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.toolbarCornerRadius)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .fixedSize()
```

The inner rows (`HStack` for row 1 and row 2) must have NO `.background` modifier. Verify none exist.

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Stash/DesignTokens.swift Stash/NotesSelectionToolbar.swift
git commit -m "feat(notes-toolbar): darker bg #141414, reduced border, single background layer"
```

---

## Task B: Toolbar controller — debounce hide + elevate panel level

**Files:**
- Modify: `Stash/NotesSelectionToolbarController.swift`

### Context

**Debounce hide (spec Task 3):**
When the user taps a heading option in the SwiftUI `Menu`, NSMenu briefly steals first responder, causing `syncWithSelection()` to fire with `length == 0` and immediately hiding the toolbar. Fix: debounce the hide by 0.18 s so that if selection is restored (after menu dismissal) the hide is cancelled.

**Panel level (spec Task 5):**
The toolbar is created at `.popUpMenu` level (101), but the main content panel is at `assistiveTechHighWindow` level (~1500), so the main panel can render above the toolbar. Fix: set the toolbar panel level to `assistiveTechHighWindow + 1`.

### Current relevant code in NotesSelectionToolbarController.swift

`syncWithSelection()` (lines 86–102):
```swift
func syncWithSelection() {
    guard let textView else { hide(); return }
    ensureObserversAttached()
    guard textView.window?.firstResponder === textView else {
        hide()
        return
    }
    let selectedRange = textView.selectedRange()
    if selectedRange.length == 0 {
        hide()          // ← debounce this
        return
    }
    ensurePanel()
    repositionIfVisible()
    panel?.orderFrontRegardless()
    installEscapeMonitor()
}
```

`hide()` (lines 109–112):
```swift
func hide() {
    panel?.orderOut(nil)
    removeEscapeMonitor()
}
```

`ensurePanel()` (line 187):
```swift
p.level = .popUpMenu
```

- [ ] **Step 1: Add `pendingHideTask` property**

After the `private var linkPopoverEscapeMonitor: Any?` property declaration (around line 29), add:

```swift
    private var pendingHideTask: DispatchWorkItem?
```

- [ ] **Step 2: Debounce the hide in `syncWithSelection()`**

Replace:
```swift
    if selectedRange.length == 0 {
        hide()
        return
    }
    ensurePanel()
    repositionIfVisible()
```

With:
```swift
    if selectedRange.length == 0 {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHideTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        return
    }
    pendingHideTask?.cancel()
    pendingHideTask = nil
    ensurePanel()
    repositionIfVisible()
```

- [ ] **Step 3: Cancel pending task in `hide()`**

Replace:
```swift
func hide() {
    panel?.orderOut(nil)
    removeEscapeMonitor()
}
```

With:
```swift
func hide() {
    pendingHideTask?.cancel()
    pendingHideTask = nil
    panel?.orderOut(nil)
    removeEscapeMonitor()
}
```

- [ ] **Step 4: Elevate panel level in `ensurePanel()`**

Replace:
```swift
        p.level = .popUpMenu
```

With:
```swift
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)) + 1)
```

- [ ] **Step 5: Build**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add Stash/NotesSelectionToolbarController.swift
git commit -m "fix(notes-toolbar): debounce hide for heading menu + elevate panel level"
```

---

## Task C: Close toolbar when main panel hides

**Files:**
- Modify: `Stash/PanelController.swift`
- Modify: `Stash/NotesSelectionToolbarController.swift`

### Context

The `NotesSelectionToolbarPanel` is a separate NSWindow. When the main panel hides, `NSTextView.didEndEditingNotification` doesn't fire reliably because `becomesKeyOnlyIfNeeded = true` means the toolbar panel is never key. The toolbar stays on screen after the tray closes.

Fix: post a custom `stashPanelDidHide` notification at the top of `hidePanel()` in `PanelController`, and subscribe to it in `NotesSelectionToolbarController.ensureObserversAttached()`.

### Current relevant code

`PanelController.swift` lines 6–8:
```swift
extension Notification.Name {
    static let quickPanelUserInteraction = Notification.Name("QuickPanelUserInteraction")
}
```

`PanelController.swift` `hidePanel()` starts at line 794:
```swift
func hidePanel() {
    guard let panel = contentPanel, panel.isVisible else { return }

    // Quick Look and the key monitor must go BEFORE the animation...
    fileQuickLook.closeQuickLookIfVisible()
```

`NotesSelectionToolbarController.ensureObserversAttached()` (lines 54–81) — currently subscribes to scroll bounds, window move/resize/close.

- [ ] **Step 1: Declare `stashPanelDidHide` in PanelController.swift**

In `Stash/PanelController.swift`, add the new name to the existing `Notification.Name` extension (lines 6–8):

```swift
extension Notification.Name {
    static let quickPanelUserInteraction = Notification.Name("QuickPanelUserInteraction")
    static let stashPanelDidHide = Notification.Name("StashPanelDidHide")
}
```

- [ ] **Step 2: Post notification at start of `hidePanel()`**

After the `guard` statement in `hidePanel()` and before the first imperative line, add:

```swift
    func hidePanel() {
        guard let panel = contentPanel, panel.isVisible else { return }
        NotificationCenter.default.post(name: .stashPanelDidHide, object: nil)

        // Quick Look and the key monitor must go BEFORE the animation...
        fileQuickLook.closeQuickLookIfVisible()
```

- [ ] **Step 3: Subscribe in NotesSelectionToolbarController.ensureObserversAttached()**

Inside `ensureObserversAttached()`, after the existing `willCloseNotification` subscriber block (around line 78), add before the closing `}` of the `if !didAttachWindowObservers` block:

```swift
        NotificationCenter.default
            .publisher(for: .stashPanelDidHide)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.hide() }
            .store(in: &cancellables)
```

Note: this subscriber does not need a guard for `didAttachWindowObservers` — it only subscribes once per `attach(to:)` lifecycle because `ensureObserversAttached` is guarded by `didAttachWindowObservers`. The subscriber can live inside or just after that block. Place it inside `if !didAttachWindowObservers { ... }` so it is registered exactly once.

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Run swiftformat + swiftlint on changed files**

```bash
swiftformat Stash/DesignTokens.swift Stash/NotesSelectionToolbar.swift Stash/NotesSelectionToolbarController.swift Stash/PanelController.swift
swiftlint lint --path Stash/DesignTokens.swift Stash/NotesSelectionToolbar.swift Stash/NotesSelectionToolbarController.swift Stash/PanelController.swift
```

- [ ] **Step 6: Commit**

```bash
git add Stash/PanelController.swift Stash/NotesSelectionToolbarController.swift
git commit -m "fix(notes-toolbar): close toolbar when main panel hides via stashPanelDidHide"
```
