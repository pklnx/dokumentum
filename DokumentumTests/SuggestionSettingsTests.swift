import DokumentumCore
import DokumentumKit
import Foundation
import Testing

@testable import Dokumentum

/// A classifier whose availability the test sets; `changes` are the values its stream yields before it ends. It is
/// never asked to classify.
private final class AvailabilityStub: DocumentClassifying, @unchecked Sendable {
    // Only the test's main actor reads and writes these.
    var availability: ClassifierAvailability
    var changes: [ClassifierAvailability] = []

    init(_ availability: ClassifierAvailability) {
        self.availability = availability
    }

    func availabilityChanges() -> AsyncStream<ClassifierAvailability> {
        let changes = changes
        return AsyncStream { continuation in
            for change in changes { continuation.yield(change) }
            continuation.finish()
        }
    }

    func classify(text: String, known: KnownMetadata) async throws -> ClassificationSuggestion {
        Issue.record("the settings never classify")
        return ClassificationSuggestion()
    }
}

private func rendered(_ resource: LocalizedStringResource?, _ locale: Locale) -> String? {
    guard var resource else { return nil }
    resource.locale = locale
    return String(localized: resource)
}

private let englishLocale = Locale(identifier: "en")
private let germanLocale = Locale(identifier: "de")

/// The "Suggestions" settings (#8, part 3; P3–P6, plan review N8): the switch, the availability with its reason, the
/// observation of availability changes, and the texts in English and German.
@MainActor
struct SuggestionSettingsTests {
    /// A defaults suite of its own and the settings on it; the caller removes the suite.
    private func makeSettings(
        _ availability: ClassifierAvailability, runs: @escaping @MainActor () -> Void = {}
    ) -> (SuggestionSettings, AvailabilityStub, suite: String) {
        let suite = "DokumentumTests-SuggestionSettings-\(UUID().uuidString)"
        let classifier = AvailabilityStub(availability)
        let model = SuggestionSettings(
            classifier: classifier, settings: ClassificationSettings(defaultsSuite: suite), requestRun: runs)
        return (model, classifier, suite)
    }

    // MARK: The switch (P3, P4, T16)

