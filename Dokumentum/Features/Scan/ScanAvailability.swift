import DokumentumCore
import Foundation

#if os(iOS)
    import VisionKit
#endif

/// How "Scan…" works in this launch, if at all (#5, part 2): with the camera where VisionKit supports it (an
/// iPhone, never the simulator), never on the Mac. Debug builds with `-UITestScanSynthetic YES` on an
/// in-memory store import rendered pages instead of opening the camera.
enum ScanAvailability: Equatable {
    case unavailable
    case camera
    #if DEBUG
        case synthetic
    #endif

    @MainActor
    static func current(launchStore: LaunchStore, arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        #if os(iOS)
            #if DEBUG
                if UITestScanSynthetic.isRequested(arguments: arguments, launchStore: launchStore) { return .synthetic }
            #endif
            return VNDocumentCameraViewController.isSupported ? .camera : .unavailable
        #else
            return .unavailable
        #endif
    }
}
