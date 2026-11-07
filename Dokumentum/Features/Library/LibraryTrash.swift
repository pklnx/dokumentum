import DokumentumCore
import DokumentumKit
import Foundation
import Observation

/// A library source whose documents can go into the trash (plan of #3, part 4). Separate from `LibrarySource`
/// so the trash and the editing of part 3 stay out of each other's lines; `nil` for a source that cannot write.
protocol DocumentTrashSource {
    @MainActor var documentTrash: DocumentTrash? { get }
}

/// The trash works in the main context, which the library reads; its saves fire `changes`.
extension StoreLibrarySource: DocumentTrashSource {
    @MainActor var documentTrash: DocumentTrash? { DocumentTrash(context: container.mainContext) }
}

/// The window's trash actions (plan of #3, part 4): move the open document to the trash, restore it, and empty
/// the trash after a confirmation that names how many documents it deletes (PQ8, PQ9).
///
/// Moving needs no confirmation: it can be undone with Restore. Emptying asks first, and deletes only the
/// documents the confirmation counted (`DocumentTrash.emptyTrash(confirmed:)`). After each change the library
/// is read again at once; a document that leaves the shown list is deselected by `LibraryModel`, so on the
/// iPhone the stack goes back to the list.
@MainActor @Observable
final class LibraryTrash {
    let model: LibraryModel
    @ObservationIgnored private let trash: DocumentTrash?

    /// The trashed documents the Empty Trash confirmation counts; `nil` while it is not shown.
    private(set) var pendingEmptyTrash: Set<UUID>?

    init(model: LibraryModel) {
        self.model = model
        trash = (model.source as? any DocumentTrashSource)?.documentTrash
    }

    /// Whether the source can write: the store can; the fixtures of unit tests cannot.
    var isAvailable: Bool { trash != nil }

    /// The open document's row, while it is in the shown list.
    var openDocument: LibraryDocument? {
        model.selectedDocumentID.flatMap { id in model.documents.first { $0.instanceID == id } }
    }

    /// The number of documents in the trash.
    var trashCount: Int { model.counts.trash }

    // MARK: Move and restore

    func moveToTrash(_ instanceID: UUID) {
        guard let trash else { return }
        do {
            if try !trash.moveToTrash([instanceID]).isEmpty { model.reload() }
        } catch {
            Log.store.error("Could not move a document to the trash: \(Log.code(of: error), privacy: .public)")
        }
    }

    func restore(_ instanceID: UUID) {
        guard let trash else { return }
        do {
            if try !trash.restore([instanceID]).isEmpty { model.reload() }
        } catch {
            Log.store.error("Could not restore a document: \(Log.code(of: error), privacy: .public)")
        }
    }

    // MARK: Empty Trash

    /// Shows the confirmation for the documents in the trash now. Nothing in the trash: nothing to ask.
    func requestEmptyTrash() {
        guard isAvailable else { return }
        let trashed = Set(model.snapshot.documents.filter(\.isTrashed).map(\.instanceID))
        pendingEmptyTrash = trashed.isEmpty ? nil : trashed
    }

    /// Whether the confirmation is shown; setting `false` cancels it.
    var isConfirmingEmptyTrash: Bool {
        get { pendingEmptyTrash != nil }
        set { if !newValue { pendingEmptyTrash = nil } }
    }

    /// Deletes the documents the confirmation counted, as far as they are still in the trash.
    func confirmEmptyTrash() {
        guard let confirmed = pendingEmptyTrash else { return }
        pendingEmptyTrash = nil
        guard let trash else { return }
        do {
            let deleted = try trash.emptyTrash(confirmed: confirmed)
            Log.store.notice("Emptied the trash: \(deleted.count, privacy: .public) documents deleted")
            if !deleted.isEmpty { model.reload() }
        } catch {
            Log.store.error("Could not empty the trash: \(Log.code(of: error), privacy: .public)")
        }
    }
}
