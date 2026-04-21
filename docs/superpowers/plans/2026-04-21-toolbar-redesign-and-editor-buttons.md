# Toolbar Redesign + Editor Header Buttons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the notes selection toolbar from a single-row pill to a 2-row grid, and replace the plain-text back/copy buttons in the note editor header with `HeaderIconButton` instances.

**Architecture:** Two independent changes — (1) `NotesSelectionToolbar.swift` layout restructured to `VStack` with two `HStack` rows, background switched from `Capsule` to `RoundedRectangle`, new design tokens added; (2) `PanelSharedSections.swift` `noteEditorView` header row swaps bare `Button`/`Image` for `HeaderIconButton`.

**Tech Stack:** SwiftUI, macOS 13+, `DesignTokens.swift` for all sizing constants.

---

## File Map

| File | Change |
|------|--------|
| `Stash/DesignTokens.swift` | Add `toolbarRowHeight` and `toolbarCornerRadius` tokens |
| `Stash/NotesSelectionToolbar.swift` | Restructure body to 2-row VStack, swap Capsule → RoundedRectangle, reorder buttons |
| `Stash/PanelSharedSections.swift` | Replace back + copy buttons in `noteEditorView` with `HeaderIconButton` |

`NotesSelectionToolbarController.swift` — **no changes needed** (uses `fittingSize`, which auto-adapts to new height).

---

## Task 1: Add design tokens

**Files:**
- Modify: `Stash/DesignTokens.swift:25-29`

- [ ] **Step 1: Add two new tokens after the existing toolbar group**

Open `Stash/DesignTokens.swift`. After line 29 (`static let toolbarItemSpacing: CGFloat = 10`), add:

```swift
        static let toolbarRowHeight: CGFloat = 34
        static let toolbarCornerRadius: CGFloat = 12
```

The block should now look like:

```swift
        // Notes selection toolbar.
        static let toolbarHeight: CGFloat = 34
        static let toolbarIconSize: CGFloat = 14
        static let toolbarPadding: CGFloat = 8
        static let toolbarItemSpacing: CGFloat = 10
        static let toolbarRowHeight: CGFloat = 34
        static let toolbarCornerRadius: CGFloat = 12
```

- [ ] **Step 2: Build to verify no errors**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 3: Commit**

```bash
git add Stash/DesignTokens.swift
git commit -m "feat(design-tokens): add toolbarRowHeight + toolbarCornerRadius"
```

---

## Task 2: Redesign toolbar to 2-row grid

**Files:**
- Modify: `Stash/NotesSelectionToolbar.swift` (full body replacement)

The current layout is a flat `HStack` with a `Capsule` background. The new layout is a `VStack(spacing: 0)` with:
- Row 1 (top): `styleMenu` + thin vertical separator + B/I/U/S buttons
- 1pt horizontal divider
- Row 2 (bottom): link + curlybraces + disabled paintpalette + disabled ellipsis

- [ ] **Step 1: Replace the entire `body` property**

Replace lines 13–49 (`var body: some View { ... }`) with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            // Row 1 — paragraph style + character formats
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                styleMenu
                verticalSeparator
                iconButton("bold", command: .bold, format: .bold)
                iconButton("italic", command: .italic, format: .italic)
                iconButton("underline", command: .underline, format: .underline)
                iconButton("strikethrough", command: .strikethrough, format: .strikethrough)
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
            .frame(height: DesignTokens.Spacing.toolbarRowHeight)

            // Horizontal divider between rows
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            // Row 2 — link / code / stubs
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                iconButton("link", command: .link, format: .link)
                iconButton("curlybraces", command: .inlineCode, format: .inlineCode)
                disabledIconButton("paintpalette", tooltip: "Coming soon")
                disabledIconButton("ellipsis", tooltip: "Coming soon")
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
            .frame(height: DesignTokens.Spacing.toolbarRowHeight)
        }
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Spacing.toolbarCornerRadius)
                .fill(PanelCardChromeStyle.bgDefault)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Spacing.toolbarCornerRadius)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .fixedSize()
    }
```

- [ ] **Step 2: Add the `verticalSeparator` helper below `divider`**

The old `divider` computed property (lines 112–116) is no longer used in the body. Rename it to `verticalSeparator` to make the axis explicit and avoid confusion:

Replace:
```swift
    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 18)
    }
```

With:
```swift
    private var verticalSeparator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 18)
    }
```

- [ ] **Step 3: Build to verify no errors**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Commit**

```bash
git add Stash/NotesSelectionToolbar.swift
git commit -m "feat(notes-toolbar): redesign to 2-row grid with RoundedRectangle background"
```

---

## Task 3: Replace back + copy buttons with HeaderIconButton

**Files:**
- Modify: `Stash/PanelSharedSections.swift:680-710`

Current code in `noteEditorView`:
- Back: `Button("← Back") { ... }.buttonStyle(.plain).font(.subheadline)` — text-only
- Copy: raw `Button { } label: { Image(...) }` — no container

Both should use `HeaderIconButton` (32×32 frame, circular 28pt background, hover highlight).

- [ ] **Step 1: Replace the back button (lines 681–686)**

Replace:
```swift
                Button("← Back") {
                    notesStorage.refreshNotes()
                    editingNoteId = nil
                }
                .buttonStyle(.plain)
                .font(.subheadline)
```

With:
```swift
                HeaderIconButton(
                    icon: .system("chevron.left"),
                    iconColor: DesignTokens.Icon.tintMuted
                ) {
                    notesStorage.refreshNotes()
                    editingNoteId = nil
                }
```

- [ ] **Step 2: Replace the copy button (lines 697–709)**

Replace:
```swift
                Button {
                    let text = notesStorage.loadNote(id: noteId)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    noteCopyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { noteCopyFeedback = false }
                } label: {
                    Image(systemName: noteCopyFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15))
                        .foregroundColor(noteCopyFeedback ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy note")
```

With:
```swift
                HeaderIconButton(
                    icon: .system(noteCopyFeedback ? "checkmark" : "doc.on.doc"),
                    iconColor: noteCopyFeedback ? .green : DesignTokens.Icon.tintMuted
                ) {
                    let text = notesStorage.loadNote(id: noteId)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    noteCopyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { noteCopyFeedback = false }
                }
                .help("Copy note")
```

- [ ] **Step 3: Build to verify no errors**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet 2>&1 | grep -E "error:|Build succeeded"
```

Expected: `Build succeeded`

- [ ] **Step 4: Run swiftformat + swiftlint**

```bash
swiftformat Stash/PanelSharedSections.swift Stash/NotesSelectionToolbar.swift Stash/DesignTokens.swift
swiftlint lint --path Stash/PanelSharedSections.swift Stash/NotesSelectionToolbar.swift Stash/DesignTokens.swift
```

- [ ] **Step 5: Commit**

```bash
git add Stash/PanelSharedSections.swift
git commit -m "feat(notes-editor): replace back+copy buttons with HeaderIconButton"
```
