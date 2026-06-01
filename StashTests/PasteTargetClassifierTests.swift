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
