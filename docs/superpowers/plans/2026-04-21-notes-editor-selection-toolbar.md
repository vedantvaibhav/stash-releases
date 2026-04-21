# Notes Editor — Bigger Body + Floating Selection Toolbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the inline AppKit formatting bar in `SingleNoteEditorView` with a floating, Notion-style selection toolbar (pill-shaped, dark chrome, anchored to the selection rect) and raise body text to 15 pt. Toolbar covers paragraph style (Paragraph / H1 / H2 / H3), inline character formats (Bold, Italic, Underline, Strikethrough, Inline Code), Link, Color (stubbed), and More (placeholder). Keyboard shortcuts editor-wide: ⌘B, ⌘I, ⌘U, ⌘K.

**Architecture:** Keep `NSTextView` + RTF via `NSAttributedString` — the existing storage stack (`NotesStorage.saveNoteAttributed` / `loadNoteAttributed`) is unchanged, only font size and per-selection attribute application move. A new `NotesSelectionToolbarController` owns a `.nonactivatingPanel` `NSPanel` (same pattern as the transcription pill) that hosts a SwiftUI `NotesSelectionToolbar` view. Panel is shown whenever the wrapped editor is first-responder AND selection length > 0, positioned 8 pt above the selection rect (flipped below when offscreen-top), and tracks on scroll / window move. Active-state tint updates are driven by `textViewDidChangeSelection(_:)` diffed against the last applied state so the toolbar never flickers while the caret drifts inside a uniformly-styled run.

**Tech Stack:** Swift 6+, SwiftUI + AppKit bridge (`NSViewRepresentable`, `NSHostingView`), `NSTextView` + `NSLayoutManager` (subclassed for rounded inline-code backgrounds), `NSAttributedString` + RTF on disk, Combine (observe scroll + window notifications).

---

## Path A vs Path B: storage-format decision (explicit tradeoff called out per user request)

**Investigation of `Stash/NotesEditorView.swift` (277 lines) and `Stash/NotesStorage.swift` (463 lines):**

| Signal | Finding |
|---|---|
| Editor type | `NSViewRepresentable` wrapping `NSTextView` with `isRichText = true` (`NotesEditorView.swift:6, 47`) |
| Current body font | `NSFont.systemFont(ofSize: 14)` with `lineHeightMultiple: 1.7`, text color `white.opacity(0.9)` (`NotesEditorView.swift:122-130`) |
| Storage format | **RTF** — `saveNoteAttributed(id:attributed:)` serialises `NSAttributedString` → `.documentType: .rtf`, written to `<id>.rtf` under `~/Library/Application Support/QuickPanel/notes/` (`NotesStorage.swift:381-403`); `loadNoteAttributed(id:)` round-trips RTF, falls back to `.txt` for legacy files (`NotesStorage.swift:336-360`) |
| Call site | Single — `Stash/PanelSharedSections.swift:718`, props `noteId: String`, `notesStorage: NotesStorage`. Gated by `if showTabs { …readonly… } else { SingleNoteEditorView(…) }` |
| Existing inline formatting | Bold / Italic / Underline via `NSFontManager.convert(_:toHaveTrait:)` and `.underlineStyle` attribute on `NSTextStorage`; inline `NSStackView` toolbar at the top (lines 14-34) |

### Path A — Markdown storage + live MD rendering

Pros:
- Portable; files are inspectable / editable with any text editor
- No RTF bloat; diffs legible in git
- Familiar syntax for power users

Cons:
- **Full editor rewrite.** Live markdown rendering requires a parser (swift-markdown or hand-rolled) plus an NSTextStorage subclass that styles runs on every `replaceCharacters(in:with:)` — non-trivial.
- **Storage migration.** Every existing RTF note needs an RTF→MD conversion; lossy for colors / custom fonts / links with tooltips.
- **Regression surface.** Transcription notes already use a custom delimited plain-text format (`---TRANSCRIPT---` / `---OVERVIEW---` / `---META---` — `NotesStorage.swift:250-275`); interaction with a markdown pipeline needs to be thought through separately.
- Zero user-visible win over current RTF: selection toolbar works identically either way.

### Path B — Keep RTF / `NSAttributedString` ✅ **CHOSEN**

Pros:
- Zero storage migration; existing notes keep working.
- Current formatting (`applyFontTraits`, `.underlineStyle`) already operates on `NSAttributedString`; toolbar adds the missing attributes (strikethrough, inline code, link, heading-level font) on the same foundation.
- Save / load pipeline untouched — bug blast radius stays inside the editor.
- Interaction with transcription's delimited-text format is already handled by `loadNoteAttributed` falling through to `.txt` with default attributes.

Cons:
- RTF isn't git-friendly; nobody diffs notes in git today though.
- Locked into AppKit font handling (NSFontManager) — acceptable, already in use.

**Decision: Path B.** No migration, contained blast radius, the toolbar is the actual feature here — storage is scaffolding and it already works.

---

## Scroll tracking behavior (decision called out)

User spec left "Scroll editor → toolbar tracks or dismisses" open.

**Choice: toolbar tracks on scroll.** Matches Notion; keeps the visual relationship between selection and toolbar stable. Implementation: set `scrollView.contentView.postsBoundsChangedNotifications = true` (default on `NSClipView`; verify), observe `NSView.boundsDidChangeNotification` for that clip view, and reposition the panel on each tick using the cached selection range.

Caveat: if the selection scrolls entirely above / below the visible rect the toolbar still anchors to where the selection WOULD be — that reads as "pinned off-screen" which is worse than dismissal. Mitigation: hide the panel when the computed anchor rect is outside the scroll view's visible rect by more than the toolbar height, show it again once it re-enters.

---

## File structure

**Modify:**
- `Stash/DesignTokens.swift` — add `Icon.tintMuted`, `Typography.bodyFont` / `bodyLineHeight` / `h1Font` / `h2Font` / `h3Font`, `Spacing.toolbarHeight` / `toolbarIconSize` / `toolbarPadding` / `toolbarItemSpacing`. Tokens only; no logic.
- `Stash/NotesEditorView.swift` — delete the inline `NSStackView` toolbar (lines 14-34) and its layout constraints; switch typing attributes + default attributes to the new token-driven font; add a `NotesFormattingCoordinator`-style extension on `Coordinator` that exposes `applyBold()` / `applyItalic()` / `applyUnderline()` / `applyStrikethrough()` / `applyInlineCode()` / `applyHeading(_:)` / `applyLink(_:)` / `currentActiveFormats()`; wire a local event monitor for ⌘B ⌘I ⌘U ⌘K; implement `textViewDidChangeSelection(_:)` to drive the toolbar controller; install a custom `NSLayoutManager` subclass to render inline-code rounded backgrounds; use `scheduleLoad` (existing) to re-apply token attributes after load.

**Create:**
- `Stash/NotesSelectionToolbarController.swift` (~200 lines) — AppKit. Owns the `NSPanel`, positioning, scroll/window tracking, show/hide logic, Escape-to-hide key monitor. Takes a weak reference to the `NSTextView` and the `Coordinator`.
- `Stash/NotesSelectionToolbar.swift` (~180 lines) — SwiftUI. Pill-shaped view with four groups (Style / Inline / Link+Code / More) separated by hairlines. Driven by `NotesSelectionToolbarState` (`@Observable` final class) with fields: `activeFormats: Set<TextFormat>`, `currentHeading: HeadingLevel`, `onCommand: (ToolbarCommand) -> Void`.
- `Stash/NotesInlineCodeLayoutManager.swift` (~40 lines) — AppKit. `NSLayoutManager` subclass that overrides `fillBackgroundRectArray(_:count:forCharacterRange:color:)` to draw rounded rects (radius 4) for `.backgroundColor` spans flagged via a custom attribute `NotesInlineCodeAttribute` so *only* inline-code backgrounds are rounded (and not any other `.backgroundColor` usage that Apple might add).
- `Stash/NotesLinkPopover.swift` (~80 lines) — SwiftUI. URL entry field with Enter-to-apply / Escape-to-cancel. Hosted in an `NSPopover` anchored to the Link toolbar button.
- `StashTests/NotesEditorView+SelectionToolbarTests.swift` (~30 lines) — Swift Testing `@Suite(.disabled("manual-only for v1"))` scaffold enumerating the manual checklist cases as TODO test names so automation can fill them in later.

