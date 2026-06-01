# Core Transcription + Pill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the record→transcribe→deliver loop and the floating pill airtight across every state, with best-in-class spring morphing and a precise three-way delivery contract (Pasted ✓ / Saved / Copied) plus a long-running "walk away" path.

**Architecture:** Split the *decisions* (pure, unit-tested Swift value types) from the *effects* (NSPanel/AX/clipboard/LLM side-effects that stay in the existing `@MainActor` classes). Three new pure units — a `Spring` solver, a `PillMorphAnimator` that drives `NSPanel.setFrame` along that spring (interruptible/retargetable), and a `DeliveryDecision` resolver — let us test the brittle logic without a live mic, network, or window server. The short-dictation path runs ONE fast LLM cleanup pass *before* pasting (so spoken lists land as real lists in the pasted text), with raw Whisper as the timeout/failure fallback. The long meeting-note path (≥5 min) is unchanged. A processing-time threshold OR a network retry flips the session into "clipboard-only" delivery: the pill shows a long-running card, and on completion the transcript is copied to the clipboard and the card dismisses.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSPanel`/`NSHostingView`), `CADisplayLink`, AX (`ApplicationServices`), Swift Testing, OpenAI-compatible Whisper + chat. Deployment target macOS 13+.

---

## Locked Decisions (from spec + clarifications)

1. **Pasted text source:** short dictation runs one fast cleanup pass (fillers + self-corrections + spoken-list formatting via the existing `promptShortClean`, on `APIConstants.chatModelForShortClean`) BEFORE pasting. Raw Whisper text is the fallback only when cleanup throws or exceeds `shortCleanupTimeoutSeconds`.
2. **Routing:** keep the duration split. `< 300s` → short paste path (the new three-way contract). `≥ 300s` → meeting-note path (unchanged: save + overview + auto-open editor).
3. **Long-running:** triggered when processing/delivery exceeds `Pill.longRunningThresholdSeconds` (6s) OR a network retry is pending (`isWaitingOnRetry`). In that state the session delivers **clipboard-only**: the pill morphs into the long-running card; on completion it copies the transcript to the clipboard and dismisses. The user can walk away.

## Delivery Contract (the exact truth table)

Short path only. `note` is always saved first (raw), then updated to cleaned text. Clipboard is **never** pre-written.

| Situation | Paste attempted? | Pill | Clipboard |
| --- | --- | --- | --- |
| Editable target, AX write read-back confirmed | yes (Strategy 1) | `Pasted ✓` | untouched (Strategy 2 not used) |
| Editable target, only synthetic ⌘V available (unverifiable) | yes (Strategy 2) | `Copied` | transcript LEFT on clipboard |
| Editable target, no Accessibility permission | no | `Copied` | transcript written |
| Editable target, both strategies failed / deadline | yes, failed | `Copied` | transcript written |
| No target (Stash frontmost / no front app) | no | `Saved` | untouched |
| Secure (password) field focused | no (privacy) | `Saved` | untouched |
| Long-running clipboard-only mode active | no | `Copied` (card → flash → hide) | transcript written |
| Whisper returned silence only | no | `No audio` | untouched |
| Pipeline error (disk/promote/persistent API) | no | `Failed` | untouched |

Rationale: only a read-back-verified AX write earns `Pasted ✓`. Every attempted-but-unverifiable or failed paste degrades to `Copied` with the transcript left on the clipboard as the recoverable backstop — honest, and strictly more informative than today's silent hide.

## File Structure

> **Xcode target membership (VERIFIED against `project.pbxproj` — the two targets are NOT symmetrical):**
> - `StashTests` IS a `PBXFileSystemSynchronizedRootGroup` (pbxproj line 110) → new test files under `StashTests/` auto-compile, no manual step.
> - `Stash` is a CLASSIC `PBXGroup` (line 144) with an explicit `Sources` build phase listing each file (`StashApp.swift in Sources`, …). New PRODUCTION files do NOT auto-compile — each must be added to the **Stash** target (Xcode: select file → File Inspector → Target Membership → check **Stash**; or add `PBXFileReference` + `PBXBuildFile` + the `… in Sources` entry by hand).
>
> The four new production files therefore live FLAT in `Stash/` (matching the project's existing flat layout; no `Motion/`/`Delivery/` subfolders, which would need extra `PBXGroup` entries). Every production-file task has an explicit "add to Stash target" step; test-file tasks note auto-inclusion. A "cannot find … in scope" on a production file means missing target membership, not DerivedData.

**Create:**
- `Stash/Spring.swift` — pure spring solver (response/dampingRatio → position+velocity at t). No UIKit/AppKit. Unit-tested.
- `Stash/PillMorphAnimator.swift` — `@MainActor` `CADisplayLink`-driven animator that steps `NSPanel.setFrame` along a `Spring`; retargetable mid-flight (carries velocity); reduce-motion → instant set.
- `Stash/DeliveryDecision.swift` — pure resolver: target classification + paste outcome → pill string, clipboard action, paste action. Unit-tested.
- `Stash/PasteTargetClassifier.swift` — pure classification of (frontmost bundle id, is-Stash, AX subrole/role) → `.editable` / `.noTarget` / `.secureField`. Unit-tested via injected inputs.
- `StashTests/SpringTests.swift`
- `StashTests/DeliveryDecisionTests.swift`
- `StashTests/PasteTargetClassifierTests.swift`

**Modify:**
- `Stash/DesignTokens.swift` — add `DesignTokens.Motion` (curves + spring params + reduce-motion helper) and new `Pill` morph/crossfade/threshold tokens.
- `Stash/AutoPasteService.swift` — document `InsertResult` mapping and expose `classifyTarget(capturedFrontmostBundleID:)`. Clipboard ownership stays with the service; Strategy 2 restore is unchanged.
- `Stash/TranscriptionService.swift` — cleanup-before-paste with timeout; three-way short delivery via `DeliveryDecision`; long-running threshold timer + clipboard-only flag; new completion strings; keep long path intact.
- `Stash/TranscriptionFloatingWidget.swift` — masked blur+opacity crossfade; spring morph via `PillMorphAnimator`; new completion glyphs (`Saved`, `Copied`); reduce-motion; clean supersession.
- `Stash/TranscriptionStatusNotification.swift` — long-running card copy variants (incl. the "we'll copy to your clipboard" message).
- `Stash/PanelController.swift` — wire the long-running card's "Open Notes"/clipboard behavior (respecting `onNoteCreated` ownership — do not touch it).
- `Stash/StashApp.swift` — wire debug selectors for `Pasted ✓` / `Saved` / `Copied` / long-running card; make "list pending sessions" show an `NSAlert`.

**Do NOT touch:** `GlobalHotKey.swift`, `APIKeys.swift` resolution chain, Sparkle appcast/`SUFeedURL`, `FileDropZoneView` `isHidden`, the OAuth callback path, `onNoteCreated` ownership in `PanelController.setup` (read it, wire around it; don't reassign it from view-level `onAppear`).

---

## Phase 0 — Motion foundation (tokens + spring math)

### Task 0.1: Add motion tokens to DesignTokens

**Files:**
- Modify: `Stash/DesignTokens.swift` (add to `enum Pill` and a new `enum Motion`)

- [ ] **Step 1: Add the `Motion` enum and new Pill tokens**

Insert a new `enum Motion` inside `enum DesignTokens` (e.g. directly after `enum Icon { … }`), and append the new constants to `enum Pill`.

```swift
    /// Animation curves, spring parameters, and the reduce-motion gate.
    /// Curves follow Emil Kowalski's "strong custom easing" guidance — the
    /// built-in SwiftUI/Core Animation easings are too weak. cubic-bezier
    /// control points below are the strong ease-out (0.23, 1, 0.32, 1) and
    /// strong ease-in-out (0.77, 0, 0.175, 1) from the design-engineering skill.
    enum Motion {
        // Strong ease-out — entrances/exits (starts fast, feels responsive).
        static let strongEaseOutCP: (Double, Double, Double, Double) = (0.23, 1.0, 0.32, 1.0)
        // Strong ease-in-out — on-screen movement that isn't a spring.
        static let strongEaseInOutCP: (Double, Double, Double, Double) = (0.77, 0.0, 0.175, 1.0)

        // The morph spring (capsule width/height between visible states).
        // Apple-style params: a 0.34s response with subtle bounce (≈ damping
        // ratio 0.78). Bounce is intentionally < 0.3 — emil: "keep bounce
        // subtle." Used both by the SwiftUI content and PillMorphAnimator.
        static let morphResponse: Double = 0.34
        static let morphDampingRatio: Double = 0.78
        // Hard cap on how long the spring driver runs before snapping to the
        // target, so an under-damped tail can never leave the panel un-settled.
        static let morphSettleCap: TimeInterval = 0.5

        static func caEaseOut() -> CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints:
                Float(strongEaseOutCP.0), Float(strongEaseOutCP.1),
                Float(strongEaseOutCP.2), Float(strongEaseOutCP.3))
        }

        /// True when the user has asked the system to minimise motion. Springs
        /// and blur are dropped to plain opacity in that case (emil: reduced
        /// motion = fewer/gentler, not zero).
        static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