    /// P3: on when it was never set.
    @Test func theSwitchIsOnByDefault() {
        let (model, _, suite) = makeSettings(.available)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(model.isEnabled)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: ClassificationSettings.enabledKey) == nil)
    }

    /// The switch writes the key the processing queue reads (`classification.enabled` in the per-device suite), and
    /// each change asks the queue for a run; setting the same value again changes nothing.
    @Test func theSwitchWritesTheQueuesKeyAndRequestsARun() {
        var runs = 0
        let (model, _, suite) = makeSettings(.available) { runs += 1 }
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        model.setEnabled(false)
        #expect(!model.isEnabled)
        #expect(UserDefaults(suiteName: suite)?.object(forKey: ClassificationSettings.enabledKey) as? Bool == false)
        #expect(!ClassificationSettings(defaultsSuite: suite).isEnabled, "the queue reads it off")
        #expect(runs == 1)

        model.setEnabled(false)
        #expect(runs == 1, "no change, no run")

        model.setEnabled(true)
        #expect(ClassificationSettings(defaultsSuite: suite).isEnabled, "the queue reads it on")
        #expect(runs == 2)
    }

    /// The stored value is shown: a switch turned off earlier on this device is off at the next launch.
    @Test func theSwitchShowsTheStoredValue() {
        let suite = "DokumentumTests-SuggestionSettings-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        ClassificationSettings(defaultsSuite: suite).isEnabled = false
        let model = SuggestionSettings(
            classifier: AvailabilityStub(.available), settings: ClassificationSettings(defaultsSuite: suite),
            requestRun: {})
        #expect(!model.isEnabled)
    }

    /// While the model is unavailable the switch cannot be changed (P5): nothing is written and no run requested.
    /// While it is getting ready, it can.
    @Test(arguments: [
        (ClassifierAvailability.available, true), (.notReady, true), (.unavailable(.deviceNotEligible), false),
        (.unavailable(.appleIntelligenceNotEnabled), false), (.unavailable(.other), false),
    ])
    func theSwitchCanBeChangedUnlessTheModelIsUnavailable(availability: ClassifierAvailability, changeable: Bool) {
        var runs = 0
        let (model, _, suite) = makeSettings(availability) { runs += 1 }
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(model.canChangeSwitch == changeable)

        model.setEnabled(false)

        #expect(model.isEnabled == !changeable)
        #expect(ClassificationSettings(defaultsSuite: suite).isEnabled == !changeable)
        #expect(runs == (changeable ? 1 : 0))
    }

    // MARK: Availability (T17)

    /// The availability is the classifier's when the settings are made, and follows each change of its stream.
    @Test func theAvailabilityFollowsTheClassifiersChanges() async {
        let (model, classifier, suite) = makeSettings(.notReady)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        #expect(model.availability == .notReady)
        #expect(model.canChangeSwitch)

        classifier.changes = [.unavailable(.appleIntelligenceNotEnabled)]
        // The stub's stream ends after its changes: the observation returns once it handled them.
        await model.observeAvailability()
        #expect(model.availability == .unavailable(.appleIntelligenceNotEnabled))
        #expect(!model.canChangeSwitch)

        classifier.changes = [.notReady, .available]
        await model.observeAvailability()
        #expect(model.availability == .available)
        #expect(model.canChangeSwitch)
    }

    /// A change while no settings view followed the stream is read when one appears (`refresh()`), with the switch as
    /// stored now.
    @Test func refreshReadsTheAvailabilityAndTheSwitchAgain() {
        let (model, classifier, suite) = makeSettings(.notReady)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        classifier.availability = .available
        ClassificationSettings(defaultsSuite: suite).isEnabled = false
        #expect(model.availability == .notReady, "not read before the refresh")

        model.refresh()

        #expect(model.availability == .available)
        #expect(!model.isEnabled)
    }

    // MARK: Texts (P5, P6, N8)

    /// The line under the switch for each availability, in English and German; none while available.
    @Test func everyAvailabilityHasItsNote() {
        #if os(macOS)
            let device = ("this Mac", "Dieser Mac", "diesem Mac")
            let settings = ("System Settings", "Systemeinstellungen")
        #else
            let device = ("this iPhone", "Dieses iPhone", "diesem iPhone")
            let settings = ("Settings", "Einstellungen")
        #endif
        let expected: [(ClassifierAvailability, String, String)] = [
            (
                .notReady, "Apple Intelligence is getting ready. Suggestions start once it is ready.",
                "Apple Intelligence wird vorbereitet. Vorschläge beginnen, sobald es bereit ist."
            ),
            (
                .unavailable(.deviceNotEligible), "Not available: \(device.0) does not support Apple Intelligence.",
                "Nicht verfügbar: \(device.1) unterstützt Apple Intelligence nicht."
            ),
            (
                .unavailable(.appleIntelligenceNotEnabled),
                "Not available: Apple Intelligence is turned off. Turn it on in \(settings.0) > Apple Intelligence & Siri.",
                "Nicht verfügbar: Apple Intelligence ist ausgeschaltet. Es lässt sich in den \(settings.1) unter „Apple Intelligence & Siri“ einschalten."
            ),
            (
                .unavailable(.other), "Not available: Apple Intelligence cannot be used on \(device.0) right now.",
                "Nicht verfügbar: Apple Intelligence lässt sich auf \(device.2) gerade nicht verwenden."
            ),
        ]
        #expect(SuggestionSettingsText.availabilityNote(.available) == nil)
        for (availability, english, german) in expected {
            let note = SuggestionSettingsText.availabilityNote(availability)
            #expect(rendered(note, englishLocale) == english, "\(availability)")
            #expect(rendered(note, germanLocale) == german, "\(availability)")
        }
    }

    /// The section, the switch, what suggestions do, the privacy statement (P6) and the per-device consequence (N8),
    /// in English and German.
    @Test func theSectionsTextsAreTranslated() {
        #if os(macOS)
            let device = ("this Mac", "diesem Mac")
        #else
            let device = ("this iPhone", "diesem iPhone")
        #endif
        let expected: [(LocalizedStringResource, String, String)] = [
            (SuggestionSettingsText.section, "Suggestions", "Vorschläge"),
            (
                SuggestionSettingsText.toggle, "Suggest metadata with Apple Intelligence",
                "Metadaten mit Apple Intelligence vorschlagen"
            ),
            (
                SuggestionSettingsText.explanation,
                "After text recognition, Apple Intelligence suggests a title, correspondent, document type, tags and date. Suggestions only fill empty fields and never change what you entered.",
                "Nach der Texterkennung schlägt Apple Intelligence Titel, Korrespondent, Dokumenttyp, Tags und Datum vor. Vorschläge füllen nur leere Felder und ändern nichts, was eingegeben wurde."
            ),
            (
                SuggestionSettingsText.privacy,
                "Suggestions are made on this device. The document's text is not sent anywhere for them.",
                "Vorschläge entstehen auf diesem Gerät. Der Text des Dokuments wird dafür nirgendwohin gesendet."
            ),
            (
                SuggestionSettingsText.perDevice,
                "Documents added on \(device.0) while suggestions are off or not available get none later, also not on your other devices.",
                "Dokumente, die auf \(device.1) hinzugefügt werden, während Vorschläge aus oder nicht verfügbar sind, bekommen auch später keine, auch nicht auf deinen anderen Geräten."
            ),
        ]
        for (resource, english, german) in expected {
            #expect(rendered(resource, englishLocale) == english)
            #expect(rendered(resource, germanLocale) == german)
        }
    }

    // MARK: The injected availability (UI tests)

    /// `-UITestClassifierAvailability <case>` fixes the classifier's availability; without it, or with an unknown
    /// case, the classifier is the model's.
    @Test func theLaunchArgumentFixesTheAvailability() {
        let base = AvailabilityStub(.available)
        for name in UITestClassifierAvailability.Case.allCases {
            let classifier = UITestClassifierAvailability.classifier(
                base, arguments: ["Dokumentum", "-UITestClassifierAvailability", name.rawValue])
            #expect(classifier.availability == name.availability)
        }
        #expect(
            UITestClassifierAvailability.availability(arguments: ["-UITestClassifierAvailability", "deviceNotEligible"])
                == .unavailable(.deviceNotEligible))
        #expect(UITestClassifierAvailability.availability(arguments: ["-UITestClassifierAvailability", "x"]) == nil)
        #expect(UITestClassifierAvailability.availability(arguments: ["-UITestClassifierAvailability"]) == nil)
        #expect(UITestClassifierAvailability.classifier(base, arguments: []) as? AvailabilityStub === base)
    }

    /// The fixed classifier never asks the model while its availability is not `available`.
    @Test func aFixedUnavailableClassifierNeverAsksTheModel() async {
        let classifier = FixedAvailabilityClassifier(base: AvailabilityStub(.available), availability: .notReady)
        await #expect(throws: ClassificationFailure.notReady) {
            _ = try await classifier.classify(text: "text", known: KnownMetadata())
        }
    }
}