**Do not touch:**
- `Stash/NotesStorage.swift` — the save/load contract is unchanged.
- `Stash/GlobalHotKey.swift`
- `Stash/PanelController.swift` — only depends on `SingleNoteEditorView(noteId:notesStorage:)` which keeps the same signature.

---

## Key decisions (read before executing)

1. **Pure AppKit panel + SwiftUI content.** The panel itself is AppKit (we need `.nonactivatingPanel` + `canBecomeKey = false`), but the toolbar body is SwiftUI hosted in `NSHostingView`, updated by reassigning `rootView` on state change (supported pattern for standalone `NSHostingView`, distinct from the `NSViewRepresentable` landmine in `CLAUDE.md`).
2. **@Observable over ObservableObject** for `NotesSelectionToolbarState` per `CLAUDE.md`.
3. **Editor keeps first responder through toolbar clicks.** Achieved by the panel being non-activating + `canBecomeKey = false`; buttons fire closures, never `target:` selectors that'd route through the responder chain.
4. **Active-state diff.** `currentActiveFormats()` returns `Set<TextFormat>` and `currentHeading()` returns `HeadingLevel`. The controller compares to the last values; if equal, skip the state update. Prevents SwiftUI body re-eval on every cursor keystroke inside a bold run.
5. **Link popover uses `NSPopover`, not the toolbar panel.** User explicitly OK'd this (popover *should* dismiss on focus-resign here — the goal is to get the URL then return focus to the editor). Popover anchors to the Link button's rect in the toolbar panel's coordinate space.
6. **Inline-code rounded background via subclassed `NSLayoutManager`.** NSAttributedString's `.backgroundColor` attribute paints a plain rectangle; rounded corners require overriding `fillBackgroundRectArray(_:count:forCharacterRange:color:)`. We gate on a custom attribute key so only explicit inline-code runs get rounded — safer than rounding every `.backgroundColor` hit.
7. **Headings are paragraph-range formats.** `applyHeading(.h1)` expands the selection to full paragraph boundaries (`(textView.string as NSString).paragraphRange(for: selectedRange)`) then applies `NSFont` at the heading size + semibold to that range. Converting H1 back to Paragraph restores body font.
8. **Strikethrough** uses `.strikethroughStyle: NSUnderlineStyle.single.rawValue`.
9. **⌘K with no selection** inserts an empty link with the URL as its display text. ⌘K with selection wraps the selected text as the display text.
10. **Escape** dismisses the toolbar only; it does NOT collapse the selection or un-focus the editor.
11. **Tests.** No Swift Testing target currently exists in the repo (verify in Task 1 Step 1); the scaffold file ships with `@Suite(.disabled(...))` so it compiles even without a test target wired up — if no target exists, drop it as plain Swift file with comments in `StashTests/` (marked build target `none` in Xcode) and document the decision in the PR.

---

### Task 1: Add DesignTokens for body / headings / toolbar

**Files:**
- Modify: `Stash/DesignTokens.swift`

- [ ] **Step 1: Verify current file state**

Read `Stash/DesignTokens.swift`. Expect:
- `enum Icon` contains `backgroundRest`, `backgroundHover`, `tintRecording`, `tintPlusButton`, `backgroundActive` — **no** `tintMuted` yet.
- `enum Typography` contains `itemFont`, `itemColor`, `itemLineHeight`, `sectionFont`, `sectionColor` — no body or heading tokens.
- `enum Spacing` contains `panel`, `sectionGap`, `itemGap`, `cardGap` — no toolbar tokens.

If this doesn't match, stop and re-read the file; the plan snippets below assume this baseline.

- [ ] **Step 2: Add `Icon.tintMuted`**

Edit `Stash/DesignTokens.swift`. Inside `enum Icon { … }`, just after `static let tintPlusButton = Color.white.opacity(0.45)`, add:

```swift
        static let tintMuted        = Color.white.opacity(0.72)
```

- [ ] **Step 3: Add body + heading fonts to `Typography`**

Inside `enum Typography { … }`, after the existing `sectionColor` line, append:

```swift

        // Note editor — body text and heading levels.
        // Body: 15 pt regular, 20 pt line height (≈ 1.33 multiple).
        static let bodyFont = Font.system(size: 15, weight: .regular)
        static let bodyLineHeight: CGFloat = 20

        static let h1Font = Font.system(size: 24, weight: .semibold)
        static let h2Font = Font.system(size: 20, weight: .semibold)
        static let h3Font = Font.system(size: 17, weight: .semibold)

        // AppKit equivalents (NSTextView needs NSFont, not SwiftUI Font).
        // Keep both in lockstep with the SwiftUI sizes above.
        static let bodyNSFont: NSFont = .systemFont(ofSize: 15, weight: .regular)
        static let h1NSFont: NSFont = .systemFont(ofSize: 24, weight: .semibold)
        static let h2NSFont: NSFont = .systemFont(ofSize: 20, weight: .semibold)
        static let h3NSFont: NSFont = .systemFont(ofSize: 17, weight: .semibold)
        static let inlineCodeNSFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
```

- [ ] **Step 4: Add toolbar spacing tokens**

Inside `enum Spacing { … }`, append:

```swift

        // Notes selection toolbar.
        static let toolbarHeight: CGFloat = 34
        static let toolbarIconSize: CGFloat = 14
        static let toolbarPadding: CGFloat = 8
        static let toolbarItemSpacing: CGFloat = 10
```

- [ ] **Step 5: Add `import AppKit` so `NSFont` resolves in `DesignTokens.swift`**

The current file only imports SwiftUI. Add at the top, just below `import SwiftUI`:

```swift
import AppKit
```

- [ ] **Step 6: Build and verify**

Run:

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **` (the tokens are only referenced by new code in later tasks, so this should not break any existing call site).

- [ ] **Step 7: Commit**

```bash
git status --short
git add Stash/DesignTokens.swift
git diff --cached --stat
git commit -m "feat(tokens): body/heading fonts + toolbar spacing for notes editor

Add Icon.tintMuted (white 72%), Typography body/h1/h2/h3 fonts (SwiftUI
+ AppKit pairs), and Spacing.toolbar* (height 34, icon 14, padding 8,
item spacing 10). All net-new tokens; no existing call sites affected."
```

---

### Task 2: Bump body font, delete inline toolbar in NotesEditorView

**Files:**
- Modify: `Stash/NotesEditorView.swift:14-34, 80-98, 122-130, 179-190, 192-198`

- [ ] **Step 1: Replace `defaultTypingAttributes()`**

Open `Stash/NotesEditorView.swift`. Find the private static method at lines 122-130:

```swift
    private static func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.7
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraphStyle
        ]
    }
```

Replace with:

```swift
    static func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = DesignTokens.Typography.bodyLineHeight
        paragraphStyle.maximumLineHeight = DesignTokens.Typography.bodyLineHeight
        return [
            .font: DesignTokens.Typography.bodyNSFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraphStyle
        ]
    }
```

Note the visibility change from `private` to internal — `NotesSelectionToolbarController` will need it in a later task to reset paragraph formatting when converting a heading back to Paragraph.

- [ ] **Step 2: Remove the inline NSStackView toolbar**

Find lines 14-34 (`let toolbar = NSStackView()` through `toolbar.addArrangedSubview(NSView()) // spacer`). Delete the entire block, including:

```swift
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 2
        toolbar.distribution = .fill
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        func formatButton(symbolName: String, accessibility: String, action: Selector) -> NSButton {
            let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibility)!
            img.isTemplate = true
            let b = NSButton(image: img, target: context.coordinator, action: action)
            b.bezelStyle = .texturedRounded
            b.isBordered = false
            b.controlSize = .small
            b.toolTip = accessibility
            return b
        }

        toolbar.addArrangedSubview(formatButton(symbolName: "bold", accessibility: "Bold", action: #selector(Coordinator.toggleBold)))
        toolbar.addArrangedSubview(formatButton(symbolName: "italic", accessibility: "Italic", action: #selector(Coordinator.toggleItalic)))
        toolbar.addArrangedSubview(formatButton(symbolName: "underline", accessibility: "Underline", action: #selector(Coordinator.toggleUnderline)))
        toolbar.addArrangedSubview(NSView()) // spacer
```

