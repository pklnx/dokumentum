import DokumentumKit
import Foundation
import SwiftData

// The classification step of the processing queue (#8, part 1): the outcomes table and the result write are
// described on `ProcessingQueue`; docs/development/index.md, "The processing queue", has the whole step.

/// A model answer whose write has not saved yet (T3): the next run writes it without asking the model again, as
/// long as the document still links the text record it was made from. A decline is kept the same way, so a `done`
/// write that met another save does not ask the model a second time (reviews of #146, A N-b, B N-4).
struct CachedSuggestion: Sendable {
    enum Answer: Sendable {
        case suggestion(CheckedSuggestion)
        case declined
    }

    var text: PersistentIdentifier
    var answer: Answer
}

/// A request that threw `ClassificationFailure.notReady` (review B1 of #146): the step does not ask again before
/// `retryAt`, and finishes the document at `claimEnd`, the end of this device's claim the wait was decided on.
struct ModelWait: Sendable {
    var claimEnd: Date
    var retryAt: Date
}

extension ProcessingQueue {
    /// Whether a text result write sets `classify` now (besides the cut-off, which the write reads from the row):
    /// a classifier, the switch on, and the model not unavailable on this device. A model that is not ready yet
    /// still sets `classify`: the step waits for it.
    var classificationIsOn: Bool {
        guard let classifier, classificationSettings.isEnabled else { return false }
        if case .unavailable = classifier.availability { return false }
        return true
    }

    /// Handles one document in `classify` that the rules let this device process. Always ends in `done`, never
    /// `failed` (the text is fine). `false` ends the run (interrupted, cancelled, or stalled).
    func classify(
        _ candidate: Candidate, claim: ProcessingDecision.ClaimWrite, into report: inout ProcessingReport
    ) async -> Bool {
        let id = candidate.instanceID
        var held = Held(
            stateRaw: candidate.stateRaw, deviceID: candidate.input.deviceID, claimedAt: candidate.input.claimedAt,
            file: nil, checksFile: false)
        guard let classifier, classificationSettings.isEnabled else {
            finish(id, expecting: held, reason: "off", into: &report)
            return true
        }
        switch classifier.availability {
        case .unavailable(let reason):
            finish(id, expecting: held, reason: "unavailable.\(reason)", into: &report)
            return true
        case .notReady:
            waitForModel(id, decidedOn: held, held: held, into: &report)
            return true
        case .available:
            break
        }
        if let until = classificationPausedUntil {
            if now() < until {
                report.waiting += 1
                report.nextRetry = min(report.nextRetry ?? until, until)
                return true
            }
            classificationPausedUntil = nil
        }
        // A request threw `notReady` earlier: no new request before its retry time; the wait ends with the claim.
        if let wait = modelWaits[id] {
            if now() >= wait.claimEnd {
                finish(id, expecting: held, reason: "notReady", into: &report)
                return true
            }
            if now() < wait.retryAt {
                report.waiting += 1
                report.nextRetry = min(report.nextRetry ?? wait.retryAt, wait.retryAt)
                report.nextClaimEnd = min(report.nextClaimEnd ?? wait.claimEnd, wait.claimEnd)
                return true
            }
        }
        // The text and the known records, by key, in a context that ends with the read.
        guard let input = Self.readClassificationInput(of: id, in: container) else {
            report.dropped += 1
            return true
        }
        held.text = input.text
        guard
            ClassificationLimits.meaningfulCharacters(in: input.extractedText)
                >= ClassificationLimits.minimumTextCharacters
        else {
            finish(id, expecting: held, reason: "shortText", into: &report)
            return true
        }
        // The claim as the decision found it, before this run renews it: a thrown `notReady` is decided on it (B1).
        let decided = held
        if claim != .keep {
            guard let claimed = writeClaim(id, expecting: held, into: &report) else { return true }
            held = claimed
        }
        let checked: CheckedSuggestion
        if let cached = suggestions[id], cached.text == input.text {
            switch cached.answer {
            case .suggestion(let suggestion):
                checked = suggestion
            case .declined:
                if finish(id, expecting: held, reason: nil, into: &report) { report.declined += 1 }
                return true
            }
        } else {
            suggestions[id] = nil
            // One job at a time across both kinds of stage (T6).
            guard await stages.waitUntilStartable(), !Task.isCancelled else { return false }
            switch await askModel(classifier, id: id, input: input, decided: decided, held: held, into: &report) {
            case .answer(let answer): checked = answer
            case .handled: return true
            case .stop: return false
            }
            suggestions[id] = CachedSuggestion(text: input.text, answer: .suggestion(checked))
        }
        let outcome = Self.writeClassification(
            id, expecting: held, suggestion: checked, text: input.extractedText, now: now(), calendar: calendar,
            in: container, beforeCheck: hooks.beforeCheck)
        switch outcome {
        case .saved:
            forget(id)
            report.saves += 1
            report.done += 1
            report.classified += 1
        case .metAnotherSave:
            // Kept: the next run decides the fields again and writes without asking the model (T3).
            report.backedOff += 1
        case .changed:
            forget(id)
            report.dropped += 1
        case .failed:
            break
        }
        return true
    }

