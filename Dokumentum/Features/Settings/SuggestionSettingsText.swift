import DokumentumKit
import Foundation

/// The texts of the "Suggestions" settings (#8, part 3; maintainer decisions P5, P6; plan review N8). The device's
/// name differs per platform: "this iPhone" on iOS, "this Mac" and "System Settings" on macOS.
enum SuggestionSettingsText {
    static let section: LocalizedStringResource = "Suggestions"
    static let toggle: LocalizedStringResource = "Suggest metadata with Apple Intelligence"

    /// What suggestions do (P5).
    static let explanation: LocalizedStringResource =
        "After text recognition, Apple Intelligence suggests a title, correspondent, document type, tags and date. Suggestions only fill empty fields and never change what you entered."

    /// The privacy statement (P6).
    static let privacy: LocalizedStringResource =
        "Suggestions are made on this device. The document's text is not sent anywhere for them."

    /// The consequence of a per-device switch (plan review N8): the text result write on this device decides, so a
    /// document whose text this device recognised while suggestions were off or unavailable is never classified,
    /// also not by the other device.
    static var perDevice: LocalizedStringResource {
        #if os(macOS)
            "Documents added on this Mac while suggestions are off or not available get none later, also not on your other devices."
        #else
            "Documents added on this iPhone while suggestions are off or not available get none later, also not on your other devices."
        #endif
    }

    /// The line under the switch for the model's availability; `nil` while it is available.
    static func availabilityNote(_ availability: ClassifierAvailability) -> LocalizedStringResource? {
        switch availability {
        case .available:
            return nil
        case .notReady:
            return "Apple Intelligence is getting ready. Suggestions start once it is ready."
        case .unavailable(.deviceNotEligible):
            #if os(macOS)
                return "Not available: this Mac does not support Apple Intelligence."
            #else
                return "Not available: this iPhone does not support Apple Intelligence."
            #endif
        case .unavailable(.appleIntelligenceNotEnabled):
            #if os(macOS)
                return
                    "Not available: Apple Intelligence is turned off. Turn it on in System Settings > Apple Intelligence & Siri."
            #else
                return
                    "Not available: Apple Intelligence is turned off. Turn it on in Settings > Apple Intelligence & Siri."
            #endif
        case .unavailable(.other):
            #if os(macOS)
                return "Not available: Apple Intelligence cannot be used on this Mac right now."
            #else
                return "Not available: Apple Intelligence cannot be used on this iPhone right now."
            #endif
        }
    }

    /// The note's symbol.
    static func availabilitySymbol(_ availability: ClassifierAvailability) -> String {
        switch availability {
        case .available: "checkmark.circle"
        case .notReady: "hourglass"
        case .unavailable: "exclamationmark.circle"
        }
    }
}
