import DokumentumKit
import DokumentumTestSupport
import Testing

struct TitleTests {
    @Test func whitespaceAroundATitleGoes() {
        #expect(normalizedTitle("  Stromrechnung März\n") == "Stromrechnung März")
    }

    @Test func whitespaceInsideATitleStays() {
        #expect(normalizedTitle("Stromrechnung März") == "Stromrechnung März")
    }
}
