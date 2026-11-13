import DokumentumKit
import Foundation

/// The sender that detection found in a text result write that set `classify` (plan of #11, Approach 5; the
/// maintainer's Q3: Apple Intelligence wins): per document, in the per-device `UserDefaults` next to
/// `ProcessingFailures` and `ClaimSightings`, **never synced**.
///
/// On the `classify` path the text write fills nothing detected. It stashes the sender here instead, and both exits
/// of the classification step fill it after the classifier, only into a correspondent that is still empty. The date
/// is not stashed: the classification write recomputes it from the stored text.
///
/// One dictionary under `defaultsKey`, keyed by the document's `instanceID`. An entry holds the `instanceID` of the
/// text record it was found with, and the sender (its name and, for a known correspondent, that record's
/// `instanceID` as a hint) or "nothing found". **Always written** by the text write, never kept because one exists
/// (re-review N-r1): an entry written for a save that then backed off is replaced by the next text write. Removed
/// when the classification write saved, and pruned with the failure counters when the document is `done` or gone.
/// Only the processing queue reads and writes it, one document at a time.
///
/// **The text record's key:** an entry whose text record is not the document's current one is ignored (a swapped
/// text record). Keying by the record's `instanceID` does not catch a text **rewritten in place**; no path rewrites
/// the text of a document in `classify` (Try again takes only `failed` documents, the re-queue pass only `done`
/// ones). The entry holds document content (a name) on this device only, and is never logged.
public struct DetectionStash: Sendable {
    /// The key in the per-device defaults.
    public static let defaultsKey = "detectionStash"

    /// What the text write found for one document.
    public struct Entry: Equatable, Sendable {
        /// The `instanceID` of the text record the sender was found with.
        public var text: UUID
        /// The sender, or `nil` when none was found (or the correspondent was not empty then).
        public var sender: DetectedSender?

        public init(text: UUID, sender: DetectedSender?) {
            self.text = text
            self.sender = sender
        }
    }

    /// The `UserDefaults` suite; `nil` is `UserDefaults.standard`.
    public let defaultsSuite: String?

    public init(defaultsSuite: String?) {
        self.defaultsSuite = defaultsSuite
    }

    /// Writes `entry` for `document`, replacing any entry it had.
    public func write(_ entry: Entry, for document: UUID) {
        var all = stored
        all[document.uuidString] = Self.encoded(entry)
        stored = all
    }

    /// The entry of `document`, or `nil`.
    public func entry(for document: UUID) -> Entry? {
        stored[document.uuidString].flatMap(Self.decoded)
    }

    /// Removes the entries of `documents`, in one write.
    public func forget(_ documents: [UUID]) {
        var all = stored
        var changed = false
        for document in documents where all.removeValue(forKey: document.uuidString) != nil { changed = true }
        if changed { stored = all }
    }

    /// The documents that have an entry.
    public var documents: [UUID] {
        stored.keys.compactMap(UUID.init(uuidString:))
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private var stored: [String: Any] {
        get { defaults.dictionary(forKey: Self.defaultsKey) ?? [:] }
        nonmutating set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                defaults.set(newValue, forKey: Self.defaultsKey)
            }
        }
    }

    private static func encoded(_ entry: Entry) -> [String: String] {
        var fields = ["text": entry.text.uuidString]
        switch entry.sender {
        case .existing(let id, let name):
            fields["kind"] = "existing"
            fields["hint"] = id.uuidString
            fields["name"] = name
        case .name(let name):
            fields["kind"] = "name"
            fields["name"] = name
        case nil:
            fields["kind"] = "none"
        }
        return fields
    }

    /// An entry as stored; `nil` for anything else (an entry of a newer build is ignored, like no entry).
    private static func decoded(_ value: Any) -> Entry? {
        guard let fields = value as? [String: String], let text = fields["text"].flatMap(UUID.init(uuidString:))
        else { return nil }
        switch fields["kind"] {
        case "existing":
            guard let hint = fields["hint"].flatMap(UUID.init(uuidString:)), let name = fields["name"] else {
                return nil
            }
            return Entry(text: text, sender: .existing(id: hint, name: name))
        case "name":
            guard let name = fields["name"] else { return nil }
            return Entry(text: text, sender: .name(name))
        case "none":
            return Entry(text: text, sender: nil)
        default:
            return nil
        }
    }
}
