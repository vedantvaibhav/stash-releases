import AppKit
import ApplicationServices

/// Pastes short voice-transcripts directly into the user's currently-focused
/// text field. Two strategies in order:
///   1. AXUIElement direct value write (clean, app-cooperative apps).
///   2. CGEvent ⌘V with pasteboard preservation (universal fallback).
///
/// One of three delivery channels for short transcripts. The caller
/// (`TranscriptionService.deliverTranscriptShort`) ALSO writes the transcript
/// to the system pasteboard and saves a quick note to disk regardless
/// of this service's return value. So any non-`.verifiedPasted` outcome is
/// not user-data loss — the note is already saved before this is called.
/// Only `.verifiedPasted` (Strategy 1 with read-back confirmation) earns
/// the "Pasted ✓" pill.
///
/// The service is intentionally synchronous — both strategies complete in a
/// few ms or fail fast.
@MainActor
final class AutoPasteService {

    static let shared = AutoPasteService()
    private init() {}

    enum InsertResult {
        /// Strategy 1 (AX value write) ran AND its post-write read-back
        /// confirmed the focused element's value actually changed. Caller
        /// can confidently show "Pasted ✓" — we know the text landed in
        /// the focused field.
        case verifiedPasted
        /// Strategy 2 (synthetic ⌘V) posted the keyboard events. Whether
        /// the destination app actually consumed them is unobservable from
        /// the source process — Electron renderers, Finder, secure-mode
        /// fields all swallow synthetic events silently with no readable
        /// signal. Caller should show "Saved" rather than claim success
        /// dishonestly; clipboard + dictations history backstop.
        case attemptedPaste
        /// User hasn't granted Accessibility permission. Caller can prompt
        /// via `requestAccessibilityPermission()` from a user-initiated UI
        /// action (e.g., the permissions onboarding screen).
        case noPermission
        /// Paste was skipped or both strategies aborted before posting:
        /// Stash itself frontmost (we never paste into our own UI), focused
        /// element is a secure field (privacy guard), Strategy 2 event-
        /// creation failed outright, or the 5s deadline expired before
        /// Strategy 2 could start. Caller should surface "Saved".
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

    /// Strategy 2 saves the user's previous pasteboard, writes the transcript,
    /// posts ⌘V, and restores the saved contents this many seconds later.
    /// Public so the caller can sequence its own pasteboard writes after the
    /// restore window closes (otherwise our restore could clobber a clipboard
    /// write the caller did right after attemptInsert returned).
    public static let pasteboardRestoreDelaySeconds: TimeInterval = 0.30

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

