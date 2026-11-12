import Foundation

/// Which part of a document's text the model gets (plan of #8, Approach 3, T8): the head, at most
/// `ClassificationLimits.textTokens` tokens and never more than the context leaves.
///
/// The text is first cut by bytes (`ClassificationLimits.bytesPerToken`), at the last line break within the cut
/// (else the last whitespace, else the last whole character; a break or space is used only when it keeps at least
/// half of the cut), so a 500,000-byte text is never counted whole (it
/// would be about 190,000 tokens, P-c). The cut is then counted with the model's own tokenizer and, while it is
/// too long, cut again by the measured ratio: at most `ClassificationLimits.budgetRounds` counts. Form feeds (the
/// page separator) become blank lines.
public enum TextBudget {
    public enum Failure: Error, Equatable {
        /// The instructions, the schema, the prompt's lists and the answer leave no room for the text.
        case noRoom
    }

    /// The tokens the text may use: `ClassificationLimits.textTokens`, or less when `contextSize` minus the fixed
    /// part of the request (`fixedTokens`: instructions, schema, prompt without the text) and the answer
    /// (`ClassificationLimits.responseTokens`) leaves less. Never negative.
    public static func textTokens(contextSize: Int, fixedTokens: Int) -> Int {
        max(0, min(ClassificationLimits.textTokens, contextSize - fixedTokens - ClassificationLimits.responseTokens))
    }

    /// The head of `text` within `tokens`, counted with `count` (the model's tokenizer).
    ///
    /// Each round cuts `head(of:maxBytes:)` and counts it; a cut within `tokens` is returned. A cut that is too
    /// long is cut again at its bytes times `tokens / counted`, minus 5 %. After the last round the shorter cut is
    /// returned without another count: the context keeps room beyond the budget.
    /// - Throws: `Failure.noRoom` when `tokens` is not positive; any error of `count`.
    public static func fit(_ text: String, tokens: Int, count: (String) async throws -> Int) async throws -> String {
        guard tokens > 0 else { throw Failure.noRoom }
        let text = pages(text)
        var maxBytes = Int(Double(tokens) * ClassificationLimits.bytesPerToken)
        var cut = head(of: text, maxBytes: maxBytes)
        for _ in 0..<ClassificationLimits.budgetRounds {
            let counted = try await count(cut)
            guard counted > tokens else { return cut }
            let shrunk = Int(Double(cut.utf8.count) * Double(tokens) / Double(counted) * 0.95)
            maxBytes = min(maxBytes - 1, shrunk)
            cut = head(of: text, maxBytes: maxBytes)
        }
        return cut
    }

    /// The head of `text` with at most `maxBytes` UTF-8 bytes, cut at the last line break (else the last
    /// whitespace, else the last whole character), each only when it keeps at least half of the bytes; the break
    /// itself is left out. A text within `maxBytes` is returned whole. Form feeds become blank lines first.
    public static func head(of text: String, maxBytes: Int) -> String {
        let text = pages(text)
        guard text.utf8.count > maxBytes else { return text }
        guard maxBytes > 0 else { return "" }
        // The longest prefix of whole characters within `maxBytes`.
        var bytes = 0
        var end = text.startIndex
        var lastBreak: (index: String.Index, bytes: Int)?
        var lastSpace: (index: String.Index, bytes: Int)?
        for index in text.indices {
            let character = text[index]
            let size = character.utf8.count
            guard bytes + size <= maxBytes else { break }
            if character.isNewline {
                lastBreak = (index, bytes)
            } else if character.isWhitespace {
                lastSpace = (index, bytes)
            }
            bytes += size
            end = text.index(after: index)
        }
        // A cut that ends right before a break ends with a whole line. A break that would drop more than half of
        // the cut (one long line after a short one) is not used.
        let next = end < text.endIndex ? text[end] : nil
        if next?.isNewline == true { return String(text[..<end]) }
        if let lastBreak, lastBreak.bytes * 2 >= bytes { return String(text[..<lastBreak.index]) }
        if next?.isWhitespace == true { return String(text[..<end]) }
        if let lastSpace, lastSpace.bytes * 2 >= bytes { return String(text[..<lastSpace.index]) }
        return String(text[..<end])
    }

    /// The text with each form feed (the page separator of the text step) as a blank line.
    static func pages(_ text: String) -> String {
        text.contains("\u{0C}") ? text.replacingOccurrences(of: "\u{0C}", with: "\n\n") : text
    }
}