- [ ] **Step 3: Remove toolbar from the container layout**

Find the layout block around lines 80-98. The current block ends:

```swift
        container.addSubview(toolbar)
        container.addSubview(scrollView)

        context.coordinator.setupPlaceholder(in: container)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 2),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.constrainPlaceholder(in: container, below: toolbar)
```

Replace it with the toolbar-free version:

```swift
        container.addSubview(scrollView)

        context.coordinator.setupPlaceholder(in: container)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.constrainPlaceholder(in: container)
```

- [ ] **Step 4: Drop the `below:` placeholder API**

Find `constrainPlaceholder(in:below:)` in the `Coordinator` class (around lines 192-198):

```swift
        func constrainPlaceholder(in container: NSView, below toolbar: NSView) {
            guard let label = placeholderField else { return }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 25),
                label.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 18)
            ])
        }
```

Replace with:

```swift
        func constrainPlaceholder(in container: NSView) {
            guard let label = placeholderField else { return }
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 25),
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 18)
            ])
        }
```

- [ ] **Step 5: Update the placeholder font to the body token**

In `setupPlaceholder(in:)` (around lines 179-190), change:

```swift
            label.font = NSFont.systemFont(ofSize: 14)
```

to:

```swift
            label.font = DesignTokens.Typography.bodyNSFont
```

- [ ] **Step 6: Delete the three legacy `@objc toggle*` methods**

Find `toggleBold()`, `toggleItalic()`, `toggleUnderline()` in the `Coordinator` class (around lines 213-275). These were wired to the inline toolbar's `action: #selector(...)`. Delete all three methods. Keyboard shortcuts + new toolbar commands in later tasks will supersede them via closures.

- [ ] **Step 7: Build and visually verify**

Run:

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Then launch the app (`open build/Build/Products/Debug/Stash.app` after `-derivedDataPath build` build), open any written note, confirm:
- Inline toolbar is gone (no buttons above the text).
- Body text renders at 15 pt (visibly larger than before).
- Placeholder "Start writing..." sits flush at the top-left of the editor when the note is empty.

Note: Bold / Italic / Underline are temporarily *unreachable* at the end of this task — no toolbar yet, no keyboard shortcuts yet. That's expected; Task 8 restores them editor-wide and the toolbar lands in Tasks 3-4.

- [ ] **Step 8: Commit**

```bash
git status --short
git add Stash/NotesEditorView.swift
git diff --cached --stat
git commit -m "refactor(notes-editor): remove inline toolbar, bump body to 15 pt

Delete NSStackView toolbar (Bold/Italic/Underline NSButtons) at the top
of SingleNoteEditorView — floating selection toolbar replaces it in a
follow-up commit. Drop the @objc toggle* methods, the constrainPlaceholder
below:toolbar parameter, and shift the placeholder anchor to container
top. Body font moves to DesignTokens.Typography.bodyNSFont (15 pt) with
a pinned 20 pt line height.

Formatting is temporarily unreachable; Tasks 3-8 of the plan restore it."
```

---

### Task 3: `NotesSelectionToolbarController` scaffold (panel + show/hide)

**Files:**
- Create: `Stash/NotesSelectionToolbarController.swift`
- Modify: `Stash/NotesEditorView.swift` — add a controller property on `Coordinator` + selection delegate hooks

- [ ] **Step 1: Create the controller file**

Write `Stash/NotesSelectionToolbarController.swift`:

```swift
import AppKit
import Combine
import SwiftUI

/// Owns the floating `.nonactivatingPanel` that renders the selection toolbar
/// above the user's current selection in an `NSTextView`. The panel is hosted
/// via `NSHostingView<NotesSelectionToolbar>`; we reassign `rootView` on state
/// change (standalone `NSHostingView` pattern — safe to assign outside an
/// NSViewRepresentable update cycle).
///
/// `@MainActor`: every method touches AppKit (`NSPanel`, `NSTextView`,
/// `NSEvent` monitors, `NSHostingView.rootView` reassignment) — all of which
/// are main-thread-only. Explicit annotation mirrors the pattern used by
/// `TranscriptionFloatingWidgetController` in this codebase.
@MainActor
final class NotesSelectionToolbarController: NSObject {

    // Weak — the text view owns its window, the coordinator owns us.
    private weak var textView: NSTextView?

    private var panel: NotesSelectionToolbarPanel?
    private var hosting: NSHostingView<NotesSelectionToolbar>?
    private let state = NotesSelectionToolbarState()

    private var cancellables: Set<AnyCancellable> = []
    private var escapeMonitor: Any?
    private var didAttachWindowObservers = false
    private var didAttachScrollObserver = false

    var onCommand: ((ToolbarCommand) -> Void)?

    // MARK: Lifecycle

    func attach(to textView: NSTextView) {
        self.textView = textView
        // We cannot subscribe to the enclosing scroll view or window here —
        // during `makeNSView`, the text view has not been added to a window
        // hierarchy yet, so `textView.window` and `enclosingScrollView` are
        // both nil. Defer to `ensureObserversAttached`, called lazily from
        // the first `syncWithSelection` once the view is live.
    }

    func detach() {
        hide()
        cancellables.removeAll()
        textView = nil
        didAttachWindowObservers = false
        didAttachScrollObserver = false
    }

    /// Called from `syncWithSelection` once we know `textView` is in a window.
    private func ensureObserversAttached() {
        guard let textView else { return }

        if !didAttachScrollObserver, let clipView = textView.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default
                .publisher(for: NSView.boundsDidChangeNotification, object: clipView)
                .sink { [weak self] _ in self?.repositionIfVisible() }
                .store(in: &cancellables)
            didAttachScrollObserver = true
        }

        if !didAttachWindowObservers, let window = textView.window {
            NotificationCenter.default
                .publisher(for: NSWindow.didMoveNotification, object: window)
                .sink { [weak self] _ in self?.repositionIfVisible() }
                .store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: NSWindow.didResizeNotification, object: window)
                .sink { [weak self] _ in self?.repositionIfVisible() }
                .store(in: &cancellables)
            NotificationCenter.default
                .publisher(for: NSWindow.willCloseNotification, object: window)
                .sink { [weak self] _ in self?.hide() }
                .store(in: &cancellables)
            didAttachWindowObservers = true
        }
    }

    // MARK: Public API

    /// Called from the text view's delegate on every selection change.
    func syncWithSelection() {
        guard let textView else { hide(); return }
        ensureObserversAttached()
        guard textView.window?.firstResponder === textView else {
            hide()
            return
        }
        let selectedRange = textView.selectedRange()
        if selectedRange.length == 0 {
            hide()
            return
        }
        ensurePanel()
        repositionIfVisible()
        panel?.orderFrontRegardless()
        installEscapeMonitor()
    }

    func updateActiveState(_ newState: NotesSelectionToolbarState.Snapshot) {
        if state.snapshot == newState { return }
        state.apply(newState)
    }

    func hide() {
        panel?.orderOut(nil)
        removeEscapeMonitor()
    }

    // MARK: Internals

    private func ensurePanel() {
        if panel != nil { return }

        let initial = NotesSelectionToolbar(state: state, onCommand: { [weak self] command in
            self?.onCommand?(command)
        })
        let host = NSHostingView(rootView: initial)
        // Fitting size drives the panel frame; SwiftUI `.fixedSize()` inside
        // the toolbar keeps the pill hug-width.
        host.translatesAutoresizingMaskIntoConstraints = false

        let contentSize = host.fittingSize
        let p = NotesSelectionToolbarPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        p.contentView = host
        panel = p
        hosting = host
    }

    /// Computes the anchor rect in screen coords: 8 pt above selection's minY,
    /// flipped below maxY + 8 when the panel would clip offscreen-top.
    private func repositionIfVisible() {
        guard let panel, let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let window = textView.window
        else { return }

        let selectedRange = textView.selectedRange()
        guard selectedRange.length > 0 else { hide(); return }

        // glyph range corresponds to the selected characters in the text container.
        let glyphRange = layoutManager.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)
        let selectionRectInContainer = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        // Offset by the text container's inset so it's in textView coords, not container coords.
        let inset = textView.textContainerInset
        var selectionRectInView = selectionRectInContainer
        selectionRectInView.origin.x += inset.width
        selectionRectInView.origin.y += inset.height

        // Hide if the selection scrolls entirely out of the visible rect by
        // more than the toolbar's own height.
        if let scrollView = textView.enclosingScrollView {
            let visible = scrollView.documentVisibleRect
            let toolbarH = panel.frame.height
            if selectionRectInView.maxY < visible.minY - toolbarH ||
               selectionRectInView.minY > visible.maxY + toolbarH {
                panel.orderOut(nil)
                return
            }
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        // view → window → screen.
        let rectInWindow = textView.convert(selectionRectInView, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)

        let toolbarSize = panel.frame.size
        let gap: CGFloat = 8
        let centerX = rectOnScreen.midX - toolbarSize.width / 2

        // Prefer above, flip below if that puts us offscreen-top.
        var targetY = rectOnScreen.maxY + gap
        if let screen = window.screen {
            let screenMaxY = screen.visibleFrame.maxY
            if targetY + toolbarSize.height > screenMaxY {
                targetY = rectOnScreen.minY - gap - toolbarSize.height
            }
        }

        panel.setFrameOrigin(NSPoint(x: centerX, y: targetY))
    }

    // MARK: Escape monitor

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

/// Borderless, non-activating, never-key panel so clicks inside the toolbar
/// don't steal first-responder from the text view.
final class NotesSelectionToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Commands + state snapshot

enum ToolbarCommand {
    case bold
    case italic
    case underline
    case strikethrough
    case inlineCode
    case heading(HeadingLevel)
    case link
    case color   // stub — no-op for v1
    case more    // stub — no-op for v1
}

enum HeadingLevel: Equatable {
    case paragraph
    case h1
    case h2
    case h3
}

enum TextFormat: Hashable {
    case bold, italic, underline, strikethrough, inlineCode, link
}

@Observable
final class NotesSelectionToolbarState {
    struct Snapshot: Equatable {
        var activeFormats: Set<TextFormat> = []
        var heading: HeadingLevel = .paragraph
    }

    private(set) var snapshot = Snapshot()

    func apply(_ next: Snapshot) {
        snapshot = next
    }
}
```

