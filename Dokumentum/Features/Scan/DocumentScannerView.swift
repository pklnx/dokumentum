#if os(iOS)
    import SwiftUI
    import VisionKit

    /// VisionKit's document camera (#5, part 2): edge detection, perspective correction, its own filters, retake
    /// and page delete in its own review screen. Its coordinator only forwards the three delegate calls; what
    /// follows them is `ImportController`'s, tested through `ScannedPages`. The camera itself, the permission
    /// prompt and the denied path are the device check (M2): this view cannot run in the simulator.
    struct DocumentScannerView: UIViewControllerRepresentable {
        let onFinish: @MainActor (VNDocumentCameraScan) -> Void
        let onCancel: @MainActor () -> Void
        let onFail: @MainActor (any Error) -> Void

        func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
            let controller = VNDocumentCameraViewController()
            controller.delegate = context.coordinator
            return controller
        }

        func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
            context.coordinator.parent = self
        }

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        @MainActor
        final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
            var parent: DocumentScannerView

            init(parent: DocumentScannerView) {
                self.parent = parent
            }

            func documentCameraViewController(
                _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
            ) {
                parent.onFinish(scan)
            }

            func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
                parent.onCancel()
            }

            func documentCameraViewController(
                _ controller: VNDocumentCameraViewController, didFailWithError error: any Error
            ) {
                parent.onFail(error)
            }
        }
    }
#endif
