import AppKit
import ApplicationServices

/// Snapshot of the user's paste-target intent, captured at the moment they
/// begin a recording. The user may switch apps mid-recording (handled by
/// re-activation at paste time), close the captured window (handled by the
/// element re-validation gate), or have nothing focused at capture time
/// (handled by the nil-element path → morph fallback). Either way, intent
/// is set at start, not inferred at end.
struct CapturedPasteTarget {
    /// The frontmost app at capture time. Held strong; checked for
    /// termination at paste time.
    let app: NSRunningApplication
    /// Bundle ID cached at capture time so diagnostics survive even if
    /// `app` becomes terminated and `bundleIdentifier` returns nil.
    let appBundleID: String
    /// Focused element at capture time, or nil if AX exposed nothing.
    /// nil is a meaningful signal — caller should treat it as "user wasn't
    /// in a text input when they started dictating" and morph at paste
    /// time without attempting Strategy 2.
    let element: AXUIElement?
    /// For diagnostics only.
    let capturedAt: Date

    /// True if the captured app process is still running. Element validity
    /// is checked separately at paste time via an AX query, since
    /// `AXUIElement` references can outlive their underlying UI.
    var isAppStillAlive: Bool {
        !app.isTerminated
    }
}

/// Pastes short voice-transcripts directly into the user's currently-focused
/// text field. Two strategies in order:
///   1. AXUIElement direct value write (clean, app-cooperative apps).
///   2. CGEvent ⌘V with pasteboard preservation (universal fallback).
///
/// Caller should treat any non-`.success` result as a signal to fall back to
/// the floating-pill morph. The service is intentionally synchronous — both
/// strategies complete in a few ms or fail fast.
@MainActor
final class AutoPasteService {

    static let shared = AutoPasteService()
    private init() {}

    enum InsertResult {
        case success
        /// User hasn't granted Accessibility permission. Caller can prompt
        /// via `requestAccessibilityPermission()` from a user-initiated UI
        /// action (e.g., the permissions onboarding screen).
        case noPermission
        /// No insertable text field has focus right now (or the focused
        /// element is read-only / a secure field / the focused app is
        /// Stash itself).
        case noFocusedField
        /// Permission and target both fine, but the insertion call returned
        /// failure or the pasteboard write didn't take.
        case insertionFailed
    }

    /// Hard deadline for the strategy chain. Apple's AX framework has no
    /// documented timeouts; a stuck `AXUIElementSetAttributeValue` would
    /// otherwise freeze the main thread indefinitely.
    private static let attemptDeadlineSeconds: TimeInterval = 5.0

    /// Pre-flight skip threshold for Strategy 1. AX value writes scale poorly
    /// in some Electron AX implementations — large strings can take seconds
    /// or silently truncate. Strategy 2 (synthetic ⌘V) is constant-time
    /// regardless of length, so route long transcripts straight to it.
    private static let strategy1MaxTextLength = 500

    /// Per-call token for the active paste. Strategy 2's pasteboard restore
    /// compares against this; if a newer paste superseded ours, the older
    /// restore is silently cancelled (the newer paste's token now owns the
    /// service). The `changeCount` guard remains as the secondary safety
    /// against clobbering a user copy.
    private var currentPasteToken: UUID?

    /// Polling timer for `AXIsProcessTrusted`. Active only while a UI
    /// surface (currently SettingsView) is observing — see `startPermissionPolling`
    /// / `stopPermissionPolling`. Nil when no observer is attached.
    /// Posts `.accessibilityStatusChanged` (declared in AppSettings.swift
    /// alongside the rest of the project's notification names) on flip.
    private var pollingTimer: Timer?
    private var lastPolledTrusted: Bool = false

