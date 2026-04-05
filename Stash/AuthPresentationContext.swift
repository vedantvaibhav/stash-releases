import AuthenticationServices
import AppKit

// MARK: - Presentation context for ASWebAuthenticationSession
// Must be an NSObject conforming to ASWebAuthenticationPresentationContextProviding.
// Provides the window anchor and keeps the session alive during OAuth.

final class AuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = AuthPresentationContext()

    /// Retains the active session so it isn't released before the callback fires.
    var activeSession: ASWebAuthenticationSession?

    private override init() { super.init() }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        print("[Auth] presentationAnchor called")
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.isKeyWindow }) {
            print("[Auth] Using key window: \(type(of: w))")
            return w
        }
        if let w = NSApp.windows.first(where: { $0.isVisible }) {
            print("[Auth] Using first visible window: \(type(of: w))")
            return w
        }
        if let w = NSApp.windows.first {
            print("[Auth] Using first window (not visible): \(type(of: w))")
            return w
        }
        print("[Auth] ERROR: No windows available!")
        return NSWindow()
    }
}
