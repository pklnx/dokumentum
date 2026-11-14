import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

@testable import Dokumentum

/// The rule sheet's draft (#10, part 2; plan §8): only the changed fields are saved, each validation result has its
/// line, Save is disabled while a problem shows or the probe runs, the probe is debounced, and a record with copies or
/// one that is gone shows its state. In-memory stores with the sample library.
@MainActor
struct MatchingRuleDraftTests {
    struct SaveFailed: Error {}

    private static let musterbank = FixtureCatalog.musterbank

    private func makeContainer() throws -> ModelContainer {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext)
        return container
    }

    private func correspondent(_ id: UUID, in context: ModelContext) throws -> Correspondent {
        let descriptor = FetchDescriptor<Correspondent>(predicate: #Predicate { $0.instanceID == id })
        return try #require(try context.fetch(descriptor).first)
    }

    private func draft(
        _ container: ModelContainer, _ target: MatchingRuleTarget? = nil,
        editor: MatchingRuleEditor? = nil, probe: @escaping MatchingRuleDraft.Probe = { _ in nil },
        sleep: @escaping MatchingRuleDraft.Sleep = ManualDebounce().sleep
    ) -> MatchingRuleDraft {
        let musterbank = MatchingRuleTarget(
            kind: .correspondent, instanceID: Self.musterbank.instanceID, name: "Musterbank AG")
        return MatchingRuleDraft(
            target: target ?? musterbank,
            editor: editor ?? MatchingRuleEditor(context: container.mainContext), probe: probe, sleep: sleep)
    }

    /// The draft is older than the store: the mode changed after the sheet opened (another device's edit arrived),
    /// and the user changed only the pattern. Only the pattern is written; the newer mode stays (review A of #57).
    /// Counter-proof: pass the draft's mode whether it changed or not → the stored mode is `any` again.
    @Test func onlyTheChangedFieldsAreSaved() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let record = try correspondent(Self.musterbank.instanceID, in: context)
        record.matchMode = .any
        record.matchPattern = "Musterbank"
        try context.save()
        let draft = draft(container)
        #expect(draft.state == .editing)
        #expect(draft.mode == .any && draft.pattern == "Musterbank")

        record.matchMode = .all
        try context.save()
        draft.pattern = "Autohaus"
        #expect(draft.changedMode == nil)
        #expect(draft.changedPattern == "Autohaus")
        #expect(draft.save())

        #expect(record.matchMode == .all, "the newer mode was overwritten")
        #expect(record.matchPattern == "Autohaus")

        // A mode the user picks is written.
        let second = self.draft(container)
        second.mode = .exact
        #expect(second.changedMode == .exact && second.changedPattern == nil)
        #expect(second.save())
        #expect(record.matchMode == .exact && record.matchPattern == "Autohaus")
    }

    /// Each problem of `MatchingRuleValidation` has its own line in the user's words (T8; review B of #205, N1), and the
    /// synchronous check runs on each change. Counter-proof: no check on a change → `("--` shows no problem.
    @Test func eachValidationResultHasItsLine() throws {
        let container = try makeContainer()
        let draft = draft(container)
        draft.mode = .regex
        draft.pattern = "(\"--"
        #expect(draft.shownProblem == .invalidRegularExpression)
        #expect(!draft.canSave)
        draft.pattern = "(a)\\1"
        #expect(draft.shownProblem == .backReference)
        draft.pattern = String(repeating: "a", count: MatchingLimits.patternLength + 1)
        #expect(draft.shownProblem == .tooLong)
        // The same text is no problem for a word mode, which does not compile it.
        draft.mode = .any
        draft.pattern = "(\"--"
        #expect(draft.shownProblem == nil)
        #expect(draft.canSave)

        let english = Locale(identifier: "en_US")
        let lines: [(MatchingRuleValidation.Problem, String)] = [
            (.tooLong, "The pattern can have at most 1,000 characters."),
            (.invalidRegularExpression, "This regular expression is not valid."),
            (.tooSlow, "This regular expression takes too long to check."),
            (.backReference, "Back-references such as \\1 or \\k<name> are not supported."),
        ]
        for (problem, line) in lines {
            var resource = MatchingRuleText.problem(problem)
            resource.locale = english
            #expect(String(localized: resource) == line)
        }
    }

    /// The probe runs after the quiet period, only for the newest pattern, and Save stays disabled until it answered;
    /// a slow pattern then shows "takes too long" and keeps Save disabled (plan §8, review N3 b). Counter-proofs: no
    /// debounce (probe at once) → "a" is probed too; Save enabled while probing → `canSave` is true before the answer.
    @Test func theProbeIsDebouncedAndSaveWaitsForIt() async throws {
        let container = try makeContainer()
        let debounce = ManualDebounce()
        let probed = Mutex<[String]>([])
        let draft = draft(
            container,
            probe: { pattern in
                probed.withLock { $0.append(pattern) }
                return pattern == "slow" ? .tooSlow : nil
            }, sleep: debounce.sleep)

        draft.mode = .regex
        draft.pattern = "a"
        draft.pattern = "ab"
        #expect(draft.isProbing)
        #expect(!draft.canSave, "Save while the probe has not answered")
        #expect(draft.shownProblem == nil, "nothing while checking")
        await debounce.waitForStarts(2)
        // Only the newest change's quiet period is waiting.
        debounce.fire()
        await draft.probeTask?.value
        #expect(probed.withLock { $0 } == ["ab"])
        #expect(!draft.isProbing)
        #expect(draft.canSave)

        draft.pattern = "slow"
        #expect(!draft.canSave)
        await debounce.waitForStarts(3)
        debounce.fire()
        await draft.probeTask?.value
        #expect(probed.withLock { $0 } == ["ab", "slow"])
        #expect(draft.shownProblem == .tooSlow)
        #expect(!draft.canSave)
        #expect(!draft.save(), "a disabled Save writes nothing")
        #expect(try correspondent(Self.musterbank.instanceID, in: container.mainContext).matchMode == MatchMode.none)

        // A word mode needs no probe.
        draft.mode = .any
        #expect(!draft.isProbing)
        #expect(draft.canSave)
        #expect(debounce.started == 3)
    }

    /// A record with copies sharing its `instanceID` shows that state, never an editor (review A of #205, N6); a gone
    /// record says so. Counter-proof: read `copies` as `gone` → the first expectation fails.
    @Test func aRecordWithCopiesOrAGoneRecordShowsItsState() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let copy = Correspondent(name: "Musterbank AG")
        copy.instanceID = Self.musterbank.instanceID
        copy.matchMode = .any
        copy.matchPattern = "Bank"
        context.insert(copy)
        try context.save()

        let copied = draft(container)
        #expect(copied.state == .copies)
        #expect(!copied.canSave)

        let gone = draft(container, MatchingRuleTarget(kind: .tag, instanceID: UUID(), name: "Gone"))
        #expect(gone.state == .gone)
        #expect(!gone.canSave)
    }

    /// A newer build's mode is offered while it is the stored one, takes no pattern, and is kept on save; a failed
    /// save says so until the next change. Counter-proofs: leave `unknown` out of the options → the picker has no
    /// value to show; a failed save not recorded → no line.
    @Test func aNewerModeIsKeptAndAFailedSaveSaysSo() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let record = try correspondent(Self.musterbank.instanceID, in: context)
        record.matchModeRaw = "fuzzy"
        record.matchPattern = "Musterbank"
        try context.save()

        let draft = draft(container)
        #expect(draft.mode == .unknown)
        #expect(draft.modeOptions.last == .unknown)
        #expect(!draft.isPatternEnabled)
        #expect(draft.changedMode == nil)
        #expect(draft.save())
        #expect(record.matchModeRaw == "fuzzy")

        let failingEditor = MatchingRuleEditor(context: context, save: { _ in throw SaveFailed() })
        let failing = self.draft(container, editor: failingEditor)
        failing.mode = .any
        #expect(!failing.save())
        #expect(failing.saveFailed)
        #expect(record.matchModeRaw == "fuzzy", "the failed save was rolled back")
        failing.pattern = "Bank"
        #expect(!failing.saveFailed, "a change ends the line")
    }
}
