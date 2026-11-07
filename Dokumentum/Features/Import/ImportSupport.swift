import DokumentumCore
import DokumentumKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Everything one library window needs to import: the files picker (the "+" menu and ⌘O open it), the Photos
/// picker (the "+" menu), dropping files onto the window (Mac), and the notice. Applied once, on the window's
/// root.
struct ImportSupport: ViewModifier {
    @Bindable var controller: ImportController
    /// The launch's store: the Debug synthetic import runs only on an in-memory one.
    let launchStore: LaunchStore
    /// The photos just picked, in selection order; emptied as soon as they are handed to the controller.
    @State private var pickedPhotos: [PhotosPickerItem] = []

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
            #if os(macOS)
                .dropDestination(for: ImportedFile.self) { files, _ in
                    Task { await controller.importDropped(files) }
                }
            #endif
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
            pickPhotos: { [controller] in controller.isPickingPhotos = true })
    }

    private var isShowingNotice: Binding<Bool> {
        Binding(
            get: { controller.notices.shown != nil },
            set: { isShown in
                if !isShown { controller.dismissNotice() }
            })
    }
}
