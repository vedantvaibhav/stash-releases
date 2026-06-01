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

    @Test func noPasteAlwaysCopies() {
        // No target / secure field / chose not to paste → copy + "Copied".
        let d = DeliveryDecision.resolveNoPaste()
        #expect(d.pill == "Copied")
        #expect(d.clipboard == .writeTranscript)
    }

    @Test func shouldAttemptPasteOnlyForEditable() {
        #expect(DeliveryDecision.shouldAttemptPaste(target: .editable) == true)
        #expect(DeliveryDecision.shouldAttemptPaste(target: .noTarget) == false)
        #expect(DeliveryDecision.shouldAttemptPaste(target: .secureField) == false)
    }
}