```

Append inside `enum Pill` (after `completionWarningHold`):

```swift
        // Masked crossfade for state→state text/glyph swaps. Old content
        // blurs+fades out fast; new content blurs in after a short delay so
        // two crisp text layers never overlap (emil: "use blur to mask
        // imperfect transitions"). Total < 300ms.
        static let crossfadeOutDuration: TimeInterval = 0.10
        static let crossfadeInDelay: TimeInterval = 0.12
        static let crossfadeInDuration: TimeInterval = 0.16
        static let crossfadeBlurRadius: CGFloat = 6
        // Entrance starts at this scale (never scale(0) — emil) combined with opacity.
        static let entranceScale: CGFloat = 0.96

        // Processing/delivery longer than this flips the session into the
        // long-running "walk away" path (clipboard-only delivery + card).
        static let longRunningThresholdSeconds: TimeInterval = 6.0
```

- [ ] **Step 2: Build to confirm tokens compile**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Stash/DesignTokens.swift
git commit -m "feat(tokens): add Motion curves, morph spring, and crossfade/long-running pill tokens"
```

### Task 0.2: Pure spring solver (TDD)

**Files:**
- Create: `Stash/Spring.swift`
- Test: `StashTests/SpringTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import Stash

@Suite("Spring solver")
struct SpringTests {
    @Test func startsAtFromAndEndsAtTo() {
        let s = Spring(response: 0.3, dampingRatio: 0.8)
        let start = s.value(at: 0, from: 0, to: 100, initialVelocity: 0)
        #expect(abs(start.position - 0) < 0.001)
        let end = s.value(at: 2.0, from: 0, to: 100, initialVelocity: 0)
        #expect(abs(end.position - 100) < 0.5)        // settled near target
        #expect(abs(end.velocity) < 1.0)
    }

    @Test func underdampedOvershootsTarget() {
        let s = Spring(response: 0.3, dampingRatio: 0.5)   // bouncy
        var maxPos = 0.0
        var t = 0.0
        while t < 1.0 {
            maxPos = max(maxPos, s.value(at: t, from: 0, to: 100, initialVelocity: 0).position)
            t += 0.005
        }
        #expect(maxPos > 100)                              // overshoot proves bounce
    }

    @Test func criticallyDampedDoesNotOvershoot() {
        let s = Spring(response: 0.3, dampingRatio: 1.0)
        var t = 0.0
        while t < 1.0 {
            #expect(s.value(at: t, from: 0, to: 100, initialVelocity: 0).position <= 100.5)
            t += 0.01
        }
    }

    @Test func settledReportsTrueOnlyNearRest() {
        let s = Spring(response: 0.3, dampingRatio: 0.8)
        #expect(s.isSettled(at: 0, from: 0, to: 100, initialVelocity: 0) == false)
        #expect(s.isSettled(at: 1.5, from: 0, to: 100, initialVelocity: 0) == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/SpringTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'Spring' in scope`.

- [ ] **Step 3: Implement the solver**

```swift
import Foundation

/// Analytic spring solver (no AppKit). Parameterised the Apple way —
/// `response` (the natural period) and `dampingRatio` (1.0 = critically
/// damped, < 1.0 = bouncy). `value(at:)` returns position + velocity so a
/// driver can retarget mid-flight while preserving momentum (emil:
/// "springs maintain velocity when interrupted").
struct Spring {
    let response: Double
    let dampingRatio: Double

    /// Undamped natural frequency ω₀ = 2π / response.
    private var omega0: Double { (2 * Double.pi) / max(response, 0.0001) }

    /// Position + velocity of a spring released from `from` toward `to` with
    /// `initialVelocity`, evaluated `t` seconds after release.
    func value(at t: Double, from: Double, to: Double, initialVelocity v0: Double) -> (position: Double, velocity: Double) {
        let zeta = dampingRatio
        let w0 = omega0
        let x0 = from - to                      // displacement from target

        if zeta < 1 {                           // under-damped (can overshoot)
            let wd = w0 * (1 - zeta * zeta).squareRoot()
            let a = x0
            let b = (v0 + zeta * w0 * x0) / wd
            let envelope = exp(-zeta * w0 * t)
            let pos = envelope * (a * cos(wd * t) + b * sin(wd * t))
            let vel = envelope * ((b * wd - zeta * w0 * a) * cos(wd * t)
                                  - (a * wd + zeta * w0 * b) * sin(wd * t))
            return (pos + to, vel)
        } else {                                // critically damped (zeta == 1)
            let a = x0
            let b = v0 + w0 * x0
            let envelope = exp(-w0 * t)
            let pos = envelope * (a + b * t)
            let vel = envelope * (b - w0 * (a + b * t))
            return (pos + to, vel)
        }
    }

    /// True once the spring is within 0.5pt of the target and nearly still.
    func isSettled(at t: Double, from: Double, to: Double, initialVelocity v0: Double) -> Bool {
        let r = value(at: t, from: from, to: to, initialVelocity: v0)
        return abs(r.position - to) < 0.5 && abs(r.velocity) < 1.0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/SpringTests 2>&1 | tail -15`
Expected: PASS (4 tests).

- [ ] **Step 4a: Add `Stash/Spring.swift` to the Stash target**

`Stash/Spring.swift` is a production file under the CLASSIC `Stash` group → it must be added to the **Stash** target (File Inspector → Target Membership → **Stash**, or add the `PBXFileReference` + `PBXBuildFile` + `Spring.swift in Sources` entries). `StashTests/SpringTests.swift` auto-compiles (synchronized group). Re-run Step 4 to confirm `Spring` resolves.

- [ ] **Step 5: Commit**

```bash
git add Stash/Spring.swift StashTests/SpringTests.swift
git commit -m "feat(motion): add pure analytic Spring solver with tests"
```

---

## Phase 1 — Delivery decision core (pure, TDD)

### Task 1.1: PasteTargetClassifier (TDD)

**Files:**
- Create: `Stash/PasteTargetClassifier.swift`
- Test: `StashTests/PasteTargetClassifierTests.swift`

> **Classification timing (fixes review D2):** the target is classified from the
> frontmost app **captured at stop time** (`PendingSessionMetadata.frontmostAppBundleID`),
> NOT the live frontmost at delivery time. After a 2–4s Whisper+cleanup round-trip the
> live frontmost is often no longer the field the user dictated into. The captured id is
> the truest read of "did the user have an external target when they spoke." Secure-field
> detection is the one signal that must be live (AX tree), read best-effort at delivery.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Stash

