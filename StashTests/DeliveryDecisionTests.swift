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
        let d = DeliveryDecision.resolveNoPaste(target: .noTarget)
        #expect(d.pill == "Saved")
        #expect(d.clipboard == .none)
    }

    @Test func secureFieldSaves() {
        let d = DeliveryDecision.resolveNoPaste(target: .secureField)
        #expect(d.pill == "Saved")
        #expect(d.clipboard == .none)
    }

    @Test func editableNoPasteFallsBackToCopy() {
        let d = DeliveryDecision.resolveNoPaste(target: .editable)
        #expect(d.pill == "Copied")
        #expect(d.clipboard == .writeTranscript)
    }

    @Test func shouldAttemptPasteOnlyForEditable() {
        #expect(DeliveryDecision.shouldAttemptPaste(target: .editable) == true)
        #expect(DeliveryDecision.shouldAttemptPaste(target: .noTarget) == false)
        #expect(DeliveryDecision.shouldAttemptPaste(target: .secureField) == false)
    }
}
