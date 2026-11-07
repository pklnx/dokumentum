import DokumentumCore
import DokumentumKit
import SwiftUI
import UniformTypeIdentifiers

/// Everything one library window needs to import: the files picker (the "+" menu and ⌘O open it), dropping
/// files onto the window (Mac), and the notice. Applied once, on the window's root.
struct ImportSupport: ViewModifier {
    @Bindable var controller: ImportController
    /// The launch's store: the Debug synthetic import runs only on an in-memory one.
    let launchStore: LaunchStore

    func body(content: Content) -> some View {
        content
            .environment(\.importActions, actions)
            .focusedSceneValue(\.importActions, actions)
            .fileImporter(
                isPresented: $controller.isPickingFiles, allowedContentTypes: [.pdf], allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await controller.importFiles(urls) }
                case .failure(let error):
                    Log.importing.error("The files picker failed: \(Log.code(of: error), privacy: .public)")
                }
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
        ImportActions(pickFiles: { [controller] in controller.isPickingFiles = true })
    }

    private var isShowingNotice: Binding<Bool> {
        Binding(
            get: { controller.notices.shown != nil },
            set: { isShown in
                if !isShown { controller.dismissNotice() }
            })
    }
}
