import Foundation

/// Which live record a suggested name means (plan of #8, Approach 4, T10; P-l: a model writes "Amazon EU S.à r.l."
/// for a known "Amazon").
///
/// Correspondents and document types, in this order:
/// 1. a record with an equal `MetadataName.normalized` name: the first in the given order (the caller passes the
///    records in the repair's keeper order, as `DocumentEditor.createMetadata` picks one);
/// 2. otherwise by **word prefix**: the record's words start the suggestion's words, or the other way round
///    (words are the runs of letters and digits of the normalized name). The record with the most words wins; two
///    different names with equally many words match none;
/// 3. otherwise none: the caller creates a record (P1).
///
/// Tags (`tag(_:among:)`): only an equal normalized name, and only when exactly one live tag has it. The repair
/// keeps two live tags with the same name under different parents, so such a name is ambiguous and dropped
/// (review N7 of #8). Tags are never created.
public enum MetadataMatcher {
    public struct Record: Equatable, Sendable {
        public var id: UUID
        public var name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The record `name` means among the live `records` (in keeper order), or `nil`.
    public static func match(_ name: String, among records: [Record]) -> UUID? {
        let key = MetadataName.normalized(name)
        guard !key.isEmpty else { return nil }
        if let equal = records.first(where: { MetadataName.normalized($0.name) == key }) { return equal.id }
        let suggested = words(of: key)
        guard !suggested.isEmpty else { return nil }
        var best: (words: Int, name: String, id: UUID)?
        var tied = false
        for record in records {
            let recordKey = MetadataName.normalized(record.name)
            let known = words(of: recordKey)
            guard !known.isEmpty, isPrefix(known, of: suggested) || isPrefix(suggested, of: known) else { continue }
            if let current = best {
                if known.count > current.words {
                    best = (known.count, recordKey, record.id)
                    tied = false
                } else if known.count == current.words, recordKey != current.name {
                    tied = true
                }
            } else {
                best = (known.count, recordKey, record.id)
            }
        }
        return tied ? nil : best?.id
    }

    /// The one live tag named `name`, or `nil` when none or several have that normalized name.
    public static func tag(_ name: String, among tags: [Record]) -> UUID? {
        let key = MetadataName.normalized(name)
        guard !key.isEmpty else { return nil }
        let equal = tags.filter { MetadataName.normalized($0.name) == key }
        return equal.count == 1 ? equal[0].id : nil
    }

    static func words(of normalized: String) -> [Substring] {
        normalized.split { !($0.isLetter || $0.isNumber) }
    }

    private static func isPrefix(_ head: [Substring], of words: [Substring]) -> Bool {
        head.count <= words.count && zip(head, words).allSatisfy { $0 == $1 }
    }
}
