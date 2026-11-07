import Foundation
import OSLog

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

    /// The statements of one thread from a starting point on.
    public struct Recording {
        private let store: OSLogStore
        private let start: Date
        private let marker: String
        private let thread: UInt64

        /// Turns the log on and starts recording on the current thread.
        public init() throws {
            enable()
            store = try OSLogStore(scope: .currentProcessIdentifier)
            start = Date()
            thread = SQLLog.currentThread()
            // The log's timestamps and `Date()` differ by milliseconds (measured), so the recording starts at a
            // marker entry of its own, logged on this thread, not at a date.
            let marker = "SQLLog recording \(UUID().uuidString)"
            self.marker = marker
            SQLLog.logger.notice("\(marker, privacy: .public)")
        }

        /// The statements logged on the recording's thread since it started, without the `CoreData: sql: `
        /// prefix, in order.
        public func statements() throws -> [String] {
            var started = false
            var statements: [String] = []
            for entry in try store.getEntries(at: store.position(date: start.addingTimeInterval(-1))) {
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

    enum RecordingError: Error {
        /// The recording's own start entry is not in the log: the log cannot be read in this process.
        case markerNotFound
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
