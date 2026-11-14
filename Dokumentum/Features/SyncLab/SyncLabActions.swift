#if DEBUG
    import DokumentumCore
    import DokumentumKit
    import Foundation
    import SwiftData

    /// The Sync lab's writes that bypass the app's code paths (plan of #31, T8, Revision 1 note 2). Everything else the
    /// lab writes goes through `DocumentImporter`, `DocumentEditor` and `DocumentTrash`. Debug builds only; Core has no
    /// API for any of these.
    ///
    /// 1. **A legacy document** (`insertLegacyDocument`): as step 3 left documents, for the re-queue cases (R).
    /// 2. **Delete directly** (`deleteDirectly`): a `Document` deleted without the trash, for S3.
    /// 3. **Write large text** (`writeLargeText`): megabytes into a `done` document's `extractedText`, past the
    ///    processing cap, for C7.
    /// 4. **Reset the re-queue flag** (`resetRequeueFlag`): this device's `processingRequeue.textV1`, for R1 and R2. A
    ///    per-device default, never synced.
    /// 5. **Move a tag under another** (`moveTag`), for C6: the app has no tag editing yet, so there is no real path.
    ///
    /// 2, 3 and 5 act only on what the lab created: a document whose `originalFileName` starts with `SyncLab-`, a tag
    /// whose name does. Every other record of the store (the maintainer's documents of 2026-11-11 included) is refused.
    /// Each write is one synchronous call in a fresh context with one save.
    enum SyncLabActions {
        /// The prefix of every lab document's `originalFileName` and every lab tag's, correspondent's and type's name.
        static let prefix = "SyncLab-"

        enum Refusal: Error, Equatable {
            /// No document or tag with that `instanceID`.
            case notFound
            /// Not created by the lab (no `SyncLab-` prefix).
            case notLabRecord
            /// "Write large text" needs a `done` document.
            case notDone
            /// The document has no text record.
            case noText
            /// The move would put a tag under itself or one of its descendants.
            case cycle
        }

        /// Whether the lab created the document.
        static func isLabDocument(originalFileName: String) -> Bool {
            originalFileName.hasPrefix(prefix)
        }

        /// Whether the lab created the tag, correspondent or type.
        static func isLabName(_ name: String) -> Bool {
            name.hasPrefix(prefix)
        }

        /// `name` with the lab's prefix, once.
        static func labName(_ name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return isLabName(trimmed) ? trimmed : prefix + trimmed
        }

        // MARK: 1. Legacy document

        /// Inserts a document as step 3 left it: `done`, `textSource` none, an empty text record, a file, no thumbnail,
        /// claimed by `deviceID`. One save. Returns its `instanceID`.
        @discardableResult
        static func insertLegacyDocument(
            in container: ModelContainer, deviceID: String, word: String, pages: Int, now: Date = Date()
        ) throws -> UUID {
            let pdf = SyncLabGenerator.textPDF(word: word, pages: pages)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let document = Document(title: "SyncLab legacy \(word)", createdAt: now)
            document.originalFileName = "\(prefix)legacy-\(word).pdf"
            document.source = .file
            document.contentHash = ContentHash.sha256(pdf)
            document.fileSize = pdf.count
            document.pageCount = pages
            document.processingState = .done
            document.processingDeviceID = deviceID
            document.processingClaimedAt = now
            let file = DocumentFile(documentID: document.id, pdfData: pdf, createdAt: now)
            let text = DocumentText(documentID: document.id, createdAt: now)
            context.insert(document)
            context.insert(file)
            context.insert(text)
            document.file = file
            document.text = text
            try context.save()
            Log.store.notice("Sync lab: legacy document inserted")
            return document.instanceID
        }

        // MARK: 2. Delete directly

        /// Deletes the lab document (its file, thumbnail and text go by the cascade), without the trash. One save.
        static func deleteDirectly(_ instanceID: UUID, in container: ModelContainer) throws {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let document = try labDocument(instanceID, in: context)
            context.delete(document)
            try context.save()
            Log.store.notice("Sync lab: document deleted directly")
        }

        // MARK: 3. Large text

        /// Writes about `megabytes` MB of text into the lab document's text record: `word` first, then filler words.
        /// Only for a `done` document; nothing else changes (no `touch()`, as processing writes the text). One save.
        /// Returns the UTF-8 length written.
        @discardableResult
        static func writeLargeText(
            _ instanceID: UUID, megabytes: Int, word: String, in container: ModelContainer
        ) throws -> Int {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let document = try labDocument(instanceID, in: context)
            guard document.processingState == .done else { throw Refusal.notDone }
            guard let text = document.text else { throw Refusal.noText }
            let value = largeText(word: word, bytes: max(1, megabytes) * 1_000_000)
            text.extractedText = value
            try context.save()
            Log.store.notice("Sync lab: large text written, \(value.utf8.count, privacy: .public) bytes")
            return value.utf8.count
        }

        /// `word`, then filler words, about `bytes` UTF-8 bytes in all, in lines.
        static func largeText(word: String, bytes: Int) -> String {
            var text = word + "\n"
            text.reserveCapacity(bytes + 64)
            var count = text.utf8.count
            var line = 0
            while count < bytes {
                line += 1
                let next = "Zeile \(line) synclab füllwort lorem ipsum dolor sit amet\n"
                text += next
                count += next.utf8.count
            }
            return text
        }

        // MARK: 4. Re-queue flag

        /// Clears this device's re-queue flag (`ProcessingRequeue.flagKey`), so the queue's next run makes the pass
        /// again. A per-device default; nothing synced changes.
        static func resetRequeueFlag(defaultsSuite: String? = nil) {
            let defaults = defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            defaults.removeObject(forKey: ProcessingRequeue.flagKey)
            Log.processing.notice("Sync lab: re-queue flag reset")
        }

        // MARK: 5. Tag move

        /// Puts the lab tag `child` under the lab tag `parent` (`nil`: top level). Refuses a move that would make a
        /// cycle on this device; a cycle across devices is the repair's (C6). One save.
        static func moveTag(_ child: UUID, under parent: UUID?, in container: ModelContainer) throws {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let tag = try labTag(child, in: context)
            if let parent {
                let target = try labTag(parent, in: context)
                var ancestor: Tag? = target
                var steps = 0
                while let current = ancestor, steps < 1_000 {
                    if current.instanceID == tag.instanceID { throw Refusal.cycle }
                    ancestor = current.parent
                    steps += 1
                }
                tag.parent = target
            } else {
                tag.parent = nil
            }
            try context.save()
            Log.store.notice("Sync lab: tag moved")
        }

        // MARK: Reading

        /// The lab document with `instanceID` (of copies sharing it, the oldest), or a refusal.
        static func labDocument(_ instanceID: UUID, in context: ModelContext) throws -> Document {
            let documents = try context.fetch(
                FetchDescriptor<Document>(predicate: #Predicate { $0.instanceID == instanceID }))
            guard let document = documents.min(by: { $0.createdAt < $1.createdAt }) else { throw Refusal.notFound }
            guard isLabDocument(originalFileName: document.originalFileName) else { throw Refusal.notLabRecord }
            return document
        }

        private static func labTag(_ instanceID: UUID, in context: ModelContext) throws -> Tag {
            let tags = try context.fetch(FetchDescriptor<Tag>(predicate: #Predicate { $0.instanceID == instanceID }))
            guard let tag = tags.min(by: { $0.createdAt < $1.createdAt }) else { throw Refusal.notFound }
            guard isLabName(tag.name) else { throw Refusal.notLabRecord }
            return tag
        }
    }
#endif