- [ ] **Step 2: Wire the controller into the editor coordinator**

Open `Stash/NotesEditorView.swift`. Inside the `Coordinator` class (around the existing `weak var textView: NSTextView?` declaration), add a new stored property:

```swift
        let toolbarController = NotesSelectionToolbarController()
```

Then, inside `makeNSView(context:)` — after `context.coordinator.textView = textView` — add:

```swift
        context.coordinator.toolbarController.attach(to: textView)
```

Add (anywhere in `Coordinator`, grouped with existing delegate methods) a selection delegate hook:

```swift
        func textViewDidChangeSelection(_ notification: Notification) {
            toolbarController.syncWithSelection()
        }
```

Also pass through first-responder changes — use a Combine publisher stored in the coordinator's cancellables so the subscription is torn down with the coordinator (the closure-form `addObserver(forName:...)` returns a token that must be removed manually; Combine's `.sink(...).store(in:)` is the leak-proof path).

Add to `Coordinator`:

```swift
        private var notificationSubscriptions: Set<AnyCancellable> = []
```

Then in `makeNSView`, after `context.coordinator.toolbarController.attach(to: textView)`:

```swift
        NotificationCenter.default
            .publisher(for: NSTextView.didEndEditingNotification, object: textView)
            .sink { [weak coordinator = context.coordinator] _ in
                coordinator?.toolbarController.hide()
            }
            .store(in: &context.coordinator.notificationSubscriptions)
```

Add `import Combine` at the top of `NotesEditorView.swift` if it isn't there already.

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. The toolbar SwiftUI view doesn't exist yet — `NSHostingView(rootView: NotesSelectionToolbar(...))` references an unknown type. Task 4 adds it; we build after that task completes. If the build fails at this step on `NotesSelectionToolbar` lookup, that's expected — either skip this step's build or stage Task 4's file before building.

- [ ] **Step 4: Commit (partial — build green only after Task 4)**

```bash
git status --short
git add Stash/NotesSelectionToolbarController.swift Stash/NotesEditorView.swift
git commit -m "feat(notes-editor): selection toolbar controller scaffold

Introduce NotesSelectionToolbarController with a non-activating NSPanel,
selection-rect → screen positioning (8 pt above selection, flipped below
when offscreen-top), and scroll / window-move / window-close observers.
The controller reads selection from NSTextView via textViewDidChangeSelection
and shows/hides accordingly. Escape dismisses via a local key-down monitor
installed on show.

Does not build on its own — NotesSelectionToolbar view lands in the next
commit."
```

---

### Task 4: `NotesSelectionToolbar` SwiftUI view

**Files:**
- Create: `Stash/NotesSelectionToolbar.swift`

- [ ] **Step 1: Create the view**

Write `Stash/NotesSelectionToolbar.swift`:

```swift
import SwiftUI

/// Pill-shaped floating toolbar matching Figma (Notion-style). Stateless —
/// the controller owns `NotesSelectionToolbarState` and dispatches commands.
struct NotesSelectionToolbar: View {
    let state: NotesSelectionToolbarState
    let onCommand: (ToolbarCommand) -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Group 1 — paragraph style
            styleMenu
            divider

            // Group 2 — inline character formats
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                iconButton("bold", command: .bold, format: .bold)
                iconButton("italic", command: .italic, format: .italic)
                iconButton("underline", command: .underline, format: .underline)
                iconButton("strikethrough", command: .strikethrough, format: .strikethrough)
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
            divider

            // Group 3 — link / code
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                iconButton("curlybraces", command: .inlineCode, format: .inlineCode)
                iconButton("link", command: .link, format: .link)
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
            divider

            // Group 4 — color (stub) + more (stub)
            HStack(spacing: DesignTokens.Spacing.toolbarItemSpacing) {
                disabledIconButton("paintpalette", tooltip: "Coming soon")
                disabledIconButton("ellipsis", tooltip: "Coming soon")
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
        }
        .frame(height: DesignTokens.Spacing.toolbarHeight)
        .background(
            Capsule().fill(PanelCardChromeStyle.bgDefault)
        )
        .fixedSize()
    }

    // MARK: Buttons

    private func iconButton(_ symbol: String, command: ToolbarCommand, format: TextFormat) -> some View {
        let isActive = state.snapshot.activeFormats.contains(format)
        return Button(action: { onCommand(command) }) {
            Image(systemName: symbol)
                .font(.system(size: DesignTokens.Spacing.toolbarIconSize, weight: .regular))
                .foregroundStyle(isActive ? Color.white : DesignTokens.Icon.tintMuted)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func disabledIconButton(_ symbol: String, tooltip: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: DesignTokens.Spacing.toolbarIconSize, weight: .regular))
            .foregroundStyle(DesignTokens.Icon.tintMuted.opacity(0.4))
            .frame(width: 20, height: 20)
            .help(tooltip)
    }

    // MARK: Heading menu

    private var styleMenu: some View {
        Menu {
            Button("Paragraph") { onCommand(.heading(.paragraph)) }
            Button("Heading 1") { onCommand(.heading(.h1)) }
            Button("Heading 2") { onCommand(.heading(.h2)) }
            Button("Heading 3") { onCommand(.heading(.h3)) }
        } label: {
            HStack(spacing: 4) {
                Text(currentHeadingLabel)
                    .font(.system(size: DesignTokens.Spacing.toolbarIconSize, weight: .regular))
                    .foregroundStyle(DesignTokens.Icon.tintMuted)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(DesignTokens.Icon.tintMuted)
            }
            .padding(.horizontal, DesignTokens.Spacing.toolbarPadding)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var currentHeadingLabel: String {
        switch state.snapshot.heading {
        case .paragraph: return "Paragraph"
        case .h1:        return "Heading 1"
        case .h2:        return "Heading 2"
        case .h3:        return "Heading 3"
        }
    }

    // MARK: Dividers

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 18)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. The previous commit and this one now resolve `NotesSelectionToolbar` + `NotesSelectionToolbarController`; the coordinator wires them up but no commands are handled yet (click handlers fire into the void).

- [ ] **Step 3: Visually verify panel positioning**

Run the app, open a written note, select some text. The toolbar should appear above the selection, pill-shaped, with Paragraph menu + Bold / Italic / Underline / Strikethrough / Code / Link + two disabled icons. Buttons don't do anything yet (commands aren't wired).

Click the Paragraph dropdown — verify the menu opens with four options. Click a button — confirm the text view keeps first responder (caret continues to blink / selection stays highlighted). Press Escape — toolbar hides.

- [ ] **Step 4: Commit**

```bash
git add Stash/NotesSelectionToolbar.swift
git commit -m "feat(notes-editor): SwiftUI selection toolbar view

