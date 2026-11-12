import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import FoundationModels
import SwiftData
import Testing

@testable import DokumentumCore

// The Foundation Models classifier (#8, part 2). The only test file that imports the framework
// (`scripts/check-project.py`, review N6): it constructs the framework's errors for the mapping. Only
// `theModelClassifiesASyntheticBill` runs the model, and only where it is available.

/// The error mapping (review N5), the availability, the schema and the options, without the model.
struct FoundationModelsClassifierTests {
    // MARK: Errors

    @Test func declinesOfTheModel() {
        let cases: [(any Error, ClassificationFailure)] = [
            (
                LanguageModelError.refusal(.init(explanation: "No.", debugDescription: "refusal")),
                .declined(.refusal)
            ),
            (
                LanguageModelError.guardrailViolation(.init(debugDescription: "guardrail")),
                .declined(.guardrailViolation)
            ),
            (
                LanguageModelError.unsupportedLanguageOrLocale(
                    .init(languageCode: Locale.LanguageCode("tlh"), debugDescription: "language")),
                .declined(.unsupportedLanguage)
            ),
        ]
        for (error, expected) in cases {
            #expect(FoundationModelsClassifier.mapped(error) as? ClassificationFailure == expected)
        }
    }

    @Test func aRateLimitKeepsItsResetDate() {
        let reset = Date(timeIntervalSinceReferenceDate: 830_000_000)
        let limited = LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: "rate"))
        #expect(FoundationModelsClassifier.mapped(limited) as? ClassificationFailure == .rateLimited(until: reset))
        let withoutDate = LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "rate"))
        #expect(FoundationModelsClassifier.mapped(withoutDate) as? ClassificationFailure == .rateLimited(until: nil))
    }

    @Test func assetsThatAreUnavailableAreNotReady() {
        let error = SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "assets"))
        #expect(FoundationModelsClassifier.mapped(error) as? ClassificationFailure == .notReady)
    }

    /// Every other error stays as it is: a failed attempt (a cancellation's answer is dropped by the step).
    @Test func otherErrorsAreFailedAttempts() {
        let errors: [any Error] = [
            LanguageModelError.contextSizeExceeded(
                .init(contextSize: 8192, tokenCount: 12237, debugDescription: "context")),
            LanguageModelError.timeout(.init(debugDescription: "timeout")),
            LanguageModelError.unsupportedGenerationGuide(.init(schemaName: "Suggestion", debugDescription: "guide")),
            LanguageModelError.unsupportedTranscriptContent(.init(unsupportedContent: [], debugDescription: "content")),
            LanguageModelSession.Error.concurrentRequests,
            GeneratedContent.ParsingError(rawContent: "{", debugDescription: "parsing"),
            CancellationError(),
            ClassificationAnswer.Failure.notAnObject,
            TextBudget.Failure.noRoom,
            CocoaError(.fileReadUnknown),
        ]
        for error in errors {
            let mapped = FoundationModelsClassifier.mapped(error)
            #expect(!(mapped is ClassificationFailure), "\(error)")
            #expect(type(of: mapped) == type(of: error), "unchanged: \(error)")
        }
        #expect(FoundationModelsClassifier.mapped(CancellationError()) is CancellationError)
    }

    /// N5: the deprecated `LanguageModelSession.GenerationError` maps like its successors.
    @Test func theDeprecatedErrorsMapLikeTheirSuccessors() {
        for (name, error, expected) in DeprecatedErrorCases.all() {
            let mapped = FoundationModelsClassifier.mapped(error)
            if let expected {
                #expect(mapped as? ClassificationFailure == expected, "\(name)")
            } else {
                #expect(!(mapped is ClassificationFailure), "\(name)")
                #expect(type(of: mapped) == type(of: error), "unchanged: \(name)")
            }
        }
        #expect(DeprecatedErrorCases.all().count == 9, "every case of the deprecated error")
    }

    // MARK: Availability

    @Test func theAvailabilityAsTheStepReadsIt() {
        typealias Availability = SystemLanguageModel.Availability
        let cases: [(Availability, ClassifierAvailability)] = [
            (.available, .available),
            (.unavailable(.modelNotReady), .notReady),
            (.unavailable(.deviceNotEligible), .unavailable(.deviceNotEligible)),
            (.unavailable(.appleIntelligenceNotEnabled), .unavailable(.appleIntelligenceNotEnabled)),
        ]
        for (availability, expected) in cases {
            #expect(FoundationModelsClassifier.availability(availability) == expected)
        }
    }

    // MARK: Schema and options

    @Test func theOptionsAreGreedyWithALimitedAnswer() {
        #expect(
            FoundationModelsClassifier.options == GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 300))
    }

    @Test func theSchemaHasEveryFieldOptionalAndTagsOnlyFromTheList() throws {
        let schema = try Self.json(FoundationModelsClassifier.schema(tags: ["Strom", "Steuer"]))
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["title", "correspondent", "documentType", "tags", "issueDate"])
        #expect((schema["required"] as? [String])?.isEmpty == true, "every field optional")
        #expect(schema["x-order"] as? [String] == ["title", "correspondent", "documentType", "tags", "issueDate"])
        let title = try #require(properties["title"] as? [String: Any])
        #expect(title["type"] as? String == "string")
        #expect(title["description"] as? String == ClassificationPrompt.titleDescription)
        let tags = try #require(properties["tags"] as? [String: Any])
        #expect(tags["type"] as? String == "array")
        #expect(tags["maxItems"] as? Int == 3)
        #expect(tags["minItems"] as? Int == 0)
        let items = try #require(tags["items"] as? [String: Any])
        #expect(items["enum"] as? [String] == ["Strom", "Steuer"])
        #expect(tags["description"] as? String == ClassificationPrompt.tagsDescription)
    }

    @Test func theDateIsThreeIntegersInTheirRanges() throws {
        let schema = try Self.json(FoundationModelsClassifier.schema(tags: []))
        let date = try #require((schema["$defs"] as? [String: Any])?["IssueDate"] as? [String: Any])
        let properties = try #require(date["properties"] as? [String: [String: Any]])
        #expect(Set(date["required"] as? [String] ?? []) == ["day", "month", "year"])
        for (name, range) in [("day", 1...31), ("month", 1...12), ("year", 1900...2100)] {
            #expect(properties[name]?["type"] as? String == "integer", "\(name)")
            #expect(properties[name]?["minimum"] as? Int == range.lowerBound, "\(name)")
            #expect(properties[name]?["maximum"] as? Int == range.upperBound, "\(name)")
        }
    }

    @Test func withoutTagsTheSchemaHasNoTagField() throws {
        let schema = try Self.json(FoundationModelsClassifier.schema(tags: []))
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["title", "correspondent", "documentType", "issueDate"])
    }

    @Test func theTagChoicesAreCapped() throws {
        let known = KnownMetadata(tags: (1...200).map { "Tag \($0)" })
        let schema = try Self.json(FoundationModelsClassifier.schema(tags: ClassificationPrompt.tagChoices(known)))
        let tags = try #require((schema["properties"] as? [String: Any])?["tags"] as? [String: Any])
        #expect((tags["items"] as? [String: Any])?["enum"] as? [String] == (1...150).map { "Tag \($0)" })
    }

    private static func json(_ schema: GenerationSchema) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any])
    }
}

