import DokumentumKit
import Foundation
import Testing

/// The index against a brute-force oracle (plan of #7, Tests): the same normalised words per document, but every
/// term checked against every word, without vocabulary, buffer, overflow or postings.
struct SearchIndexOracleTests {
    /// Each document's words, as the index should have them: normalised, plus the *a/o/u* form of *ae/oe/ue*.
    struct Oracle {
        var words: [UUID: Set<String>] = [:]

        static func words(of texts: [String]) -> Set<String> {
            var result: Set<String> = []
            for text in texts {
                for word in SearchTokenizer.words(of: text) {
                    result.insert(word)
                    if let form = SearchNormalizer.detranscribed(word) { result.insert(form) }
                }
            }
            return result
        }

        /// Every distinct word with the documents that have it, made once per round of queries.
        func entries() -> [([UInt8], Set<UUID>)] {
            var vocabulary: [String: Set<UUID>] = [:]
            for (id, words) in words {
                for word in words { vocabulary[word, default: []].insert(id) }
            }
            return vocabulary.map { (Array($0.key.utf8), $0.value) }
        }

        /// Every term must match some word of the document, by prefix, or from four characters by infix.
        static func matches(_ query: String, in entries: [([UInt8], Set<UUID>)]) -> Set<UUID> {
            let terms = SearchTokenizer.terms(of: query)
            guard !terms.isEmpty else { return [] }
            var result: Set<UUID>?
            for term in terms {
                var found: Set<UUID> = []
                for (form, infix) in zip(term.forms, term.allowsInfix) {
                    let needle = Array(form.utf8)
                    for (word, ids) in entries where Self.matches(word, needle, infix: infix) {
                        found.formUnion(ids)
                    }
                }
                result = result.map { $0.intersection(found) } ?? found
            }
            return result ?? []
        }

        /// Byte by byte, without the index's search: a prefix, or with `infix` anywhere.
        static func matches(_ word: [UInt8], _ needle: [UInt8], infix: Bool) -> Bool {
            let count = needle.count
            guard count <= word.count else { return false }
            return word.withUnsafeBufferPointer { word in
                needle.withUnsafeBufferPointer { needle in
                    let last = infix ? word.count - count : 0
                    var start = 0
                    while start <= last {
                        if word[start] == needle[0] {
                            var offset = 1
                            while offset < count && word[start + offset] == needle[offset] { offset += 1 }
                            if offset == count { return true }
                        }
                        start += 1
                    }
                    return false
                }
            }
        }
    }

    @Test func theIndexAgreesWithTheOracleThroughEditsAndMerges() {
        let corpus = SyntheticCorpus(count: 300, seed: 121)
        let tree = TagTree(corpus.tags)
        var random = TestRandom(seed: 0x0121)
        var index = SearchIndex()
        var oracle = Oracle()
        var metadata: [UUID: SearchFields] = [:]
        var texts: [UUID: String] = [:]

        func set(_ id: UUID, fields: SearchFields?, text: String?) {
            if let fields {
                index.setMetadata(fields, for: id)
                metadata[id] = fields
            }
            if let text {
                index.setText(text, for: id)
                texts[id] = text
            }
            oracle.words[id] = Oracle.words(of: (metadata[id]?.partsForTest ?? []) + [texts[id] ?? ""])
        }

        for document in corpus.documents {
            set(
                document.instanceID, fields: SearchFields(document.libraryDocument, tree: tree),
                text: corpus.text(of: document))
        }
        index.mergeOverflow()

        let small = corpus.documents.filter { !$0.fillsTextCap && $0.pageCount <= 2 }
        var pool = Self.pool(of: oracle)
        var added = 0
        var compared = 0
        var nonEmpty = 0
        for phase in 0..<5 {
            if phase > 0 {
                // Edits: new texts, new titles, removals, new documents. Phases 2 and 4 query before any merge.
                for _ in 0..<40 {
                    let ids = Array(oracle.words.keys).sorted { $0.uuidString < $1.uuidString }
                    let target = ids[random.below(ids.count)]
                    switch random.below(4) {
                    case 0:
                        set(target, fields: nil, text: corpus.text(of: small[random.below(small.count)]))
                    case 1:
                        let title =
                            Self.randomWord(from: pool, random: &random) + " "
                            + Self.randomWord(from: pool, random: &random)
                        set(target, fields: SearchFields(title: title + " Überweisung"), text: nil)
                    case 2:
                        index.remove(target)
                        oracle.words[target] = nil
                        metadata[target] = nil
                        texts[target] = nil
                    default:
                        added += 1
                        set(
                            SearchIndexTests.id(1_000 + added), fields: SearchFields(title: "Neu"),
                            text: corpus.text(of: small[random.below(small.count)]))
                    }
                }
                if phase % 2 == 1 { index.mergeOverflow() }
            }
            let entries = oracle.entries()
            pool = Self.pool(of: oracle)
            for _ in 0..<100 {
                let query = Self.randomQuery(from: pool, random: &random)
                let expected = Oracle.matches(query, in: entries)
                #expect(index.search(query) == expected, "query \(query)")
                compared += 1
                if !expected.isEmpty { nonEmpty += 1 }
            }
        }
        #expect(compared == 500)
        // The queries are not all misses.
        #expect(nonEmpty > 250)
    }

    /// Each document's words, sorted, in the order of the documents' ids: the same choices on every run.
    static func pool(of oracle: Oracle) -> [[String]] {
        oracle.words.sorted { $0.key.uuidString < $1.key.uuidString }.map { $0.value.sorted() }.filter { !$0.isEmpty }
    }

    static func randomWord(from pool: [[String]], random: inout TestRandom) -> String {
        let words = pool[random.below(pool.count)]
        return words[random.below(words.count)]
    }

    static func randomQuery(from pool: [[String]], random: inout TestRandom) -> String {
        let fixed = ["Müller", "mueller", "Köhler", "koehler", "Straße", "strasse", "Grüße", "œuvre", "zzzq", "12.03"]
        var terms: [String] = []
        for _ in 0..<(1 + random.below(3)) {
            let word = Array(randomWord(from: pool, random: &random).unicodeScalars)
            switch random.below(6) {
            case 0:
                terms.append(fixed[random.below(fixed.count)])
            case 1:
                // A prefix of 1 to 3 characters.
                terms.append(String(String.UnicodeScalarView(word.prefix(1 + random.below(3)))))
            case 2 where word.count >= 5:
                // An infix of 4 or more characters.
                let length = 4 + random.below(word.count - 3)
                let start = random.below(word.count - length + 1)
                terms.append(String(String.UnicodeScalarView(word[start..<(start + length)])))
            default:
                terms.append(String(String.UnicodeScalarView(word)))
            }
        }
        return terms.joined(separator: " ")
    }
}

extension SearchFields {
    var partsForTest: [String] { [title, correspondent, documentType] + tagPaths }
}
