import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Synchronization
import Testing

/// The setting in memory, for the indexer's tests (`SpotlightSettings` writes a `UserDefaults` suite).
final class TestSpotlightSwitch: SpotlightSettingStoring {
    private let value: Mutex<Bool>

    init(_ enabled: Bool = true) { value = Mutex(enabled) }

    var isEnabled: Bool { value.withLock { $0 } }

    func setEnabled(_ enabled: Bool) { value.withLock { $0 = enabled } }
}

/// Everything one test's indexer works on: a container, the in-memory index, the state and the setting. A new
/// `indexer(…)` on the same harness is the next launch.
struct SpotlightHarness {
    static let storeIdentity = "test|Test.store"
    static let untitled = "Untitled document"

    let container: ModelContainer
    let index: InMemorySpotlightIndex
    let state: InMemorySpotlightStateStore
    let setting: TestSpotlightSwitch

    init(
        container: ModelContainer? = nil, index: InMemorySpotlightIndex = InMemorySpotlightIndex(),
        state: InMemorySpotlightStateStore = InMemorySpotlightStateStore(), setting: TestSpotlightSwitch = .init()
    ) throws {
        self.container = try container ?? TestSupport.makeContainer()
        self.index = index
        self.state = state
        self.setting = setting
    }

    static func configuration(
        storeIdentity: String = storeIdentity, locale: String = "en_US",
        formatVersion: Int = SpotlightItem.formatVersion
    ) -> SpotlightIndexer.Configuration {
        SpotlightIndexer.Configuration(
            storeIdentity: storeIdentity, locale: Locale(identifier: locale), untitledTitle: untitled,
            formatVersion: formatVersion)
    }

    func indexer(
        _ configuration: SpotlightIndexer.Configuration = configuration(),
        stateStore: (any SpotlightStateStoring)? = nil,
        hooks: SpotlightIndexer.Hooks = .init()
    ) -> SpotlightIndexer {
        SpotlightIndexer(
            container: container, index: index, state: stateStore ?? state, settings: setting,
            configuration: configuration, hooks: hooks)
    }

    /// The items Spotlight has, by `instanceID`.
    func items() async -> [UUID: SpotlightItem] {
        var result: [UUID: SpotlightItem] = [:]
        for (key, item) in await index.items {
            if let id = UUID(uuidString: key) { result[id] = item }
        }
        return result
    }

    /// The `instanceID`s of every `index` call since the last `clearCalls()`.
    func pushed() async -> [UUID] { await index.indexedIdentifiers.compactMap(UUID.init(uuidString:)) }

    func deleted() async -> [UUID] { await index.deletedIdentifiers.compactMap(UUID.init(uuidString:)) }

    /// The fingerprints the state holds, by `instanceID`.
    func fingerprinted() -> Set<UUID> {
        Set((state.state?.fingerprints.keys).map { $0.compactMap(UUID.init(uuidString:)) } ?? [])
    }
}

/// Signals each pass's end; the reports are the indexer's own.
final class PassSignal: Sendable {
    let ended = TestSignal()

    var hooks: SpotlightIndexer.Hooks { SpotlightIndexer.Hooks(afterPass: { [ended] _ in ended.fire() }) }
}

/// Writes for the Spotlight tests, each in a fresh context of its own and saved at once, as another part of the app
/// would (an import, the processing queue's result write, an edit, the trash).
enum SpotlightStore {
    struct Fields {
        var title = "Dokument"
        var text = ""
        var correspondent: String?
        var documentType: String?
        var tags: [String] = []
        var thumbnail: Data?
        var documentDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var createdAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var isInbox = true
        /// A copy of an existing document (#205, #213).
        var instanceID: UUID?
    }

    /// A document as the import creates it: its text (and thumbnail) in the same save.
    @discardableResult
    static func insert(_ fields: Fields, in container: ModelContainer) throws -> UUID {
        try insert([fields], in: container)[0]
    }

