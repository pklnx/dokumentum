import DokumentumCore
import DokumentumCoreTestSupport
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

/// Not a test: the measurement of plan T1 (the duplicate check at 5,000 documents; over 50 ms on the
/// simulator would call for an index on `contentHash` in a later schema version). Off unless
/// `DOKUMENTUM_MEASURE_DUPLICATE_CHECK=1` (`TEST_RUNNER_DOKUMENTUM_MEASURE_DUPLICATE_CHECK=1` for
/// `xcodebuild`); it prints the times and asserts nothing about them.
struct DuplicateCheckMeasurement {
    static let isRequested = ProcessInfo.processInfo.environment["DOKUMENTUM_MEASURE_DUPLICATE_CHECK"] == "1"

    @Test(.enabled(if: isRequested, "a measurement, run on request"))
    func duplicateCheckAt5000Documents() throws {
        let container = try TestSupport.makeContainerOnDisk()
        let context = ModelContext(container)
        var hashes: [String] = []
        for index in 0..<5_000 {
            let document = Document(title: "Document \(index)")
            document.contentHash = ContentHash.sha256(Data("document \(index)".utf8))
            hashes.append(document.contentHash)
            context.insert(document)
            if index % 500 == 499 { try context.save() }
        }
        try context.save()

        let clock = ContinuousClock()
        for (label, hash) in [("absent", ContentHash.sha256(Data("absent".utf8))), ("present", hashes[2_500])] {
            var times: [Duration] = []
            for _ in 0..<21 {
                let fresh = ModelContext(container)
                let start = clock.now
                _ = try DocumentImporter.existingDocument(withHash: hash, in: fresh)
                times.append(clock.now - start)
            }
            times.sort()
            print("Duplicate check, 5,000 documents, \(label) hash: median \(times[10]), max \(times[20])")
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Document>()) == 5_000)
    }
}
