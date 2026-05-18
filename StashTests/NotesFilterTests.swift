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

    @Test func transcriptionsBucket() {
        let f = NotesFilter.transcriptions
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
        #expect(NotesFilter.all.displayName           == "All notes")
        #expect(NotesFilter.meetings.displayName      == "Meetings")
        #expect(NotesFilter.transcriptions.displayName == "Transcriptions")
        #expect(NotesFilter.manual.displayName        == "Manual")
    }

    @Test func rawValuesAreStableForPersistence() {
        // Raw values are written to UserDefaults — changing these silently
        // resets every user's filter to `.all` on next launch.
        #expect(NotesFilter.all.rawValue        == "all")
        #expect(NotesFilter.meetings.rawValue   == "meetings")
        // rawValue preserved across the 2026-05-19 rename — see `NotesFilter.swift`.
        #expect(NotesFilter.transcriptions.rawValue == "quickNotes")
        #expect(NotesFilter.manual.rawValue     == "manual")
    }

    @Test func cycleAdvancesInFixedOrder() {
        // Cycle order is contractual — it determines what users see on each F press.
        // Changing this breaks muscle memory for anyone who learned the order.
        #expect(NotesFilter.all.next()           == .meetings)
        #expect(NotesFilter.meetings.next()      == .transcriptions)
        #expect(NotesFilter.transcriptions.next() == .manual)
        #expect(NotesFilter.manual.next()        == .all)

        // Four-step round trip lands back where it started.
        var cursor = NotesFilter.all
        for _ in 0..<4 { cursor = cursor.next() }
        #expect(cursor == .all)
    }
}

/// Round-trip tests for `NotesFilter` persistence shape — guards against
/// raw-value drift that would silently reset every user's filter to `.all`
/// on next launch. Does NOT touch `AppSettings.shared` directly because
/// that would require swizzling its `ud` reference; instead these tests
/// verify the contract that `AppSettings` consumes (raw string in, enum out).
struct NotesFilterPersistenceTests {

    private func makeSuite() -> UserDefaults {
        let suiteName = "qp.notesFilterTests.\(UUID().uuidString)"
        guard let ud = UserDefaults(suiteName: suiteName) else {
            fatalError("UserDefaults suite creation failed — unexpected for a random UUID name")
        }
        ud.removePersistentDomain(forName: suiteName)
        return ud
    }

    @Test func roundTripsEveryCaseThroughUserDefaults() {
        let ud = makeSuite()
        let key = "qp.notesActiveFilter"
        for filter in NotesFilter.allCases {
            ud.set(filter.rawValue, forKey: key)
            let read = ud.string(forKey: key).flatMap(NotesFilter.init(rawValue:))
            #expect(read == filter)
        }
    }

    @Test func unknownRawValueFallsBackToNil() {
        // AppSettings.init defaults `.all` when init(rawValue:) returns nil.
        let result = NotesFilter(rawValue: "not-a-real-case")
        #expect(result == nil)
    }
}
