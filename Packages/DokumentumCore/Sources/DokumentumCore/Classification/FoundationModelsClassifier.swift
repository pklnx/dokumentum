import DokumentumKit
import Foundation
import FoundationModels
import Observation

/// The classification step's model in the app (#8, part 2): Apple's on-device model through the FoundationModels
/// framework, `SystemLanguageModel.default` with its default guardrails, and nothing else. The text never leaves
/// the device. This is the only file of the app and the packages that imports the framework, and no file names the
/// framework's server model (`scripts/check-project.py` fails otherwise; plan of #8, T13).
///
/// One request (`classify`):
/// 1. the generation schema from `ClassificationPrompt.fields(tags:)`: title, correspondent and type as text, tags
///    as up to three choices of the known live tags (left out when there are none), the issue date as three
///    integers; every field optional;
/// 2. the text's budget (`TextBudget`): `ClassificationLimits.textTokens`, or less when the context
///    (`contextSize`) minus the instructions, the schema, the prompt without the text and the answer leaves less;
///    the head of the text cut to it with the model's `tokenCount`;
/// 3. a new session per request with `ClassificationPrompt.instructions`, greedy sampling (the same text gives the
///    same answer), at most `ClassificationLimits.responseTokens`;
/// 4. the answer read by `ClassificationAnswer` (only offered tags); the step then checks it with
///    `SuggestionRules`.
///
/// Every error is mapped by `mapped(_:)` into what the step distinguishes (`ClassificationFailure`).
public struct FoundationModelsClassifier: DocumentClassifying {
    private let model: SystemLanguageModel

    public init() {
        self.init(model: .default)
    }

    init(model: SystemLanguageModel) {
        self.model = model
    }

    public var availability: ClassifierAvailability {
        Self.availability(model.availability)
    }

