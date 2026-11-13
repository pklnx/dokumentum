import Testing

@testable import DokumentumKit

/// Internal helpers of `SenderDetector` that no realistic layout reaches alone (DN3 of #204).
struct SenderDetectorInternalTests {
    @Test(arguments: ["80284", "8001", "62701", "62701-1234", "IL 62701", "OX1 1AA", "SW1A 2AA", "M1 1AE"])
    func aSegmentThatIsOnlyAPostcode(segment: String) {
        #expect(SenderDetector.isOnlyPostcode(segment), "\(segment)")
    }

    @Test(arguments: ["80284 Musterstadt", "Postfach 12", "123", "Springfield", "IL 62701 USA", "OX1"])
    func aSegmentThatIsMoreOrLessThanAPostcode(segment: String) {
        #expect(!SenderDetector.isOnlyPostcode(segment), "\(segment)")
    }
}
