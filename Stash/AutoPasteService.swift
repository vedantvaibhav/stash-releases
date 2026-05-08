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
        // Strategies wired in subsequent commits.
        return .noFocusedField
    }
}