@Suite("Paste target classification")
struct PasteTargetClassifierTests {
    let stash = "com.stash.app"
    @Test func noCapturedFrontAppIsNoTarget() {
        #expect(PasteTargetClassifier.classify(capturedFrontmostBundleID: nil, stashBundleID: stash, liveAXSubrole: nil) == .noTarget)
    }
    @Test func stashCapturedAtStopIsNoTarget() {
        #expect(PasteTargetClassifier.classify(capturedFrontmostBundleID: stash, stashBundleID: stash, liveAXSubrole: nil) == .noTarget)
    }
    @Test func secureFieldIsSecure() {
        #expect(PasteTargetClassifier.classify(capturedFrontmostBundleID: "com.apple.Safari", stashBundleID: stash, liveAXSubrole: "AXSecureTextField") == .secureField)
    }
    @Test func externalAppIsEditableEvenWhenAXIsOpaque() {
        // Electron apps expose no focused element — still optimistically editable.
        #expect(PasteTargetClassifier.classify(capturedFrontmostBundleID: "com.example.electron", stashBundleID: stash, liveAXSubrole: nil) == .editable)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/PasteTargetClassifierTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'PasteTargetClassifier'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Pure classification of the paste destination. Side-effect-free so it can be
/// unit-tested without a window server. Drives Case 1 (paste) vs Case 2 (save,
/// no clipboard). Classified from the STOP-TIME captured frontmost app (see
/// timing note above); only the secure-field subrole is read live.
enum PasteTarget: Equatable {
    case editable      // attempt a paste
    case noTarget      // Stash (or nothing) was frontmost at stop → save, no clipboard
    case secureField   // password field → never paste, never clipboard
}

enum PasteTargetClassifier {
    static func classify(capturedFrontmostBundleID: String?, stashBundleID: String?, liveAXSubrole: String?) -> PasteTarget {
        // No external target when the user spoke → Case 2 (Save, no clipboard).
        if capturedFrontmostBundleID == nil { return .noTarget }
        if capturedFrontmostBundleID == stashBundleID { return .noTarget }
        if liveAXSubrole == "AXSecureTextField" { return .secureField }
        // External app had focus at stop → optimistically editable. Electron/
        // ToDesktop apps expose no focused element but DO accept ⌘V.
        return .editable
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/PasteTargetClassifierTests 2>&1 | tail -15`
Expected: PASS (4 tests).

- [ ] **Step 4a: Add `Stash/PasteTargetClassifier.swift` to the Stash target** (production file in the classic `Stash` group). `StashTests/PasteTargetClassifierTests.swift` auto-compiles (synchronized). Re-run Step 4.

- [ ] **Step 5: Commit**

```bash
git add Stash/PasteTargetClassifier.swift StashTests/PasteTargetClassifierTests.swift
git commit -m "feat(delivery): add pure PasteTargetClassifier with tests"
```

### Task 1.2: DeliveryDecision resolver (TDD)

**Files:**
- Create: `Stash/DeliveryDecision.swift`
- Test: `StashTests/DeliveryDecisionTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Stash

@Suite("Delivery decision")
struct DeliveryDecisionTests {
    @Test func verifiedPasteShowsPastedAndLeavesClipboardAlone() {
        let d = DeliveryDecision.resolvePaste(.verifiedPasted)
        #expect(d.pill == "Pasted ✓")
        #expect(d.clipboard == .none)
    }
    @Test func unverifiedPasteCopies() {
        for outcome in [PasteOutcome.attemptedUnverified, .noPermission, .failed] {
            let d = DeliveryDecision.resolvePaste(outcome)
            #expect(d.pill == "Copied")
            #expect(d.clipboard == .writeTranscript)
        }
    }
    @Test func noTargetSaves() {
        let d = DeliveryDecision.resolveNoPaste(target: .noTarget, clipboardOnly: false)
        #expect(d.pill == "Saved")
        #expect(d.clipboard == .none)
    }
    @Test func secureFieldSaves() {
        let d = DeliveryDecision.resolveNoPaste(target: .secureField, clipboardOnly: false)
        #expect(d.pill == "Saved")
        #expect(d.clipboard == .none)
    }
    @Test func clipboardOnlyCopies() {
        let d = DeliveryDecision.resolveNoPaste(target: .noTarget, clipboardOnly: true)
        #expect(d.pill == "Copied")
        #expect(d.clipboard == .writeTranscript)
    }
    @Test func shouldAttemptPasteOnlyForEditableWhenNotClipboardOnly() {
        #expect(DeliveryDecision.shouldAttemptPaste(target: .editable, clipboardOnly: false) == true)
        #expect(DeliveryDecision.shouldAttemptPaste(target: .editable, clipboardOnly: true) == false)
        #expect(DeliveryDecision.shouldAttemptPaste(target: .noTarget, clipboardOnly: false) == false)
        #expect(DeliveryDecision.shouldAttemptPaste(target: .secureField, clipboardOnly: false) == false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/DeliveryDecisionTests 2>&1 | tail -15`
Expected: FAIL — `cannot find 'DeliveryDecision'`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Normalised paste result, decoupled from AutoPasteService's richer enum so
/// the decision table is testable in isolation.
enum PasteOutcome: Equatable {
    case verifiedPasted        // Strategy 1 AX write, read-back confirmed
    case attemptedUnverified   // Strategy 2 ⌘V posted, landing unobservable
    case noPermission          // Accessibility not granted
    case failed                // both strategies failed / deadline
}

/// Pure resolver for the short-path delivery contract (see plan truth table).
/// Returns the pill string and what to do with the clipboard. The note is
/// always saved by the caller regardless; this only governs pill + clipboard.
enum DeliveryDecision {
    enum Clipboard: Equatable { case none, writeTranscript }
    struct Outcome: Equatable { let pill: String; let clipboard: Clipboard }

    static func shouldAttemptPaste(target: PasteTarget, clipboardOnly: Bool) -> Bool {
        guard !clipboardOnly else { return false }
        return target == .editable
    }

    static func resolvePaste(_ outcome: PasteOutcome) -> Outcome {
        switch outcome {
        case .verifiedPasted:
            return Outcome(pill: "Pasted ✓", clipboard: .none)
        case .attemptedUnverified, .noPermission, .failed:
            return Outcome(pill: "Copied", clipboard: .writeTranscript)
        }
    }

    static func resolveNoPaste(target: PasteTarget, clipboardOnly: Bool) -> Outcome {
        if clipboardOnly { return Outcome(pill: "Copied", clipboard: .writeTranscript) }
        switch target {
        case .noTarget, .secureField:
            return Outcome(pill: "Saved", clipboard: .none)
        case .editable:
            // Editable but we chose not to paste — treat as copy backstop.
            return Outcome(pill: "Copied", clipboard: .writeTranscript)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/DeliveryDecisionTests 2>&1 | tail -15`
Expected: PASS (6 tests).

- [ ] **Step 4a: Add `Stash/DeliveryDecision.swift` to the Stash target** (production file in the classic `Stash` group). `StashTests/DeliveryDecisionTests.swift` auto-compiles (synchronized). Re-run Step 4.

- [ ] **Step 5: Commit**

```bash
git add Stash/DeliveryDecision.swift StashTests/DeliveryDecisionTests.swift
git commit -m "feat(delivery): add pure DeliveryDecision resolver with tests"
```

---

## Phase 2 — AutoPasteService: richer result + classification + leave-on-clipboard

### Task 2.1: Expand InsertResult and add target classification

**Files:**
- Modify: `Stash/AutoPasteService.swift`

- [ ] **Step 1a: Correct the now-stale top-of-file doc comment (completes review D1)**

The header doc (lines ~4-16, 37) still describes the OLD contract — "the caller ALSO writes the transcript to the system pasteboard and saves a quick note … regardless," and "Caller should show 'Saved' rather than claim success." Under the new contract the caller writes the clipboard ONLY for `Copied` outcomes (service-owned, single write), and `attemptedPaste` maps to `Copied`, not `Saved`. Rewrite the header to:

```swift
/// Pastes short voice-transcripts into the user's focused text field. Two
/// strategies in order: (1) AXUIElement direct value write (read-back verified
/// → `.verifiedPasted`), (2) CGEvent ⌘V with pasteboard preservation
/// (`.attemptedPaste`, landing unobservable). Clipboard ownership lives in the
/// CALLER (`TranscriptionService.performShortDelivery`): it writes the transcript
/// to the pasteboard ONLY for `Copied` outcomes, which bumps `changeCount` so
/// Strategy 2's delayed restore skips. `.verifiedPasted` leaves the clipboard
/// untouched; `Saved` (no-target / secure field) never reaches this service.
/// The note is always saved before delivery, so no outcome is data loss.
```

- [ ] **Step 1: Replace the `InsertResult` enum**

Replace the existing `enum InsertResult { … }` (lines ~25-48) with:

```swift
    enum InsertResult {
        /// Strategy 1 (AX value write) confirmed via read-back. → Pasted ✓.
        case verifiedPasted
        /// Strategy 2 (synthetic ⌘V) posted; landing unobservable. → Copied.
        case attemptedPaste
        /// No Accessibility permission. → Copied (clipboard backstop).
        case noPermission
        /// Both strategies aborted/failed before a confirmed paste. → Copied.
        case insertionFailed
    }

    /// Classify the paste destination for a session. Target existence is judged
    /// from the STOP-TIME captured frontmost app (`capturedFrontmostBundleID`),
    /// not the live frontmost (which drifts during the round-trip). Only the
    /// secure-field subrole is read live (best-effort AX). Pure decision lives
    /// in `PasteTargetClassifier`.
    func classifyTarget(capturedFrontmostBundleID: String?) -> PasteTarget {
        var subrole: String?
        let front = NSWorkspace.shared.frontmostApplication
        let liveIsStash = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        if let front, !liveIsStash, let element = focusedElement(in: front) {
            var subroleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success {
                subrole = subroleRef as? String
            }
        }
        return PasteTargetClassifier.classify(
            capturedFrontmostBundleID: capturedFrontmostBundleID,
            stashBundleID: Bundle.main.bundleIdentifier,
            liveAXSubrole: subrole
        )
    }
```

- [ ] **Step 2: (No clipboard plumbing change — by design)**

`writeViaCGEventPaste` keeps its existing behavior: it transiently writes the transcript to post ⌘V, then restores the previous pasteboard 300ms later, **guarded by `token` + `pb.changeCount`**. The clipboard for `Copied` outcomes is owned by the SERVICE (Phase 3): after `attemptInsert` returns, the service writes the transcript to the clipboard, which bumps `changeCount` — so Strategy 2's delayed restore sees `changeCount != changeCountAtWrite` and skips, leaving the transcript in place. This needs no flag and is correct for every `insertionFailed` sub-case (Stash-front, deadline) where Strategy 2 never wrote at all. Leave `attemptInsert`/`writeViaCGEventPaste` unchanged.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (the only new public surface is `classifyTarget(capturedFrontmostBundleID:)`; `TranscriptionService` call sites are added in Phase 3).

- [ ] **Step 4: Commit**

```bash
git add Stash/AutoPasteService.swift
git commit -m "feat(autopaste): expose classifyTarget(capturedFrontmostBundleID:) for delivery routing"
```

---

## Phase 3 — TranscriptionService: cleanup-before-paste, three-way delivery, long-running

### Task 3.1: Fast cleanup-before-paste with bounded timeout (TDD)

**Files:**
- Modify: `Stash/TranscriptionService.swift`
- Test: `StashTests/RawFirstDeliveryTests.swift` (extend)

- [ ] **Step 1: Write the failing tests FIRST (RED), with the DEBUG seam they need**

The timeout is a parameter (default = the constant) so the "timeout wins" case is deterministic with a tiny injected timeout instead of racing a 4s wall clock. Add to `RawFirstDeliveryTests`:

```swift
    @Test func shortCleanupReturnsModelOutputWhenFast() async {
        let svc = TranscriptionService()
        svc.chatFunction = { _, _, _, _ in "1. one\n2. two" }   // returns immediately
        let out = await svc.testCleanupShortWithTimeout("one two", timeout: 4.0)
        #expect(out == "1. one\n2. two")
    }

    @Test func shortCleanupReturnsNilWhenModelThrows() async {
        let svc = TranscriptionService()
        struct Boom: Error {}
        svc.chatFunction = { _, _, _, _ in throw Boom() }
        let out = await svc.testCleanupShortWithTimeout("hello", timeout: 4.0)
        #expect(out == nil)
    }

    @Test func shortCleanupReturnsNilWhenModelTooSlow() async {
        let svc = TranscriptionService()
        svc.chatFunction = { _, _, _, _ in
            try? await Task.sleep(nanoseconds: 500_000_000)        // 0.5s
            return "too late"
        }
        let out = await svc.testCleanupShortWithTimeout("hi", timeout: 0.05)  // 50ms — timeout wins
        #expect(out == nil)
    }
```

The seam is required for these to even compile, so add it now too (next to `testSanitiseWhisperOutput`):

```swift
    #if DEBUG
    func testCleanupShortWithTimeout(_ text: String, timeout: TimeInterval) async -> String? {
        await cleanupShortWithTimeout(text, timeout: timeout)
    }
    #endif
```

- [ ] **Step 2: Run to verify RED**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/RawFirstDeliveryTests 2>&1 | tail -20`
Expected: FAIL to compile — `cannot find 'cleanupShortWithTimeout'` (the seam references a method that does not exist yet). This is the RED state.

- [ ] **Step 3: Add the constant + the helper (GREEN)**

Add near `minProcessingVisibility`:

```swift
    /// Upper bound on the pre-paste cleanup pass for short dictation. If the
    /// fast model hasn't returned within this window we paste the raw Whisper
    /// text (still correct, just unformatted) and let the saved note keep raw.
    /// Keeps the round-trip bounded.
    private static let shortCleanupTimeoutSeconds: TimeInterval = 4.0
```

Add the helper (races cleanup vs. a sleep; nil = timed out/failed → caller uses raw). `timeout` defaults to the constant so production callers omit it:

```swift
    /// Run the short-clip cleanup pass with a hard timeout. Returns cleaned
    /// text, or nil if the model threw or exceeded `timeout`.
    @MainActor
    private func cleanupShortWithTimeout(_ text: String, timeout: TimeInterval = shortCleanupTimeoutSeconds) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                return try? await self.runChat(
                    systemPrompt: Self.promptShortClean,
                    userMessage: text,
                    maxTokens: 1024,
                    model: APIConstants.chatModelForShortClean
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            // group.next() yields String?? (Optional of the child's String?);
            // `?? nil` flattens the outer Optional. First task to finish wins;
            // cancelAll() tears down the loser.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
```

- [ ] **Step 4: Run to verify GREEN**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/RawFirstDeliveryTests 2>&1 | tail -20`
Expected: PASS (existing tests + the 3 new ones).

- [ ] **Step 5: Commit**

```bash
git add Stash/TranscriptionService.swift StashTests/RawFirstDeliveryTests.swift
git commit -m "feat(transcription): bounded fast cleanup-before-paste helper + tests (red-first)"
```

### Task 3.2: Long-running threshold + clipboard-only flag

**Files:**
- Modify: `Stash/TranscriptionService.swift`

- [ ] **Step 1: Add published state + timer**

Add published properties near `isWaitingOnRetry`:

```swift
    /// True once a session has crossed the long-running threshold OR a network
    /// retry is pending. While true, delivery is clipboard-only and the pill
    /// shows the long-running card. Reset on every new recording + on delivery.
    @Published var isLongRunning: Bool = false
```

Add a timer field near `sizeMonitorTimer`:

```swift
    private var longRunningTimer: Timer?
```

- [ ] **Step 2: Arm the timer when processing begins, reset on new recording/delivery**

In `stopRecording()`, right after `isProcessing = true`, arm the threshold timer:

```swift
        longRunningTimer?.invalidate()
        longRunningTimer = Timer(timeInterval: DesignTokens.Pill.longRunningThresholdSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isProcessing else { return }
                self.isLongRunning = true
            }
        }
        if let t = longRunningTimer { RunLoop.main.add(t, forMode: .common) }
```

In `startRecording()`, alongside `resetWaitingState()`, add `resetLongRunning()`. Define:

```swift
    private func resetLongRunning() {
        longRunningTimer?.invalidate()
        longRunningTimer = nil
        isLongRunning = false
    }
```

Make `resetWaitingState()` also surface long-running for the retry path by setting `isLongRunning = true` inside the `URLError` catch (where `isWaitingOnRetry = true` is set) — add `isLongRunning = true` on the same line block. And in `deliverTranscript`, after `resetWaitingState()`, call `longRunningTimer?.invalidate()` so a fast delivery cancels a pending threshold fire (but leave `isLongRunning` as-is if already true — delivery handles clipboard-only below).

- [ ] **Step 3: Commit**

```bash
git add Stash/TranscriptionService.swift
git commit -m "feat(transcription): long-running threshold timer + isLongRunning state"
```

### Task 3.3: Rewrite `deliverTranscriptShort` to the three-way contract

**Files:**
- Modify: `Stash/TranscriptionService.swift`

- [ ] **Step 1: Make the floor-clear intent-aware in `uploadSession` (keeps the long path identical to today; fixes the stuck-`isProcessing` regression)**

`deliverTranscriptLong` is synchronous and shows `"Note saved"` immediately, relying on the spinner being cleared BEFORE it runs. The SHORT path must instead keep the spinner up through its async cleanup and clear itself. So make the line-745 clear conditional on intent — do NOT remove it outright:

Replace (line ~745):
```swift
        if isFirstAttempt { await clearProcessingHonoringFloor() }
        // Raw-first delivery — same actor, just call through.
        await deliverTranscript(text: text, metadata: metadata)
```
with:
```swift
        // Long path clears the spinner BEFORE its synchronous "Note saved"
        // (unchanged from today). Short path keeps the spinner up and clears
        // itself after the bounded cleanup-before-paste (see deliverTranscriptShort).
        if isFirstAttempt && metadata.intent == .longNote {
            await clearProcessingHonoringFloor()
        }
        await deliverTranscript(text: text, metadata: metadata)
```
(Keep the early `clearProcessingHonoringFloor()` calls in the error / no-audio branches exactly as-is. `deliverTranscriptLong` is untouched — LOCKED.)

- [ ] **Step 2: Replace `deliverTranscriptShort` with an `async` helper (and forward the captured id)**

Making it `async` (no inner detached `Task`) means `deliverTranscript` → `uploadSession` only return `true` AFTER the paste/clipboard/pill resolve, so the queue archives the session only once delivery is actually done (tightens the success contract). In `deliverTranscript(text:metadata:)`, change the short call:

```swift
        case .shortPaste:
            noteId = await deliverTranscriptShort(
                text: text,
                durationSeconds: metadata.durationSeconds,
                capturedFrontmostBundleID: metadata.frontmostAppBundleID
            )
```

```swift
    @MainActor
    @discardableResult
    private func deliverTranscriptShort(text rawText: String, durationSeconds: Int, capturedFrontmostBundleID: String?) async -> String? {
        // Phase 1 — persist raw immediately so a note always exists.
        let rawNoteId = notesStorage?.saveQuickNote(text: rawText, durationSeconds: durationSeconds)

        // Phase 2 — cleanup-before-paste (bounded). The cleaned text is what we
        // paste AND save; raw is the fallback on timeout/failure. Runs while the
        // processing spinner is still up (uploadSession deferred the clear for
        // the short intent).
        let cleaned = await cleanupShortWithTimeout(rawText) ?? rawText

        // Spinner has covered Whisper + cleanup; transition to completion now.
        await clearProcessingHonoringFloor()

        // Update the saved note to the cleaned text (so note == pasted text).
        if let rawNoteId, cleaned != rawText {
            notesStorage?.replaceTranscriptContent(
                noteId: rawNoteId, transcript: cleaned, overview: nil,
                durationSeconds: durationSeconds, type: "quick"
            )
        }

        // Re-read isLongRunning HERE (fixes review D3 TOCTOU): the threshold
        // timer fires at +6s, which can elapse DURING cleanup. Capturing the
        // flag at function entry would race; reading it now guarantees the
        // "clipboard-only / no paste" contract matches what the card promised.
        let clipboardOnly = isLongRunning
        performShortDelivery(cleaned: cleaned, clipboardOnly: clipboardOnly, capturedFrontmostBundleID: capturedFrontmostBundleID)
        return rawNoteId
    }

    /// Executes the delivery truth table: classify target → paste or not →
    /// resolve pill + clipboard. Pure decisions come from `DeliveryDecision`.
    @MainActor
    private func performShortDelivery(cleaned: String, clipboardOnly: Bool, capturedFrontmostBundleID: String?) {
        let target = AutoPasteService.shared.classifyTarget(capturedFrontmostBundleID: capturedFrontmostBundleID)
        let decision: DeliveryDecision.Outcome

        if DeliveryDecision.shouldAttemptPaste(target: target, clipboardOnly: clipboardOnly) {
            let result = AutoPasteService.shared.attemptInsert(text: cleaned)
            let outcome: PasteOutcome
            switch result {
            case .verifiedPasted:   outcome = .verifiedPasted
            case .attemptedPaste:   outcome = .attemptedUnverified
            case .noPermission:     outcome = .noPermission
            case .insertionFailed:  outcome = .failed
            }
            decision = DeliveryDecision.resolvePaste(outcome)
        } else {
            decision = DeliveryDecision.resolveNoPaste(target: target, clipboardOnly: clipboardOnly)
        }

        // Single clipboard owner: write the transcript iff the decision says
        // `Copied`. This bumps NSPasteboard.changeCount, which makes any pending
        // Strategy 2 restore skip (its `changeCount` guard fails), so the
        // transcript stays put. `verifiedPasted`/`Saved` (clipboard == .none)
        // never touch the clipboard — satisfying spec Case 1 and Case 2.
        if decision.clipboard == .writeTranscript {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cleaned, forType: .string)
        }

        // Long-running: card → flash "Copied" → dismiss (controller handles morph).
        resetLongRunning()
        showCompletion(decision.pill)
    }
```

> The async cleanup that previously updated the note in the background is now folded into Phase 2 (the note is updated inline once cleanup returns). No second detached task — DRY. The clipboard is written in exactly ONE place (above), guarded by the decision; the `changeCount` guard inside Strategy 2's restore makes this safe against the 300ms delayed restore.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Stash/TranscriptionService.swift
git commit -m "feat(transcription): three-way short delivery (Pasted/Saved/Copied) with cleanup-before-paste"
```

### Task 3.4: `pillCopyFor` cleanup + verify long path untouched

**Files:**
- Modify: `Stash/TranscriptionService.swift`

- [ ] **Step 1: Remove the now-unused `pillCopyFor`**

`performShortDelivery` owns pill strings now. Delete `pillCopyFor(_:)` (lines ~626-633) — it's dead. Confirm no other references: `grep -n pillCopyFor Stash/*.swift` returns nothing.

- [ ] **Step 2: Confirm `deliverTranscriptLong` is unchanged**

It still saves the meeting note, shows `"Note saved"`, fires `onNoteCreated`, and runs async cleanup+overview. No edits.

- [ ] **Step 3: Build + run the full delivery suite**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' -only-testing:StashTests/RawFirstDeliveryTests -only-testing:StashTests/DeliveryDecisionTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Stash/TranscriptionService.swift
git commit -m "refactor(transcription): drop dead pillCopyFor; pill strings owned by delivery"
```

---

## Phase 4 — Pill: spring morph + masked crossfade + states + reduce-motion

### Task 4.1: PillMorphAnimator (spring-driven, interruptible panel frame)

**Files:**
- Create: `Stash/PillMorphAnimator.swift`

- [ ] **Step 1: Implement the animator**

```swift
import AppKit
import QuartzCore

/// Drives `NSPanel.setFrame` along a `Spring` via a CVDisplayLink. Interruptible
/// and retargetable: calling `animate(to:)` mid-flight reseeds from the current
/// position AND the live per-axis velocity, so a recording→processing→completion
/// burst morphs smoothly instead of restarting from zero (emil: springs keep
/// momentum when interrupted). Reduce-motion → instant frame set, no spring.
@MainActor
final class PillMorphAnimator {
    private weak var panel: NSPanel?
    private var link: CVDisplayLink?
    private let spring: Spring

    private var startTime: CFTimeInterval = 0
    private var fromFrame: NSRect = .zero
    private var toFrame: NSRect = .zero
    // Initial per-axis velocity carried across retargets.
    private var velFrame: (w: Double, h: Double, x: Double, y: Double) = (0, 0, 0, 0)
    // Last per-axis velocity computed in tick() — read on retarget.
    private var liveVel: (w: Double, h: Double, x: Double, y: Double) = (0, 0, 0, 0)
    private var inFlight = false
    private var onSettle: (() -> Void)?

    init(panel: NSPanel) {
        self.panel = panel
        self.spring = Spring(response: DesignTokens.Motion.morphResponse,
                             dampingRatio: DesignTokens.Motion.morphDampingRatio)
    }

    /// Morph the panel to `target`. `onSettle` fires when motion completes.
    func animate(to target: NSRect, onSettle: (() -> Void)? = nil) {
        guard let panel else { return }
        if DesignTokens.Motion.reduceMotion {
            stop()
            panel.setFrame(target, display: true)
            onSettle?()
            return
        }
        // Reseed from the live frame; carry the live velocity if we were already
        // mid-morph so the spring retargets without losing momentum.
        fromFrame = panel.frame
        toFrame = target
        velFrame = inFlight ? liveVel : (0, 0, 0, 0)
        startTime = CACurrentMediaTime()
        inFlight = true
        self.onSettle = onSettle
        startLink()
    }

    private func startLink() {
        if link == nil {
            var l: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&l)
            if let l {
                CVDisplayLinkSetOutputHandler(l) { [weak self] _, _, _, _, _ in
                    DispatchQueue.main.async { self?.tick() }
                    return kCVReturnSuccess
                }
                link = l
            }
        }
        if let link { CVDisplayLinkStart(link) }
    }

    private func tick() {
        guard let panel, inFlight else { stop(); return }
        let t = CACurrentMediaTime() - startTime

        func axis(_ from: Double, _ to: Double, _ v0: Double) -> (Double, Double) {
            let r = spring.value(at: t, from: from, to: to, initialVelocity: v0)
            return (r.position, r.velocity)
        }
        let (w, vw) = axis(Double(fromFrame.width),  Double(toFrame.width),  velFrame.w)
        let (h, vh) = axis(Double(fromFrame.height), Double(toFrame.height), velFrame.h)
        let (x, vx) = axis(Double(fromFrame.minX),   Double(toFrame.minX),   velFrame.x)
        let (y, vy) = axis(Double(fromFrame.minY),   Double(toFrame.minY),   velFrame.y)
        liveVel = (vw, vh, vx, vy)

        panel.setFrame(NSRect(x: x, y: y, width: max(1, w), height: max(1, h)), display: true)

        let settled = spring.isSettled(at: t, from: Double(fromFrame.width), to: Double(toFrame.width), initialVelocity: velFrame.w)
        if settled || t > DesignTokens.Motion.morphSettleCap {
            panel.setFrame(toFrame, display: true)
            inFlight = false
            stop()
            onSettle?()
            onSettle = nil
        }
    }

    /// Pause the display link without clearing target state. Call before an
    /// entrance/exit alpha animation so two frame drivers never run at once.
    func stop() {
        if let link { CVDisplayLinkStop(link) }
    }

    deinit { if let link { CVDisplayLinkStop(link) } }
}
```

> The interruptible-velocity claim is now delivered: `tick()` records the live per-axis velocity, and `animate(to:)` seeds the new spring with it when `inFlight`. If frame-stepping a borderless `NSPanel` shows tearing in review, swap the `CVDisplayLink` for a `Timer(timeInterval: 1.0/120.0)` driver calling the same `tick()` — the spring math and retarget logic are unchanged.

- [ ] **Step 1a: Add `Stash/PillMorphAnimator.swift` to the Stash target** (production file in the classic `Stash` group — File Inspector → Target Membership → **Stash**, or add the `PBXBuildFile`/`PBXFileReference`/Sources entries). Required before the build in Step 2 will resolve `PillMorphAnimator`.

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Stash/PillMorphAnimator.swift
git commit -m "feat(motion): spring-driven interruptible PillMorphAnimator for the capsule morph"
```

### Task 4.2: Use the spring morph for phase frames; strong ease-out for entrance/exit

**Files:**
- Modify: `Stash/TranscriptionFloatingWidget.swift`

- [ ] **Step 1: Hold a `PillMorphAnimator` and route `applyPanelFrame` through it for animated morphs**

In `TranscriptionFloatingWidgetController`, add:

```swift
    private var morphAnimator: PillMorphAnimator?
```

In `buildPanel()`, after `panel = p`, create it:

```swift
        morphAnimator = PillMorphAnimator(panel: p)
```

In `applyPanelFrame(_:animated:duration:timingFunction:)`, when `animated == true` AND the panel is already visible (a true morph, not an entrance), drive via the spring instead of `NSAnimationContext`:

```swift
        guard let panel else { return }
        if animated {
            if panel.isVisible && !hideInFlight, let morphAnimator {
                morphAnimator.animate(to: frame)
                return
            }
            // entrance/exit & first show keep the NSAnimationContext path but
            // use the strong ease-out curve from Motion tokens:
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = timingFunction ?? DesignTokens.Motion.caEaseOut()
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
```

- [ ] **Step 2: Stop the morph before any entrance/exit (fixes review D4 — no two frame drivers at once)**

The spring morph and the `NSAnimationContext` alpha+slide animations both call `setFrame` on the same panel; running them concurrently stutters. Guard against it: at the **head** of `showCollapsedPanelIfNeeded()` (right after `guard let panel`) and `hidePanel()` (right after `guard let panel, panel.isVisible`), add:

```swift
        morphAnimator?.stop()   // never let a spring morph fight the entrance/exit frame animation
```

Because `applyPanelFrame` already routes to the spring ONLY when `panel.isVisible && !hideInFlight`, and entrance/exit set `hideInFlight`/run while alpha animates, the morph path and the alpha-animation path are now mutually exclusive: morphs happen only between two fully-visible, settled phases.

- [ ] **Step 3: Swap the slide+fade entrance/exit timing functions to strong ease-out**

In `showCollapsedPanelIfNeeded()` and `hidePanel()`, replace `CAMediaTimingFunction(name: .easeInEaseOut)` with `DesignTokens.Motion.caEaseOut()` (entrances/exits are ease-out per emil). Keep the slide offsets + durations from `PanelAnimation`.

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Stash/TranscriptionFloatingWidget.swift
git commit -m "feat(pill): spring morph for phase frames, strong ease-out entrance/exit, no driver overlap"
```

### Task 4.3: Masked blur+opacity crossfade for content; entrance from scale 0.96

**Files:**
- Modify: `Stash/TranscriptionFloatingWidget.swift`

- [ ] **Step 1: Add a blur+opacity transition and apply it to pill content**

Add a reusable transition and modifier near `TranscriptionPillView`:

```swift
/// Crossfade that blurs both layers during the swap so two crisp text layers
/// never overlap (emil: "use blur to mask imperfect transitions"). Falls back
/// to plain opacity under reduce-motion.
private struct BlurFadeModifier: ViewModifier {
    let active: Bool   // true = mid-transition (blurred + transparent)
    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .blur(radius: active ? DesignTokens.Pill.crossfadeBlurRadius : 0)
            .scaleEffect(active ? DesignTokens.Pill.entranceScale : 1)
    }
}

private extension AnyTransition {
    static var maskedCrossfade: AnyTransition {
        if DesignTokens.Motion.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: BlurFadeModifier(active: true), identity: BlurFadeModifier(active: false))
                .animation(.easeOut(duration: DesignTokens.Pill.crossfadeInDuration)
                    .delay(DesignTokens.Pill.crossfadeInDelay)),
            removal: .modifier(active: BlurFadeModifier(active: true), identity: BlurFadeModifier(active: false))
                .animation(.easeOut(duration: DesignTokens.Pill.crossfadeOutDuration))
        )
    }
}
```

Replace the existing `asymmetricContentTransition` usages (`.transition(asymmetricContentTransition)`) on the processing branch and the full-pill branch with `.transition(.maskedCrossfade)`.

- [ ] **Step 1b: Force identity change on every message swap so the crossfade ALSO fires within the full-pill branch (fixes review D5)**

The `Group { if processing … else fullPill }` only changes view identity when crossing the processing↔full boundary — so a `Saved`→`Copied` swap, or the `First`→`Second`→`Third` supersession stack, would re-render the same `Text` with NO transition. Attach `.id(PillPhaseKey(mode))` to the full-pill content so each distinct completion message is a distinct identity, making SwiftUI insert/remove (and run `maskedCrossfade`) on every message change. Wrap the HStack:

```swift
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
                .id(PillPhaseKey(mode))                 // distinct identity per message → crossfade on swap
                .transition(.maskedCrossfade)
```

`PillPhaseKey` already collapses recording timer ticks to a single `.recording` case (the `durationSeconds` is dropped), so the per-second timer does NOT churn identity — only true state/message changes do. Change the body's existing `.animation(.default, value: PillPhaseKey(mode))` to the strong curve so the insert/remove transaction uses emil timing:

```swift
        .animation(.easeOut(duration: DesignTokens.Pill.crossfadeInDuration), value: PillPhaseKey(mode))
```

> Verified against current code: `PillPhaseKey(_:)` maps `.recording → .recording` (no associated value), so `.id(PillPhaseKey(mode))` is stable across timer ticks and the timer label keeps its `transaction { $0.animation = nil }` no-crossfade pin.

- [ ] **Step 2: Add `Saved` and `Copied` glyphs**

In `completionSymbol(for:)`, add cases (keep existing):

```swift
        case "Saved":       return "checkmark"
        case "Copied":      return "doc.on.clipboard"
```

`Pasted ✓` keeps the custom `PastedConfirm` asset via `isPastedCompletion`.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Stash/TranscriptionFloatingWidget.swift
git commit -m "feat(pill): masked blur crossfade, scale-0.96 entrance, Saved/Copied glyphs"
```

### Task 4.4: Long-running drives the card; completion morphs card → Copied → hide

**Files:**
- Modify: `Stash/TranscriptionFloatingWidget.swift`

- [ ] **Step 1: Trigger the card on `isLongRunning` (time-threshold path), reuse the retry card for `isWaitingOnRetry`**

In `sync()`, before the `isProcessing` branch, add a check: if `ts.isProcessing && ts.isLongRunning` (still working, crossed threshold) → show the clipboard-promise card via `enterNotificationPhase`-style content (new content variant — see Phase 5). Keep the existing `isWaitingOnRetry` branch for the network path. Both set the card; both rely on delivery to copy + dismiss.

```swift
        if ts.isProcessing && ts.isLongRunning {
            enterLongRunningCard()
            return
        }
```

- [ ] **Step 2: On completion while a card is showing, morph card → pill `Copied` → hide, and tear down the auto-hide (fixes review D9)**

When a `completionMessage` arrives while the card is up, clear the notification AND cancel the 5-min auto-hide + reset the dismissed flag, so a stale `notificationAutoHideWork` can't fire later and `dismissNotification()` mid-pill. Add at the top of the `if let msg = ts.completionMessage` block:

```swift
            if displayState.notification != nil || notificationAutoHideWork != nil {
                clearNotification()   // cancels notificationAutoHideWork + resets notificationDismissed + nils displayState.notification
            }
```

`clearNotification()` already exists and does exactly this teardown; reusing it (instead of only `displayState.notification = nil`) is DRY and closes the stale-timer leak. Clearing happens inside the same animated transaction that sets the completion mode, so the card morphs into the pill (no hide/show flicker).

- [ ] **Step 2a: Also reset the threshold card teardown when the wait ends**

In `clearNotification()` no change is needed, but ensure the time-threshold path resets too: in `sync()`, when neither `isProcessing && isLongRunning` nor `isWaitingOnRetry` holds and a notification is still showing, the existing "Not waiting anymore — clear any notification state" branch (`if phase == .notification || displayState.notification != nil { clearNotification() }`) now also covers the threshold card because both use the same `displayState.notification`. Confirm that branch is reached for the threshold path (it is — the new `isProcessing && isLongRunning` guard returns early only while still processing).

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Stash/TranscriptionFloatingWidget.swift
git commit -m "feat(pill): long-running card on threshold; morph card→Copied→hide on completion"
```

---

## Phase 5 — Long-running card copy

### Task 5.1: Clipboard-promise card content

**Files:**
- Modify: `Stash/TranscriptionFloatingWidget.swift` (add `enterLongRunningCard()`)

- [ ] **Step 1: Add the card-entry helper**

```swift
    /// Long-running (threshold-crossed) card: promises a clipboard copy so the
    /// user can walk away. Reuses the notification surface + auto-hide.
    private func enterLongRunningCard() {
        let content = NotificationContent(
            title: "Taking longer than usual",
            message: "We'll copy your transcript to the clipboard when it's ready",
            primaryLabel: "Open Notes",
            secondaryLabel: "Hide"
        )
        let oldPhase = phase
        let firstShow = (phase != .notification)
        cancelAllPendingWork()
        phase = .notification
        heldCompletionMessage = nil
        if displayState.notification != content { displayState.notification = content }
        applyPhaseFrame(animated: oldPhase != .none)
        showCollapsedPanelIfNeeded()
        if firstShow { startNotificationAutoHide() }
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Stash/TranscriptionFloatingWidget.swift
git commit -m "feat(pill): clipboard-promise copy for the long-running card"
```

> `TranscriptionStatusNotification.swift` view itself needs no structural change — it is fully parameterized. Update the stale doc comment that references a non-existent `StatusPanelController` to name `TranscriptionFloatingWidgetController` (one-line doc fix, same commit acceptable).

---

## Phase 6 — Debug menu

### Task 6.1: Wire new delivery-state selectors + visible pending-sessions alert

**Files:**
- Modify: `Stash/StashApp.swift`

- [ ] **Step 1: Update `debugMenuItems()` with the real delivery states**

Replace the stale `("Test pill: filter rejection", …)` / `("Test pill: cleanup failure", …)` rows with the actual delivery states, keeping the warnings/stacking rows:

```swift
            ("Test pill: Pasted ✓",          #selector(debugTestPillPasted)),
            ("Test pill: Saved",             #selector(debugTestPillSaved)),
            ("Test pill: Copied",            #selector(debugTestPillCopied)),
            ("Test pill: No audio",          #selector(debugTestPillNoAudio)),
            ("Test pill: Failed",            #selector(debugTestPillFailed)),
            ("Test pill: 5 min warning",     #selector(debugTestPill5MinWarning)),
            ("Test pill: 90-min warning",    #selector(debugTestPill90MinHardStop)),
            ("Test pill: 20-MB warning",     #selector(debugTestPill20MBWarning)),
            ("Test pill: 24-MB warning",     #selector(debugTestPill24MBHardStop)),
            ("Test pill: state stacking",    #selector(debugTestPillStacking)),
            ("Test: simulate network failure on next upload", #selector(debugSimulateNextUploadFailure)),
            ("Test: drain retry queue now",  #selector(debugDrainRetryQueue)),
            ("Test: list pending sessions",  #selector(debugListPendingSessions)),
            ("Test: show long-running card", #selector(debugShowStatusNotification)),
```

- [ ] **Step 2: Add/replace the selector bodies**

```swift
    @objc private func debugTestPillPasted()  { debugFirePill("Pasted ✓") }
    @objc private func debugTestPillSaved()   { debugFirePill("Saved") }
    @objc private func debugTestPillCopied()  { debugFirePill("Copied") }
    @objc private func debugTestPillNoAudio() { debugFirePill("No audio") }
    @objc private func debugTestPillFailed()  { debugFirePill("Failed") }
```

(Delete `debugTestPillRejection`, `debugTestPillCleanupFailure`, `debugTestPillNetworkTimeout` — replaced above.) The warning/hard-stop selectors must fire the EXACT production strings so the debug menu renders the real pill (fixes review D8). Update their bodies to mirror `TranscriptionService.showCompletion` callers — `"5 min left"` and `"Almost full"` already match; change the 90-min and 24-MB ones to also use real warning copy with the warning hold:

```swift
    @objc private func debugTestPill5MinWarning()   { debugFirePill("5 min left",  hold: DesignTokens.Pill.completionWarningHold) }
    @objc private func debugTestPill90MinHardStop() { debugFirePill("1 min left",  hold: DesignTokens.Pill.completionWarningHold) }
    @objc private func debugTestPill20MBWarning()   { debugFirePill("Almost full", hold: DesignTokens.Pill.completionWarningHold) }
    @objc private func debugTestPill24MBHardStop()  { debugFirePill("Almost full", hold: DesignTokens.Pill.completionWarningHold) }
```

- [ ] **Step 2a: Add glyph cases for the warning strings (so they render faithfully, not a default checkmark)**

In `TranscriptionFloatingWidget.swift` `completionSymbol(for:)`, add:

```swift
        case "5 min left", "1 min left":  return "clock"
        case "Almost full":               return "exclamationmark.triangle"
```

This keeps the debug-fired warnings visually distinct from the success states (emil: the debugger must let you VIEW every state faithfully). Real production warnings already use these exact strings.

- [ ] **Step 3: Make pending-sessions show an `NSAlert`**

```swift
    @objc private func debugListPendingSessions() {
        Task { @MainActor in
            let sessions = await TranscriptionRetryQueue.shared.pendingSnapshot()
            let body: String
            if sessions.isEmpty {
                body = "No pending sessions."
            } else {
                body = sessions.map { s in
                    "• \(s.sessionUUID.uuidString.prefix(8)) — \(s.durationSeconds)s, attempts \(s.attemptCount), error: \(s.lastError ?? "none")"
                }.joined(separator: "\n")
            }
            let alert = NSAlert()
            alert.messageText = "Pending sessions (\(sessions.count))"
            alert.informativeText = body
            alert.runModal()
        }
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Stash/StashApp.swift
git commit -m "feat(debug): wire Pasted/Saved/Copied/No audio/Failed selectors; visible pending-sessions alert"
```

---

## Phase 7 — Verify, format, lint, finalize

### Task 7.1: Full build + test + format + lint

- [ ] **Step 1: Full build**

Run: `xcodebuild -scheme Stash -configuration Debug build 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Full test suite**

Run: `xcodebuild test -scheme Stash -destination 'platform=macOS' 2>&1 | tail -25`
Expected: all suites pass, including `SpringTests`, `DeliveryDecisionTests`, `PasteTargetClassifierTests`, `RawFirstDeliveryTests`.

- [ ] **Step 3: Format + lint**

Run: `swiftformat Stash StashTests && swiftlint --quiet`
Expected: no errors; warnings reviewed.

- [ ] **Step 4: Manual state walkthrough (debug menu)**

Launch the app, open the status-bar Debug submenu, fire each: `Pasted ✓`, `Saved`, `Copied`, `No audio`, `Failed`, the four warnings, state stacking, long-running card. Confirm per emil checklist (slow-motion if possible): no ghost flash, no stuck state, no two-text overlap during width morph, spring settles, reduce-motion (System Settings → Accessibility → Display → Reduce motion) drops spring+blur to opacity.

- [ ] **Step 5: Commit any format/lint deltas**

```bash
git add -A
git commit -m "style: swiftformat + swiftlint pass"
```

### Task 7.2: /simplify pass + PR

- [ ] **Step 1:** Run the `simplify` review on the branch diff; apply reuse/altitude cleanups (quality only).
- [ ] **Step 2:** Confirm no "do not touch" file changed unexpectedly: `git diff --stat main...HEAD` — expect only the files in this plan.
- [ ] **Step 3:** Open PR with Conventional Commits title `feat: airtight transcription delivery + best-in-class pill morph`.

---

## Self-Review

**1. Spec coverage:**
- Delivery two cases + fallback + long-running → Phase 1 (decision), Phase 3 (execution). ✅ (truth table)
- Pill state machine, all states/transitions, no ghost/stuck, supersession → Phase 4 (existing supersession kept; card→pill morph added). ✅
- Animation (strong curves, <300ms, subtle-bounce spring for morph only, never scale(0), interruptible, reduce-motion, masked crossfade, tokens) → Phase 0 + 4. ✅
- List structuring in pasted output → Phase 3.1/3.3 (cleanup-before-paste uses `promptShortClean`, which already formats spoken enumeration; pasted text is the cleaned text). ✅
- Latency architecture (where LLM pass is worth it) → documented decision + Phase 3.1 timeout/raw-fallback; long path unchanged. ✅
- Debugger (wire states + visible alert) → Phase 6. ✅

**2. Placeholder scan:** No "TBD/implement later"; every code step shows real code. Interruptible velocity is now fully implemented in `PillMorphAnimator` (no deferred placeholder).

**3. Type consistency:** `PasteTarget` (`.editable/.noTarget/.secureField`) used identically in classifier + `classifyTarget(capturedFrontmostBundleID:)` + decision + service. `PasteOutcome` (`.verifiedPasted/.attemptedUnverified/.noPermission/.failed`) consistent. `DeliveryDecision.Outcome { pill; clipboard }` and `Clipboard { none, writeTranscript }` consistent across resolver + service. `Spring(response:dampingRatio:)` + `value(at:from:to:initialVelocity:)` consistent across solver + animator + tests. `cleanupShortWithTimeout(_:timeout:)` signature consistent between helper, default, and DEBUG seam. Pill strings (`"Pasted ✓"`, `"Saved"`, `"Copied"`, `"No audio"`, `"Failed"`, `"5 min left"`, `"1 min left"`, `"Almost full"`) consistent across `DeliveryDecision`, `completionSymbol`, and debug selectors.

**4. Review-round-2 fixes applied (from the 6.5/10 scoring pass):**
- D2 (classification timing): classify from stop-time `metadata.frontmostAppBundleID`, not live frontmost — Task 1.1 + 2.1 + 3.3.
- D3 (long-running TOCTOU): re-read `isLongRunning` after cleanup, inside the delivery `Task` — Task 3.3.
- D4 (two frame drivers): `morphAnimator.stop()` at the head of entrance/exit; morph runs only between settled visible phases — Task 4.2.
- D5 (crossfade misses same-branch swaps): `.id(PillPhaseKey(mode))` forces identity change per message — Task 4.3.
- D6 (interruptible velocity): `tick()` records live velocity; `animate(to:)` reseeds it — Task 4.1.
- D7 (TDD red-first): cleanup tests written + run RED before the helper, with a deterministic injected-timeout case — Task 3.1.
- D8 (debug glyph fidelity): warning selectors fire real production strings + dedicated glyph cases — Task 6.1.
- D9 (card teardown): completion reuses `clearNotification()` to cancel the 5-min auto-hide — Task 4.4.
- D10 (file targets): corrected with the TRUE pbxproj shape — only `StashTests` is a synchronized root group (test files auto-compile); `Stash` is a classic `PBXGroup`, so the 4 new production files (`Spring`, `PillMorphAnimator`, `DeliveryDecision`, `PasteTargetClassifier`, now flat in `Stash/`) each have an explicit "add to Stash target" step.
- Clipboard model simplified: single service-owned write guarded by `changeCount`; no `leaveOnClipboard` plumbing — Task 2.1 + 3.3.

**5. Review-round-3 fixes (from the 7.5/10 re-score):**
- Long path no longer leaves `isProcessing` stuck: `uploadSession` clears the floor for `.longNote` intent only; the short path clears itself after cleanup — Task 3.3 Step 1. `deliverTranscriptLong` untouched (LOCKED).
- `deliverTranscriptShort` is now `async` and awaited by `deliverTranscript` → `uploadSession` returns `true` only after delivery resolves (tighter success contract; no detached Task) — Task 3.3 Step 2.
- `AutoPasteService` top-of-file doc rewritten to the new clipboard contract — Task 2.1 Step 1a (completes D1).

**Remaining low risk:** `CVDisplayLink` tearing on a borderless panel — documented `Timer(1/120)` fallback with identical `tick()`; acceptance criterion unchanged (subtle-bounce spring, no clipping, no double-text).
