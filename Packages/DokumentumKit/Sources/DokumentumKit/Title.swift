import Foundation

/// A document title without the whitespace around it.
public func normalizedTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
}