    /// Attempt to insert `text` at the focused field's caret. Synchronous;
    /// returns within a few ms (or up to 5s on a stuck AX server, after which
    /// it aborts cleanly).
    ///
    /// Hard deadline: every AX call boundary inside Strategy 1 is checked
    /// against `Date()` and aborts cleanly on timeout, falling through to
    /// Strategy 2 (which is queue-based and never blocks). If Strategy 2
    /// itself can't even start (deadline exceeded before its entry), we
    /// return `.insertionFailed` without writing the pasteboard.
    ///
    /// Concurrent pastes: a per-call `UUID` is stored in `currentPasteToken`
    /// at entry. Strategy 2's restore closure checks that token before
    /// touching the pasteboard. A newer paste setting a fresh token
    /// implicitly cancels the older paste's pending restore.
    ///
    /// Permission: re-checked at the head of each strategy. The user can
    /// revoke Accessibility from System Settings while we're mid-flight
    /// (especially during a multi-second LLM round-trip); we want to surface
    /// `.noPermission` cleanly in that case rather than running with stale
    /// state and reporting bogus success.
    ///
    /// Flow:
    ///   1. Permission gate (`AXIsProcessTrusted`). Returns `.noPermission`.
    ///   2. Frontmost-app gate (must exist; Stash-self rejected — we never
    ///      auto-paste into our own UI). Returns `.insertionFailed`.
    ///   3. Optional focus introspection. Many Electron / ToDesktop apps
    ///      (Cursor, Linear desktop, etc.) refuse to expose their focused
    ///      element to the app-level AX query — `focusedElement` will return
    ///      nil. That's NOT a reason to bail; it just means we skip Strategy
    ///      1 and the secure-field privacy check, and rely on Strategy 2 to
    ///      deliver the paste.
    ///   4. Privacy gate — only enforceable when introspection succeeded.
    ///      Reject `AXSecureTextField` subrole. Returns `.insertionFailed`.
    ///   5. Strategy 1 (AX value write) — only runs if introspection found
    ///      a visible writable element with a known role
    ///      (AXTextField/AXTextArea/AXComboBox) AND text is below the
    ///      pre-flight length threshold. On success, returns
    ///      `.verifiedPasted` (the read-back confirmed the write landed).
    ///   6. Strategy 2 (CGEvent ⌘V) — universal fallback. Returns
    ///      `.attemptedPaste` on event-post completion (we cannot verify
    ///      whether the destination app accepted the events), or
    ///      `.insertionFailed` if event creation itself failed.
    func attemptInsert(text: String) -> InsertResult {
        let token = UUID()
        currentPasteToken = token
        let deadline = Date().addingTimeInterval(Self.attemptDeadlineSeconds)

        guard hasAccessibilityPermission else {
            #if DEBUG
            print("[AutoPaste] noPermission — AXIsProcessTrusted() == false. Bundle: \(Bundle.main.bundlePath)")
            #endif
            return .noPermission
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            #if DEBUG
            let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            print("[AutoPaste] insertionFailed — no front app or Stash itself is front. Front: \(id)")
            #endif
            return .insertionFailed
        }

        // Best-effort introspection. Returns nil for apps that don't expose
        // their focused element via the app-level AX query — common in
        // Electron/ToDesktop. Strategy 2 still runs in that case.
        let element = focusedElement(in: frontApp)

        if let element {
            if isSecureTextElement(element) {
                #if DEBUG
                print("[AutoPaste] insertionFailed — focused element is a secure (password) field")
                #endif
                return .insertionFailed
            }
            if isStandardWritableRole(element) {
                // Re-check permission at strategy entry; the user may have revoked
                // Accessibility between attemptInsert's first gate and now.
                guard hasAccessibilityPermission else { return .noPermission }
                if writeViaAXValue(text, into: element, deadline: deadline) {
                    #if DEBUG
                    print("[AutoPaste] verifiedPasted via Strategy 1 (AXValue write, read-back confirmed). Front app: \(frontApp.bundleIdentifier ?? "?")")
                    #endif
                    return .verifiedPasted
                }
            }
        }

        guard hasAccessibilityPermission else { return .noPermission }
        guard !isDeadlineExceeded(deadline) else {
            // Strategy 2 didn't even start; pasteboard is untouched, no
            // restore needed.
            return .insertionFailed
        }
        if writeViaCGEventPaste(text, token: token) {
            #if DEBUG
            let roleDescription: String
            if let element {
                var roleRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                roleDescription = (roleRef as? String) ?? "unknown"
            } else {
                roleDescription = "(AX introspection unavailable)"
            }
            print("[AutoPaste] attemptedPaste via Strategy 2 (CGEvent ⌘V — landing unverifiable). Front app: \(frontApp.bundleIdentifier ?? "?"). Role: \(roleDescription)")
            #endif
            return .attemptedPaste
        }
        #if DEBUG
        print("[AutoPaste] insertionFailed — both strategies returned false")
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

    /// Universal fallback: snapshot the pasteboard, write `text` to it, post
    /// a synthetic ⌘V via CGEvent, restore the original pasteboard 300ms
    /// later. The restore is gated by both `token` (so a newer paste
    /// implicitly cancels ours) and `pb.changeCount` (so a user copy beats
    /// our restore).
    ///
    /// Returns true on completion. Returns false only if event creation or
    /// the pasteboard write fails outright (very rare).
    private func writeViaCGEventPaste(_ text: String, token: UUID) -> Bool {
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

        // Brief delay before posting ⌘V so the pasteboard server has time
        // to propagate our setString to other processes. Electron apps read
        // the pasteboard via Mach IPC in response to keydown — without this
        // gap, fast renderers occasionally read the OLD pasteboard contents.
        // 25ms is well below human-perception threshold and reliably above
        // the daemon's commit latency on contemporary macOS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            cmdDown.post(tap: .cghidEventTap)
            vDown.post(tap: .cghidEventTap)
            vUp.post(tap: .cghidEventTap)
            cmdUp.post(tap: .cghidEventTap)
        }

        // Restore the original pasteboard after the destination has consumed
        // our paste. 300ms accounts for the 25ms pre-paste delay plus the
        // slower IPC round-trip in Electron apps.
        //
        // Two guards before restoring:
        //   1. Token — newer paste superseded us; their token now owns the
        //      service. Skip our restore so we don't clobber their write.
        //   2. changeCount — user (or another agent) copied between our
        //      write and our restore. Their copy wins.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteboardRestoreDelaySeconds) { [weak self] in
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
        return true
    }
}
