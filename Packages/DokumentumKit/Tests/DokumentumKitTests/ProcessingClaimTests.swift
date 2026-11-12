import DokumentumKit
import Foundation
import Testing

/// The processing queue's decision table, its clock-skew rules (plan of #4, part 5, B2; #97 point 1, T8) and the
/// retry backoff (#97 point 2, T9).
struct ProcessingClaimTests {
    static let me = "DEVICE-A"
    static let other = "DEVICE-B"
    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let hour: TimeInterval = 60 * 60
    static let interval = ProcessingClaimRules.takeoverInterval

    /// The decision for a document claimed by `device` `age` seconds ago (negative: in the future).
    /// `seenFor`: how long this device has seen the claim (`nil`: first seen now). `retryIn`: when the backoff ends,
    /// from now (`nil`: no backoff).
    private func decide(
        _ state: ProcessingState, by device: String, age: TimeInterval?, failures: Int = 0, isTrashed: Bool = false,
        hasFile: Bool = true, hasText: Bool = true, seenFor: TimeInterval? = nil, retryIn: TimeInterval? = nil
    ) -> ProcessingDecision {
        ProcessingClaimRules.decide(
            ProcessingClaimInput(
                state: state, deviceID: device, claimedAt: age.map { Self.now.addingTimeInterval(-$0) },
                isTrashed: isTrashed, hasFile: hasFile, hasText: hasText,
                claimSeenSince: seenFor.map { Self.now.addingTimeInterval(-$0) },
                retryNotBefore: retryIn.map { Self.now.addingTimeInterval($0) }),
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

    @Test(arguments: [ProcessingState.pending, .processing, .classify])
    func noClaimIsClaimed(state: ProcessingState) {
        #expect(decide(state, by: "", age: nil) == .process(.claim))
        #expect(decide(state, by: "", age: Self.hour) == .process(.claim), "a time without a device is no claim")
        #expect(decide(state, by: Self.other, age: nil) == .process(.claim), "a device without a time is no claim")
    }

    @Test(arguments: [ProcessingState.pending, .processing, .classify])
    func anOwnFreshClaimIsKeptAndAStaleOneRenewed(state: ProcessingState) {
        #expect(decide(state, by: Self.me, age: 0) == .process(.keep))
        #expect(decide(state, by: Self.me, age: Self.interval - 1) == .process(.keep))
        #expect(decide(state, by: Self.me, age: Self.interval) == .process(.claim))
        #expect(decide(state, by: Self.me, age: -(Self.interval + 1)) == .process(.claim))
    }

    @Test(arguments: [ProcessingState.pending, .processing, .classify])
    func anotherDevicesFreshClaimWaitsUntilItExpires(state: ProcessingState) {
        let claimedAt = Self.now.addingTimeInterval(-Self.hour)
        #expect(
            decide(state, by: Self.other, age: Self.hour)
                == .wait(.claimedElsewhere(until: claimedAt.addingTimeInterval(Self.interval))))
        #expect(decide(state, by: Self.other, age: 0).isWait)
    }

    @Test(arguments: [ProcessingState.pending, .processing, .classify])
    func anotherDevicesExpiredClaimIsTakenOver(state: ProcessingState) {
        #expect(decide(state, by: Self.other, age: Self.interval) == .process(.takeOver))
        #expect(decide(state, by: Self.other, age: 400 * 24 * Self.hour) == .process(.takeOver))
    }

    // MARK: Boundaries

    @Test func sixHoursTakesOverAndOneSecondLessWaits() {
        #expect(decide(.pending, by: Self.other, age: Self.interval) == .process(.takeOver))
        #expect(decide(.pending, by: Self.other, age: Self.interval - 1).isWait)
    }

    /// T8: a claim in the future is never taken over at once, however far ahead; it waits until this device has
    /// seen it unchanged for 6 hours by its own clock (#97 point 1).
    @Test func aFutureClaimWaitsUntilThisDeviceHasSeenItForSixHours() {
        for ahead in [Self.interval - 1, Self.interval, 7 * Self.hour, 3 * 24 * Self.hour] {
            #expect(
                decide(.processing, by: Self.other, age: -ahead)
                    == .wait(.claimedElsewhere(until: Self.now.addingTimeInterval(Self.interval))),
                "first seen now: \(ahead) s ahead")
            #expect(
                decide(.processing, by: Self.other, age: -ahead, seenFor: Self.interval - 1)
                    == .wait(.claimedElsewhere(until: Self.now.addingTimeInterval(1))),
                "seen one second less than 6 h: \(ahead) s ahead")
            #expect(
                decide(.processing, by: Self.other, age: -ahead, seenFor: Self.interval) == .process(.takeOver),
                "seen for 6 h: \(ahead) s ahead")
        }
    }

    /// A past claim still expires at an age of 6 hours, also when this device first sees it late.
    @Test func aPastClaimStillExpiresAtAnAgeOfSixHours() {
        #expect(decide(.pending, by: Self.other, age: Self.interval, seenFor: 0) == .process(.takeOver))
        #expect(decide(.pending, by: Self.other, age: Self.interval - 1, seenFor: 0).isWait)
        #expect(decide(.pending, by: Self.other, age: Self.interval - 1, seenFor: Self.interval) == .process(.takeOver))
    }

    /// The wait ends at the earlier of the two expiries: by the claim's age, or by this device's sighting.
    @Test func theWaitEndsAtTheEarlierExpiry() {
        let byAge = decide(.pending, by: Self.other, age: 5 * Self.hour, seenFor: 2 * Self.hour)
        #expect(byAge == .wait(.claimedElsewhere(until: Self.now.addingTimeInterval(Self.hour))))
        let bySighting = decide(.pending, by: Self.other, age: Self.hour, seenFor: 4 * Self.hour)
        #expect(bySighting == .wait(.claimedElsewhere(until: Self.now.addingTimeInterval(2 * Self.hour))))
        let future = decide(.pending, by: Self.other, age: -Self.hour, seenFor: 3 * Self.hour)
        #expect(future == .wait(.claimedElsewhere(until: Self.now.addingTimeInterval(3 * Self.hour))))
    }

    /// A sighting in the future (this device's clock was set back) counts from now: the wait is never longer than 6
    /// hours from here.
    @Test func aSightingInTheFutureCountsFromNow() {
        #expect(
            decide(.pending, by: Self.other, age: -10 * Self.hour, seenFor: -24 * Self.hour)
                == .wait(.claimedElsewhere(until: Self.now.addingTimeInterval(Self.interval))))
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

    /// The other half of B2: a clock that is days or years fast cannot keep a document waiting for ever; its claim
    /// expires once this device has seen it for 6 hours.
    @Test func aFastClockCannotBlockADocumentForEver() {
        for ahead in [3 * 24 * Self.hour, 10 * 365 * 24 * Self.hour] {
            #expect(decide(.pending, by: Self.other, age: -ahead, seenFor: Self.interval - 1).isWait)
            #expect(decide(.pending, by: Self.other, age: -ahead, seenFor: Self.interval) == .process(.takeOver))
        }
    }

    // MARK: Further conditions

    @Test(arguments: [ProcessingState.pending, .processing, .classify, .failed])
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

    /// The classification step (#8) reads the text, never the file: a document in `classify` waits for its text
    /// record only.
    @Test func classifyNeedsTheTextRecordButNotTheFile() {
        #expect(decide(.classify, by: Self.me, age: 0, hasFile: false) == .process(.keep))
        #expect(decide(.classify, by: Self.me, age: 0, hasText: false) == .wait(.noText))
        #expect(decide(.classify, by: Self.me, age: 0, hasFile: false, hasText: false) == .wait(.noText))
        #expect(decide(.classify, by: "", age: nil, hasFile: false) == .process(.claim))
    }

    /// The new raw value on an older build (frozen-enum rule, #8): a build that does not know `classify` reads it
    /// as `.unknown`, and the rules skip `.unknown` before trash, claims, files and backoff, so such a build never
    /// claims, takes over or writes a document waiting for classification.
    @Test func aStateAnOlderBuildDoesNotKnowIsSkippedBeforeEveryOtherRule() {
        for raw in ["classify-v2", "suggest", "Classify"] {
            let state = ProcessingState(storedValue: raw)
            #expect(state == .unknown)
            for device in ["", Self.me, Self.other] {
                for age in [nil, 0, Self.interval, 48 * Self.hour] as [TimeInterval?] {
                    #expect(
                        decide(
                            state, by: device, age: age, failures: 0, hasFile: false, hasText: false, retryIn: 60)
                            == .skip(.unknownState))
                }
            }
        }
    }

    @Test func aShorterIntervalIsUsed() {
        let decision = ProcessingClaimRules.decide(
            ProcessingClaimInput(state: .pending, deviceID: Self.other, claimedAt: Self.now.addingTimeInterval(-120)),
            thisDevice: Self.me, failures: 0, now: Self.now, takeoverInterval: 120)
        #expect(decision == .process(.takeOver))
    }

    // MARK: Backoff (T9)

    /// Every "process" waits while the backoff runs, and processes from the second it ends.
    @Test(arguments: [nil, me, other] as [String?])
    func aProcessWaitsForTheBackoff(device: String?) {
        // Another device's claim is expired here, so the decision without the backoff is a takeover.
        let age: TimeInterval? = device == nil ? nil : (device == Self.me ? 0 : Self.interval)
        let processes = decide(.pending, by: device ?? "", age: age)
        #expect(processes.isProcess)
        #expect(
            decide(.pending, by: device ?? "", age: age, retryIn: 1)
                == .wait(.retryAfter(Self.now.addingTimeInterval(1))))
        #expect(decide(.pending, by: device ?? "", age: age, retryIn: 0) == processes)
        #expect(decide(.pending, by: device ?? "", age: age, retryIn: -1) == processes)
        #expect(
            decide(.failed, by: device ?? "", age: age, failures: 1, retryIn: 60)
                == .wait(.retryAfter(Self.now.addingTimeInterval(60))))
    }

    /// The backoff never hides a skip, and another device's fresh claim is waited for first.
    @Test func theBackoffComesAfterTheTable() {
        #expect(decide(.done, by: Self.me, age: 0, retryIn: 60) == .skip(.done))
        #expect(decide(.failed, by: Self.me, age: 0, failures: 3, retryIn: 60) == .skip(.failedOnThisDevice))
        #expect(decide(.pending, by: Self.me, age: 0, isTrashed: true, retryIn: 60) == .skip(.trashed))
        #expect(
            decide(.pending, by: Self.other, age: Self.hour, retryIn: 60)
                == .wait(.claimedElsewhere(until: Self.now.addingTimeInterval(5 * Self.hour))))
    }

    @Test func theBackoffIsOneMinuteThenTenMinutes() {
        let last = Self.now.addingTimeInterval(-30)
        #expect(ProcessingBackoff.retryNotBefore(attempts: 0, lastAttemptAt: last, now: Self.now) == nil)
        #expect(
            ProcessingBackoff.retryNotBefore(attempts: 1, lastAttemptAt: last, now: Self.now)
                == last.addingTimeInterval(60))
        #expect(
            ProcessingBackoff.retryNotBefore(attempts: 2, lastAttemptAt: last, now: Self.now)
                == last.addingTimeInterval(600))
        #expect(
            ProcessingBackoff.retryNotBefore(attempts: 3, lastAttemptAt: last, now: Self.now) == nil,
            "at the limit the next decision gives up at once")
        #expect(
            ProcessingBackoff.retryNotBefore(attempts: 1, lastAttemptAt: nil, now: Self.now) == nil,
            "a counter of the old form has no time")
    }

    /// N9: a last attempt in the future (the clock was set back) gives `now` plus the delay, never later.
    @Test func aLastAttemptInTheFutureCountsFromNow() {
        let future = Self.now.addingTimeInterval(24 * Self.hour)
        #expect(
            ProcessingBackoff.retryNotBefore(attempts: 1, lastAttemptAt: future, now: Self.now)
                == Self.now.addingTimeInterval(60))
        #expect(
            ProcessingBackoff.retryNotBefore(attempts: 2, lastAttemptAt: future, now: Self.now)
                == Self.now.addingTimeInterval(600))
    }

    // MARK: Sightings (T8)

    @Test func aSightingIsKeptForTheSameClaimAndRestartsForANewOne() {
        let claimedAt = Self.now.addingTimeInterval(3 * Self.hour)
        let first = ClaimSighting.seeing(deviceID: Self.other, claimedAt: claimedAt, now: Self.now, after: nil)
        #expect(first == ClaimSighting(deviceID: Self.other, claimedAt: claimedAt, seenAt: Self.now))
        let later = Self.now.addingTimeInterval(Self.hour)
        #expect(ClaimSighting.seeing(deviceID: Self.other, claimedAt: claimedAt, now: later, after: first) == first)
        let renewed = claimedAt.addingTimeInterval(1)
        #expect(
            ClaimSighting.seeing(deviceID: Self.other, claimedAt: renewed, now: later, after: first)
                == ClaimSighting(deviceID: Self.other, claimedAt: renewed, seenAt: later), "a new claim time")
        #expect(
            ClaimSighting.seeing(deviceID: "DEVICE-C", claimedAt: claimedAt, now: later, after: first)
                == ClaimSighting(deviceID: "DEVICE-C", claimedAt: claimedAt, seenAt: later), "another device")
        let setBack = Self.now.addingTimeInterval(-Self.hour)
        #expect(
            ClaimSighting.seeing(deviceID: Self.other, claimedAt: claimedAt, now: setBack, after: first).seenAt
                == setBack, "a sighting in the future moves to now")
    }

    // MARK: Property test

    /// 1,000 seeded inputs, both devices' clocks skewed by up to ±48 h, each claim first seen now. `trueAge` is the real time since the claim;
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
                #expect(age < Self.interval, "waits for a claim older than the interval: \(age)")
                #expect(until > myNow && until <= myNow.addingTimeInterval(Self.interval), "waits beyond the interval")
                #expect(until == min(claimedAt, myNow).addingTimeInterval(Self.interval))
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