    /// The documents the queue keeps something in memory for (a cached answer, a wait for the model). For tests.
    var classificationMemory: Set<UUID> { Set(suggestions.keys).union(modelWaits.keys) }

    /// Drops what the queue keeps in memory for a document: its cached answer and its wait for the model.
    func forget(_ id: UUID) {
        suggestions[id] = nil
        modelWaits[id] = nil
    }

    /// Keeps the memory only for documents still in `classify` (review B N-5 of #146): one that another device
    /// finished, or that was deleted, leaves it.
    func forgetClassificationMemory(keeping candidates: [Candidate]) {
        let open = Set(candidates.filter { $0.input.state == .classify }.map(\.instanceID))
        for id in Set(suggestions.keys).union(modelWaits.keys) where !open.contains(id) { forget(id) }
    }

    private enum ModelOutcome {
        case answer(CheckedSuggestion)
        /// The outcome is handled (waiting, finished or counted); nothing to write.
        case handled
        case stop
    }

    /// Counts the attempt, asks the model and handles every outcome but an answer.
    /// - Parameters:
    ///   - decided: the claim as the decision found it, before this run's claim write.
    ///   - held: the claim the writes expect now.
    private func askModel(
        _ classifier: any DocumentClassifying, id: UUID, input: ClassificationInput, decided: Held, held: Held,
        into report: inout ProcessingReport
    ) async -> ModelOutcome {
        let counter = classificationFailures
        // Counted before the call: a request that never returns (a crash) stays counted.
        let attempt = counter.begin(id, at: now())
        guard attempt.number <= ProcessingClaimRules.failureLimit else {
            counter.fail(attempt)
            Log.processing.error(
                "Classification gave up: \(attempt.number - 1, privacy: .public) attempts never returned")
            finish(id, expecting: held, reason: "gaveUp", into: &report)
            return .handled
        }
        let text = input.extractedText
        let known = input.known
        let result = await race(attempt: attempt, counter: counter) { _ in
            .suggested(try await classifier.classify(text: text, known: known))
        }
        switch result {
        case .suggested(let suggestion):
            guard counter.succeed(attempt) else {
                report.interrupted += 1
                return .stop
            }
            return .answer(SuggestionRules.check(suggestion, text: text, now: now()))
        case .threw(let failure as ClassificationFailure):
            return handle(
                failure, attempt: attempt, id: id, text: input.text, decided: decided, held: held, into: &report)
        case .threw(let error):
            guard counter.fail(attempt) else {
                report.interrupted += 1
                return .stop
            }
            Log.processing.error(
                """
                Classification failed: \(Log.code(of: error), privacy: .public), attempt \
                \(attempt.number, privacy: .public) on this device
                """)
            failedAttempt(attempt, held: held, into: &report)
            return .handled
        case .returned:
            // Only the text stage answers so; counted like an error.
            guard counter.fail(attempt) else {
                report.interrupted += 1
                return .stop
            }
            failedAttempt(attempt, held: held, into: &report)
            return .handled
        case .timedOut:
            guard counter.fail(attempt) else {
                report.interrupted += 1
                return .stop
            }
            report.timedOut += 1
            Log.processing.error(
                "Classification timed out: no answer, attempt \(attempt.number, privacy: .public) on this device")
            failedAttempt(attempt, held: held, into: &report)
            guard stages.timedOutAlive < 2 else {
                report.stalled = true
                Log.processing.error("Processing stalled: two stages that timed out have not returned")
                return .stop
            }
            return .handled
        case .interrupted:
            report.interrupted += 1
            return .stop
        }
    }

