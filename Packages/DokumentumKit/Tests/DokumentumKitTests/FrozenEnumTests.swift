import DokumentumKit
import Testing

/// Raw values sync between builds, so they are pinned as literals: renaming one fails here.
struct FrozenEnumTests {
    @Test func documentSourceRawValuesAreFrozen() {
        let table: [(DocumentSource, String)] = [(.file, "file"), (.scan, "scan"), (.image, "image")]
        #expect(table.count == DocumentSource.allCases.count)
        for (value, raw) in table {
            #expect(value.storedValue == raw)
            #expect(DocumentSource(storedValue: raw) == value)
        }
    }

    @Test func textSourceRawValuesAreFrozen() {
        let table: [(TextSource, String)] = [(.none, ""), (.pdfText, "pdfText"), (.vision, "vision")]
        #expect(table.count == TextSource.allCases.count - 1)
        for (value, raw) in table {
            #expect(value.storedValue == raw)
            #expect(TextSource(storedValue: raw) == value)
        }
    }

    @Test func processingStateRawValuesAreFrozen() {
        let table: [(ProcessingState, String)] = [
            (.pending, "pending"), (.processing, "processing"), (.done, "done"), (.failed, "failed"),
        ]
        #expect(table.count == ProcessingState.allCases.count - 1)
        for (value, raw) in table {
            #expect(value.storedValue == raw)
            #expect(ProcessingState(storedValue: raw) == value)
        }
    }

    @Test(arguments: ["fax", "FILE", " file", "unknown", "queued"])
    func unknownValuesReadAsTheFallback(raw: String) {
        #expect(DocumentSource(storedValue: raw) == .file)
        #expect(TextSource(storedValue: raw) == .unknown)
        #expect(ProcessingState(storedValue: raw) == .unknown)
    }

    @Test func anEmptyValueIsNoTextButAnUnknownSourceAndState() {
        #expect(TextSource(storedValue: "") == .none)
        #expect(DocumentSource(storedValue: "") == .file)
        #expect(ProcessingState(storedValue: "") == .unknown)
    }

    @Test func unknownHasNoStoredValueOfItsOwn() {
        #expect(TextSource.unknown.storedValue == nil)
        #expect(ProcessingState.unknown.storedValue == nil)
    }
}
