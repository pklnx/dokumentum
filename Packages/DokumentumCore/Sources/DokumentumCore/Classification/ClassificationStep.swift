import DokumentumKit
import Foundation
import SwiftData

// The classification step of the processing queue (#8, part 1): the outcomes table and the result write are
// described on `ProcessingQueue`; docs/development/index.md, "The processing queue", has the whole step.

/// A checked answer whose write has not saved yet (T3): the next run writes it without asking the model again,
/// as long as the document still links the text record it was made from.
struct CachedSuggestion: Sendable {
    var text: PersistentIdentifier
    var suggestion: CheckedSuggestion
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
            waitForModel(id, held: held, into: &report)
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
        if claim != .keep {
            guard let claimed = writeClaim(id, expecting: held, into: &report) else { return true }
            held = claimed
        }
        let checked: CheckedSuggestion
        if let cached = suggestions[id], cached.text == input.text {
            checked = cached.suggestion
        } else {
            suggestions[id] = nil
            // One job at a time across both kinds of stage (T6).
            guard await stages.waitUntilStartable(), !Task.isCancelled else { return false }
            switch await askModel(classifier, id: id, input: input, held: held, into: &report) {
            case .answer(let answer): checked = answer
            case .handled: return true
            case .stop: return false
            }
            suggestions[id] = CachedSuggestion(text: input.text, suggestion: checked)
        }
        let outcome = Self.writeClassification(
            id, expecting: held, suggestion: checked, now: now(), calendar: calendar, in: container,
            beforeCheck: hooks.beforeCheck)
        switch outcome {
        case .saved:
            suggestions[id] = nil
            report.saves += 1
            report.done += 1
            report.classified += 1
        case .metAnotherSave:
            // Kept: the next run decides the fields again and writes without asking the model (T3).
            report.backedOff += 1
        case .changed:
            suggestions[id] = nil
            report.dropped += 1
        case .failed:
            break
        }
        return true
    }

    private enum ModelOutcome {
        case answer(CheckedSuggestion)
        /// The outcome is handled (waiting, finished or counted); nothing to write.
        case handled
        case stop
    }

    /// Counts the attempt, asks the model and handles every outcome but an answer.
    private func askModel(
        _ classifier: any DocumentClassifying, id: UUID, input: ClassificationInput, held: Held,
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
            return handle(failure, attempt: attempt, id: id, held: held, into: &report)
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
        _ failure: ClassificationFailure, attempt: ProcessingFailures.Attempt, id: UUID, held: Held,
        into report: inout ProcessingReport
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
            if finish(id, expecting: held, reason: nil, into: &report) { report.declined += 1 }
        case .rateLimited(let until):
            guard counter.refund(attempt) else {
                report.interrupted += 1
                return .stop
            }
            let resume = until ?? now().addingTimeInterval(ClassificationLimits.rateLimitPause)
            classificationPausedUntil = resume
            report.waiting += 1
            report.nextRetry = min(report.nextRetry ?? resume, resume)
            Log.processing.notice("Classification rate limited; attempt given back")
        case .notReady:
            guard counter.refund(attempt) else {
                report.interrupted += 1
                return .stop
            }
            waitForModel(id, held: held, into: &report)
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
    /// staleness is checked here, before the claim the rules would renew (N4).
    private func waitForModel(_ id: UUID, held: Held, into report: inout ProcessingReport) {
        switch ClassificationWait.decide(
            deviceID: held.deviceID, claimedAt: held.claimedAt, thisDevice: deviceID, now: now(),
            interval: takeoverInterval)
        {
        case .finish:
            finish(id, expecting: held, reason: "notReady", into: &report)
        case .wait(let until):
            report.waiting += 1
            report.nextClaimEnd = min(report.nextClaimEnd ?? until, until)
        case .claimAndWait:
            guard let claimed = writeClaim(id, expecting: held, into: &report), let claimedAt = claimed.claimedAt
            else { return }
            let until = claimedAt.addingTimeInterval(takeoverInterval)
            report.waiting += 1
            report.nextClaimEnd = min(report.nextClaimEnd ?? until, until)
        }
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
        suggestions[id] = nil
        let outcome = write(.classification, id, expecting: held) { $0.processingState = .done }
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
    /// 2. it decides each field's emptiness on this row (`ClassificationFields`);
    /// 3. it resolves the names against the live records it fetches (`MetadataMatcher`): an existing correspondent
    ///    or type is linked, else one is inserted (P1); a tag only when exactly one live tag has the name, never a
    ///    new one;
    /// 4. it sets only the fields it fills and `done`, and never calls `touch()`;
    /// 5. it reads the document row and every metadata row it found linked or links again in a second fresh
    ///    context (`RowState.read`) and saves only if all are unchanged (a linked record must still be live under
    ///    the same name); otherwise it rolls back and writes nothing.
    static func writeClassification(
        _ instanceID: UUID, expecting held: Held, suggestion: CheckedSuggestion, now: Date, calendar: Calendar,
        in container: ModelContainer, beforeCheck: (@Sendable (Write) throws -> Void)?
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
            for tag in document.tags ?? [] {
                related[RowKey(entity: .tag, instanceID: tag.instanceID)] = RowState.capture(tag)
            }
            let fields = ClassificationFields(
                title: document.title, createdAt: document.createdAt, modifiedAt: document.modifiedAt,
                documentDate: document.documentDate, hasCorrespondent: document.correspondent != nil,
                hasDocumentType: document.documentType != nil, hasTags: !(document.tags ?? []).isEmpty)
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
                        let record = live.first(where: { $0.instanceID == id })
                    else { continue }
                    related[RowKey(entity: .tag, instanceID: id)] = RowState.capture(record)
                    linked.append(record)
                }
                if !linked.isEmpty { document.tags = linked }
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

    /// `records` in the repair's keeper order: oldest `createdAt`, then the smaller `instanceID.uuidString`.
    private static func keeperOrder<T>(_ records: [T], _ createdAt: KeyPath<T, Date>, _ instanceID: KeyPath<T, UUID>)
        -> [T]
    {
        records.sorted { lhs, rhs in
            lhs[keyPath: createdAt] != rhs[keyPath: createdAt]
                ? lhs[keyPath: createdAt] < rhs[keyPath: createdAt]
                : lhs[keyPath: instanceID].uuidString < rhs[keyPath: instanceID].uuidString
        }
    }
}
