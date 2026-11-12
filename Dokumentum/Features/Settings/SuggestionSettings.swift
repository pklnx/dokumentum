import DokumentumCore
import DokumentumKit
import Foundation
import Observation

/// The "Suggestions" settings (#8, part 3; maintainer decisions P3–P6): this device's switch and the on-device model's
/// availability, for the Mac's Settings window and the iPhone's settings sheet. One instance for the app.
///
/// - **The switch** is `ClassificationSettings.isEnabled` (per device, never synced, on by default; P3, P4). The
///   processing queue reads it at each decision (T16). A change requests a run (`requestRun`): turned on, documents
///   whose text is recognised from then on get suggestions; turned off, documents waiting in `classify` on this
///   device finish without suggestions at that run, as the step's outcome table says ("the switch is off: `done`").
/// - **The availability** is the classifier's (`DocumentClassifying.availability`), the same value the queue decides
///   on. `observeAvailability()` follows its changes while a settings view is shown (T17); `refresh()` reads it again
///   when one appears, so a change while none was shown is not missed.
/// - While the model is `unavailable` the switch cannot be changed and the reason is shown (P5); while it is getting
///   ready (`notReady`) the switch works and a note says suggestions start once it is ready.
@MainActor
@Observable
final class SuggestionSettings {
    /// The model's availability as last read.
    private(set) var availability: ClassifierAvailability
    /// The switch as stored.
    private(set) var isEnabled: Bool

    @ObservationIgnored private let classifier: any DocumentClassifying
    @ObservationIgnored private let settings: ClassificationSettings
    @ObservationIgnored private let requestRun: @MainActor () -> Void

    /// - Parameters:
    ///   - classifier: the queue's classifier, so the settings show what the queue decides on.
    ///   - settings: the defaults the queue reads the switch from.
    ///   - requestRun: asks the processing queue for a run (`ProcessingScheduler.requestRun()`); nothing for a store
    ///     that runs no queue.
    init(
        classifier: any DocumentClassifying, settings: ClassificationSettings,
        requestRun: @escaping @MainActor () -> Void
    ) {
        self.classifier = classifier
        self.settings = settings
        self.requestRun = requestRun
        availability = classifier.availability
        isEnabled = settings.isEnabled
    }

    /// Whether the switch can be changed: not while the model is unavailable on this device.
    var canChangeSwitch: Bool {
        if case .unavailable = availability { return false }
        return true
    }

    /// Stores the switch and requests a run; nothing when it does not change or cannot be changed.
    func setEnabled(_ enabled: Bool) {
        guard canChangeSwitch, enabled != isEnabled else { return }
        settings.isEnabled = enabled
        isEnabled = enabled
        requestRun()
    }

    /// Reads the availability and the switch again.
    func refresh() {
        availability = classifier.availability
        isEnabled = settings.isEnabled
    }

    /// Follows the availability's changes until the stream ends or the task is cancelled (a view's `.task`).
    func observeAvailability() async {
        for await value in classifier.availabilityChanges() {
            availability = value
        }
    }
}