    private func handle(
        _ failure: ClassificationFailure, attempt: ProcessingFailures.Attempt, id: UUID, text: PersistentIdentifier,
        decided: Held, held: Held, into report: inout ProcessingReport
    ) -> ModelOutcome {
        let counter = classificationFailures
        switch failure {
        case .declined:
            // Cleared: the model answered, and a decline is never asked again.
            guard counter.succeed(attempt) else {
                report.interrupted += 1
                return .stop
            }
            Log.processing.notice("Classification declined: \(failure.code, privacy: .public)")
            // Kept until the `done` write saved, so a write that meets another save does not ask again.
            suggestions[id] = CachedSuggestion(text: text, answer: .declined)
            if finish(id, expecting: held, reason: nil, into: &report) { report.declined += 1 }
        case .rateLimited(let until):
            guard counter.refund(attempt) else {
                report.interrupted += 1
                return .stop
            }
            // A reset date in the past (or none) still pauses: never a wake in the past (B N-1 of #146).
            let earliest = now().addingTimeInterval(ClassificationLimits.minimumRateLimitPause)
            let resume = max(until ?? now().addingTimeInterval(ClassificationLimits.rateLimitPause), earliest)
            classificationPausedUntil = resume
            report.waiting += 1
            report.nextRetry = min(report.nextRetry ?? resume, resume)
            Log.processing.notice("Classification rate limited; attempt given back")
        case .notReady:
            guard counter.refund(attempt) else {
                report.interrupted += 1
                return .stop
            }
            // Decided on the claim before this run renewed it (B1 of #146): a stale own claim ends the wait here.
            if let claimEnd = waitForModel(id, decidedOn: decided, held: held, into: &report) {
                let retryAt = min(now().addingTimeInterval(ClassificationLimits.notReadyRetry), claimEnd)
                modelWaits[id] = ModelWait(claimEnd: claimEnd, retryAt: retryAt)
                report.nextRetry = min(report.nextRetry ?? retryAt, retryAt)
            }
        }
        return .handled
    }

    /// A failed attempt: below the limit nothing is written and the backoff starts; the third writes `done`.
    private func failedAttempt(_ attempt: ProcessingFailures.Attempt, held: Held, into report: inout ProcessingReport) {
        guard attempt.number >= ProcessingClaimRules.failureLimit else {
            report.failures += 1
            if let retry = classificationFailures.backoff(for: attempt.document, now: now()).retryNotBefore {
                report.nextRetry = min(report.nextRetry ?? retry, retry)
            }
            return
        }
        finish(attempt.document, expecting: held, reason: "gaveUp", into: &report)
    }

    /// The model is not ready: wait, without an attempt, until this device's own claim is stale; then finish. The
    /// staleness is decided on `decided`, the claim before any renewal of this run (N4; review B1 of #146), and the
    /// writes expect `held`, the claim now (the same unless this run already wrote a claim). Returns the end of the
    /// wait when the document waits, `nil` when it was finished or nothing was written.
    @discardableResult
    private func waitForModel(
        _ id: UUID, decidedOn decided: Held, held: Held, into report: inout ProcessingReport
    ) -> Date? {
        let until: Date
        switch ClassificationWait.decide(
            deviceID: decided.deviceID, claimedAt: decided.claimedAt, thisDevice: deviceID, now: now(),
            interval: takeoverInterval)
        {
        case .finish:
            finish(id, expecting: held, reason: "notReady", into: &report)
            return nil
        case .wait(let end):
            until = end
        case .claimAndWait:
            if held != decided, held.deviceID == deviceID, let claimedAt = held.claimedAt {
                // This run already claimed it before the request.
                until = claimedAt.addingTimeInterval(takeoverInterval)
            } else {
                guard let claimed = writeClaim(id, expecting: held, into: &report), let claimedAt = claimed.claimedAt
                else { return nil }
                until = claimedAt.addingTimeInterval(takeoverInterval)
            }
        }
        report.waiting += 1
        report.nextClaimEnd = min(report.nextClaimEnd ?? until, until)
        return until
    }

    /// The claim write of the classification step: the state stays `classify`. The held state after it, or `nil`
    /// when it did not save.
    private func writeClaim(_ id: UUID, expecting held: Held, into report: inout ProcessingReport) -> Held? {
        let claimedAt = now()
        let outcome = write(.claim, id, expecting: held) { document in
            document.processingDeviceID = self.deviceID
            document.processingClaimedAt = claimedAt
        }
        guard count(outcome, into: &report) else { return nil }
        var claimed = held
        claimed.deviceID = deviceID
        claimed.claimedAt = claimedAt
        return claimed
    }

