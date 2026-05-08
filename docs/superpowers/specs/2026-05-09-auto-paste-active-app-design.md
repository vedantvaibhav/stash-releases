# Auto-Paste Short Transcripts to Focused App — Design Spec

**Status:** Draft 2026-05-09. Pending approval.

## Goal

After a short (<5 min) recording finishes processing, paste the cleaned transcript directly into the user's currently-focused text field. The morph-pill handoff (PR #20) stays in the codebase but demotes to a fallback path: shown only when auto-paste is impossible (no focused text field, no Accessibility permission, or insertion fails).

This is the **launch-critical UX** for short recordings — the morph alone "feels inadequate to launch" per user feedback. Auto-paste matches the mental model of voice-to-text dictation: speak, see your words appear where you were typing.

## Why this works (and the morph alone doesn't)

The morph requires the user to:
1. Notice the pill expanded somewhere on screen
2. Move cursor onto it
3. Hover and stay there long enough to read
4. Click Copy
5. Switch back to the app they were typing in
6. Cmd+V

That's 6 steps for what should be 1. Auto-paste collapses 1-6 into "the text appears where you were typing." The pill morph still has a place — for users without Accessibility permission, or when the focused element isn't a text field — but as a fallback, not the primary flow.

## Architecture

### High-level flow

```
short recording finishes
  → cleaned transcript ready
  → AutoPasteService.attemptInsert(text:)
       ├─ has Accessibility permission? if no → fall back to morph
       ├─ identify focused application (NSWorkspace.frontmostApplication)
       ├─ identify focused UI element (AXUIElement via AXUIElementCopyAttributeValue)
       ├─ is element a text input (role: AXTextField, AXTextArea, AXComboBox)? if no → morph
       ├─ insert text via AXValue setting OR pasteboard+CGEvent ⌘V
       └─ if insertion throws / returns failure → morph
```

### Components

**`AutoPasteService` (new file `Stash/AutoPasteService.swift`)**

```swift
@MainActor
final class AutoPasteService {
    static let shared = AutoPasteService()

    enum InsertResult {
        case success
        case noPermission       // user hasn't granted Accessibility
        case noFocusedField     // no text field has focus
        case insertionFailed    // tried but write failed
    }

    /// Attempt to insert `text` at the current focused text-field caret. Synchronous
    /// — completes within a few ms or returns a failure result.
    func attemptInsert(text: String) -> InsertResult { ... }

    /// Trigger the macOS "Trust Center" / accessibility-permission prompt.
    /// Calling this from a button handler in the permissions screen opens
    /// System Settings to the right pane.
    func requestAccessibilityPermission() { ... }

    var hasAccessibilityPermission: Bool { ... }
}
```

**Insertion strategies** (try in order):

1. **AXUIElement direct write** — set the focused element's `kAXValueAttribute` to current value + transcript at caret position. Cleanest. Doesn't require pasteboard manipulation. Fails on apps that don't expose AX value writes (some Electron apps).

2. **Pasteboard preserve + CGEvent ⌘V** — save current pasteboard contents, write transcript to pasteboard, post a synthetic ⌘V keydown/keyup pair via `CGEventCreateKeyboardEvent`, restore pasteboard contents after a short delay. Universal compatibility (works in any app that handles paste). Slight risk of pasteboard race if user copies something else within the restore window (~50ms).

3. **(future)** **Apple Events for known apps** — Word, Pages, etc. could use their scripting interface. Out of scope for launch 1.

The service tries strategy 1, falls back to strategy 2, returns `.insertionFailed` if both fail.

### TranscriptionService integration

`TranscriptionService.processRecording`'s `if isShort` branch currently sets `shortTranscriptResult` to drive the morph. Change to:

```swift
if isShort {
    do {
        let cleaned = try await callChat(...)
        let result = ShortTranscriptResult(text: cleaned, isRaw: false, durationSeconds: durationSeconds)
        switch AutoPasteService.shared.attemptInsert(text: cleaned) {
        case .success:
            // Pasted directly. Brief pill confirmation: "Pasted ✓" for ~1s.
            showCompletion("Pasted ✓")
        case .noPermission, .noFocusedField, .insertionFailed:
            // Fall back to the morph.
            shortTranscriptResult = result
        }
    } catch {
        // LLM cleaning failed → use raw + try paste, fallback to morph.
        // ... same pattern with rawTranscript
    }
}
```

The `shortTranscriptResult` plumbing from PR #20 stays untouched — it's the fallback path. Only the success-default changes from "always show morph" to "try paste, show morph on failure."

