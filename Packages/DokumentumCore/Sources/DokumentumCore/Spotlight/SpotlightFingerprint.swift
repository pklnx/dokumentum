import CryptoKit
import DokumentumKit
import Foundation

/// What a Spotlight item was made of (#13, plan §3): SHA-256 over the document's canonical bytes and the item format
/// version, as 64 lowercase hex characters (as `ContentHash`). Equal fingerprints mean the item would be the same,
/// except for the text and the thumbnail, which the persistent history names.
public enum SpotlightFingerprint {
    public static func of(_ document: SpotlightDocument, formatVersion: Int = SpotlightItem.formatVersion) -> String {
        SHA256.hash(data: document.canonicalBytes(formatVersion: formatVersion)).map { String(format: "%02x", $0) }
            .joined()
    }
}
