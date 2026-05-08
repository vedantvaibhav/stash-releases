import AppKit
import ApplicationServices

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

    enum InsertResult: Equatable {
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

    /// Attempt to insert `text` at the focused field's caret. Synchronous;
    /// returns within a few ms.
    func attemptInsert(text: String) -> InsertResult {
        guard hasAccessibilityPermission else { return .noPermission }
        guard let element = focusedTextElement(),
              isWritableTextElement(element) else {
            return .noFocusedField
        }
        if writeViaAXValue(text, into: element) {
            return .success
        }
        // Strategy 2 (CGEvent ⌘V) wired in next commit.
        return .insertionFailed
    }

    // MARK: - Focused-element discovery

    /// Returns the focused UI element of the currently-frontmost app, or
    /// nil if discovery fails (no front app, no focused element, AX call
    /// returns non-success). Also returns nil when the front app is Stash
    /// itself — we never want to auto-paste into our own UI.
    private func focusedTextElement() -> AXUIElement? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let element = focused else { return nil }
        // CFGetTypeID check ensures we got an AXUIElement back. Apple's
        // documented `CFTypeRef` unwrapping pattern for AX framework.
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    /// True if `element` is a role we can write text into AND is not a
    /// secure (password) field. Pasting a transcript into a password field
    /// is a serious privacy fail — the secure-subrole reject is mandatory.
    private func isWritableTextElement(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else {
            return false
        }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox":
            // Reject the secure-text-field subrole. Secure fields report
            // role `AXTextField` with subrole `AXSecureTextField`.
            var subroleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
               let subrole = subroleRef as? String,
               subrole == "AXSecureTextField" {
                return false
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Strategy 1: AXUIElement direct value write

    /// Write the new text value via AXUIElementSetAttributeValue at
    /// `kAXValueAttribute`. Reads current value + selected range, splices
    /// `text` into the selected range (or appends if no selection), writes
    /// back, and bumps the selected range to the end of the inserted text
    /// so the caret lands AFTER the inserted transcript.
    ///
    /// Returns true on confirmed success. Returns false on any AX failure —
    /// caller falls through to Strategy 2.
    private func writeViaAXValue(_ text: String, into element: AXUIElement) -> Bool {
        // Read current value (string).
        var valueRef: CFTypeRef?
        let valueStatus = AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &valueRef
        )
        let currentValue = (valueStatus == .success ? (valueRef as? String) : nil) ?? ""

        // Read selected range. Some elements don't expose this — treat as
        // append-at-end.
        var rangeRef: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        )
        var selRange = CFRange(location: (currentValue as NSString).length, length: 0)
        if rangeStatus == .success, let cfRange = rangeRef,
           CFGetTypeID(cfRange) == AXValueGetTypeID() {
            let axRange = cfRange as! AXValue
            if AXValueGetType(axRange) == .cfRange {
                var r = CFRange(location: 0, length: 0)
                if AXValueGetValue(axRange, .cfRange, &r) {
                    selRange = r
                }
            }
        }

        // Splice the text into the selected range (replacing any selection).
        let nsCurrent = currentValue as NSString
        let safeLocation = max(0, min(selRange.location, nsCurrent.length))
        let safeLength = max(0, min(selRange.length, nsCurrent.length - safeLocation))
        let newValue = nsCurrent.replacingCharacters(
            in: NSRange(location: safeLocation, length: safeLength),
            with: text
        )

        // Write the new value.
        let setStatus = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, newValue as CFString
        )
        guard setStatus == .success else { return false }

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
}