Pill-shaped HStack with four groups (Paragraph menu / inline formats /
link+code / stubs) separated by 1-pt hairline dividers. Reuses
PanelCardChromeStyle.bgDefault for chrome and DesignTokens.Icon.tintMuted
for rest-state icons; active format icons tint pure white. Color +
More buttons render disabled with a 'Coming soon' tooltip."
```

---

### Task 5: Inline format actions (bold, italic, underline, strikethrough, inline code)

**Files:**
- Create: `Stash/NotesInlineCodeLayoutManager.swift`
- Modify: `Stash/NotesEditorView.swift` — add `NotesFormattingCoordinator` extension with the five actions + install custom layout manager + handle `ToolbarCommand`

- [ ] **Step 1: Create the custom layout manager for rounded inline-code backgrounds**

Write `Stash/NotesInlineCodeLayoutManager.swift`:

```swift
import AppKit

/// Draws rounded-rect backgrounds (radius 4) for runs that carry both a
/// monospaced font AND a background color — our inline-code signature.
///
/// RTF-safe: Apple's RTF serializer preserves both `.font` (including
/// monospaced trait) and `.backgroundColor`, so the rounded rendering survives
/// save/close/reopen. A custom attribute key (`.notesInlineCode`) would have
/// been cleaner semantically but gets silently dropped on round-trip.
final class NotesInlineCodeLayoutManager: NSLayoutManager {

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>,
                                          count rectCount: Int,
                                          forCharacterRange charRange: NSRange,
                                          color: NSColor) {
        // Only round when the run at this range uses a monospaced font.
        guard let textStorage,
              charRange.location < textStorage.length,
              let font = textStorage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont,
              font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }

        color.setFill()
        for i in 0..<rectCount {
            let rect = rectArray[i].insetBy(dx: 0, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.fill()
        }
    }
}
```

- [ ] **Step 2: Install the custom layout manager on the NSTextView**

In `NotesEditorView.swift`, inside `makeNSView(context:)`, *after* the `NSTextView()` is created and *before* `scrollView.documentView = textView`, add:

```swift
        // Swap in our inline-code-aware layout manager using the documented
        // container-side replacement path. `replaceLayoutManager` re-wires
        // NSTextView.layoutManager automatically and avoids leaving the
        // container bound ambiguously during the swap.
        if let existingContainer = textView.textContainer {
            existingContainer.replaceLayoutManager(NotesInlineCodeLayoutManager())
        }
```

No force unwrap: if `textContainer` is unexpectedly nil we skip the swap and inline-code backgrounds render as squares — graceful degradation, not a crash.

- [ ] **Step 3: Add the formatting methods on `Coordinator`**

Add the following methods to the `Coordinator` class in `NotesEditorView.swift`. Place them under a `// MARK: - Formatting` header near the bottom of the class:

```swift
        // MARK: - Formatting

        func ensureFirstResponder() {
            guard let tv = textView else { return }
            tv.window?.makeKeyAndOrderFront(nil)
            tv.window?.makeFirstResponder(tv)
        }

        func applyBold()           { applyFontTrait(.boldFontMask) }
        func applyItalic()         { applyFontTrait(.italicFontMask) }

        func applyUnderline() {
            applyUnderlineLike(attribute: .underlineStyle)
        }

        func applyStrikethrough() {
            applyUnderlineLike(attribute: .strikethroughStyle)
        }

        func applyInlineCode() {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }

            // Detect "already inline code" via the monospaced font trait — this
            // survives RTF serialization (unlike a custom attribute key, which
            // Apple's RTF serializer silently drops on round-trip).
            var alreadyCoded = false
            storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
                if let f = value as? NSFont,
                   f.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                    alreadyCoded = true
                    stop.pointee = true
                }
            }

            let defaultFgColor = NSColor.white.withAlphaComponent(0.9)
            let inlineCodeFgColor = NSColor(Color(hex: "#A3A3A3"))
            let inlineCodeBgColor = NSColor.white.withAlphaComponent(0.08)

            storage.beginEditing()
            if alreadyCoded {
                storage.removeAttribute(.backgroundColor, range: range)
                storage.addAttribute(.font, value: DesignTokens.Typography.bodyNSFont, range: range)
                storage.addAttribute(.foregroundColor, value: defaultFgColor, range: range)
            } else {
                storage.addAttribute(.backgroundColor, value: inlineCodeBgColor, range: range)
                storage.addAttribute(.font, value: DesignTokens.Typography.inlineCodeNSFont, range: range)
                storage.addAttribute(.foregroundColor, value: inlineCodeFgColor, range: range)
            }
            storage.endEditing()
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        // MARK: Shared helpers

        private func applyFontTrait(_ trait: NSFontTraitMask) {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            if range.length == 0 {
                let font = (tv.typingAttributes[.font] as? NSFont) ?? DesignTokens.Typography.bodyNSFont
                let fm = NSFontManager.shared
                let hasTrait = font.fontDescriptor.symbolicTraits.contains(symbolicTrait(for: trait))
                tv.typingAttributes[.font] = hasTrait
                    ? fm.convert(font, toNotHaveTrait: trait)
                    : fm.convert(font, toHaveTrait: trait)
                return
            }
            storage.applyFontTraits(trait, range: range)
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        private func symbolicTrait(for mask: NSFontTraitMask) -> NSFontDescriptor.SymbolicTraits {
            switch mask {
            case .boldFontMask:   return .bold
            case .italicFontMask: return .italic
            default:              return []
            }
        }

        private func applyUnderlineLike(attribute: NSAttributedString.Key) {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()

            if range.length == 0 {
                let cur = tv.typingAttributes[attribute] as? Int ?? 0
                tv.typingAttributes[attribute] = cur == 0 ? NSUnderlineStyle.single.rawValue : 0
                return
            }

            guard NSMaxRange(range) <= storage.length else { return }
            var hasIt = false
            storage.enumerateAttribute(attribute, in: range, options: []) { value, _, stop in
                if let n = value as? Int, n != 0 { hasIt = true; stop.pointee = true }
            }
            let newVal = hasIt ? 0 : NSUnderlineStyle.single.rawValue
            storage.beginEditing()
            storage.addAttribute(attribute, value: newVal, range: range)
            storage.endEditing()
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }
```

- [ ] **Step 4: Wire `onCommand` in the coordinator**

Inside `makeNSView(context:)`, just after `context.coordinator.toolbarController.attach(to: textView)`, install the command dispatcher:

```swift
        context.coordinator.toolbarController.onCommand = { [weak coordinator = context.coordinator] command in
            guard let coordinator else { return }
            switch command {
            case .bold:          coordinator.applyBold()
            case .italic:        coordinator.applyItalic()
            case .underline:     coordinator.applyUnderline()
            case .strikethrough: coordinator.applyStrikethrough()
            case .inlineCode:    coordinator.applyInlineCode()
            case .heading:       break    // Task 6
            case .link:          break    // Task 7
            case .color, .more:  break    // v1 stubs
            }
        }
```

- [ ] **Step 5: Build and visually verify**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Launch the app, open a note, type "hello world", select "hello", and in order:
- Click Bold → "hello" bolds; editor keeps first responder; caret/selection preserved.
- Click Italic → "hello" italicises on top of bold.
- Click Underline → underline appears.
- Click Strikethrough → strikethrough line draws through.
- Select " world", click Code → " world" renders in SF Mono with a faint rounded-rect background.
- Click Bold again with same selection → bold removes.

Confirm there's no flicker — each click should leave focus exactly where it was.

- [ ] **Step 6: Commit**

```bash
git add Stash/NotesInlineCodeLayoutManager.swift Stash/NotesEditorView.swift
git commit -m "feat(notes-editor): inline format actions via selection toolbar

Bold / Italic / Underline / Strikethrough / Inline Code land as
Coordinator methods dispatched from NotesSelectionToolbarController.
Inline code uses a custom NSLayoutManager subclass that rounds the
background rect (radius 4) for runs in a monospaced font — gating on
the font trait instead of a custom attribute key so the rounded
rendering survives RTF save/close/reopen. All actions preserve first
responder and selection."
```

