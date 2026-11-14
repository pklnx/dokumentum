import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// What an `SQLLog.Recording` keeps (#221). It reads the log by an activity of its own, so the read stays cheap
/// however long the log has grown; these tests are what notice if that loses or adds statements. A statement of the
/// recording's thread between its start and `statements()` is in it; one of that thread before the start, one of
/// another thread meanwhile, and one of work the recording thread dispatched to a queue (which carries the
/// activity) are not. Two recordings never overlap on one thread. `swift test` only (`SQLLog.isReadable`).
///
/// Each test runs its recordings on a thread of its own (`TestSupport.onOwnThread`): a recording is synchronous,
/// and the test waits there for the other thread. The expectations come after, outside that thread.
struct SQLLogTests {
    struct Timeout: Error {}

    /// Waits on the recording's own thread for work that does not wait for anything; the timeout is the safety
    /// net only.
    static func waitOnOwnThread(_ start: (@escaping @Sendable () -> Void) -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        start { done.signal() }
        guard done.wait(timeout: .now() + 60 * TestSupport.timeoutScale) == .success else { throw Timeout() }
    }

    static func names(_ statements: [String], _ table: String) -> Bool {
        statements.contains { SQLLog.statement($0, names: table) }
    }

    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func aRecordingKeepsOnlyItsThreadsStatementsFromItsStart() async throws {
        let container = try TestSupport.makeContainer()
        let statements = try await TestSupport.onOwnThread { () throws -> [String] in
            let context = ModelContext(container)
            _ = try context.fetch(FetchDescriptor<DokumentumCore.Tag>())  // before the start
            let recording = try SQLLog.Recording()
            try Self.waitOnOwnThread { done in
                Thread {
                    _ = try? ModelContext(container).fetch(FetchDescriptor<DocumentType>())
                    done()
                }.start()
            }
            _ = try context.fetch(FetchDescriptor<Correspondent>())
            return try recording.statements()
        }

        #expect(Self.names(statements, "ZCORRESPONDENT"), "\(statements)")
        #expect(!Self.names(statements, "ZTAG"), "before the start: \(statements)")
        #expect(!Self.names(statements, "ZDOCUMENTTYPE"), "another thread: \(statements)")
    }

    /// Work dispatched from the recording thread carries the recording's activity (through the dispatch voucher),
    /// so only the thread check keeps its statements out (review B1 of #228).
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func workDispatchedFromTheRecordingThreadIsNotRecorded() async throws {
        let container = try TestSupport.makeContainer()
        let queue = DispatchQueue(label: "SQLLogTests.dispatched")
        let statements = try await TestSupport.onOwnThread { () throws -> [String] in
            let context = ModelContext(container)
            let recording = try SQLLog.Recording()
            try Self.waitOnOwnThread { done in
                queue.async {
                    _ = try? ModelContext(container).fetch(FetchDescriptor<DocumentType>())
                    done()
                }
            }
            _ = try context.fetch(FetchDescriptor<Correspondent>())
            return try recording.statements()
        }

        #expect(Self.names(statements, "ZCORRESPONDENT"), "\(statements)")
        #expect(!Self.names(statements, "ZDOCUMENTTYPE"), "dispatched to a queue: \(statements)")
    }

    /// A second recording while one runs on the same thread throws, and so does the first one's `statements()`:
    /// the first would miss the second's statements without notice (review N1 of #228). The next recording records
    /// as usual.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func twoRecordingsNeverOverlapOnOneThread() async throws {
        let container = try TestSupport.makeContainer()
        let (inner, outer, next) = try await TestSupport.onOwnThread {
            () throws -> ((any Error)?, Result<[String], any Error>, [String]) in
            let context = ModelContext(container)
            let outer = try SQLLog.Recording()
            var inner: (any Error)?
            do { _ = try SQLLog.Recording() } catch { inner = error }
            _ = try context.fetch(FetchDescriptor<DokumentumCore.Tag>())
            let outerStatements = Result { try outer.statements() }
            let next = try SQLLog.Recording()
            _ = try context.fetch(FetchDescriptor<Correspondent>())
            return (inner, outerStatements, try next.statements())
        }

        #expect(inner as? SQLLog.RecordingError == .nested, "\(String(describing: inner))")
        #expect(throws: SQLLog.RecordingError.nested) { try outer.get() }
        #expect(Self.names(next, "ZCORRESPONDENT"), "\(next)")
    }

    /// A recording that is never ended (its test threw before `statements()`) costs the next recording on its
    /// thread, which throws, and no more: the one after records as usual.
    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func aRecordingNeverEndedFailsOnlyTheNextOneOnItsThread() async throws {
        let container = try TestSupport.makeContainer()
        let (afterTheLeak, later) = try await TestSupport.onOwnThread {
            () throws -> ((any Error)?, [String]) in
            _ = try SQLLog.Recording()  // never ended
            var afterTheLeak: (any Error)?
            do { _ = try SQLLog.Recording() } catch { afterTheLeak = error }
            let later = try SQLLog.Recording()
            _ = try ModelContext(container).fetch(FetchDescriptor<Correspondent>())
            return (afterTheLeak, try later.statements())
        }

        #expect(afterTheLeak as? SQLLog.RecordingError == .nested, "\(String(describing: afterTheLeak))")
        #expect(Self.names(later, "ZCORRESPONDENT"), "\(later)")
    }
}
