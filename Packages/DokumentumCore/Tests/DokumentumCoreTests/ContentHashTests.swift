import DokumentumCore
import Foundation
import Testing

/// SHA-256 over the bytes as received, as 64 lowercase hex characters (FIPS 180-2 test vectors).
struct ContentHashTests {
    @Test func theTestVectors() {
        #expect(
            ContentHash.sha256(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            ContentHash.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