---

### Task 6: Heading dropdown — `Paragraph` / `H1` / `H2` / `H3`

**Files:**
- Modify: `Stash/NotesEditorView.swift` — add `applyHeading(_:)` on `Coordinator`; extend `onCommand` switch

- [ ] **Step 1: Add `applyHeading(_:)` on `Coordinator`**

Append to the `// MARK: - Formatting` section of `Coordinator`:

```swift
        func applyHeading(_ level: HeadingLevel) {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let nsString = tv.string as NSString
            let selectedRange = tv.selectedRange()
            let paragraphRange = nsString.paragraphRange(for: selectedRange)
            guard paragraphRange.length > 0, NSMaxRange(paragraphRange) <= storage.length else { return }

            let font: NSFont
            switch level {
            case .paragraph: font = DesignTokens.Typography.bodyNSFont
            case .h1:        font = DesignTokens.Typography.h1NSFont
            case .h2:        font = DesignTokens.Typography.h2NSFont
            case .h3:        font = DesignTokens.Typography.h3NSFont
            }

            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: paragraphRange)
            // Strip inline-code chrome — background color + the #A3A3A3
            // foreground — so a paragraph that was previously inline-coded
            // reads clean after promotion to a heading. The overwriting
            // `.font` assignment above already clears the monospaced trait.
            storage.removeAttribute(.backgroundColor, range: paragraphRange)
            storage.addAttribute(
                .foregroundColor,
                value: NSColor.white.withAlphaComponent(0.9),
                range: paragraphRange
            )
            storage.endEditing()

            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }
```

- [ ] **Step 2: Wire `heading` in the command dispatcher**

In `makeNSView(context:)`, replace the existing `case .heading: break` arm (from Task 5) with:

```swift
            case .heading(let level):
                coordinator.applyHeading(level)
```

- [ ] **Step 3: Build and visually verify**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Launch, open a note, write three lines: "One", "Two", "Three". Place the caret on "One", open the Paragraph dropdown, pick Heading 1 → "One" becomes 24 pt semibold; caret stays on line 1.

Repeat with H2 / H3 on the other lines. Pick Paragraph → reverts to 15 pt.

- [ ] **Step 4: Commit**

```bash
git add Stash/NotesEditorView.swift
git commit -m "feat(notes-editor): heading dropdown (Paragraph / H1 / H2 / H3)

applyHeading(_:) expands the selection to full paragraph bounds via
NSString.paragraphRange(for:), applies the chosen heading NSFont from
DesignTokens.Typography, and strips inline-code attributes within the
paragraph (mixing 13 pt mono with a 24 pt heading reads as a bug)."
```

---

### Task 7: Link popover (⌘K UI in Task 8 — here we build the popover)

**Files:**
- Create: `Stash/NotesLinkPopover.swift`
- Modify: `Stash/NotesSelectionToolbarController.swift` — add `presentLinkPopover(anchoringTo:)`
- Modify: `Stash/NotesEditorView.swift` — `applyLink(_:)` on `Coordinator`; plug into `onCommand`

- [ ] **Step 1: Create `NotesLinkPopover.swift`**

```swift
import AppKit
import SwiftUI

/// Small URL entry popover. `.onSubmit` handles Enter; Escape dismissal is
/// wired via a local `NSEvent` key-down monitor installed by the controller
/// when the popover shows (see `presentLinkPopover`) — attempting to handle
/// Escape inside the SwiftUI hierarchy fails because `NSTextField` holds
/// first responder inside the popover window, so the child NSView never sees
/// the key event.
struct NotesLinkPopover: View {
    @State private var url: String = ""
    let initialURL: String?
    let onApply: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(DesignTokens.Icon.tintMuted)
            TextField("https://example.com", text: $url)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.bodyFont)
                .frame(width: 260)
                .onSubmit { submit() }
        }
        .padding(10)
        .onAppear {
            url = initialURL ?? ""
        }
    }

    private func submit() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onApply(trimmed)
    }
}
```

- [ ] **Step 2: Add `presentLinkPopover` on the controller**

In `Stash/NotesSelectionToolbarController.swift`, add:

```swift
    private var linkPopover: NSPopover?
    private var linkPopoverEscapeMonitor: Any?

    func presentLinkPopover(initialURL: String?,
                            onApply: @escaping (String) -> Void) {
        guard let panel, let hostingView = panel.contentView else { return }

        let popover = NSPopover()
        popover.behavior = .transient   // dismisses on clicks outside
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: NotesLinkPopover(
            initialURL: initialURL,
            onApply: { [weak popover, weak self] url in
                onApply(url)
                popover?.performClose(nil)
                self?.removeLinkPopoverEscapeMonitor()
            }
        ))
        // Anchor to the full toolbar panel rect; minY edge so popover appears below the toolbar.
        popover.show(relativeTo: hostingView.bounds, of: hostingView, preferredEdge: .minY)
        linkPopover = popover

        // `.transient` dismisses on outside clicks but NOT on Escape; install a
        // local key monitor that closes the popover when Escape fires. Scope
        // the monitor to events landing on the popover's window so other
        // Escape handlers (e.g., the toolbar's own monitor) still fire
        // normally when the popover isn't shown.
        linkPopoverEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak popover] event in
            guard event.keyCode == 53 else { return event }
            guard let popover, popover.isShown else { return event }
            popover.performClose(nil)
            self?.removeLinkPopoverEscapeMonitor()
            return nil
        }

        // Catch outside-click dismissal too — `.transient` closes the popover
        // without calling our apply / escape paths, so without this the
        // escape monitor would leak until the next `presentLinkPopover`
        // overwrites it. Observing `didCloseNotification` covers all three
        // dismissal paths uniformly.
        NotificationCenter.default
            .publisher(for: NSPopover.didCloseNotification, object: popover)
            .sink { [weak self] _ in
                self?.removeLinkPopoverEscapeMonitor()
                self?.linkPopover = nil
            }
            .store(in: &cancellables)
    }

    private func removeLinkPopoverEscapeMonitor() {
        if let monitor = linkPopoverEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            linkPopoverEscapeMonitor = nil
        }
    }
```

- [ ] **Step 3: Add `applyLink(_:)` on `Coordinator`**

Append to the `// MARK: - Formatting` section:

```swift
        func applyLink(_ urlString: String) {
            ensureFirstResponder()
            guard let tv = textView, let storage = tv.textStorage else { return }
            let range = tv.selectedRange()
            guard let url = URL(string: urlString) else { return }

            if range.length == 0 {
                // No selection — insert the URL string and link it.
                let attr = NSAttributedString(string: urlString, attributes: [
                    .link: url,
                    .foregroundColor: NSColor.systemBlue,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .font: DesignTokens.Typography.bodyNSFont
                ])
                storage.beginEditing()
                storage.replaceCharacters(in: range, with: attr)
                storage.endEditing()
            } else {
                guard NSMaxRange(range) <= storage.length else { return }
                storage.beginEditing()
                storage.addAttribute(.link, value: url, range: range)
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                storage.endEditing()
            }
            notesStorage.saveNoteAttributed(id: noteId, attributed: tv.attributedString())
        }

        func currentSelectionURL() -> String? {
            guard let tv = textView, let storage = tv.textStorage else { return nil }
            let range = tv.selectedRange()
            guard range.location < storage.length else { return nil }
            if let url = storage.attribute(.link, at: range.location, effectiveRange: nil) as? URL {
                return url.absoluteString
            }
            return nil
        }
```

- [ ] **Step 4: Plug `link` into the command dispatcher**

Replace `case .link: break` with:

```swift
            case .link:
                let initial = coordinator.currentSelectionURL()
                coordinator.toolbarController.presentLinkPopover(initialURL: initial) { url in
                    coordinator.applyLink(url)
                }
```

- [ ] **Step 5: Build and visually verify**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Select text, click the Link button on the toolbar — a popover appears below the toolbar with a URL field. Type `https://apple.com`, press Enter — the popover closes, selected text renders blue + underlined + clickable (cmd-click opens in browser).