### Permissions

**Microphone** — already requested on first record via `AVCaptureDevice.requestAccess`. Move into the permissions onboarding screen (separate backlog item).

**Accessibility** (new) — required for AutoPasteService. Two ways to detect:

1. `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true] as CFDictionary)` — returns true if granted, prompts the user if not. Should only be called from a user-initiated action (button click), not at app launch.

2. `AXIsProcessTrusted()` — returns current status without prompting.

Use #2 for the gating check (`hasAccessibilityPermission`), use #1 from the permissions screen's CTA.

If the user denies Accessibility, AutoPasteService.attemptInsert returns `.noPermission` and the morph fallback fires every time. The permissions screen will surface this so the user can enable it later. The product still works without it (degrades gracefully to the morph).

### Pasteboard preservation

Strategy 2 (CGEvent ⌘V) requires temporarily replacing the pasteboard. To not destroy the user's current clipboard:

```swift
let original = NSPasteboard.general.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
    var dict: [NSPasteboard.PasteboardType: Data] = [:]
    for type in item.types {
        if let data = item.data(forType: type) { dict[type] = data }
    }
    return dict
} ?? []

NSPasteboard.general.clearContents()
NSPasteboard.general.setString(transcript, forType: .string)

postCGCommandV()

// Restore after the paste has been consumed (post-paste timing is the
// hardest part — too short and the paste hasn't fired; too long and the
// user might have copied something else).
DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
    NSPasteboard.general.clearContents()
    let pb = NSPasteboard.general
    for itemDict in original {
        let item = NSPasteboardItem()
        for (type, data) in itemDict {
            item.setData(data, forType: type)
        }
        pb.writeObjects([item])
    }
}
```

The 150ms restore delay is empirical — too short risks the paste not firing before restoration; too long risks user-clipboard-changes-in-flight. Tune in testing.

### Edge cases

- **Focused element is read-only** (e.g., a text view in a viewer app): AXValue write fails with `.attributeUnsupported` or `.actionUnsupported`. Treat as `.insertionFailed`, fall back to morph.
- **App was foregrounded between processing start and finish** (e.g., user switched apps mid-record): `frontmostApplication` at attemptInsert time gives the CURRENT focus, which might be different from where they started. Acceptable — the user is still in a place where the transcript could plausibly go.
- **App is Stash itself** (user has the panel/pill open): refuse to auto-paste into Stash's own text fields. Detect via bundle ID match. Fall back to morph.
- **Long auto-paste (300+ chars)** in a buggy AX implementation: the AX write may stall or partial-write. 5-second timeout on attemptInsert. On timeout, restore pasteboard, fall back to morph.

### Telemetry / debug

Behind `#if DEBUG`:
- Log every `attemptInsert` call with result and elapsed time
- Log which strategy succeeded
- Log focused-app bundle ID

For launch: minimal. Don't ship verbose logging.

## Out of scope

- Long-recording (≥5 min) flow — meeting notes don't auto-paste; they go to the notes panel as today.
- Apple Events (Word/Pages) — strategy 3, future.
- Smart quoting / formatting per destination app (e.g., Markdown in code editors, plain text in chat). Future.
- Undo integration — system Cmd+Z handles the paste naturally; no special work.

## Open questions

| Question | Default |
|---|---|
| Pill confirmation copy when paste succeeds | "Pasted ✓" with checkmark glyph |
| Should we auto-paste raw transcript on LLM failure? | Yes — better than no output. Use `isRaw: true` in the brief confirmation if needed. |
| What if the user is in Spotlight or some system overlay? | Most system overlays don't expose AX text fields → falls back to morph. Acceptable. |
| Permissions screen: where in onboarding flow? | Step 1, before the first hotkey. (To be confirmed when permissions screen is designed.) |

## Plan file (next step)

After this spec is approved, write `docs/superpowers/plans/2026-05-09-auto-paste-active-app.md` with task-by-task implementation steps. Likely tasks:

1. Branch off main
2. Create `AutoPasteService.swift` with permission check + AXValue write strategy
3. Add CGEvent ⌘V fallback strategy + pasteboard preservation
4. Wire into `TranscriptionService.processRecording`'s `if isShort` branch
5. Add "Pasted ✓" completion message + symbol mapping in `TranscriptionPillView`
6. Manual verification across at least 3 apps (TextEdit, Safari address bar, a chat app)
7. `/simplify` + PR

The permissions onboarding screen is a separate plan/PR.
