import Foundation
import Testing
@testable import Stash

/// Pure-logic tests for `NotesFilter.matches(_:)`.
///
/// **Wiring status:** mirrors the convention used by
/// `HallucinationFilterTests.swift` — tests are ready to execute, will run
/// once the `StashTests` target is added to `Stash.xcodeproj`. No xcodeproj
/// change is required for this PR.
struct NotesFilterTests {

    private func note(origin: NoteOrigin, duration: Int = 0) -> NoteItem {
        NoteItem(
            id: "test-\(UUID().uuidString)",
            title: "t",
            preview: "p",
            lastEdited: Date(),
            origin: origin,
            duration: duration
        )
    }

    @Test func allMatchesEverything() {
        let f = NotesFilter.all
        #expect(f.matches(note(origin: .written)))
        #expect(f.matches(note(origin: .meeting, duration: 3600)))
        #expect(f.matches(note(origin: .voice,   duration: 200)))
        #expect(f.matches(note(origin: .quick,   duration: 30)))
        #expect(f.matches(note(origin: .transcribed)))
    }

    @Test func meetingsBucket() {
        let f = NotesFilter.meetings
        #expect(f.matches(note(origin: .meeting, duration: 3600)))
        #expect(f.matches(note(origin: .transcribed)))   // legacy stays here
        #expect(!f.matches(note(origin: .written)))
        #expect(!f.matches(note(origin: .voice)))
        #expect(!f.matches(note(origin: .quick)))
    }

    @Test func quickNotesBucket() {
        let f = NotesFilter.quickNotes
        #expect(f.matches(note(origin: .quick, duration: 30)))
        #expect(f.matches(note(origin: .voice, duration: 220)))
        #expect(!f.matches(note(origin: .meeting)))
        #expect(!f.matches(note(origin: .transcribed)))   // legacy is NOT quick
        #expect(!f.matches(note(origin: .written)))
    }

    @Test func manualBucket() {
        let f = NotesFilter.manual
        #expect(f.matches(note(origin: .written)))
        #expect(!f.matches(note(origin: .meeting)))
        #expect(!f.matches(note(origin: .voice)))
        #expect(!f.matches(note(origin: .quick)))
        #expect(!f.matches(note(origin: .transcribed)))
    }

    @Test func displayNamesAreStable() {
        #expect(NotesFilter.all.displayName        == "All notes")
        #expect(NotesFilter.meetings.displayName   == "Meetings")
        #expect(NotesFilter.quickNotes.displayName == "Quick notes")
        #expect(NotesFilter.manual.displayName     == "Manual")
    }

    @Test func rawValuesAreStableForPersistence() {
        // Raw values are written to UserDefaults — changing these silently
        // resets every user's filter to `.all` on next launch.
        #expect(NotesFilter.all.rawValue        == "all")
        #expect(NotesFilter.meetings.rawValue   == "meetings")
        #expect(NotesFilter.quickNotes.rawValue == "quickNotes")
        #expect(NotesFilter.manual.rawValue     == "manual")
    }
}
