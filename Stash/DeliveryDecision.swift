import Foundation

/// Normalised paste result, decoupled from AutoPasteService's richer enum so
/// the decision table is testable in isolation.
enum PasteOutcome: Equatable {
    case verifiedPasted // Strategy 1 AX write, read-back confirmed
    case attemptedUnverified // Strategy 2 ⌘V posted, landing unobservable
    case noPermission // Accessibility not granted
    case failed // both strategies failed / deadline
}

/// Pure resolver for the short-path delivery contract (see plan truth table).
/// Returns the pill string and what to do with the clipboard. The note is
/// always saved by the caller regardless; this only governs pill + clipboard.
enum DeliveryDecision {
    enum Clipboard: Equatable { case none, writeTranscript }
    struct Outcome: Equatable { let pill: String; let clipboard: Clipboard }

    static func shouldAttemptPaste(target: PasteTarget) -> Bool {
        target == .editable
    }

    static func resolvePaste(_ outcome: PasteOutcome) -> Outcome {
        switch outcome {
        case .verifiedPasted:
            return Outcome(pill: "Pasted ✓", clipboard: .none)
        case .attemptedUnverified, .noPermission, .failed:
            return Outcome(pill: "Copied", clipboard: .writeTranscript)
        }
    }

    static func resolveNoPaste(target: PasteTarget) -> Outcome {
        switch target {
        case .noTarget, .secureField:
            return Outcome(pill: "Saved", clipboard: .none)
        case .editable:
            // Editable but we chose not to paste — treat as copy backstop.
            return Outcome(pill: "Copied", clipboard: .writeTranscript)
        }
    }
}
