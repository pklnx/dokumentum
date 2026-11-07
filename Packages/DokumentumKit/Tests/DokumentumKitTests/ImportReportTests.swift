import DokumentumKit
import Foundation
import Testing

/// The notice and the document to open after a batch (PQ1, PQ3, PQ4), and the notice queue.
struct ImportReportTests {
    /// Recognisable stand-ins for the app's catalog strings.
    static let strings = ImportNoticeStrings(
        alreadyInArchive: { "ALREADY" },
        importedDuplicatesSkipped: { "IMPORTED \($0), SKIPPED" },
        partlyFailed: { "PARTLY FAILED" },
        failed: { "FAILED" },
        duplicatesHeading: { $0 == 1 ? "ONE DUPLICATE:" : "\($0) DUPLICATES:" },
        duplicateLine: { "• \($0) → “\($1)”" + ($2 ? " (TRASH)" : "") },
        failureLine: { "\($0): \($1)" })

    let a = UUID()
    let b = UUID()
    let existing = UUID()

    @Test func everythingImportedGivesNoNotice() {
        let report = ImportReport(entries: [
            .init(fileName: "a.pdf", outcome: .imported(instanceID: a)),
            .init(fileName: "b.pdf", outcome: .imported(instanceID: b)),
        ])
        #expect(report.notice(Self.strings) == nil)
        #expect(ImportReport().notice(Self.strings) == nil)
    }

    @Test func duplicatesOnly() {
        let report = ImportReport(entries: [
            .init(fileName: "a.pdf", outcome: .duplicate(of: existing, title: "Strom", isTrashed: false))
        ])
        #expect(
            report.notice(Self.strings) == ImportNotice(title: "ALREADY", message: "ONE DUPLICATE:\n• a.pdf → “Strom”"))
    }

    @Test func importedAndDuplicatesCountThePluralAndNameTheTrash() {
        let report = ImportReport(entries: [
            .init(fileName: "a.pdf", outcome: .imported(instanceID: a)),
            .init(fileName: "x.pdf", outcome: .duplicate(of: existing, title: "Strom", isTrashed: false)),
            .init(fileName: "b.pdf", outcome: .imported(instanceID: b)),
            .init(fileName: "y.pdf", outcome: .duplicate(of: UUID(), title: "Alt", isTrashed: true)),
        ])
        #expect(
            report.notice(Self.strings)
                == ImportNotice(
                    title: "IMPORTED 2, SKIPPED",
                    message: "2 DUPLICATES:\n• x.pdf → “Strom”\n• y.pdf → “Alt” (TRASH)"))
    }

    @Test func failuresOnly() {
        let report = ImportReport(entries: [
            .init(fileName: "a.pdf", outcome: .failed(.passwordProtected)),
            .init(fileName: "b.txt", outcome: .failed(.unsupportedType)),
        ])
        #expect(
            report.notice(Self.strings)
                == ImportNotice(title: "FAILED", message: "a.pdf: passwordProtected\nb.txt: unsupportedType"))
    }

    @Test func failuresAndDuplicatesAreAPartialFailure() {
        let report = ImportReport(entries: [
            .init(fileName: "a.pdf", outcome: .failed(.unreadablePDF)),
            .init(fileName: "x.pdf", outcome: .duplicate(of: existing, title: "", isTrashed: false)),
        ])
        #expect(
            report.notice(Self.strings)
                == ImportNotice(title: "PARTLY FAILED", message: "ONE DUPLICATE:\n• x.pdf → “”\na.pdf: unreadablePDF"))
        let imported = ImportReport(entries: [
            .init(fileName: "a.pdf", outcome: .imported(instanceID: a)),
            .init(fileName: "b.pdf", outcome: .failed(.couldNotRead)),
        ])
        #expect(imported.notice(Self.strings)?.title == "PARTLY FAILED")
    }

    @Test func theDocumentToOpen() {
        let one = ImportReport(entries: [
            .init(fileName: "a.pdf", outcome: .imported(instanceID: a)),
            .init(fileName: "x.pdf", outcome: .duplicate(of: existing, title: "", isTrashed: false)),
            .init(fileName: "f.pdf", outcome: .failed(.empty)),
        ])
        #expect(one.documentToOpen == .new(a))
        let several = ImportReport(entries: [
            .init(fileName: "a.pdf", outcome: .imported(instanceID: a)),
            .init(fileName: "b.pdf", outcome: .imported(instanceID: b)),
        ])
        #expect(several.documentToOpen == nil)
        let duplicate = ImportReport(entries: [
            .init(fileName: "x.pdf", outcome: .duplicate(of: existing, title: "", isTrashed: true)),
            .init(fileName: "f.pdf", outcome: .failed(.empty)),
        ])
        #expect(duplicate.documentToOpen == .existing(existing))
        let twoDuplicates = ImportReport(entries: [
            .init(fileName: "x.pdf", outcome: .duplicate(of: existing, title: "", isTrashed: false)),
            .init(fileName: "y.pdf", outcome: .duplicate(of: a, title: "", isTrashed: false)),
        ])
        #expect(twoDuplicates.documentToOpen == nil)
        #expect(ImportReport(entries: [.init(fileName: "f.pdf", outcome: .failed(.empty))]).documentToOpen == nil)
    }

    @Test func aNoticeWaitsWhileAnotherIsShown() {
        let first = ImportNotice(title: "1", message: "")
        let second = ImportNotice(title: "2", message: "")
        var queue = ImportNoticeQueue()
        queue.add(nil)
        #expect(queue.shown == nil)
        queue.add(first)
        queue.add(second)
        queue.add(second)
        #expect(queue.shown == first)
        #expect(queue.waiting == [second])
        let replaced = queue.showNext()
        #expect(!replaced, "nothing replaces the shown notice")
        queue.dismissShown()
        #expect(queue.shown == nil)
        let next = queue.showNext()
        #expect(next)
        #expect(queue.shown == second)
        #expect(queue.waiting.isEmpty)
        queue.dismissShown()
        let none = queue.showNext()
        #expect(!none)
    }
}
