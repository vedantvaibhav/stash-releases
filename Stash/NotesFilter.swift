import Foundation

/// Active filter applied to the Notes tab list. Persisted in `AppSettings`
/// under `qp.notesActiveFilter`. Filter buckets map to `NoteOrigin` cases —
/// duration is NOT a gate, since `TranscriptionService` already decides
/// meeting-vs-quick at the 5-minute threshold and writes the result into
/// `NoteOrigin`. Re-applying a duration check here would double-encode that
/// decision and could drift.
enum NotesFilter: String, CaseIterable, Identifiable {
    case all
    case meetings
    // rawValue preserved across rename for UserDefaults compatibility.
    // The case was renamed from `quickNotes` to `transcriptions` on 2026-05-19;
    // changing the rawValue would silently reset every user's saved filter to `.all`.
    case transcriptions = "quickNotes"
    case manual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:            return "All notes"
        case .meetings:       return "Meetings"
        case .transcriptions: return "Transcriptions"
        case .manual:         return "Manual"
        }
    }

    func matches(_ note: NoteItem) -> Bool {
        switch self {
        case .all:
            return true
        case .meetings:
            // `.meeting` = new-format meeting notes (≥ 5 min path).
            // `.transcribed` = legacy notes from before the new format —
            // bucketed into Meetings so they stay visible in the
            // "important" view instead of being buried under Quick notes.
            return note.origin == .meeting || note.origin == .transcribed
        case .transcriptions:
            // Bucket semantics unchanged from `.quickNotes`: short dictations
            // (`.quick`) and voice memos (`.voice`). Display name flipped to
            // "Transcriptions" to better reflect what users see in the list.
            return note.origin == .quick || note.origin == .voice
        case .manual:
            return note.origin == .written
        }
    }

    /// Next filter in the F-key cycle order: `.all → .meetings → .transcriptions → .manual → .all`.
    /// Order is contractual — see `cycleAdvancesInFixedOrder()`.
    func next() -> NotesFilter {
        switch self {
        case .all:            return .meetings
        case .meetings:       return .transcriptions
        case .transcriptions: return .manual
        case .manual:         return .all
        }
    }
}
