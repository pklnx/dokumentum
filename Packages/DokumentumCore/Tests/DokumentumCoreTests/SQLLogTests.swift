import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// What an `SQLLog.Recording` keeps (#221). It reads the log by an activity of its own, so the read stays cheap
/// however long the log has grown; this test is what notices if that loses or adds statements. A statement of the
/// recording's thread between its start and `statements()` is in it; one of that thread before the start, and one
/// of another thread meanwhile, are not. `swift test` only (`SQLLog.isReadable`).
struct SQLLogTests {
    struct Timeout: Error {}

    @Test(.enabled(if: SQLLog.isReadable, "Core Data logs no SQL in the xctest runner (measured on #29)"))
    func aRecordingKeepsOnlyItsThreadsStatementsFromItsStart() async throws {
        let container = try TestSupport.makeContainer()
        // On a thread of its own: the recording is synchronous, and the test waits there for the other thread.
        let statements = try await TestSupport.onOwnThread { () throws -> [String] in
            let context = ModelContext(container)
            _ = try context.fetch(FetchDescriptor<DokumentumCore.Tag>())  // before the start
            let recording = try SQLLog.Recording()
            let otherThreadDone = DispatchSemaphore(value: 0)
            Thread {
                _ = try? ModelContext(container).fetch(FetchDescriptor<DocumentType>())
                otherThreadDone.signal()
            }.start()
            // The safety net only: the other thread's fetch does not wait for anything.
            guard otherThreadDone.wait(timeout: .now() + 60 * TestSupport.timeoutScale) == .success else {
                throw Timeout()
            }
            _ = try context.fetch(FetchDescriptor<Correspondent>())
            return try recording.statements()
        }

        #expect(statements.contains { SQLLog.statement($0, names: "ZCORRESPONDENT") }, "\(statements)")
        #expect(!statements.contains { SQLLog.statement($0, names: "ZTAG") }, "before the start: \(statements)")
        #expect(
            !statements.contains { SQLLog.statement($0, names: "ZDOCUMENTTYPE") }, "another thread: \(statements)")
    }
}
