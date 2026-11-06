// swift-tools-version: 6.4
import PackageDescription

// Model and processing. Apple frameworks (SwiftData, PDFKit, Vision, FoundationModels) arrive with
// the steps that need them, so unlike DokumentumKit this package is not built on Linux.
let package = Package(
    name: "DokumentumCore",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "DokumentumCore", targets: ["DokumentumCore"])
    ],
    dependencies: [
        .package(path: "../DokumentumKit")
    ],
    targets: [
        .target(name: "DokumentumCore", dependencies: ["DokumentumKit"]),
        .testTarget(name: "DokumentumCoreTests", dependencies: ["DokumentumCore"]),
    ],
    swiftLanguageModes: [.v6]
)
