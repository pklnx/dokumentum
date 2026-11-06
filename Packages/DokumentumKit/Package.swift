// swift-tools-version: 6.4
import PackageDescription

// Pure logic, Foundation only: it also builds and tests on Linux (the `kit-linux` check).
let package = Package(
    name: "DokumentumKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "DokumentumKit", targets: ["DokumentumKit"]),
        .library(name: "DokumentumTestSupport", targets: ["DokumentumTestSupport"]),
    ],
    targets: [
        .target(name: "DokumentumKit"),
        .target(name: "DokumentumTestSupport"),
        .testTarget(name: "DokumentumKitTests", dependencies: ["DokumentumKit", "DokumentumTestSupport"]),
        .testTarget(name: "DokumentumTestSupportTests", dependencies: ["DokumentumTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