    /// Several documents in one save.
    @discardableResult
    static func insert(_ all: [Fields], in container: ModelContainer) throws -> [UUID] {
        let context = ModelContext(container)
        var correspondents: [String: Correspondent] = [:]
        var types: [String: DocumentType] = [:]
        var tags: [String: DokumentumCore.Tag] = [:]
        let ids = all.map { fields -> UUID in
            let document = Document(title: fields.title, createdAt: fields.createdAt)
            if let instanceID = fields.instanceID { document.instanceID = instanceID }
            document.documentDate = fields.documentDate
            document.modifiedAt = fields.createdAt
            document.isInbox = fields.isInbox
            context.insert(document)
            if let name = fields.correspondent {
                let record = correspondents[name] ?? Correspondent(name: name)
                if correspondents[name] == nil { context.insert(record) }
                correspondents[name] = record
                document.correspondent = record
            }
            if let name = fields.documentType {
                let record = types[name] ?? DocumentType(name: name)
                if types[name] == nil { context.insert(record) }
                types[name] = record
                document.documentType = record
            }
            document.tags = fields.tags.map { name in
                if let tag = tags[name] { return tag }
                let tag = DokumentumCore.Tag(name: name)
                context.insert(tag)
                tags[name] = tag
                return tag
            }
            let text = DocumentText(documentID: document.id, extractedText: fields.text)
            context.insert(text)
            document.text = text
            if let data = fields.thumbnail {
                let thumbnail = DocumentThumbnail(documentID: document.id, imageData: data)
                context.insert(thumbnail)
                document.thumbnail = thumbnail
            }
            return document.instanceID
        }
        try context.save()
        return ids
    }

    /// `count` documents, numbered titles and texts, in one save.
    @discardableResult
    static func insert(count: Int, in container: ModelContainer) throws -> [UUID] {
        try insert(
            (0..<count).map { number in
                Fields(
                    title: "Akte \(number)", text: "Inhalt \(number)",
                    createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(number)))
            }, in: container)
    }

    /// The documents with `instanceID` (copies included), oldest first.
    static func documents(_ instanceID: UUID, in context: ModelContext) throws -> [Document] {
        try context.fetch(
            FetchDescriptor<Document>(
                predicate: #Predicate { $0.instanceID == instanceID }, sortBy: [SortDescriptor(\.createdAt)]))
    }

    static func edit(_ instanceID: UUID, in container: ModelContainer, _ change: (Document, ModelContext) -> Void)
        throws
    {
        let context = ModelContext(container)
        guard let document = try documents(instanceID, in: context).first else { throw Missing() }
        change(document, context)
        try context.save()
    }

    /// Writes the text in place in one save, as the processing queue's result write does (no `modifiedAt`).
    static func setText(_ text: String, of instanceID: UUID, in container: ModelContainer) throws {
        try edit(instanceID, in: container) { document, _ in document.text?.extractedText = text }
    }

    static func trash(_ instanceID: UUID, in container: ModelContainer, restore: Bool = false) throws {
        try edit(instanceID, in: container) { document, _ in
            document.deletedAt = restore ? nil : Date()
            document.touch()
        }
    }

    struct Missing: Error {}
}

struct SpotlightTestFailure: Error {}

/// A switch a hook reads, with what it should do.
final class HookSwitch: Sendable {
    private let operations = Mutex<Set<InMemorySpotlightIndex.Operation>>([])
    private let failures = Mutex(0)

    /// Fails every call of these operations from now on.
    func fail(_ operations: Set<InMemorySpotlightIndex.Operation>) { self.operations.withLock { $0 = operations } }

    func clear() { operations.withLock { $0 = [] } }

    /// How many calls it failed.
    var failed: Int { failures.withLock { $0 } }

    var hook: InMemorySpotlightIndex.Hook {
        { [self] call in try self.check(call) }
    }

    private func check(_ call: InMemorySpotlightIndex.Call) throws {
        guard operations.withLock({ $0.contains(call.operation) }) else { return }
        failures.withLock { $0 += 1 }
        throw SpotlightTestFailure()
    }
}
