import DokumentumCore
import Testing

struct DisplayTitleTests {
    /// Goes through `DokumentumKit`, so this also shows that Core links Kit.
    @Test func aTitleIsNormalized() {
        #expect(displayTitle("  Rechnung ", fallback: "scan.pdf") == "Rechnung")
    }

    @Test func aBlankTitleFallsBack() {
        #expect(displayTitle(" \n", fallback: "scan.pdf") == "scan.pdf")
    }
}