/// The real model (#8, part 2, T12): the synthetic bill of the plan's P-b through the classification step. Runs
/// where the model is available (the development Mac, also its iOS simulator on #138); skips wherever it is not
/// (the plan's probe P-m found the simulator without it). The simulator of a GitHub Actions macOS runner reports
/// the model as available but has no model assets (`ModelManagerError 1026`, "no underlying assets"), so the tests
/// also ask the model one trivial question first and are cancelled with the reason when even that fails.
struct FoundationModelsRealModelTests {
    static let availability = SystemLanguageModel.default.availability
    static let skipReason = Comment(rawValue: "The on-device model is not available here: \(availability)")

    /// Cancels the test (a skip with the reason) when the model reports itself available but cannot answer at all.
    /// A failure of the classification itself is not caught here: the preflight asks only a trivial question.
    static func requireAnsweringModel() async throws {
        do {
            _ = try await LanguageModelSession().respond(to: "Answer with the word yes.")
        } catch let error as LanguageModelError {
            try Test.cancel("The on-device model is available but cannot answer here (no assets?): \(error)")
        }
    }

    @Test(.enabled(if: availability == .available, skipReason), .timeLimit(.minutes(2)))
    func theModelClassifiesASyntheticBill() async throws {
        try await Self.requireAnsweringModel()
        let store = try ProcessingStore()
        defer { store.remove() }
        let clock = TestClock()
        let id = try store.insertClassify(text: syntheticBill)
        try store.insertMetadata(.correspondent, "Stadtwerke München GmbH")
        try store.insertMetadata(.correspondent, "Hausverwaltung Berger")
        try store.insertMetadata(.documentType, "Rechnung")
        try store.insertMetadata(.tag, "Strom")
        try store.insertMetadata(.tag, "Versicherung")
        let failures = store.failures(deviceA)
        let queue = ProcessingQueue(
            container: store.container, deviceID: deviceA, failures: failures, stage: textStage(),
            classifier: FoundationModelsClassifier(), calendar: testCalendar,
            watchdogSleep: ManualDebounce().sleep, now: clock.function)

        let report = await queue.run()

        #expect(report.classified == 1, "\(report)")
        let row = try store.classified(id)
        #expect(row.stateRaw == "done")
        // The correspondent is grounded in the text and matched to the existing record, not created again.
        #expect(row.correspondent == "Stadtwerke München GmbH")
        #expect(try store.correspondents() == ["Hausverwaltung Berger", "Stadtwerke München GmbH"])
        let date = testCalendar.dateComponents([.year, .month, .day], from: row.documentDate)
        #expect(date.year == 2026 && date.month == 1 && date.day == 14, "\(date)")
        #expect(row.title != "Scan 2027-04-20", "a title was suggested")
        #expect(Set(row.tags).isSubset(of: ["Strom", "Versicherung"]))
    }

