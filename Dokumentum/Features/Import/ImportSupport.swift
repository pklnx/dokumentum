import DokumentumCore
import DokumentumKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Everything one library window needs to import: the files picker (the "+" menu and ⌘O open it), the Photos
/// picker (the "+" menu) and the cleanup of the picked photos (#5, part 3), the document camera (the "+" menu,
/// iPhone), dropping files onto the window (Mac), and the notice. Applied once, on the window's root.
struct ImportSupport: ViewModifier {
    @Bindable var controller: ImportController
    /// The launch's store: the Debug synthetic import runs only on an in-memory one.
    let launchStore: LaunchStore
    /// The photos just picked, in selection order; emptied as soon as they are handed to the controller.
    @State private var pickedPhotos: [PhotosPickerItem] = []
    #if os(iOS)
        /// The share queue's imports (part 4); their reports become this window's notices.
        @Environment(ShareQueueImporter.self) private var shareQueue: ShareQueueImporter?
    #endif

    func body(content: Content) -> some View {
        content
            .environment(\.importActions, actions)
            .focusedSceneValue(\.importActions, actions)
            .fileImporter(
                isPresented: $controller.isPickingFiles, allowedContentTypes: ImportController.importableTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await controller.importFiles(urls) }
                case .failure(let error):
                    Log.importing.error("The files picker failed: \(Log.code(of: error), privacy: .public)")
                }
            }
            // Ordered: the picker numbers the photos, and that order is the page order and the hash order
            // (PQ5, N6). `.current` hands the photos over as stored, not transcoded, so the same photo hashes
            // the same the next time (T10). No authorization: the user grants access to the picked items only.
            .photosPicker(
                isPresented: $controller.isPickingPhotos, selection: $pickedPhotos, maxSelectionCount: nil,
                selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current
            )
            .onChange(of: pickedPhotos) { _, picked in
                guard !picked.isEmpty else { return }
                pickedPhotos = []
                Task { await controller.importPhotos(picked) }
            }
            // The cleanup of the picked photos (P2, both devices). Only Cancel and Save close it: a swipe would
            // drop the edits without asking.
            // Save imports once the sheet is gone, so the new document opens (PQ1) after the sheet's animation.
            .sheet(
                item: $controller.cleanup,
                onDismiss: { [controller] in Task { await controller.importSavedCleanup() } }
            ) { cleanup in
                PhotoCleanupView(
                    model: cleanup,
                    onSave: { [controller] in controller.closeCleanupForSave() },
                    onCancel: { [controller] in controller.cancelCleanup() }
                )
                .interactiveDismissDisabled()
            }
            // A window closed while its sheet animated out after Save: its pages are still imported (review
            // 5867292360, finding 3). The task keeps the controller until then.
            .onDisappear { [controller] in Task { await controller.importSavedCleanup() } }
            #if os(macOS)
                .dropDestination(for: ImportedFile.self) { files, _ in
                    Task { await controller.importDropped(files) }
                }
            #else
                // The document camera (#5, part 2). The app closes it in each of its three ends (VisionKit leaves
                // that to the app); a finished scan is encoded and imported after it closed.
                .fullScreenCover(isPresented: $controller.isScanning) {
                    DocumentScannerView(
                        onFinish: { [controller] scan in
                            controller.isScanning = false
                            Task { await controller.importScan(CameraScan(scan: scan)) }
                        },
                        onCancel: { [controller] in controller.isScanning = false },
                        onFail: { [controller] error in controller.scanFailed(error) }
                    )
                    .ignoresSafeArea()
                }
                // Also the reports that arrived before the window appeared.
                .onChange(of: shareQueue?.reports.count ?? 0, initial: true) { _, count in
                    guard count > 0, let shareQueue else { return }
                    controller.showShareQueueReports(shareQueue.takeReports())
                }
            #endif
            .overlay(alignment: .bottom) {
                if controller.isSavingScan {
                    SavingIndicator(title: "Saving scan…", identifier: AccessibilityID.importSavingScan)
                } else if controller.isSavingPhotos {
                    SavingIndicator(title: "Saving photos…", identifier: AccessibilityID.importSavingPhotos)
                }
            }
            .alert(
                Text(verbatim: controller.notices.shown?.title ?? ""), isPresented: isShowingNotice,
                presenting: controller.notices.shown
            ) { _ in
                Button("OK") {}
                    .accessibilityIdentifier(AccessibilityID.importNoticeOK)
            } message: { notice in
                Text(verbatim: notice.message)
            }
            #if DEBUG
                .fileDialogDefaultDirectory(UITestImportSynthetic.folder(for: launchStore))
                .task { await UITestImportSynthetic.runOnce(controller, launchStore: launchStore) }
            #endif
    }

    private var actions: ImportActions {
        ImportActions(
            pickFiles: { [controller] in controller.isPickingFiles = true },
            pickPhotos: photosAction,
            scan: scanAction)
    }

    /// "Photos…" opens the Photos picker; in a Debug launch with `-UITestCleanupSynthetic YES` it opens the cleanup
    /// with two rendered photos instead.
    private var photosAction: @MainActor () -> Void {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if UITestCleanupSynthetic.isRequested(arguments: arguments, launchStore: launchStore) {
                return { [controller] in Task { await controller.importPhotos(UITestCleanupSynthetic.photos) } }
            }
        #endif
        return { [controller] in controller.isPickingPhotos = true }
    }

    /// "Scan…" opens the camera; in a Debug launch with `-UITestScanSynthetic YES` it imports rendered pages
    /// instead. `nil` without a camera, so the menu has no "Scan…" (the Mac, the simulator).
    private var scanAction: (@MainActor () -> Void)? {
        switch ScanAvailability.current(launchStore: launchStore) {
        case .unavailable:
            return nil
        case .camera:
            return { [controller] in controller.isScanning = true }
        #if DEBUG
            case .synthetic:
                return { [controller] in Task { await controller.importScan(SyntheticScanPages.uiTest) } }
        #endif
        }
    }

    private var isShowingNotice: Binding<Bool> {
        Binding(
            get: { controller.notices.shown != nil },
            set: { isShown in
                if !isShown { controller.dismissNotice() }
            })
    }
}

/// "Saving …" at the bottom of the window while an import runs after its sheet closed.
private struct SavingIndicator: View {
    let title: LocalizedStringKey
    let identifier: String

    var body: some View {
        ProgressView(title)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
            .accessibilityIdentifier(identifier)
    }
}
