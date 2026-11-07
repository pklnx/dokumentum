import CryptoKit
import Foundation

/// The duplicate fingerprint of an import (plan.md, section 3.4): SHA-256 over the bytes exactly as
/// received, as 64 lowercase hex characters. Never over a PDF built or layered later. Ported from the
/// predecessor's `DocumentImporter.sha256`.
public enum ContentHash {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ContentHash {
    /// The hash of `items` concatenated in their order, without building the concatenation: the fingerprint
    /// of photos picked together (the predecessor's `PendingImport.make`). Equal to `sha256` of the joined
    /// bytes.
    public static func sha256(concatenating items: [Data]) -> String {
        var hasher = SHA256()
        for item in items { hasher.update(data: item) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