Select the same link text, click Link again — the URL field prepopulates. Press Escape — popover closes without changes.

- [ ] **Step 6: Commit**

```bash
git add Stash/NotesLinkPopover.swift Stash/NotesSelectionToolbarController.swift Stash/NotesEditorView.swift
git commit -m "feat(notes-editor): link popover with URL entry

Link button on the selection toolbar opens an NSPopover anchored to the
toolbar (popover may dismiss on focus-resign — the goal is capture URL
and return focus to the editor). Enter applies NSAttributedString.Key.link
+ blue foreground + single underline to the selection; existing links
prepopulate the URL field. NSTextView's built-in link handling opens
cmd-clicked URLs in the default browser."
```

---

### Task 8: Keyboard shortcuts editor-wide (⌘B / ⌘I / ⌘U / ⌘K)

**Files:**
- Modify: `Stash/NotesEditorView.swift` — add a local event monitor scoped to the text view

- [ ] **Step 1: Add the local event monitor to `Coordinator`**

Note on coexistence with the Escape monitor installed by
`NotesSelectionToolbarController` in Task 3: both monitors subscribe to
`NSEvent.matching: .keyDown` and both return `nil` only for events they
actually handle (Escape → keyCode 53; shortcuts → ⌘-modified b/i/u/k).
Unmatched events pass through unchanged, so neither monitor swallows the
other's keypress. Keep this invariant — if either monitor starts returning
`nil` unconditionally, the other stops receiving events.

Add a property:

```swift
        private var keyMonitor: Any?
```

And a setup / teardown pair of methods:

```swift
        func installKeyboardShortcuts() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let tv = self.textView else { return event }
                // Only intercept events targeted at our text view.
                guard tv.window?.firstResponder === tv else { return event }
                guard event.modifierFlags.contains(.command) else { return event }

                let chars = event.charactersIgnoringModifiers?.lowercased()
                switch chars {
                case "b": self.applyBold();      return nil
                case "i": self.applyItalic();    return nil
                case "u": self.applyUnderline(); return nil
                case "k":
                    let initial = self.currentSelectionURL()
                    self.toolbarController.presentLinkPopover(initialURL: initial) { url in
                        self.applyLink(url)
                    }
                    return nil
                default:  return event
                }
            }
        }

        func removeKeyboardShortcuts() {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }

        deinit {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
```

- [ ] **Step 2: Call `installKeyboardShortcuts()` in `makeNSView`**

After `context.coordinator.toolbarController.attach(to: textView)`, add:

```swift
        context.coordinator.installKeyboardShortcuts()
```