    /// Each change of `availability` after the current value (T17), from the model's observation.
    public func availabilityChanges() -> AsyncStream<ClassifierAvailability> {
        let model = model
        let (stream, continuation) = AsyncStream.makeStream(
            of: ClassifierAvailability.self, bufferingPolicy: .bufferingNewest(1))
        let observation = Task {
            var last: ClassifierAvailability?
            for await value in Observations({ Self.availability(model.availability) }) {
                // The first value is the current one, not a change.
                if let last, last != value { continuation.yield(value) }
                last = value
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in observation.cancel() }
        return stream
    }

    public func classify(text: String, known: KnownMetadata) async throws -> ClassificationSuggestion {
        do {
            let tags = ClassificationPrompt.tagChoices(known)
            let schema = try Self.schema(tags: tags)
            let instructions = Instructions(ClassificationPrompt.instructions)
            let fixed =
                try await model.tokenCount(for: instructions) + model.tokenCount(for: schema)
                + model.tokenCount(for: ClassificationPrompt.prompt(text: "", known: known))
            let budget = TextBudget.textTokens(contextSize: model.contextSize, fixedTokens: fixed)
            let model = model
            let head = try await TextBudget.fit(text, tokens: budget) { try await model.tokenCount(for: $0) }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(
                to: ClassificationPrompt.prompt(text: head, known: known), schema: schema, options: Self.options)
            return try ClassificationAnswer.suggestion(json: response.content.jsonString, tags: tags)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Greedy sampling and the answer's limit (T9).
    static let options = GenerationOptions(
        samplingMode: .greedy, maximumResponseTokens: ClassificationLimits.responseTokens)

    /// The generation schema of `ClassificationPrompt.fields(tags:)`.
    static func schema(tags: [String]) throws -> GenerationSchema {
        let properties = ClassificationPrompt.fields(tags: tags).map { field in
            DynamicGenerationSchema.Property(
                name: field.name, description: field.description, schema: schema(of: field.kind), isOptional: true)
        }
        return try GenerationSchema(
            root: DynamicGenerationSchema(name: "Suggestion", properties: properties), dependencies: [])
    }

    private static func schema(of kind: ClassificationPrompt.Field.Kind) -> DynamicGenerationSchema {
        switch kind {
        case .text:
            return DynamicGenerationSchema(type: String.self)
        case .choices(let choices, let maximum):
            return DynamicGenerationSchema(
                arrayOf: DynamicGenerationSchema(name: "Tag", anyOf: choices), minimumElements: 0,
                maximumElements: maximum)
        case .date(let years):
            typealias Property = ClassificationPrompt.Property
            return DynamicGenerationSchema(
                name: "IssueDate",
                properties: [
                    .init(
                        name: Property.day, schema: DynamicGenerationSchema(type: Int.self, guides: [.range(1...31)])),
                    .init(
                        name: Property.month, schema: DynamicGenerationSchema(type: Int.self, guides: [.range(1...12)])),
                    .init(
                        name: Property.year, schema: DynamicGenerationSchema(type: Int.self, guides: [.range(years)])),
                ])
        }
    }

    // MARK: Availability and errors

    /// The model's availability as the step reads it (plan of #8, Approach 2).
    static func availability(_ availability: SystemLanguageModel.Availability) -> ClassifierAvailability {
        switch availability {
        case .available: .available
        case .unavailable(.modelNotReady): .notReady
        case .unavailable(.deviceNotEligible): .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable: .unavailable(.other)
        }
    }

    /// An error of a request as the step distinguishes it (plan of #8, Approach 2; review N5):
    ///
    /// | Error | Step |
    /// |---|---|
    /// | `refusal`, `guardrailViolation`, `unsupportedLanguageOrLocale` | `ClassificationFailure.declined` |
    /// | `rateLimited` | `ClassificationFailure.rateLimited(until:)` with its reset date (none in the old error) |
    /// | `SystemLanguageModel.Error.assetsUnavailable` | `ClassificationFailure.notReady` |
    /// | the same cases of the deprecated `LanguageModelSession.GenerationError` | the same |
    /// | `CancellationError`, every other error (`contextSizeExceeded`, `timeout`, a decoding failure, …) | unchanged: a failed attempt (a cancelled request's answer is dropped anyway) |
    static func mapped(_ error: any Error) -> any Error {
        if let error = error as? LanguageModelError {
            switch error {
            case .refusal: return ClassificationFailure.declined(.refusal)
            case .guardrailViolation: return ClassificationFailure.declined(.guardrailViolation)
            case .unsupportedLanguageOrLocale: return ClassificationFailure.declined(.unsupportedLanguage)
            case .rateLimited(let limit): return ClassificationFailure.rateLimited(until: limit.resetDate)
            default: return error
            }
        }
        if let error = error as? SystemLanguageModel.Error {
            switch error {
            case .assetsUnavailable: return ClassificationFailure.notReady
            @unknown default: return error
            }
        }
        return mappedDeprecated(error, LegacyErrors.self) ?? error
    }

    /// Calls the deprecated mapping through a protocol: a direct call would warn on every build.
    private static func mappedDeprecated<Legacy: LegacyErrorMapping>(_ error: any Error, _: Legacy.Type)
        -> ClassificationFailure?
    {
        Legacy.mapped(error)
    }
}

/// The mapping of `LanguageModelSession.GenerationError`, deprecated in 27 but still thrown by some paths (review N5
/// of #8). Kept in a deprecated declaration, so it compiles without warnings.
protocol LegacyErrorMapping {
    static func mapped(_ error: any Error) -> ClassificationFailure?
}

enum LegacyErrors: LegacyErrorMapping {
    @available(iOS, deprecated: 27.0)
    @available(macOS, deprecated: 27.0)
    static func mapped(_ error: any Error) -> ClassificationFailure? {
        guard let error = error as? LanguageModelSession.GenerationError else { return nil }
        switch error {
        case .refusal: return .declined(.refusal)
        case .guardrailViolation: return .declined(.guardrailViolation)
        case .unsupportedLanguageOrLocale: return .declined(.unsupportedLanguage)
        case .rateLimited: return .rateLimited(until: nil)
        case .assetsUnavailable: return .notReady
        default: return nil
        }
    }
}
