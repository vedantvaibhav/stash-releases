import Foundation

/// Pure classification of the paste destination. Side-effect-free so it can be
/// unit-tested without a window server. Drives Case 1 (paste) vs Case 2 (save,
/// no clipboard). Classified from the STOP-TIME captured frontmost app (the
/// live frontmost drifts during the Whisper+cleanup round-trip); only the
/// secure-field subrole is read live.
enum PasteTarget: Equatable {
    case editable // attempt a paste
    case noTarget // Stash (or nothing) was frontmost at stop → save, no clipboard
    case secureField // password field → never paste, never clipboard
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
