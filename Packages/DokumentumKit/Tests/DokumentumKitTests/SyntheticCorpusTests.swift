import DokumentumKit
import Foundation
import Testing

struct SyntheticCorpusTests {
    @Test func theSameSeedGivesTheSameCorpus() {
        let first = SyntheticCorpus(count: 40, seed: 7)
        let second = SyntheticCorpus(count: 40, seed: 7)
        #expect(first.checksum() == second.checksum())
        #expect(first.documents == second.documents)
        #expect(SyntheticCorpus(count: 40, seed: 8).checksum() != first.checksum())
    }

    /// Pinned, so the corpus is the same on every platform and run (`kit-linux` runs this too): the device and
    /// the simulator measure the same archive.
    @Test func theChecksumIsPinned() {
        #expect(SyntheticCorpus(count: 20).checksum() == 17_324_324_361_843_453_377)
    }

    @Test func theDistributionFollowsThePlan() {
        let corpus = SyntheticCorpus(count: 1_000)
        #expect(corpus.tags.count == 40)
        #expect(corpus.tags.filter { $0.parentInstanceID == nil }.count == 10)
        #expect(corpus.correspondents.count == 60)
        #expect(corpus.documentTypes.count == 12)
        #expect(Set(corpus.documents.map(\.instanceID)).count == 1_000)

        let pages = corpus.documents.map(\.pageCount)
        #expect((540...660).contains(pages.filter { $0 == 1 }.count))
        #expect((240...360).contains(pages.filter { (2...5).contains($0) }.count))
        #expect((60...120).contains(pages.filter { (6...20).contains($0) }.count))
        #expect((3...20).contains(pages.filter { (30...100).contains($0) }.count))
        #expect(pages.allSatisfy { (1...100).contains($0) })

        #expect((70...130).contains(corpus.documents.filter(\.isInbox).count))
        #expect((3...20).contains(corpus.documents.filter { $0.deletedAt != nil }.count))
        #expect(corpus.documents.allSatisfy { $0.tagIDs.count <= 4 })
        #expect(corpus.documents.contains { $0.tagIDs.isEmpty })
        #expect(corpus.documents.contains { $0.tagIDs.count == 4 })
        #expect((850...950).contains(corpus.documents.filter { $0.correspondent != nil }.count))
        #expect(corpus.snapshot.documents.count == 1_000)
    }

    @Test func threeTextsFillTheCap() {
        let corpus = SyntheticCorpus(count: 200)
        let capped = corpus.documents.filter(\.fillsTextCap)
        #expect(capped.count == 3)
        for document in capped {
            let bytes = corpus.text(of: document).utf8.count
            #expect(bytes <= SyntheticCorpus.textCap)
            #expect(bytes > SyntheticCorpus.textCap - 1_000)
        }
    }

    @Test func textsHavePagesHyphenationsUmlautsAndNumbers() {
        let corpus = SyntheticCorpus(count: 100)
        let document = corpus.documents.first { $0.pageCount >= 3 && !$0.fillsTextCap }!
        let text = corpus.text(of: document)
        #expect(text.split(separator: "\u{000C}", omittingEmptySubsequences: false).count == document.pageCount)
        #expect((1_700...2_300).contains(text.count / document.pageCount))
        #expect(text.contains("-\n"))
        #expect(text.contains { "äöüßÄÖÜ".contains($0) })
        #expect(text.contains { $0.isNumber })
        #expect(corpus.text(of: document) == text)
    }
}
