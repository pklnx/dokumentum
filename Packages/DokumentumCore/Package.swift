// swift-tools-version: 6.4
import PackageDescription

// Model, store and processing. Apple frameworks (SwiftData now; PDFKit, Vision, FoundationModels with the
// steps that need them), so unlike DokumentumKit this package is not built on Linux.
let package = Package(
    name: "DokumentumCore",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "DokumentumCore", targets: ["DokumentumCore"]),
        // SwiftData helpers for tests; `DokumentumTestSupport` (DokumentumKit) stays Foundation only for Linux.
        .library(name: "DokumentumCoreTestSupport", targets: ["DokumentumCoreTestSupport"]),
    ],
    dependencies: [
        .package(path: "../DokumentumKit")
    ],
    targets: [
        .target(name: "DokumentumCore", dependencies: ["DokumentumKit"]),
        .target(
            name: "DokumentumCoreTestSupport",
            dependencies: ["DokumentumCore", .product(name: "DokumentumTestSupport", package: "DokumentumKit")]
        ),
        .testTarget(
            name: "DokumentumCoreTests",
            dependencies: [
                "DokumentumCore", "DokumentumCoreTestSupport",
                .product(name: "DokumentumKit", package: "DokumentumKit"),
                .product(name: "DokumentumTestSupport", package: "DokumentumKit"),
            ],
            resources: [.copy("Schema")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