    /// Writes `done` without suggestions. `reason` (a fixed code) counts it as skipped and logs it; `nil` leaves
    /// the counting to the caller. `true` when it saved.
    @discardableResult
    private func finish(_ id: UUID, expecting held: Held, reason: String?, into report: inout ProcessingReport) -> Bool
    {
        let outcome = write(.classification, id, expecting: held) { $0.processingState = .done }
        // A write that met another save keeps the cached answer (a decline) for the next run.
        if outcome == .saved || outcome == .changed { forget(id) }
        guard count(outcome, into: &report) else { return false }
        report.done += 1
        if let reason {
            report.classificationSkipped += 1
            Log.processing.notice("Classification skipped: \(reason, privacy: .public)")
        }
        return true
    }
}

// MARK: - The synchronous steps

/// What the classification stage reads of one document.
struct ClassificationInput: Sendable {
    /// The text record, by key: the result write expects the same one.
    var text: PersistentIdentifier
    var extractedText: String
    var known: KnownMetadata
}

extension ProcessingQueue {
    /// The document's text, by key, and the live records the model may reuse, most used first and capped, in one
    /// context that ends with the read. `nil` when the document or its text record is gone.
    static func readClassificationInput(of instanceID: UUID, in container: ModelContainer) -> ClassificationInput? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            guard let document = try fetch(instanceID, in: context), let text = document.text else { return nil }
            let records = try RowRecords.fetchMetadata(in: context)
            func ranked(_ entries: [(name: String, uses: Int)], limit: Int) -> [String] {
                var seen: Set<String> = []
                return
                    entries
                    .sorted {
                        $0.uses != $1.uses
                            ? $0.uses > $1.uses : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    .filter { seen.insert(MetadataName.normalized($0.name)).inserted }
                    .prefix(limit).map(\.name)
            }
            let known = KnownMetadata(
                correspondents: ranked(
                    records.correspondents.filter(\.isLive).map { ($0.name, $0.documents?.count ?? 0) },
                    limit: ClassificationLimits.knownNames),
                documentTypes: ranked(
                    records.documentTypes.filter(\.isLive).map { ($0.name, $0.documents?.count ?? 0) },
                    limit: ClassificationLimits.knownNames),
                tags: ranked(
                    records.tags.filter(\.isLive).map { ($0.name, $0.documents?.count ?? 0) },
                    limit: ClassificationLimits.knownTags))
            return ClassificationInput(text: text.persistentModelID, extractedText: text.extractedText, known: known)
        } catch {
            Log.processing.error("Could not read a document's text: \(Log.code(of: error), privacy: .public)")
            return nil
        }
    }

    /// The classification's result write (T3), one synchronous call under the queue's discipline:
    /// 1. a fresh context fetches the document and re-checks state `classify`, the exact claim, not trashed and the
    ///    same text record (`held`);
    /// 2. it decides each field's emptiness on this row (`ClassificationFields`). Tags (#10, T13, P1): the tags are
    ///    empty unless the document has a user tag, a tag whose own rule does not match `text` (the text record
    ///    `held` names, as the step read it); only the rules of the document's own tags are evaluated (review N1),
    ///    and a tag whose rule is invalid, times out or sits on a tombstone is a user tag (N2);
    /// 3. it resolves the names against the live records it fetches (`MetadataMatcher`): an existing correspondent
    ///    or type is linked, else one is inserted (P1); a tag only when exactly one live tag has the name, never a
    ///    new one, and the tags are added to the document's rule tags;
    /// 4. it sets only the fields it fills and `done`, and never calls `touch()`;
    /// 5. it reads the document row and every metadata row it found linked or links again in a second fresh
    ///    context (`RowState.read`) and saves only if all are unchanged (a linked record must still be live under
    ///    the same name, and the rule of each of the document's tags unchanged); otherwise it rolls back and writes
    ///    nothing.
    static func writeClassification(
        _ instanceID: UUID, expecting held: Held, suggestion: CheckedSuggestion, text: String, now: Date,
        calendar: Calendar, in container: ModelContainer, beforeCheck: (@Sendable (Write) throws -> Void)?
    ) -> WriteOutcome {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            guard let document = try fetch(instanceID, in: context), held.matches(document) else {
                Log.processing.notice("A document changed since the queue decided; nothing written")
                return .changed
            }
            let read = RowState.capture(document)
            var related: [RowKey: RowState] = [:]
            if let record = document.correspondent {
                related[RowKey(entity: .correspondent, instanceID: record.instanceID)] = RowState.capture(record)
            }
            if let record = document.documentType {
                related[RowKey(entity: .documentType, instanceID: record.instanceID)] = RowState.capture(record)
            }
            // Every tag of the document, with its rule (T13): a rule edited in the window makes the write back off.
            let tags = document.tags ?? []
            for tag in tags {
                related[RowKey(entity: .tag, instanceID: tag.instanceID)] = RowState.capture(tag)
            }
            // T13: only needed when there are tags to add to.
            let hasUserTags = !tags.isEmpty && (suggestion.tags.isEmpty || Self.hasUserTag(tags, text: text))
            let fields = ClassificationFields(
                title: document.title, createdAt: document.createdAt, modifiedAt: document.modifiedAt,
                documentDate: document.documentDate, hasCorrespondent: document.correspondent != nil,
                hasDocumentType: document.documentType != nil, hasTags: !tags.isEmpty, hasUserTags: hasUserTags)
            if fields.titleIsEmpty, let title = suggestion.title, document.title != title {
                document.title = title
            }
            if fields.dateIsEmpty, let date = suggestion.issueDate,
                let stored = ClassificationFields.storedDate(
                    date, keepingTimeOf: document.documentDate, calendar: calendar),
                document.documentDate != stored
            {
                document.documentDate = stored
            }
            let metadata = try RowRecords.fetchMetadata(in: context)
            if fields.correspondentIsEmpty, let name = suggestion.correspondent {
                let live = keeperOrder(metadata.correspondents.filter(\.isLive), \.createdAt, \.instanceID)
                if let id = MetadataMatcher.match(name, among: live.map { .init(id: $0.instanceID, name: $0.name) }),
                    let record = live.first(where: { $0.instanceID == id })
                {
                    related[RowKey(entity: .correspondent, instanceID: id)] = RowState.capture(record)
                    document.correspondent = record
                } else {
                    let record = Correspondent(name: name, createdAt: now)
                    context.insert(record)
                    document.correspondent = record
                }
            }
            if fields.documentTypeIsEmpty, let name = suggestion.documentType {
                let live = keeperOrder(metadata.documentTypes.filter(\.isLive), \.createdAt, \.instanceID)
                if let id = MetadataMatcher.match(name, among: live.map { .init(id: $0.instanceID, name: $0.name) }),
                    let record = live.first(where: { $0.instanceID == id })
                {
                    related[RowKey(entity: .documentType, instanceID: id)] = RowState.capture(record)
                    document.documentType = record
                } else {
                    let record = DocumentType(name: name, createdAt: now)
                    context.insert(record)
                    document.documentType = record
                }
            }
            if fields.tagsAreEmpty, !suggestion.tags.isEmpty {
                let live = metadata.tags.filter(\.isLive)
                let candidates = live.map { MetadataMatcher.Record(id: $0.instanceID, name: $0.name) }
                var linked: [Tag] = []
                for name in suggestion.tags {
                    guard let id = MetadataMatcher.tag(name, among: candidates),
                        !linked.contains(where: { $0.instanceID == id }),
                        !tags.contains(where: { $0.instanceID == id }),
                        let record = live.first(where: { $0.instanceID == id })
                    else { continue }
                    related[RowKey(entity: .tag, instanceID: id)] = RowState.capture(record)
                    linked.append(record)
                }
                // Added to the rule tags the document may have (P1), never replacing them.
                if !linked.isEmpty { document.tags = tags + linked }
            }
            document.processingState = .done
            try beforeCheck?(.classification)
            let key = RowKey(entity: .document, instanceID: instanceID)
            let stored = try RowState.read(Set(related.keys).union([key]), in: container)
            guard stored[key] == read, related.allSatisfy({ stored[$0.key] == $0.value }) else {
                context.rollback()
                Log.processing.notice("A classification write met another save of its document and wrote nothing")
                return .metAnotherSave
            }
            try context.save()
            return .saved
        } catch {
            context.rollback()
            Log.processing.error("A classification write failed: \(Log.code(of: error), privacy: .public)")
            return .failed
        }
    }

    /// T13: whether `tags` (a document's, not empty) hold a user tag, one that its own rule does not explain on
    /// `text`. Only these tags' rules are evaluated (review N1), so an edit of an unrelated rule never makes the
    /// write back off. A tag without a rule, on a tombstone (N2), with an invalid rule or one that timed out (the
    /// outcome leaves it out) is a user tag.
    static func hasUserTag(_ tags: [Tag], text: String) -> Bool {
        let rules = tags.compactMap(MatchingStore.liveRule)
        guard !rules.isEmpty else { return true }
        let ruleTags = MatchingRules.evaluate(text: text, rules: rules, budget: .production).tags
        return tags.contains { !ruleTags.contains($0.instanceID) }
    }
}
