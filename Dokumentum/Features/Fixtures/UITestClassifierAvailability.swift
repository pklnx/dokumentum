#if DEBUG
    import DokumentumCore
    import DokumentumKit
    import Foundation

    /// `-UITestClassifierAvailability <case>` (Debug builds only; #8, part 3): the app's classifier reports the
    /// availability of `<case>` instead of the model's, so a UI test and screenshots can show the settings' states
    /// that the test machine cannot produce (the simulator's model is never ready, the Mac's is available). The queue
    /// and the settings both read the injected value. An unknown case is ignored.
    enum UITestClassifierAvailability {
        static let argument = "-UITestClassifierAvailability"

        /// The cases, by the name the argument takes.
        enum Case: String, CaseIterable {
            case available, notReady, deviceNotEligible, appleIntelligenceNotEnabled, other

            var availability: ClassifierAvailability {
                switch self {
                case .available: .available
                case .notReady: .notReady
                case .deviceNotEligible: .unavailable(.deviceNotEligible)
                case .appleIntelligenceNotEnabled: .unavailable(.appleIntelligenceNotEnabled)
                case .other: .unavailable(.other)
                }
            }
        }

        /// The injected availability of this launch, `nil` without the argument or with an unknown case.
        static func availability(arguments: [String]) -> ClassifierAvailability? {
            guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
                let name = Case(rawValue: arguments[index + 1])
            else { return nil }
            return name.availability
        }

        /// `base` with the injected availability, or `base` itself without the argument.
        static func classifier(_ base: any DocumentClassifying, arguments: [String]) -> any DocumentClassifying {
            guard let availability = availability(arguments: arguments) else { return base }
            return FixedAvailabilityClassifier(base: base, availability: availability)
        }
    }

    /// A classifier whose availability is fixed and never changes; it asks `base` only while that availability is
    /// `available`, and otherwise throws `notReady` as a model whose assets went away would.
    struct FixedAvailabilityClassifier: DocumentClassifying {
        let base: any DocumentClassifying
        let availability: ClassifierAvailability

        func classify(text: String, known: KnownMetadata) async throws -> ClassificationSuggestion {
            guard availability == .available else { throw ClassificationFailure.notReady }
            return try await base.classify(text: text, known: known)
        }
    }
#endif
