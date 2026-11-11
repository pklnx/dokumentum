import DokumentumKit
import Foundation
import Testing

/// The processing queue's decision table and its clock-skew rules (plan of #4, part 5, B2).
struct ProcessingClaimTests {
    static let me = "DEVICE-A"
    static let other = "DEVICE-B"
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let hour: TimeInterval = 60 * 60
    static let interval = ProcessingClaimRules.takeoverInterval

    /// The decision for a document claimed by `device` `age` seconds ago (negative: in the future).
    private func decide(
        _ state: ProcessingState, by device: String, age: TimeInterval?, failures: Int = 0, isTrashed: Bool = false,
        hasFile: Bool = true, hasText: Bool = true
    ) -> ProcessingDecision {
        ProcessingClaimRules.decide(
            ProcessingClaimInput(
                state: state, deviceID: device, claimedAt: age.map { Self.now.addingTimeInterval(-$0) },
                isTrashed: isTrashed, hasFile: hasFile, hasText: hasText),
            thisDevice: Self.me, failures: failures, now: Self.now)
    }

    @Test func theIntervalIsSixHoursAndTheLimitThree() {
        #expect(ProcessingClaimRules.takeoverInterval == 6 * 60 * 60)
        #expect(ProcessingClaimRules.failureLimit == 3)
    }

    // MARK: The table, row by row

    @Test(arguments: [nil, me, other] as [String?])
    func doneIsSkippedWhateverTheClaim(device: String?) {
        #expect(decide(.done, by: device ?? "", age: device == nil ? nil : Self.hour) == .skip(.done))
    }

    @Test(arguments: [nil, me, other] as [String?])
    func failedIsRetriedOnlyBelowTheOwnLimit(device: String?) {
        let age: TimeInterval? = device == nil ? nil : Self.hour
        for failures in 0..<3 {
            #expect(decide(.failed, by: device ?? "", age: age, failures: failures) == .process(.claim), "\(failures)")
        }
        #expect(decide(.failed, by: device ?? "", age: age, failures: 3) == .skip(.failedOnThisDevice))
        #expect(decide(.failed, by: device ?? "", age: age, failures: 7) == .skip(.failedOnThisDevice))
    }

