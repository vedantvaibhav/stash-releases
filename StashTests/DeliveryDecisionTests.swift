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
