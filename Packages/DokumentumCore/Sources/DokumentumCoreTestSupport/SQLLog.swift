import Foundation
import OSLog
import os.activity

/// The SQL statements Core Data runs, read back from this process's unified log: the automated evidence that
/// a fetch does not touch a table (#2, DW4). Core Data logs each statement under the subsystem
/// `com.apple.coredata`, category `sql`, while the user default `com.apple.CoreData.SQLDebug` is at least 1.
///
/// **Core Data reads the setting once per process, when its first store opens** (measured: a store opened
/// before `enable()` leaves the log off for every later store). The container helpers of `TestSupport` call
/// `enable()` first; a test that opens a store another way calls it before. A recording without any statement
/// therefore means the log is off, and a test that expects a statement fails.
///
/// Tests run in parallel, and other tests' stores log too. So a recording keeps only the statements of the
/// thread that started it: record synchronous work only (no `await` inside), so it stays on one thread. If
/// the work ran on another thread, the recording is empty, and a test that expects a statement fails instead of
/// passing without evidence.
///
///     let recording = try SQLLog.Recording()
///     _ = try DocumentListQuery.fetch(.all, in: context)
///     let statements = try recording.statements()
public enum SQLLog {
    /// Whether this process can record Core Data's SQL. Measured on macOS 27.2 with Xcode 27.2 (#29): under
    /// `swift test` (`swiftpm-testing-helper`) the statements are in the process's log; in the `xctest` runner
    /// that `xcodebuild test` starts, Core Data logs no statement at all, even with
    /// `-com.apple.CoreData.SQLDebug 1` on its command line and the default reading 1. Tests that need the SQL
    /// are enabled only where it can be read, so they are evidence there and skipped, not passed, elsewhere.
    public static var isReadable: Bool {
        ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
    }

    /// Turns on Core Data's SQL log for the rest of this process. The value goes into the volatile argument
    /// domain, as `-com.apple.CoreData.SQLDebug 1` on the command line would, and never into a preferences file.
    public static func enable() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["com.apple.CoreData.SQLDebug"] = 1
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    /// The statements of one thread while the recording runs: from `init()` to `statements()`.
    ///
    /// **Why an activity (#221).** Reading the log costs time in proportion to the entries the read returns, and
    /// neither a start position nor a date or thread predicate narrows that: the read returns the process's whole
    /// log since its start, about 130 000 entries late in a `DokumentumCoreTests` run, since every test's store
    /// logs its SQL. That took 5 to 6 s per read, on the calling thread; with the one-thread pool of the
    /// strict-pool step, 40 reads held the pool for 231 s of a 242 s test run (measured on this Mac). So the
    /// recording runs in an `os_activity` of its own, and the read asks the log for that activity's entries only:
    /// the log filters by activity itself, and a read takes about 1 s whatever the log's size. The activity
    /// only narrows the read; the recording still keeps only the statements of its own thread, in order.
    public struct Recording {
        private let store: OSLogStore
        private let marker: String
        private let thread: UInt64
        private let activity: RecordingActivity

        /// Turns the log on and starts recording on the current thread.
        public init() throws {
            enable()
            store = try OSLogStore(scope: .currentProcessIdentifier)
            thread = SQLLog.currentThread()
            activity = RecordingActivity()
            // Logged inside the activity: a read that does not find it cannot read the log at all.
            let marker = "SQLLog recording \(UUID().uuidString)"
            self.marker = marker
            SQLLog.logger.notice("\(marker, privacy: .public)")
        }

        /// Ends the recording and returns the statements logged on its thread since it started, without the
        /// `CoreData: sql: ` prefix, in order. Call it once, on the thread that started the recording.
        public func statements() throws -> [String] {
            guard SQLLog.currentThread() == thread else { throw RecordingError.otherThread }
            activity.end()
            var started = false
            var statements: [String] = []
            let entries = try store.getEntries(
                matching: NSPredicate(format: "activityIdentifier == %llu", activity.identifier))
            for entry in entries {
                guard let log = entry as? OSLogEntryLog, log.threadIdentifier == thread else { continue }
                if !started {
                    started = log.subsystem == SQLLog.markerSubsystem && log.composedMessage == marker
                    continue
                }
                guard log.subsystem == "com.apple.coredata", log.category == "sql" else { continue }
                let message = log.composedMessage
                let prefix = "CoreData: sql: "
                statements.append(message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message)
            }
            if !started { throw RecordingError.markerNotFound }
            return statements
        }
    }

    /// The recording's `os_activity`, entered on the recording's thread when it is made and left by `end()`.
    /// Every entry that thread logs meanwhile carries the activity's identifier.
    final class RecordingActivity: @unchecked Sendable {
        // Only touched on the recording's thread (`Recording.statements()` checks it).
        private var scope = os_activity_scope_state_s()
        private var ended = false
        private let activity: os_activity_t
        let identifier: os_activity_id_t

        init() {
            // `os_activity_create` and `OS_ACTIVITY_NONE` are C macros that Swift does not import: the first is
            // `_os_activity_create` with the image's handle, the second the address of `_os_activity_none`.
            // A detached activity does not nest under the thread's current one.
            // -2 is `RTLD_DEFAULT`: every image of the process.
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_os_activity_none") else {
                preconditionFailure("_os_activity_none is not in this process")
            }
            let none = unsafeBitCast(symbol, to: os_activity_t.self)
            activity = _os_activity_create(
                UnsafeMutableRawPointer(mutating: #dsohandle),
                UnsafeRawPointer(SQLLog.activityName.utf8Start).assumingMemoryBound(to: CChar.self), none,
                OS_ACTIVITY_FLAG_DETACHED)
            var parent: os_activity_id_t = 0
            identifier = os_activity_get_identifier(activity, &parent)
            os_activity_scope_enter(activity, &scope)
        }

        /// Leaves the activity; later calls do nothing.
        func end() {
            guard !ended else { return }
            ended = true
            os_activity_scope_leave(&scope)
        }
    }

    /// The activity's name: a static string, since the activity keeps the pointer.
    static let activityName: StaticString = "SQLLog recording"

    enum RecordingError: Error {
        /// The recording's own start entry is not in the log: the log cannot be read in this process.
        case markerNotFound
        /// `statements()` was called on another thread than the one that started the recording.
        case otherThread
    }

    /// The marker's logger. Test support only: the app's loggers are in `Log` (`check-logging.py` checks app code).
    static let markerSubsystem = "space.pklnx.Dokumentum.tests"
    static let logger = Logger(subsystem: markerSubsystem, category: "sqllog")

    static func currentThread() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }

    /// Whether `statement` names `table` as a whole word (`ZDOCUMENT` is a prefix of `ZDOCUMENTFILE`).
    public static func statement(_ statement: String, names table: String) -> Bool {
        statement.range(of: "\\b\(table)\\b", options: .regularExpression) != nil
    }
}
