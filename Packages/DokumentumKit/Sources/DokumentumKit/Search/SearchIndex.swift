import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// The in-memory token index of the search (plan of #7, Approach 3, T1): normalised token → the documents that
/// have it. A plain value, Foundation only; the indexer (part 2) owns one per app and updates it off the main
/// actor.
///
/// - Documents get a slot (`Int32`) by `instanceID`; a removed document's slot is reused.
/// - Each token has postings (the slots that have it, sorted). A forward index per slot and field (metadata,
///   text) says which tokens to take back when a field changes or the document goes.
/// - Prefix lookups binary-search a **sorted vocabulary**; infix lookups scan a **vocabulary buffer**
///   (`\0token\0token…\0`), about 2 MB for 5,000 documents instead of their 37 MB of text (P-g, P-i).
/// - Tokens new since the last merge sit in a small unsorted **overflow** that every lookup scans too. It is merged
///   into the sorted vocabulary by `mergeOverflow()` at the end of a batch of updates, or by the index itself when
///   it grows past `overflowLimit` (T7). Tokens without postings are dropped at a merge.
///
/// Every word a text has is indexed in its normalised form and, when that contains *ae/oe/ue*, also in its
/// *a/o/u* form (Revision 1, B1), so "Müller", "Mueller" and "muller" find each other in every direction.
public struct SearchIndex: Sendable {
    /// A term typed with at least this many characters also matches inside a word ("bescheid" finds
    /// "Steuerbescheid"); a shorter one only at its start ("ung" does not find "Rechnung"). P1. Characters, not
    /// bytes, and of the word as typed, for every alternative form (`SearchTerm.allowsInfix`).
    public static let infixMinimumLength = 4

    /// What `statistics` reports.
    public struct Statistics: Sendable, Equatable {
        public var documents: Int
        /// Distinct tokens, overflow included, until the next merge also those without postings.
        public var tokens: Int
        public var postings: Int
        public var overflowTokens: Int

        public init(documents: Int, tokens: Int, postings: Int, overflowTokens: Int) {
            self.documents = documents
            self.tokens = tokens
            self.postings = postings
            self.overflowTokens = overflowTokens
        }
    }

    private enum Field {
        case metadata, text
    }

    /// The overflow is merged when it holds more than this many tokens, or more than a quarter of the sorted
    /// vocabulary, whichever is larger: while a build adds most tokens, merges stay amortised (deviation 2 in the
    /// PR of #121).
    public let overflowLimit: Int

    // Documents, by slot.
    private var slotIDs: [UUID?] = []
    private var slots: [UUID: Int32] = [:]
    private var freeSlots: [Int32] = []
    private var metadataFields: [SearchFields?] = []
    /// The token ids of each field, sorted and unique.
    private var metadataTokens: [[Int32]] = []
    private var textTokens: [[Int32]] = []

    // Vocabulary, by token id.
    private var tokenStrings: [String] = []
    private var tokenIDs: [String: Int32] = [:]
    private var postings: [[Int32]] = []
    private var freeTokenIDs: [Int32] = []
    /// Token ids in byte order of their tokens.
    private var sorted: [Int32] = []
    /// `\0` before, between and after the tokens of `sorted`.
    private var buffer: [UInt8] = [0]
    /// Where the bytes of `sorted[i]` start in `buffer`.
    private var offsets: [Int32] = []
    private var overflow: [Int32] = []

    private var cache = SearchNormalizer.Cache()

    public init(overflowLimit: Int = 2_000) {
        self.overflowLimit = max(1, overflowLimit)
    }

    // MARK: Updating

    /// Indexes the metadata of the document `id`, adding the document if it is new. Returns `false` when the
    /// fields equal those indexed: nothing is tokenised again (the metadata diff of part 2, T3).
    @discardableResult
    public mutating func setMetadata(_ fields: SearchFields, for id: UUID) -> Bool {
        let slot = self.slot(for: id)
        if metadataFields[Int(slot)] == fields { return false }
        metadataFields[Int(slot)] = fields
        var words: Set<String> = []
        for part in fields.parts { collectTokens(of: part, into: &words) }
        replace(.metadata, of: slot, with: tokenIDs(for: words))
        return true
    }

    /// Indexes the text of the document `id` in place of its previous text, adding the document if it is new.
    /// An empty text indexes nothing.
    public mutating func setText(_ text: String, for id: UUID) {
        let slot = self.slot(for: id)
        var words: Set<String> = []
        collectTokens(of: text, into: &words)
        replace(.text, of: slot, with: tokenIDs(for: words))
    }

    /// Removes the document `id` and everything indexed for it. Unknown ids are ignored.
    public mutating func remove(_ id: UUID) {
        guard let slot = slots[id] else { return }
        replace(.metadata, of: slot, with: [])
        replace(.text, of: slot, with: [])
        metadataFields[Int(slot)] = nil
        slotIDs[Int(slot)] = nil
        slots[id] = nil
        freeSlots.append(slot)
    }

