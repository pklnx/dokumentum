import DokumentumKit
import Foundation
import Testing

/// #97 point 1 (A-N1, T8 in the plan of #6): two devices whose clocks differ, each with its own replica of one
/// document that syncs with a delay, a stage that takes longer than the sync, and exact claims (a result is written
/// only while the replica still holds the claim the work ran under). With step 3's rule ("a claim more than 6 h in the
/// future counts as expired"), two devices more than 6 h apart take the document from each other in turn and every
/// result is dropped. With the sighting rule, every skew ends `done`.
struct ClaimSkewSimulationTests {
    static let start = Date(timeIntervalSinceReferenceDate: 830_000_000)
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 60 * 60

    /// Skews of B's clock against A's from −48 h to +48 h in 30-minute steps (193 cases); A imports the document.
    @Test func everySkewEndsDoneWithOneResult() {
        var latest: TimeInterval = 0
        for step in -96...96 {
            let skew = TimeInterval(step) * 30 * Self.minute
            var simulation = ClaimSimulation(skewOfB: skew, syncDelay: 5 * Self.minute, stageDuration: 15 * Self.minute)
            let outcome = simulation.simulate(through: 24 * Self.hour)
            #expect(outcome.doneOnBoth != nil, "skew \(skew / Self.hour) h: no result within 24 h, \(outcome)")
            #expect(outcome.resultWrites == 1, "skew \(skew / Self.hour) h: \(outcome)")
            if let done = outcome.doneOnBoth { latest = max(latest, done) }
        }
        // Within the stage, the sync and one takeover at worst: no case waits for a sighting.
        #expect(latest <= Self.hour, "the latest case took \(latest / Self.minute) minutes")
    }

    /// The same with a sync slower than the stage: a takeover can arrive only after the other device's result, so
    /// both write `done` (B2's accepted double processing, with the same result), and never more than two.
    @Test func aSlowSyncEndsDoneToo() {
        for step in -96...96 {
            let skew = TimeInterval(step) * 30 * Self.minute
            var simulation = ClaimSimulation(
                skewOfB: skew, syncDelay: 20 * Self.minute, stageDuration: 15 * Self.minute)
            let outcome = simulation.simulate(through: 24 * Self.hour)
            #expect(outcome.doneOnBoth != nil, "skew \(skew / Self.hour) h: no result within 24 h, \(outcome)")
            #expect((1...2).contains(outcome.resultWrites), "skew \(skew / Self.hour) h: \(outcome)")
        }
    }
}

/// Two devices, A and B, on one document. Real time advances in steps of one minute; A's clock is real time, B's is
/// real time plus `skewOfB`. Each device decides with `ProcessingClaimRules` whenever it is idle, keeps its own
/// `ClaimSighting`, writes to its own replica at once and to the other's after `syncDelay` (last writer wins, by real
/// write time). A stage takes `stageDuration`; its result is written only if the replica still holds the claim the
/// work ran under, as the queue's result write does.
struct ClaimSimulation {
    struct Row: Equatable, CustomStringConvertible {
        var state: ProcessingState
        var deviceID: String
        var claimedAt: Date?
        /// Real write time and writer, for last-writer-wins.
        var version: Int

        var description: String {
            "\(state) \(deviceID) \(claimedAt.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "-")"
        }
    }

    struct Device {
        var id: String
        var skew: TimeInterval
        var replica: Row?
        var inbox: [(arrives: TimeInterval, row: Row)] = []
        var sighting: ClaimSighting?
        var work: (endsAt: TimeInterval, held: Row)?
    }

    struct Outcome: CustomStringConvertible {
        var doneOnBoth: TimeInterval?
        var resultWrites: Int
        var claimWrites: Int
        var final: [Row?]

        var description: String {
            "done on both: \(doneOnBoth.map { "\($0 / 60) min" } ?? "never"), results \(resultWrites), claims "
                + "\(claimWrites), final \(final)"
        }
    }

