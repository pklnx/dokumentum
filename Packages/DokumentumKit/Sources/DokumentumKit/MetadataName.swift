import Foundation

/// The name part of every merge key for tags, correspondents and document types.
public enum MetadataName {
    /// Case, diacritics and width folded, trimmed. "  MÜLLER " and "muller" are the same name.
    public static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
