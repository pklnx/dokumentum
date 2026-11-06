import DokumentumKit

/// The title to show for a document, or `fallback` when it has no title of its own.
public func displayTitle(_ title: String, fallback: String) -> String {
    let normalized = normalizedTitle(title)
    return normalized.isEmpty ? fallback : normalized
}