    /// Merges the overflow into the sorted vocabulary, drops tokens without postings, and forgets the
    /// normalisation cache: the end of a build or of a batch of updates. Never part of a query.
    public mutating func mergeOverflow() {
        mergeVocabulary()
        cache.removeAll()
    }

    // MARK: Reading

    /// The documents indexed.
    public var documentIDs: Set<UUID> { Set(slots.keys) }

    public func contains(_ id: UUID) -> Bool { slots[id] != nil }

    /// The metadata indexed for `id`.
    public func metadata(for id: UUID) -> SearchFields? {
        slots[id].flatMap { metadataFields[Int($0)] }
    }

    public var statistics: Statistics {
        Statistics(
            documents: slots.count, tokens: tokenIDs.count, postings: postings.reduce(0) { $0 + $1.count },
            overflowTokens: overflow.count)
    }

    /// The documents that match every term of `text` (`SearchTokenizer.terms(of:)`). Empty for a text without
    /// terms.
    public func search(_ text: String) -> Set<UUID> {
        matches(SearchTokenizer.terms(of: text))
    }

    /// The documents that match every term: each in metadata or text, a term in one field and another term in the
    /// other field is a match. Empty for no terms.
    public func matches(_ terms: [SearchTerm]) -> Set<UUID> {
        guard !terms.isEmpty, !slotIDs.isEmpty else { return [] }
        let wordCount = (slotIDs.count + 63) / 64
        var result: [UInt64]?
        for term in terms {
            var bits = [UInt64](repeating: 0, count: wordCount)
            for form in term.forms { addMatches(of: form, infix: term.allowsInfix, to: &bits) }
            if var accumulated = result {
                var any: UInt64 = 0
                for index in 0..<wordCount {
                    accumulated[index] &= bits[index]
                    any |= accumulated[index]
                }
                if any == 0 { return [] }
                result = accumulated
            } else {
                result = bits
            }
        }
        var ids: Set<UUID> = []
        for (index, word) in (result ?? []).enumerated() where word != 0 {
            var remaining = word
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                remaining &= remaining - 1
                if let id = slotIDs[index * 64 + bit] { ids.insert(id) }
            }
        }
        return ids
    }

    // MARK: Lookup

    private func addMatches(of form: String, infix: Bool, to bits: inout [UInt64]) {
        let needle = Array(form.utf8)
        guard !needle.isEmpty else { return }
        if !infix {
            var index = lowerBound(needle)
            while index < sorted.count {
                let token = sorted[index]
                guard tokenStrings[Int(token)].utf8.starts(with: needle) else { break }
                setBits(of: token, in: &bits)
                index += 1
            }
            for token in overflow where tokenStrings[Int(token)].utf8.starts(with: needle) {
                setBits(of: token, in: &bits)
            }
        } else {
            buffer.withUnsafeBytes { haystack in
                var start = 0
                while let found = ByteSearch.firstOccurrence(of: needle, in: haystack, from: start) {
                    let position = sortedPosition(atOffset: found)
                    setBits(of: sorted[position], in: &bits)
                    start = position + 1 < offsets.count ? Int(offsets[position + 1]) : haystack.count
                }
            }
            for token in overflow where ByteSearch.contains(needle, in: tokenStrings[Int(token)]) {
                setBits(of: token, in: &bits)
            }
        }
    }

    private func setBits(of token: Int32, in bits: inout [UInt64]) {
        for slot in postings[Int(token)] {
            bits[Int(slot) >> 6] |= 1 << UInt64(slot & 63)
        }
    }

    /// The first position in `sorted` whose token is not below `needle` in byte order.
    private func lowerBound(_ needle: [UInt8]) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if tokenStrings[Int(sorted[middle])].utf8.lexicographicallyPrecedes(needle) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// The position in `sorted` of the token whose bytes contain `offset` of `buffer`.
    private func sortedPosition(atOffset offset: Int) -> Int {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = (low + high) / 2
            if Int(offsets[middle]) <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low - 1
    }

    // MARK: Maintenance

    private mutating func collectTokens(of text: String, into words: inout Set<String>) {
        SearchTokenizer.forEachWord(in: text, cache: &cache) { word in
            if words.insert(word).inserted, let form = SearchNormalizer.detranscribed(word) {
                words.insert(form)
            }
        }
    }

    private mutating func slot(for id: UUID) -> Int32 {
        if let slot = slots[id] { return slot }
        let slot: Int32
        if let free = freeSlots.popLast() {
            slot = free
            slotIDs[Int(slot)] = id
        } else {
            slot = Int32(slotIDs.count)
            slotIDs.append(id)
            metadataFields.append(nil)
            metadataTokens.append([])
            textTokens.append([])
        }
        slots[id] = slot
        return slot
    }

    /// The sorted, unique ids of `words`; new tokens go to the overflow.
    private mutating func tokenIDs(for words: Set<String>) -> [Int32] {
        var ids: [Int32] = []
        ids.reserveCapacity(words.count)
        for word in words {
            if let id = tokenIDs[word] {
                ids.append(id)
                continue
            }
            let id: Int32
            if let free = freeTokenIDs.popLast() {
                id = free
                tokenStrings[Int(id)] = word
            } else {
                id = Int32(tokenStrings.count)
                tokenStrings.append(word)
                postings.append([])
            }
            tokenIDs[word] = id
            overflow.append(id)
            ids.append(id)
        }
        return ids.sorted()
    }

    /// Replaces one field's tokens of `slot`. A token's posting changes only when the slot gains or loses it in
    /// both fields together.
    private mutating func replace(_ field: Field, of slot: Int32, with new: [Int32]) {
        let index = Int(slot)
        let old: [Int32]
        let other: [Int32]
        switch field {
        case .metadata:
            old = metadataTokens[index]
            other = textTokens[index]
            metadataTokens[index] = new
        case .text:
            old = textTokens[index]
            other = metadataTokens[index]
            textTokens[index] = new
        }
        for token in old where !Self.sortedContains(new, token) && !Self.sortedContains(other, token) {
            removePosting(token, slot)
        }
        for token in new where !Self.sortedContains(old, token) && !Self.sortedContains(other, token) {
            addPosting(token, slot)
        }
        if overflow.count > max(overflowLimit, sorted.count / 4) { mergeVocabulary() }
    }

    private static func sortedContains(_ values: [Int32], _ value: Int32) -> Bool {
        guard let first = values.first, let last = values.last, value >= first, value <= last else { return false }
        let position = insertionPoint(of: value, in: values)
        return position < values.count && values[position] == value
    }

    private static func insertionPoint(of value: Int32, in values: [Int32]) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private mutating func addPosting(_ token: Int32, _ slot: Int32) {
        let index = Int(token)
        if let last = postings[index].last, last >= slot {
            let position = Self.insertionPoint(of: slot, in: postings[index])
            if position < postings[index].count, postings[index][position] == slot { return }
            postings[index].insert(slot, at: position)
        } else {
            postings[index].append(slot)
        }
    }

    private mutating func removePosting(_ token: Int32, _ slot: Int32) {
        let index = Int(token)
        let position = Self.insertionPoint(of: slot, in: postings[index])
        if position < postings[index].count, postings[index][position] == slot {
            postings[index].remove(at: position)
        }
    }

    private mutating func mergeVocabulary() {
        var added: [Int32] = []
        for token in overflow {
            if postings[Int(token)].isEmpty {
                drop(token)
            } else {
                added.append(token)
            }
        }
        overflow.removeAll()
        added.sort { tokenStrings[Int($0)].utf8.lexicographicallyPrecedes(tokenStrings[Int($1)].utf8) }

        var merged: [Int32] = []
        merged.reserveCapacity(sorted.count + added.count)
        var left = 0
        var right = 0
        while left < sorted.count || right < added.count {
            if left < sorted.count && postings[Int(sorted[left])].isEmpty {
                drop(sorted[left])
                left += 1
                continue
            }
            let takeLeft: Bool
            if left == sorted.count {
                takeLeft = false
            } else if right == added.count {
                takeLeft = true
            } else {
                takeLeft = !tokenStrings[Int(added[right])].utf8
                    .lexicographicallyPrecedes(tokenStrings[Int(sorted[left])].utf8)
            }
            if takeLeft {
                merged.append(sorted[left])
                left += 1
            } else {
                merged.append(added[right])
                right += 1
            }
        }
        sorted = merged

        var newBuffer: [UInt8] = [0]
        newBuffer.reserveCapacity(buffer.count + added.count * 10)
        var newOffsets: [Int32] = []
        newOffsets.reserveCapacity(sorted.count)
        for token in sorted {
            newOffsets.append(Int32(newBuffer.count))
            newBuffer.append(contentsOf: tokenStrings[Int(token)].utf8)
            newBuffer.append(0)
        }
        buffer = newBuffer
        offsets = newOffsets
    }

    private mutating func drop(_ token: Int32) {
        let index = Int(token)
        tokenIDs[tokenStrings[index]] = nil
        tokenStrings[index] = ""
        freeTokenIDs.append(token)
    }
}

/// A byte search with the C library's `memchr` and `memcmp`, which Darwin and Glibc both export (`memmem` is a
/// GNU extension that Swift's Glibc module does not reliably import; deviation 1 in the PR of #121).
enum ByteSearch {
    /// The offset of the first occurrence of `needle` in `haystack` at or after `start`.
    static func firstOccurrence(of needle: [UInt8], in haystack: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard let base = haystack.baseAddress, !needle.isEmpty else { return nil }
        let count = haystack.count
        let first = Int32(needle[0])
        return needle.withUnsafeBytes { needleBytes -> Int? in
            guard let needleBase = needleBytes.baseAddress else { return nil }
            var position = start
            while position + needle.count <= count {
                guard let hit = memchr(base + position, first, count - position - needle.count + 1) else {
                    return nil
                }
                let offset = UnsafeRawPointer(hit) - base
                if memcmp(base + offset, needleBase, needle.count) == 0 { return offset }
                position = offset + 1
            }
            return nil
        }
    }

    static func contains(_ needle: [UInt8], in text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            firstOccurrence(of: needle, in: UnsafeRawBufferPointer(bytes), from: 0) != nil
        }
    }
}