    /// True iff the process is currently in the Accessibility-trusted list.
    /// Cheap read; safe to call frequently.
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Trigger the macOS Accessibility prompt. Only call from a user-
    /// initiated context (button click in onboarding/settings) — calling
    /// at app launch produces a confusing prompt the user can't action.
    func requestAccessibilityPermission() {
        // `kAXTrustedCheckOptionPrompt` is imported as `Unmanaged<CFString>!`.
        // Use `takeUnretainedValue()` (this is a get-accessor, not a create-
        // accessor — using `takeRetainedValue()` would leak a retain).
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options: CFDictionary = [key: kCFBooleanTrue!] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Intent capture

    /// Snapshot the user's paste-target intent. Call this at record START,
    /// before any state mutation in `TranscriptionService.startRecording`,
    /// so the snapshot reflects the user's environment at the moment they
    /// chose to dictate.
    ///
    /// Returns nil only when Stash itself is frontmost (the self-paste guard).
    /// All other cases produce a non-nil target — the `element` field may
    /// still be nil if AX exposed no focused UI at capture time, which is a
    /// distinct signal the caller uses to route to morph instead of pasting
    /// blindly.
    func captureTarget() -> CapturedPasteTarget? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            #if DEBUG
            print("[AutoPaste] captureTarget — no frontmost application")
            #endif
            return nil
        }
        guard frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            #if DEBUG
            print("[AutoPaste] captureTarget — Stash itself is frontmost; self-guard fires")
            #endif
            return nil
        }
        let element = focusedElement(in: frontApp)
        #if DEBUG
        print("[AutoPaste] captureTarget — app: \(frontApp.bundleIdentifier ?? "?"), element: \(element != nil ? "present" : "absent")")
        #endif
        return CapturedPasteTarget(
            app: frontApp,
            appBundleID: frontApp.bundleIdentifier ?? "",
            element: element,
            capturedAt: Date()
        )
    }

    // MARK: - Permission polling

    /// Start a 1s polling loop on `AXIsProcessTrusted`. Posts
    /// `accessibilityStatusChangedNotification` whenever the value flips.
    ///
    /// macOS exposes no AX-tree notification for the per-process trusted
    /// flag (Apple has not surfaced one and there is no
    /// kAXTrustedStateChangedNotification). Polling is the only way to
    /// react to a System-Settings toggle while our own window is in front.
    /// Caller is responsible for matching `stopPermissionPolling` when
    /// the observing UI goes away — keeps us from burning CPU on a 1Hz
    /// AX read in the background.
    func startPermissionPolling() {
        guard pollingTimer == nil else { return }
        lastPolledTrusted = hasAccessibilityPermission
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPermissionState() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollingTimer = timer
    }

    func stopPermissionPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func pollPermissionState() {
        let current = hasAccessibilityPermission
        guard current != lastPolledTrusted else { return }
        lastPolledTrusted = current
        NotificationCenter.default.post(name: .accessibilityStatusChanged, object: nil)
    }

    /// Attempt to insert `text` into the user's captured paste target. The
    /// target is snapshotted at record start (see `captureTarget()`), NOT
    /// inferred at paste time — that snapshot is the source of truth for
    /// "where did the user intend this transcript to go." This eliminates
    /// the post-hoc paste-landing inference that produced silent data loss
    /// in apps where Strategy 2's synthetic ⌘V can be swallowed (Claude
    /// with no clicked prompt, Finder on desktop, modal dialogs, etc.).
    ///
    /// Flow:
    ///   1. Permission gate (`AXIsProcessTrusted`).
    ///   2. `target == nil` → `.noFocusedField` (caller morphs).
    ///   3. App still alive? If not, `.insertionFailed`.
    ///   4. Re-activate the captured app if it isn't frontmost (user may
    ///      have switched apps mid-recording — re-route to where they
    ///      intended).
    ///   5. Re-validate the captured element via `kAXRoleAttribute` query.
    ///      If invalid, treat as element-nil → `.noFocusedField`.
    ///   6. Element-non-nil path:
    ///      a. Secure-field guard.
    ///      b. Standard-role: Strategy 1 with read-back verification.
    ///      c. Otherwise: Strategy 2 with element-aware AXValue read-back
    ///         verification (75ms wait, see `writeViaCGEventPaste(_:token:into:)`).
    ///   7. Element-nil path: `.noFocusedField`. NO fake ⌘V into the void.
    func attemptInsert(text: String, into target: CapturedPasteTarget?) -> InsertResult {
        let token = UUID()
        currentPasteToken = token
        let deadline = Date().addingTimeInterval(Self.attemptDeadlineSeconds)

        guard hasAccessibilityPermission else {
            #if DEBUG
            print("[AutoPaste] noPermission — AXIsProcessTrusted() == false. Bundle: \(Bundle.main.bundlePath)")
            #endif
            return .noPermission
        }

        guard let target else {
            #if DEBUG
            print("[AutoPaste] noFocusedField — captured target was nil (Stash was frontmost at record start, or no front app)")
            #endif
            return .noFocusedField
        }

        guard target.isAppStillAlive else {
            #if DEBUG
            print("[AutoPaste] insertionFailed — captured app \(target.appBundleID) is no longer running")
            #endif
            return .insertionFailed
        }

        // Re-activate if the user switched apps mid-recording. The user's
        // intent is the captured target, not whatever happens to be frontmost
        // now. Activation is a no-op if target.app is already frontmost.
        if NSWorkspace.shared.frontmostApplication != target.app {
            #if DEBUG
            let now = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
            print("[AutoPaste] re-activating captured app \(target.appBundleID) (current frontmost: \(now))")
            #endif
            target.app.activate(options: [.activateIgnoringOtherApps])
            // 50ms for activation to settle: window-server -> app -> AX tree
            // refresh. Below this, posted events may race the activation
            // and land on the previously-frontmost app.
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        // Re-validate the captured element. AXUIElement references can outlive
        // their UI (window closed, view removed). A cheap kAXRoleAttribute
        // query is the canonical liveness check.
        let liveElement: AXUIElement? = {
            guard let element = target.element else { return nil }
            var roleRef: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                element, kAXRoleAttribute as CFString, &roleRef
            )
            if status == .success { return element }
            #if DEBUG
            print("[AutoPaste] captured element no longer valid (kAXRoleAttribute returned non-success); treating as element-nil")
            #endif
            return nil
        }()

        guard let element = liveElement else {
            #if DEBUG
            print("[AutoPaste] noFocusedField — no live element on captured target \(target.appBundleID); morph fallback")
            #endif
            return .noFocusedField
        }

        if isSecureTextElement(element) {
            #if DEBUG
            print("[AutoPaste] noFocusedField — captured element is a secure (password) field")
            #endif
            return .noFocusedField
        }

        // Re-check permission at strategy entry; user may have revoked between
        // captureTarget at record start and now (multi-second LLM round-trip).
        guard hasAccessibilityPermission else { return .noPermission }

        if isStandardWritableRole(element) {
            if writeViaAXValue(text, into: element, deadline: deadline) {
                #if DEBUG
                print("[AutoPaste] success via Strategy 1 (AXValue write). Front app: \(target.appBundleID)")
                #endif
                return .success
            }
        }

        guard hasAccessibilityPermission else { return .noPermission }
        guard !isDeadlineExceeded(deadline) else {
            return .insertionFailed
        }

        // Strategy 2 with element-aware verification — the verification logic
        // lives in writeViaCGEventPaste(_:token:into:) so we can read the
        // captured element's AXValue before/after posting ⌘V and confirm
        // the destination actually consumed the paste.
        if writeViaCGEventPaste(text, token: token, into: element) {
            #if DEBUG
            print("[AutoPaste] success via Strategy 2 (CGEvent ⌘V, verified). Front app: \(target.appBundleID)")
            #endif
            return .success
        }

        #if DEBUG
        print("[AutoPaste] insertionFailed — both strategies returned false / Strategy 2 verification failed")
        #endif
        return .insertionFailed
    }

    /// True iff `deadline` has passed. Logs the timeout for diagnostics so
    /// users hitting the 5s wall in the wild can see it in Console.
    private func isDeadlineExceeded(_ deadline: Date) -> Bool {
        guard Date() >= deadline else { return false }
        #if DEBUG
        print("[AutoPaste] 5s deadline exceeded — aborting current strategy")
        #endif
        return true
    }

    // MARK: - Focused-element discovery

    /// Returns the focused UI element of `app`, or nil if AX introspection
    /// fails. Many Electron / ToDesktop apps (Cursor, Linear desktop, etc.)
    /// don't expose their focused element via this query — that's expected
    /// and not an error. The caller treats nil as "skip Strategy 1, go
    /// straight to Strategy 2."
    ///
    /// Stash-self rejection is the caller's responsibility (kept at the
    /// call site so this helper stays a pure AX read).
    private func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let element = focused else { return nil }
        // CFGetTypeID check ensures we got an AXUIElement back, then `as!`
        // unwraps. CLAUDE.md prohibits force-casts in new code, with explicit
        // exceptions for "known-safe" framework conventions — this is one:
        // Swift rejects both `as?` ("downcast always succeeds") and unconditional
        // `as` ("not convertible") for CFTypeRef→AXUIElement, so `as!` after
        // the type-ID guard is the only legal form. Apple's own AX-framework
        // sample code uses this pattern.
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    /// True if `element`'s role is one we know how to splice via Strategy 1
    /// (AXValue write). Anything else falls through to Strategy 2.
    /// Safari/Chrome contenteditable, Electron editors, etc. report
    /// AXGroup/AXScrollArea — those won't match here, and that's expected.
    private func isStandardWritableRole(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else {
            return false
        }
        switch role {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
            return true
        default:
            return false
        }
    }

    /// True iff the focused element is a secure (password) text field.
    /// Pasting a transcript into one is a serious privacy fail — caller
    /// must reject this case before either strategy runs.
    private func isSecureTextElement(_ element: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String else {
            return false
        }
        return subrole == kAXSecureTextFieldSubrole
    }

    // MARK: - Strategy 1: AXUIElement direct value write

    /// Write the new text value via AXUIElementSetAttributeValue at
    /// `kAXValueAttribute`. Reads current value + selected range, splices
    /// `text` into the selected range (or appends if no selection), writes
    /// back, and bumps the selected range to the end of the inserted text
    /// so the caret lands AFTER the inserted transcript.
    ///
    /// Returns true on confirmed success. Returns false on any AX failure,
    /// deadline expiry, or pre-flight length skip — caller falls through
    /// to Strategy 2.
    private func writeViaAXValue(_ text: String, into element: AXUIElement, deadline: Date) -> Bool {
        if text.count > Self.strategy1MaxTextLength {
            #if DEBUG
            print("[AutoPaste] Skipping Strategy 1 (text \(text.count) chars exceeds threshold \(Self.strategy1MaxTextLength))")
            #endif
            return false
        }
        if isDeadlineExceeded(deadline) { return false }

        var valueRef: CFTypeRef?
        let valueStatus = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        )
        let currentValue = (valueStatus == .success ? (valueRef as? String) : nil) ?? ""
        if isDeadlineExceeded(deadline) { return false }

        // Some elements don't expose a selected range — treat as append-at-end.
        var rangeRef: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        )
        var selRange = CFRange(location: (currentValue as NSString).length, length: 0)
        if rangeStatus == .success, let cfRange = rangeRef,
           CFGetTypeID(cfRange) == AXValueGetTypeID() {
            // `as!` after the type-ID guard — same exception story as
            // `focusedElement`'s AXUIElement unwrap (Swift rejects `as?`
            // and `as` for CFTypeRef→AXValue toll-free bridges).
            let axRange = cfRange as! AXValue
            if AXValueGetType(axRange) == .cfRange {
                var r = CFRange(location: 0, length: 0)
                if AXValueGetValue(axRange, .cfRange, &r) {
                    selRange = r
                }
            }
        }
        if isDeadlineExceeded(deadline) { return false }

        let nsCurrent = currentValue as NSString
        let safeLocation = max(0, min(selRange.location, nsCurrent.length))
        let safeLength = max(0, min(selRange.length, nsCurrent.length - safeLocation))
        let newValue = nsCurrent.replacingCharacters(
            in: NSRange(location: safeLocation, length: safeLength),
            with: text
        )

        let setStatus = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, newValue as CFString
        )
        guard setStatus == .success else { return false }
        if isDeadlineExceeded(deadline) { return false }

        // Verify the write actually took effect. Many Electron apps (Claude
        // desktop, VS Code, Slack, Discord) return `.success` from
        // setAttributeValue without applying the change — their AX tree is
        // a read-only mirror of DOM state, so writes silently no-op. Read
        // the value back and require it to have changed; otherwise bail so
        // the caller falls through to Strategy 2 (synthetic ⌘V), which
        // those apps DO honor.
        var verifyRef: CFTypeRef?
        let verifyStatus = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &verifyRef
        )
        guard verifyStatus == .success,
              let verifiedValue = verifyRef as? String,
              verifiedValue != currentValue else {
            #if DEBUG
            print("[AutoPaste] Strategy 1 silent no-op (value unchanged after write) — falling through to Strategy 2")
            #endif
            return false
        }

        // Move the caret to the end of the inserted text. Best-effort —
        // not all elements honor selected-range writes.
        let newCaret = safeLocation + (text as NSString).length
        var newRange = CFRange(location: newCaret, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, axRange
            )
        }
        return true
    }

    // MARK: - Strategy 2: CGEvent ⌘V with pasteboard preservation

    /// Universal fallback with element-aware verification: snapshot the
    /// pasteboard, write `text` to it, post a synthetic ⌘V via CGEvent,
    /// wait 75ms, then read the captured `element`'s AXValue length to
    /// confirm the destination actually consumed the paste. Pasteboard is
    /// restored 300ms later (token + changeCount gated).
    ///
    /// Returns true ONLY when verification passes (or the element refuses
    /// AXValue reads — optimistic success, rare). Returns false when the
    /// destination silently swallowed the paste, or when event creation
    /// or the pasteboard write fails outright.
    private func writeViaCGEventPaste(_ text: String, token: UUID, into element: AXUIElement) -> Bool {
        // Build the four-event ⌘V sequence FIRST. If event creation fails
        // we abort BEFORE clobbering the pasteboard, so the user's clipboard
        // stays intact and the caller falls through to .insertionFailed.
        //
        // CMD↓, V↓, V↑, CMD↑ — setting .maskCommand on V alone works for
        // native AppKit but Electron apps (Claude desktop, VS Code, Slack)
        // and Chromium contenteditable (WhatsApp Web, Notion, Linear, Gmail)
        // listen for the explicit CMD modifier keyDown/keyUp events to flip
        // their internal modifier state. Without those bracketing events,
        // the V keypress arrives without an active "command" state and is
        // treated as plain "v".
        //
        // `.combinedSessionState` is the correct stateID for events posted
        // on behalf of the user — modifier flags flow into session state
        // and are visible to the destination process. `.hidSystemState`
        // sources from the *physical* hardware state, which Electron
        // occasionally sees as "no modifier is held" because no real CMD
        // key is pressed.
        let source = CGEventSource(stateID: .combinedSessionState)
        // Virtual key 9 == kVK_ANSI_V; 55 (0x37) == kVK_Command. CGEvent uses
        // physical scancodes, so this is layout-independent.
        let vKey: CGKeyCode = 9
        let cmdKey: CGKeyCode = 55
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) else {
            return false
        }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []

        // Read element's AXValue length BEFORE the paste. If unreadable
        // (some apps refuse this query for non-AXTextField elements), we
        // treat it as "verification unavailable" → optimistic success after
        // posting. Length is in NSString units (UTF-16 code units),
        // matching how setValue measures the splice in Strategy 1.
        let beforeLength = readAXValueLength(of: element)

        let pb = NSPasteboard.general

        // Snapshot existing items now (after event-build success, before our
        // own write). Walking each item's types and copying their Data can
        // be MB-sized for an image clipboard — deferring past the event-build
        // guard means we never pay this for the rare event-creation failure.
        // Lazily-loaded items (file promises, drag-from-Photos) won't round-
        // trip — known limitation; most clipboards are text/image which do.
        let snapshot: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }

        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }
        // Snapshot the changeCount AFTER our write so we can detect a user
        // copying-during-the-restore-window and avoid clobbering their copy.
        let changeCountAtWrite = pb.changeCount

        // Pre-paste delay: 25ms for the pasteboard server to propagate our
        // setString to other processes. Electron apps read the pasteboard
        // via Mach IPC in response to keydown — without this gap, fast
        // renderers occasionally read the OLD pasteboard contents. Below
        // human-perception threshold, reliably above daemon commit latency.
        // Synchronous so the post and verify happen in the same logical op.
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.025))

        cmdDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)

        // Restore the original pasteboard after the destination has consumed
        // our paste. 300ms accounts for the 25ms pre-paste delay plus the
        // slower IPC round-trip in Electron apps.
        //
        // Two guards before restoring:
        //   1. Token — newer paste superseded us; their token now owns the
        //      service. Skip our restore so we don't clobber their write.
        //   2. changeCount — user (or another agent) copied between our
        //      write and our restore. Their copy wins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self else { return }
            guard self.currentPasteToken == token else { return }
            guard pb.changeCount == changeCountAtWrite else { return }
            pb.clearContents()
            for itemDict in snapshot {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    item.setData(data, forType: type)
                }
                pb.writeObjects([item])
            }
        }

        // Verification: wait 75ms for the destination app's paste handler
        // to process the ⌘V and update the element's value, then read
        // AXValue length and check whether it grew by at least our text's
        // length.
        //
        // 75ms covers native AppKit (~5–15ms) and Electron's Mach IPC
        // round-trip (~30–80ms). Below 50ms, slow Electron renderers under
        // load occasionally haven't written yet (false negative). Above
        // 100ms, the chance of the user typing additional characters in
        // the destination grows (false positive — but in the GOOD direction:
        // paste did land, just with extra chars).
        RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.075))

        let afterLength = readAXValueLength(of: element)

        // Verification disposition:
        //   - beforeLength nil OR afterLength nil → AXValue unreadable for
        //     this element. Optimistic success — most apps in this category
        //     (some Electron text fields) DO accept synthetic ⌘V; the
        //     morph path remains as user-driven recovery.
        //   - afterLength - beforeLength >= text.length (in UTF-16 units) →
        //     paste landed. Success.
        //   - Otherwise → paste was swallowed. Insertion failed.
        guard let before = beforeLength, let after = afterLength else {
            #if DEBUG
            print("[AutoPaste] Strategy 2 verification skipped (AXValue unreadable on element); optimistic success")
            #endif
            return true
        }

        let textLengthInUTF16 = (text as NSString).length
        if after - before >= textLengthInUTF16 {
            #if DEBUG
            print("[AutoPaste] Strategy 2 verified: AXValue grew \(after - before) UTF-16 units (text was \(textLengthInUTF16))")
            #endif
            return true
        }

        #if DEBUG
        print("[AutoPaste] Strategy 2 verification failed: AXValue did not grow (\(before) → \(after); text was \(textLengthInUTF16) UTF-16 units). Paste was swallowed.")
        #endif
        return false
    }

    /// Read the current AXValue's length in UTF-16 code units, or nil if
    /// unreadable. Used by Strategy 2 verification — caller treats nil as
    /// "verification unavailable, optimistic success."
    private func readAXValueLength(of element: AXUIElement) -> Int? {
        var valueRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        )
        guard status == .success, let value = valueRef as? String else {
            return nil
        }
        return (value as NSString).length
    }
}