- [ ] **Step 3: Build and visually verify**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Launch, open a note, select text, and in sequence:
- ⌘B toggles bold
- ⌘I toggles italic
- ⌘U toggles underline
- ⌘K opens the link popover (even with no selection; it'll insert the URL text)

Place cursor in an email or similar field outside the editor — ⌘B should NOT trigger there (the monitor only fires when `tv.window?.firstResponder === tv`).

- [ ] **Step 4: Commit**

```bash
git add Stash/NotesEditorView.swift
git commit -m "feat(notes-editor): ⌘B ⌘I ⌘U ⌘K editor-wide shortcuts

Local NSEvent key-down monitor scoped to the NSTextView's first-responder
state; swallows the event (returns nil) when a matching shortcut fires so
AppKit's default bindings (which would also handle ⌘B/I/U but would drive
the native font panel path) don't run twice. ⌘K opens the link popover
with the current selection's URL prepopulated if any."
```

---

### Task 9: Active-state sync (toolbar tints follow selection)

**Files:**
- Modify: `Stash/NotesEditorView.swift` — add `currentActiveFormatsSnapshot()` on `Coordinator`; push to controller on selection change
- Modify: `Stash/NotesSelectionToolbarController.swift` — no change beyond the existing `updateActiveState`

- [ ] **Step 1: Add the snapshot builder on `Coordinator`**

Append to the `// MARK: - Formatting` section:

```swift
        func currentActiveFormatsSnapshot() -> NotesSelectionToolbarState.Snapshot {
            guard let tv = textView, let storage = tv.textStorage else {
                return .init()
            }
            let range = tv.selectedRange()

            // Empty selection — read typing attributes.
            let attributes: [NSAttributedString.Key: Any]
            if range.length == 0 {
                attributes = tv.typingAttributes
            } else if range.location < storage.length {
                attributes = storage.attributes(at: range.location, effectiveRange: nil)
            } else {
                attributes = tv.typingAttributes
            }

            var formats: Set<TextFormat> = []
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold)      { formats.insert(.bold) }
                if traits.contains(.italic)    { formats.insert(.italic) }
                // Inline-code detection mirrors the apply path — gates on the
                // monospaced font trait, which survives RTF round-trip.
                if traits.contains(.monoSpace) { formats.insert(.inlineCode) }
            }
            if let u = attributes[.underlineStyle] as? Int, u != 0 {
                formats.insert(.underline)
            }
            if let s = attributes[.strikethroughStyle] as? Int, s != 0 {
                formats.insert(.strikethrough)
            }
            if attributes[.link] != nil {
                formats.insert(.link)
            }

            // Heading detection — read the font size.
            let heading: HeadingLevel
            if let font = attributes[.font] as? NSFont {
                switch font.pointSize {
                case DesignTokens.Typography.h1NSFont.pointSize: heading = .h1
                case DesignTokens.Typography.h2NSFont.pointSize: heading = .h2
                case DesignTokens.Typography.h3NSFont.pointSize: heading = .h3
                default:                                          heading = .paragraph
                }
            } else {
                heading = .paragraph
            }

            return .init(activeFormats: formats, heading: heading)
        }
```

- [ ] **Step 2: Push the snapshot from the delegate hook**

In `textViewDidChangeSelection(_:)`, change from:

```swift
        func textViewDidChangeSelection(_ notification: Notification) {
            toolbarController.syncWithSelection()
        }
```

to:

```swift
        func textViewDidChangeSelection(_ notification: Notification) {
            toolbarController.syncWithSelection()
            toolbarController.updateActiveState(currentActiveFormatsSnapshot())
        }
```

- [ ] **Step 3: Build and visually verify**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. Launch, open a note, type "hello", bold via ⌘B. Select "hello" again — the Bold icon on the toolbar should render 100% white (active) instead of muted 72%.

Place cursor inside the bolded "hello" without selecting — no toolbar (selection is empty), but if you extend a 1-character selection inside the bold text, Bold should show active.

Apply H1 to a line — the Paragraph dropdown should now display "Heading 1" when the cursor is on that line.

- [ ] **Step 4: Commit**

```bash
git add Stash/NotesEditorView.swift
git commit -m "feat(notes-editor): toolbar active-state sync on selection change

Coordinator.currentActiveFormatsSnapshot() reads typing attributes (when
selection is empty) or attributes at selectedRange.location (otherwise),
diffs font traits + underline/strikethrough/link/inline-code attributes,
and detects heading by font size. Pushed to the controller via
updateActiveState; the controller short-circuits when the snapshot is
unchanged so the SwiftUI toolbar doesn't re-render on every caret move
inside a uniformly-styled run."
```

---

### Task 10: Test skeleton

**Files:**
- Create: `StashTests/NotesEditorView+SelectionToolbarTests.swift`

- [ ] **Step 1: Check whether a test target exists**

```bash
ls -la "/Users/vedhanth/Desktop/Mark 1/StashTests" 2>/dev/null
```

If the directory exists and the Xcode project has a `StashTests` target (check `Stash.xcodeproj/project.pbxproj` for `PBXNativeTarget.*StashTests`), the skeleton is real code that compiles. If not, the skeleton ships as plain Swift file with test-ish names for future harvesting when the target is wired up.

- [ ] **Step 2: Create the skeleton**

If the directory exists already:

Write `StashTests/NotesEditorView+SelectionToolbarTests.swift`:

```swift
import Testing
@testable import Stash

/// Manual-verification checklist for the notes selection toolbar — kept as a
/// disabled suite so the structure (and test names) exists for later automation.
/// Unblock one test at a time by removing the `.disabled(...)` trait and
/// filling in the assertions.
@Suite(.disabled("Manual-only verification for v1 — see the PR description for the checklist."))
struct NotesEditorSelectionToolbarTests {

    @Test func selectionAppearsAboveSelectionWithin16pt() throws {
        // Place caret, extend selection, compute glyph bounding rect, assert
        // controller's panel origin sits at rect.maxY + 8 (or flips to
        // rect.minY - 8 - panel.height if offscreen-top).
    }

    @Test func scrollTracksToolbarUntilSelectionLeavesViewport() throws {
        // Scroll the enclosing NSScrollView while selection is held; assert the
        // panel's screen origin updates within one runloop tick.
    }

    @Test func boldClickKeepsEditorFirstResponder() throws {
        // Simulate toolbar Bold click; assert textView.window?.firstResponder === textView.
    }

    @Test func selectAllPositionsToolbarWithinScreenBounds() throws {
        // ⌘A; assert the resolved panel origin lies inside screen.visibleFrame.
    }

    @Test func escapeDismissesToolbarWithoutCollapsingSelection() throws {
        // Simulate Escape; assert panel.isVisible == false AND selectedRange.length > 0.
    }

    @Test func emptySelectionHidesToolbar() throws {
        // Collapse selection; assert panel.isVisible == false.
    }

    @Test func headingDropdownConvertsLineInPlace() throws {
        // applyHeading(.h1); assert the paragraph's font changed and caret didn't move.
    }

    @Test func linkPopoverPersistsURLAfterApply() throws {
        // Apply URL; assert attributedString has .link at the selection range.
    }

    @Test func windowResizeKeepsToolbarAttached() throws {
        // Resize the window while toolbar is visible; assert panel origin updates.
    }
}
```

- [ ] **Step 3: Build (only runs if test target is configured)**

```bash
xcodebuild -scheme Stash -configuration Debug -quiet build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If the test target isn't in the scheme the file just sits on disk uncompiled — that's fine for v1. Document either outcome in the commit message.

- [ ] **Step 4: Commit**

```bash
git add StashTests/NotesEditorView+SelectionToolbarTests.swift
git commit -m "chore(notes-editor): disabled test skeleton for selection toolbar

Swift Testing @Suite(.disabled(\"Manual-only verification for v1\"))
enumerating the nine manual-checklist items as @Test stubs so automation
has a scaffold to harvest into later. No assertions yet — the suite
builds green (or no-ops if the test target isn't in the scheme)."
```

---

### Task 11: Manual verification pass + PR-ready checklist

**Files:** none — this is a verification pass.

- [ ] **Step 1: Launch fresh + run the manual checklist**

```bash
cd "/Users/vedhanth/Desktop/Mark 1"
xcodebuild -scheme Stash -configuration Debug -derivedDataPath build build 2>&1 | tail -5
open build/Build/Products/Debug/Stash.app
```

Run all nine items from the user's checklist in order, noting any that fail:

1. Select text → toolbar appears above selection within 16 pt vertical gap.
2. Scroll editor → toolbar tracks until selection exits the visible rect by more than the toolbar height, then hides; reappears on scroll back.
3. Click Bold → selection bolds, focus retained, cursor position preserved.
4. Cmd-A → toolbar appears over full doc bounds, flipping below if the top-anchor would clip offscreen.
5. Escape → toolbar dismisses, selection preserved.
6. Empty selection (cursor only) → toolbar hidden.
7. Paragraph dropdown → H1 / H2 / H3 convert the current paragraph in place, caret stays on the same line.
8. Link → popover opens, URL persists after apply, cmd-click opens in browser.
9. Window resize / panel close → toolbar doesn't orphan; `NSWindow.willCloseNotification` observer in Task 3 handles it.

- [ ] **Step 2: Regression sanity checks on transcription notes**

Open a transcription note (the ones with tabs — Overview / Transcript). Confirm the read-only tabbed view renders as before (we shouldn't have touched that path — `if showTabs { … } else { SingleNoteEditorView(…) }` at `PanelSharedSections.swift:714-720` is untouched).

Create a quick-transcript note (< 3 min voice → clipboard primary), open it in the editor (switches to the delimited-text format under the hood), type into it, save, reopen — confirm round-trip works. The first save converts the `.txt` file to `.rtf` with the new formatting on top — that's pre-existing behavior documented in `NotesStorage.swift:395-397`.

- [ ] **Step 3: Sign off**

All nine items pass → proceed to PR. Any failure → stop and open a new task with the specific regression before PR.

---

## Self-review

**Spec coverage:**

| Spec item | Task |
|---|---|
| Body font → 15 pt, proportional line height | Task 1 (token) + Task 2 (apply in typing attrs) |
| `bodyFont` + `bodyLineHeight` tokens on DesignTokens.Typography | Task 1 |
| Floating selection toolbar — show on selection length > 0 + editor focus | Task 3 (`syncWithSelection`) |
| Hides on selection collapse / editor blur / Escape | Task 3 (controller: collapse → hide; Escape monitor; didEndEditing observer) |
| Positioning: 8 pt above selection, flip below when offscreen-top, track on scroll / resize | Task 3 (`repositionIfVisible`) |
| Non-focus-stealing panel | Task 3 (`.nonactivatingPanel` + `canBecomeKey = false`) |
| Toolbar content: Style dropdown (P/H1/H2/H3) + Bold / Italic / Underline / Strikethrough / Inline code / Link + stubs | Task 4 (layout) + Tasks 5-7 (wiring) |
| Color + More buttons stubbed disabled with tooltip | Task 4 |
| Pill shape, dark chrome via `PanelCardChromeStyle.bgDefault`, 34 pt height, 8 pt horizontal padding, 14 pt icons, 10 pt item spacing | Task 1 (tokens) + Task 4 (layout) |
| Divider hairlines between groups | Task 4 (`divider` private var) |
| Active state tints 100% white when format applied | Task 9 (`currentActiveFormatsSnapshot` → `updateActiveState`) |
| Keyboard shortcuts ⌘B ⌘I ⌘U ⌘K editor-wide | Task 8 |
| Path A vs Path B decision documented in plan doc | Explicit section above file structure |
| Scroll tracking behavior chosen and documented | "Scroll tracking behavior" section (tracks until selection exits viewport) |
| Manual test checklist in PR | Task 11 Step 1 |
| Test skeleton with `@Suite(.disabled)` | Task 10 |
| No markdown migration | Path B chosen; `NotesStorage.swift` untouched |
| No force unwraps, no new SPM deps, feature branch, Conventional Commits | Confirmed per commit + in each Task's commit message |

**Placeholder scan:** One `// Task 6` / `// Task 7` placeholder in Task 5 Step 4's command dispatcher — those are replaced in Tasks 6 and 7 with concrete code; not leftover TBDs. No TBD / "implement later" / "add error handling" text.

**Type consistency:** `ToolbarCommand`, `HeadingLevel`, `TextFormat`, `NotesSelectionToolbarState.Snapshot` are defined once (Task 3 / Controller file) and referenced with the same names across Tasks 4-9. Coordinator method names match the dispatcher cases: `applyBold` ↔ `.bold`, `applyItalic` ↔ `.italic`, etc. `presentLinkPopover(initialURL:onApply:)` signature matches both call sites (Task 7 Step 4 and Task 8 Step 1).

**Risk items (executor should watch for):**
- `scrollView.contentView.postsBoundsChangedNotifications` is `true` by default on `NSClipView`, but `NotesSelectionToolbarController.ensureObserversAttached` sets it explicitly anyway — no verification step needed.
- Active-state heading detection in Task 9 uses `font.pointSize` equality (15 / 17 / 20 / 24). These are all distinct integer point sizes, no overlap with body. Safe.
- Task 9 reads attributes at `range.location` only, so the heading dropdown reflects the first character's heading level even for selections that straddle a heading→body boundary. Acceptable — matches user intuition; if it becomes confusing, later work can compute the "majority" style across the range.
- ⌘K with no selection inserts the URL as display text. If users ask for cursor-only ⌘K to open the popover without any inserted text, change Task 7 Step 3's `range.length == 0` branch to a no-op + prompt for URL + display-text separately.
- `hide()` inside the `willCloseNotification` sink does NOT reset `didAttachWindowObservers` / `didAttachScrollObserver` — if the same window ever re-opens with the same controller still alive, observer subscriptions would still reference the closed window. Low probability for this app (the panel stays alive for the process lifetime), but if reopen behavior emerges as a regression, clear the flags in the `willClose` sink.
