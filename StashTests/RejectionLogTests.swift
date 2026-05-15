import Testing
import Foundation
@testable import Stash

@MainActor
struct RejectionLogTests {
    /// Returns an isolated temp directory for this test. Cleaned up by the
    /// caller's `defer`. Avoids clobbering the developer's real rejection log.
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RejectionLogTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func roundTripsThroughDisk() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RejectionLog(directory: dir)

        let entry = RejectionLog.Entry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 93,
            rawText: "I had a chat with Sai…",
            gate: "confidence",
            noSpeechProb: 0.68,
            avgLogprob: -0.33,
            voiceActiveSeconds: nil,
            peakPowerDBFS: nil
        )
        log.append(entry)
        let read = log.read()
        #expect(read.count == 1)
        #expect(read.first?.durationSeconds == 93)
        #expect(read.first?.gate == "confidence")
        #expect(read.first?.noSpeechProb == 0.68)
        #expect(read.first?.avgLogprob == -0.33)
        #expect(read.first?.voiceActiveSeconds == nil)
    }

    @Test func truncatesToMaxEntries() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RejectionLog(directory: dir)

        for i in 0..<60 {
            log.append(.init(
                timestamp: Date(timeIntervalSince1970: TimeInterval(i)),
                durationSeconds: i,
                rawText: "entry \(i)",
                gate: "test",
                noSpeechProb: nil,
                avgLogprob: nil,
                voiceActiveSeconds: nil,
                peakPowerDBFS: nil
            ))
        }
        let read = log.read()
        #expect(read.count == RejectionLog.maxEntries)
        #expect(read.first?.rawText == "entry 10")
        #expect(read.last?.rawText == "entry 59")
    }
}