    /// T8: a text of the #6 cap (500,000 bytes, about 190,000 tokens; the context holds 8,192, P-c, P-d) is cut to
    /// the budget, so the request does not exceed the context.
    @Test(.enabled(if: availability == .available, skipReason), .timeLimit(.minutes(2)))
    func aTextOfTheCapIsCutToTheBudget() async throws {
        try await Self.requireAnsweringModel()
        let text = String(repeating: syntheticBill + "\n", count: 500_000 / (syntheticBill.utf8.count + 1))
        #expect(text.utf8.count > 490_000)
        let suggestion = try await FoundationModelsClassifier().classify(
            text: text, known: KnownMetadata(correspondents: ["Stadtwerke München GmbH"]))
        #expect(SuggestionRules.check(suggestion, text: text, now: Date()).issueDate != nil, "\(suggestion)")
    }
}

/// The deprecated errors, constructed in a deprecated declaration (no warnings) and read through a protocol.
protocol DeprecatedErrorCasesProviding {
    static func cases() -> [(String, any Error, ClassificationFailure?)]
}

enum DeprecatedErrorCases: DeprecatedErrorCasesProviding {
    @available(iOS, deprecated: 27.0)
    @available(macOS, deprecated: 27.0)
    static func cases() -> [(String, any Error, ClassificationFailure?)] {
        typealias Old = LanguageModelSession.GenerationError
        let context = Old.Context(debugDescription: "old")
        return [
            ("refusal", Old.refusal(.init(transcriptEntries: []), context), .declined(.refusal)),
            ("guardrailViolation", Old.guardrailViolation(context), .declined(.guardrailViolation)),
            ("unsupportedLanguageOrLocale", Old.unsupportedLanguageOrLocale(context), .declined(.unsupportedLanguage)),
            ("rateLimited", Old.rateLimited(context), .rateLimited(until: nil)),
            ("assetsUnavailable", Old.assetsUnavailable(context), .notReady),
            ("exceededContextWindowSize", Old.exceededContextWindowSize(context), nil),
            ("decodingFailure", Old.decodingFailure(context), nil),
            ("unsupportedGuide", Old.unsupportedGuide(context), nil),
            ("concurrentRequests", Old.concurrentRequests(context), nil),
        ]
    }
}

extension DeprecatedErrorCasesProviding {
    /// Through the protocol: a direct call of the deprecated function would warn.
    static func all() -> [(String, any Error, ClassificationFailure?)] { cases() }
}

/// The plan's synthetic two-page bill (P-b): 2,023 bytes, invented names and numbers.
let syntheticBill = """
    Stadtwerke München GmbH
    Emmy-Noether-Straße 2 · 80992 München
    Kundenservice: 089 2361-0 · www.swm.de

    Herrn
    Robert Beispiel
    Lindwurmstraße 88
    80337 München

    Jahresabrechnung Strom 2025
    Rechnungsnummer: 4711-2025-0815
    Rechnungsdatum: 14.01.2026
    Kundennummer: 1002003004
    Vertragskonto: 200300400500
    Zählernummer: 1ESY1160123456

    Sehr geehrter Herr Beispiel,

    mit diesem Schreiben erhalten Sie Ihre Jahresabrechnung für den Abrechnungszeitraum 01.01.2025 bis \
    31.12.2025 für die Lieferstelle Lindwurmstraße 88, 80337 München.

    Ihr Verbrauch im Abrechnungszeitraum: 2.184 kWh (Vorjahr: 2.311 kWh)

    Zusammenfassung
    Arbeitspreis 2.184 kWh × 32,41 ct/kWh         707,83 €
    Grundpreis 365 Tage × 0,4467 €/Tag              163,05 €
    Nettobetrag                                     870,88 €
    Umsatzsteuer 19 %                               165,47 €
    Rechnungsbetrag brutto                        1.036,35 €
    Geleistete Abschlagszahlungen (12 × 90,00 €)  1.080,00 €
    Guthaben                                         43,65 €

    Das Guthaben in Höhe von 43,65 € überweisen wir Ihnen in den nächsten Tagen auf Ihr Konto.

    Ihr neuer monatlicher Abschlag ab Februar 2026 beträgt 88,00 €.
    \u{0C}
    Seite 2 von 2

    Erläuterungen zu Ihrer Abrechnung
    Zählerstand am 01.01.2025: 31.204 kWh (abgelesen)
    Zählerstand am 31.12.2025: 33.388 kWh (abgelesen)

    Mit freundlichen Grüßen
    Ihre Stadtwerke München

    Stadtwerke München GmbH · Sitz München · Geschäftsführung: Erika Mustermann
    """