    let syncDelay: TimeInterval
    let stageDuration: TimeInterval
    let interval = ProcessingClaimRules.takeoverInterval
    var devices: [Device]
    var resultWrites = 0
    var claimWrites = 0

    init(skewOfB: TimeInterval, syncDelay: TimeInterval, stageDuration: TimeInterval) {
        self.syncDelay = syncDelay
        self.stageDuration = stageDuration
        devices = [Device(id: "DEVICE-A", skew: 0), Device(id: "DEVICE-B", skew: skewOfB)]
    }

    func clock(of index: Int, at time: TimeInterval) -> Date {
        ClaimSkewSimulationTests.start.addingTimeInterval(time + devices[index].skew)
    }

    mutating func simulate(through end: TimeInterval) -> Outcome {
        // A imports: pending with its own claim, as `DocumentImporter` writes it.
        write(Row(state: .pending, deviceID: devices[0].id, claimedAt: clock(of: 0, at: 0), version: 0), by: 0, at: 0)
        var time: TimeInterval = 0
        while time <= end {
            for index in devices.indices { step(index, at: time) }
            if devices.allSatisfy({ $0.replica?.state == .done }) {
                return Outcome(
                    doneOnBoth: time, resultWrites: resultWrites, claimWrites: claimWrites,
                    final: devices.map(\.replica))
            }
            time += ClaimSkewSimulationTests.minute
        }
        return Outcome(
            doneOnBoth: nil, resultWrites: resultWrites, claimWrites: claimWrites, final: devices.map(\.replica))
    }

    private mutating func step(_ index: Int, at time: TimeInterval) {
        // What synced in by now.
        let arrived = devices[index].inbox.filter { $0.arrives <= time }
        devices[index].inbox.removeAll { $0.arrives <= time }
        for message in arrived where message.row.version > (devices[index].replica?.version ?? -1) {
            devices[index].replica = message.row
        }
        let now = clock(of: index, at: time)
        let me = devices[index].id
        if let work = devices[index].work {
            guard time >= work.endsAt else { return }
            devices[index].work = nil
            // The result write: only under the exact claim the work ran under.
            if let row = devices[index].replica, row.state == work.held.state, row.deviceID == work.held.deviceID,
                row.claimedAt == work.held.claimedAt
            {
                resultWrites += 1
                write(
                    Row(state: .done, deviceID: row.deviceID, claimedAt: row.claimedAt, version: 0), by: index, at: time
                )
            }
        }
        guard let row = devices[index].replica else { return }
        var seenSince: Date?
        if row.state == .pending || row.state == .processing, !row.deviceID.isEmpty, row.deviceID != me,
            let claimedAt = row.claimedAt
        {
            let sighting = ClaimSighting.seeing(
                deviceID: row.deviceID, claimedAt: claimedAt, now: now, after: devices[index].sighting)
            devices[index].sighting = sighting
            seenSince = sighting.seenAt
        }
        let decision = ProcessingClaimRules.decide(
            ProcessingClaimInput(
                state: row.state, deviceID: row.deviceID, claimedAt: row.claimedAt, claimSeenSince: seenSince),
            thisDevice: me, failures: 0, now: now)
        guard case .process(let claim) = decision else { return }
        var held = row
        if claim != .keep {
            claimWrites += 1
            held = Row(state: .processing, deviceID: me, claimedAt: now, version: 0)
            write(held, by: index, at: time)
            held = devices[index].replica ?? held
        }
        devices[index].work = (time + stageDuration, held)
    }

    private mutating func write(_ row: Row, by index: Int, at time: TimeInterval) {
        var row = row
        // Later real time wins; at the same time, B over A (a fixed order, as a server's).
        row.version = Int(time) * 2 + index
        devices[index].replica = row
        for other in devices.indices where other != index {
            devices[other].inbox.append((time + syncDelay, row))
        }
    }
}