    @Test(arguments: [nil, me, other] as [String?])
    func unknownIsNeverProcessed(device: String?) {
        for age in [nil, 0, Self.hour, 7 * Self.hour, -7 * Self.hour] as [TimeInterval?] {
            for failures in [0, 3] {
                for isTrashed in [false, true] {
                    #expect(
                        decide(.unknown, by: device ?? "", age: age, failures: failures, isTrashed: isTrashed)
                            == .skip(.unknownState))
                }
            }
        }
    }

    @Test(arguments: [ProcessingState.pending, .processing])
    func noClaimIsClaimed(state: ProcessingState) {
        #expect(decide(state, by: "", age: nil) == .process(.claim))
        #expect(decide(state, by: "", age: Self.hour) == .process(.claim), "a time without a device is no claim")
        #expect(decide(state, by: Self.other, age: nil) == .process(.claim), "a device without a time is no claim")
    }

    @Test(arguments: [ProcessingState.pending, .processing])
    func anOwnFreshClaimIsKeptAndAStaleOneRenewed(state: ProcessingState) {
        #expect(decide(state, by: Self.me, age: 0) == .process(.keep))
        #expect(decide(state, by: Self.me, age: Self.interval - 1) == .process(.keep))
        #expect(decide(state, by: Self.me, age: Self.interval) == .process(.claim))
        #expect(decide(state, by: Self.me, age: -(Self.interval + 1)) == .process(.claim))
    }

    @Test(arguments: [ProcessingState.pending, .processing])
    func anotherDevicesFreshClaimWaitsUntilItExpires(state: ProcessingState) {
        let claimedAt = Self.now.addingTimeInterval(-Self.hour)
        #expect(
            decide(state, by: Self.other, age: Self.hour)
                == .wait(.claimedElsewhere(until: claimedAt.addingTimeInterval(Self.interval))))
        #expect(decide(state, by: Self.other, age: 0).isWait)
    }

    @Test(arguments: [ProcessingState.pending, .processing])
    func anotherDevicesExpiredClaimIsTakenOver(state: ProcessingState) {
        #expect(decide(state, by: Self.other, age: Self.interval) == .process(.takeOver))
        #expect(decide(state, by: Self.other, age: 400 * 24 * Self.hour) == .process(.takeOver))
    }

    // MARK: Boundaries

    @Test func sixHoursTakesOverAndOneSecondLessWaits() {
        #expect(decide(.pending, by: Self.other, age: Self.interval) == .process(.takeOver))
        #expect(decide(.pending, by: Self.other, age: Self.interval - 1).isWait)
    }

    @Test func aClaimUpToSixHoursInTheFutureWaitsAndBeyondIsTakenOver() {
        #expect(decide(.processing, by: Self.other, age: -(Self.interval - 1)).isWait)
        #expect(decide(.processing, by: Self.other, age: -Self.interval).isWait, "exactly 6 h ahead still waits")
        #expect(decide(.processing, by: Self.other, age: -(Self.interval + 1)) == .process(.takeOver))
    }

    /// B2, written out: the claiming device's clock is 7 h slow. It claimed one minute ago in real time, but wrote
    /// its own time, 7 h and 1 min before this device's clock. This device takes it over at once. **This early
    /// takeover is accepted:** it costs a double processing with the same result (plan, "Risks"), never data.
    @Test func aSlowClockMakesAFreshClaimLookOldAndItIsTakenOverAtOnce() {
        let realAge: TimeInterval = 60
        let slowBy = 7 * Self.hour
        let written = Self.now.addingTimeInterval(-realAge).addingTimeInterval(-slowBy)
        let decision = ProcessingClaimRules.decide(
            ProcessingClaimInput(state: .processing, deviceID: Self.other, claimedAt: written),
            thisDevice: Self.me, failures: 0, now: Self.now)
        #expect(decision == .process(.takeOver), "the accepted early takeover")
    }

    /// The other half of B2: a clock that is days fast cannot keep a document waiting for ever.
    @Test func aFastClockCannotBlockADocumentForEver() {
        #expect(decide(.pending, by: Self.other, age: -3 * 24 * Self.hour) == .process(.takeOver))
        #expect(decide(.pending, by: Self.other, age: -10 * 365 * 24 * Self.hour) == .process(.takeOver))
    }

    // MARK: Further conditions

    @Test(arguments: [ProcessingState.pending, .processing, .failed])
    func aTrashedDocumentIsSkipped(state: ProcessingState) {
        #expect(decide(state, by: Self.me, age: 0, isTrashed: true) == .skip(.trashed))
        #expect(decide(state, by: "", age: nil, isTrashed: true) == .skip(.trashed))
        #expect(decide(state, by: Self.other, age: Self.interval, isTrashed: true) == .skip(.trashed))
    }

    @Test(arguments: [ProcessingState.pending, .processing, .failed])
    func withoutItsFileOrTextItWaits(state: ProcessingState) {
        #expect(decide(state, by: Self.me, age: 0, hasFile: false) == .wait(.noFile))
        #expect(decide(state, by: Self.me, age: 0, hasText: false) == .wait(.noText))
        #expect(decide(state, by: Self.other, age: Self.interval, hasFile: false, hasText: false) == .wait(.noFile))
    }

    @Test func aShorterIntervalIsUsed() {
        let decision = ProcessingClaimRules.decide(
            ProcessingClaimInput(state: .pending, deviceID: Self.other, claimedAt: Self.now.addingTimeInterval(-120)),
            thisDevice: Self.me, failures: 0, now: Self.now, takeoverInterval: 120)
        #expect(decision == .process(.takeOver))
    }

    // MARK: Property test

    /// 1,000 seeded inputs, both devices' clocks skewed by up to ±48 h. `trueAge` is the real time since the claim;
    /// the claiming device wrote `claimedAt` with its clock, this device reads it with its own.
    @Test func noClaimWaitsBeyondTheIntervalAndEqualClocksNeverTakeAYoungClaim() {
        var random = SeededGenerator(seed: 62)
        let states: [ProcessingState] = [.pending, .processing, .done, .failed, .unknown]
        let devices = ["", Self.me, Self.other]
        let maxSkew = 48 * Self.hour
        for _ in 0..<1_000 {
            let state = states.randomElement(using: &random)!
            let device = devices.randomElement(using: &random)!
            let trueAge = TimeInterval(Int.random(in: 0...(30 * 60 * 60), using: &random))
            let equalClocks = Bool.random(using: &random)
            let claimSkew = equalClocks ? 0 : TimeInterval(Int.random(in: -172_800...172_800, using: &random))
            let mySkew = equalClocks ? 0 : TimeInterval(Int.random(in: -172_800...172_800, using: &random))
            #expect(abs(claimSkew) <= maxSkew && abs(mySkew) <= maxSkew)
            let realNow = Self.now
            let claimedAt = realNow.addingTimeInterval(-trueAge).addingTimeInterval(claimSkew)
            let myNow = realNow.addingTimeInterval(mySkew)
            let input = ProcessingClaimInput(
                state: state, deviceID: device, claimedAt: device.isEmpty ? nil : claimedAt,
                isTrashed: Int.random(in: 0..<10, using: &random) == 0,
                hasFile: Int.random(in: 0..<10, using: &random) != 0,
                hasText: Int.random(in: 0..<10, using: &random) != 0)
            let failures = Int.random(in: 0...4, using: &random)
            let decision = ProcessingClaimRules.decide(input, thisDevice: Self.me, failures: failures, now: myNow)
            let age = myNow.timeIntervalSince(claimedAt)

            if case .wait(.claimedElsewhere(let until)) = decision {
                #expect(age < Self.interval && age >= -Self.interval, "waits for a claim beyond the interval: \(age)")
                #expect(until == claimedAt.addingTimeInterval(Self.interval))
            }
            if state == .unknown { #expect(decision == .skip(.unknownState)) }
            if state == .done { #expect(decision == .skip(.done)) }
            if equalClocks && device == Self.other && trueAge < Self.interval {
                #expect(decision != .process(.takeOver), "took a claim \(trueAge) s old with equal clocks")
            }
            if decision == .process(.takeOver) { #expect(device == Self.other) }
        }
    }
}
