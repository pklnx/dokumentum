import DokumentumCore
import DokumentumKit
import Foundation
import Observation

/// The record whose rule the sheet edits: a tag, correspondent or document type of the sidebar.
struct MatchingRuleTarget: Hashable, Sendable {
    let kind: MetadataKind
    let instanceID: UUID
    /// The record's name, the sheet's title.
    let name: String
}

/// The rule sheet's draft (plan of #10, §8; #200): the mode and pattern as the user edits them, the validation, and
/// the save through `MatchingRuleEditor`.
///
/// - **Validation:** `MatchingRuleValidation.check` (length, compilation, back-references) runs synchronously on each
///   change. For a regular expression that passes it, the probe runs **debounced** (`probeDelay`) and **off the main
///   actor** (`MatchingRuleValidation.probeConcurrently`, plan review N3 b); a newer change cancels the probe that is
///   waiting or running, and only the newest one's answer is shown.
/// - **Save is disabled** while a problem shows and while the probe has not answered (`canSave`).
/// - **Only the changed fields are written** (review A of #57): the mode when it differs from the one the sheet
///   opened with, the pattern likewise. A newer build's mode (`unknown`) is kept unless the user picks a mode.
/// - **A record with copies** sharing its `instanceID` shows that state (`copies`), not an editor: matching never
///   applies its rule, and the editor refuses it (review A of #205, N6).
@MainActor @Observable
final class MatchingRuleDraft: Identifiable {
    typealias Probe = @Sendable (String) async -> MatchingRuleValidation.Problem?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The quiet period before a regular expression is probed.
    static let probeDelay: Duration = .milliseconds(300)

    /// The production probe: the fixed probe texts within the run's budget, off the main actor.
    static let liveProbe: Probe = { pattern in
        await MatchingRuleValidation.probeConcurrently(regex: pattern)
    }

    enum State: Equatable {
        /// The live record's rule, editable.
        case editing
        /// The record has copies sharing its `instanceID`: its rule is never applied.
        case copies
        /// The record is gone or was merged away.
        case gone
    }

    let target: MatchingRuleTarget
    nonisolated var id: UUID { target.instanceID }
    private let editor: MatchingRuleEditor
    private let probe: Probe
    private let sleep: Sleep

    private(set) var state: State
    /// The rule as the sheet opened with it: the base of "what changed".
    private(set) var stored: MatchingRuleValue

    /// The picked mode.
    var mode: MatchMode {
        didSet { if mode != oldValue { validate() } }
    }
    /// The pattern as typed.
    var pattern: String {
        didSet { if pattern != oldValue { validate() } }
    }

    /// The synchronous check's problem.
    private(set) var problem: MatchingRuleValidation.Problem?
    /// The probe's problem, once it answered.
    private(set) var probeProblem: MatchingRuleValidation.Problem?
    /// Whether a probe is waiting for its quiet period or running.
    private(set) var isProbing = false
    /// The last save failed and was rolled back.
    private(set) var saveFailed = false
    /// The probe of the newest change, for tests: they await its `value`.
    private(set) var probeTask: Task<Void, Never>?
    /// Counts the changes: only the newest probe's answer is shown.
    private var generation = 0

    /// Reads the record's state from the editor's context.
    init(
        target: MatchingRuleTarget, editor: MatchingRuleEditor, probe: @escaping Probe = liveProbe,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.target = target
        self.editor = editor
        self.probe = probe
        self.sleep = sleep
        let recordState: MatchingRuleEditor.RecordState
        do {
            recordState = try editor.state(of: target.kind, target.instanceID)
        } catch {
            Log.store.error("Could not read a matching rule: \(Log.code(of: error), privacy: .public)")
            recordState = .gone
        }
        let value: MatchingRuleValue
        switch recordState {
        case .rule(let rule):
            state = .editing
            value = rule
        case .copies:
            state = .copies
            value = MatchingRuleValue(mode: .none, pattern: "")
        case .gone:
            state = .gone
            value = MatchingRuleValue(mode: .none, pattern: "")
        }
        stored = value
        mode = value.mode
        pattern = value.pattern
        // A stored rule that is not valid (it arrived by sync) shows its problem at once.
        validate()
    }

    /// The modes the picker offers: the five, and a newer build's mode while it is the stored one.
    var modeOptions: [MatchMode] {
        let modes: [MatchMode] = [.none, .any, .all, .exact, .regex]
        return stored.mode == .unknown ? modes + [.unknown] : modes
    }

    /// Whether the pattern field takes input: not for no rule, and not for a newer build's mode.
    var isPatternEnabled: Bool {
        switch mode {
        case .any, .all, .exact, .regex: true
        case .none, .unknown: false
        }
    }

    /// The problem the line under the field shows: the check's, else the probe's. Nothing while the probe runs.
    var shownProblem: MatchingRuleValidation.Problem? {
        problem ?? probeProblem
    }

    /// Whether Save is enabled.
    var canSave: Bool {
        state == .editing && shownProblem == nil && !isProbing
    }

    /// The mode to write: `nil` when the user did not change it.
    var changedMode: MatchMode? {
        mode == stored.mode || mode == .unknown ? nil : mode
    }

    /// The pattern to write: `nil` when the user did not change it.
    var changedPattern: String? {
        pattern == stored.pattern ? nil : pattern
    }

    /// Saves the changed fields. `true` when the sheet can close: saved, or nothing to save. A record that is gone
    /// or has copies by now shows that state; a failed save says so under the field.
    func save() -> Bool {
        guard canSave else { return false }
        do {
            switch try editor.save(target.kind, target.instanceID, mode: changedMode, pattern: changedPattern) {
            case .saved, .unchanged:
                return true
            case .noMetadata:
                state = (try? editor.state(of: target.kind, target.instanceID)) == .copies ? .copies : .gone
                return false
            case .invalid(let refused):
                problem = refused
                return false
            }
        } catch {
            Log.store.error("Could not save a matching rule: \(Log.code(of: error), privacy: .public)")
            saveFailed = true
            return false
        }
    }

    /// The checks after a change: the synchronous check now, the probe after the quiet period.
    private func validate() {
        saveFailed = false
        generation += 1
        probeTask?.cancel()
        probeTask = nil
        probeProblem = nil
        isProbing = false
        problem = MatchingRuleValidation.check(mode: mode, pattern: pattern)
        guard state == .editing, mode == .regex, problem == nil, !pattern.allSatisfy(\.isWhitespace) else { return }
        isProbing = true
        let generation = generation
        let pattern = pattern
        let probe = probe
        let sleep = sleep
        probeTask = Task { [weak self] in
            do {
                try await sleep(Self.probeDelay)
            } catch {
                return
            }
            let answer = await probe(pattern)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.probeProblem = answer
            self.isProbing = false
        }
    }
}
