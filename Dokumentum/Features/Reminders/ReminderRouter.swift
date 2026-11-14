import Foundation
import Observation

/// Opens the document of a tapped reminder (#12, part 3; plan §8): in the library window that was active last, which
/// selects Deadlines and the document (`LibraryModel.openFromReminder`); on the Mac, with no library window open, a new
/// one opens and takes it.
///
/// Every library window registers when it appears and unregisters when it goes; it moves to the front of the order when
/// it becomes active. A request waits until the window it belongs to takes it (`take(for:)`).
@MainActor
@Observable
final class ReminderRouter {
    /// A tap's request; a new one has a new `id`, so the same document can be opened twice.
    struct Request: Equatable {
        let id: Int
        let instanceID: UUID
    }

    private(set) var request: Request?
    @ObservationIgnored private var count = 0
    /// The open library windows, the most recently active last.
    @ObservationIgnored private(set) var windows: [UUID] = []
    /// Opens a library window (`openWindow(id: "library")` of the first window that appeared). Called when a request
    /// arrives with no window open.
    @ObservationIgnored var openWindow: (@MainActor () -> Void)?

    /// A reminder was tapped.
    func open(_ instanceID: UUID) {
        count += 1
        request = Request(id: count, instanceID: instanceID)
        if windows.isEmpty { openWindow?() }
    }

    func register(_ window: UUID) {
        windows.removeAll { $0 == window }
        windows.append(window)
    }

    func windowBecameActive(_ window: UUID) {
        guard windows.contains(window) else { return }
        register(window)
    }

    func unregister(_ window: UUID) {
        windows.removeAll { $0 == window }
    }

    /// The document `window` opens now, if the waiting request is its: the window that was active last takes it.
    func take(for window: UUID) -> UUID? {
        guard let request, windows.last == window else { return nil }
        self.request = nil
        return request.instanceID
    }
}
