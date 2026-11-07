import DokumentumKit
import Testing

struct MetadataNameTests {
    @Test(arguments: [
        ("  Stadtwerke\n", "stadtwerke"),
        ("STADTWERKE", "stadtwerke"),
        ("Müller", "muller"),
        ("MÜLLER", "muller"),
        ("Café", "cafe"),
        ("Ｔｅｌｅｋｏｍ", "telekom"),
        ("Auto Golf", "auto golf"),
        ("   ", ""),
    ])
    func namesFoldTo(name: String, expected: String) {
        #expect(MetadataName.normalized(name) == expected)
    }

    @Test func differentNamesStayDifferent() {
        #expect(MetadataName.normalized("Telekom") != MetadataName.normalized("Telecom"))
    }
}
