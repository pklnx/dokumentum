import DokumentumCore
import DokumentumKit
import SwiftUI

/// The detail column: the open document's PDF, or why there is none (PQ12), its processing state when it is not
/// processed yet (`ProcessingStatusBar`, #6 P2), its open deadline or the due date found in its text (`DeadlineBar`,
/// #12 parts 2a and 2b), and its info panel.
struct DocumentDetailView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        content
            // The deadline under the processing line (#12, part 2a): the inner inset lies below the outer one.
            .safeAreaInset(edge: .top, spacing: 0) { DeadlineBar(model: model) }
            .safeAreaInset(edge: .top, spacing: 0) { ProcessingStatusBar(model: model) }
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: model.selectedDocumentID) {
                await model.loadDetail(for: model.selectedDocumentID)
            }
            // The due-date suggestion in the text (#12, part 2b), read again with every read of the library.
            .task(id: model.deadlineSuggestionKey) {
                await model.loadDeadlineSuggestion()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isInfoPresented.toggle()
                    } label: {
                        Label {
                            model.isInfoPresented ? Text("Hide Info") : Text("Show Info")
                        } icon: {
                            Image(systemName: "info.circle")
                        }
                    }
                    .disabled(model.selectedDocument == nil)
                    .accessibilityIdentifier(AccessibilityID.detailShowInfo)
                }
                #if os(iOS)
                    ToolbarItem(placement: .primaryAction) {
                        DocumentDetailMenu()
                    }
                #endif
            }
            #if os(iOS)
                // A sheet on the iPhone. Not `.inspector`, which also becomes a sheet here: it put the panel's
                // toolbar ("Done") into the detail's bar beneath the sheet, where it cannot be reached
                // (measured on iOS 27.0). On the Mac the inspector is on the window's split view
                // (`LibraryRootView`).
                .sheet(isPresented: $model.isInfoPresented) {
                    DocumentInfoView(model: model)
                }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.detail {
        case .noSelection:
            placeholder(
                "No document selected", systemImage: "doc.text.magnifyingglass",
                identifier: AccessibilityID.detailNoSelection)
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(AccessibilityID.detailLoading)
        case .stillDownloading:
            placeholder(
                "Still downloading", systemImage: "icloud.and.arrow.down",
                description: Text("The file is being downloaded from iCloud."),
                identifier: AccessibilityID.detailStillDownloading)
        case .unreadable:
            placeholder(
                "This PDF cannot be shown", systemImage: "exclamationmark.triangle",
                description: Text("The file is damaged or not a PDF."), identifier: AccessibilityID.detailUnreadable)
        case .pdf(let instanceID, let data):
            // The identifier goes on a SwiftUI container: on macOS XCUITest does not find one on the
            // representable itself.
            ZStack {
                PDFKitView(data: data, id: instanceID)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.detailPDF)
        }
    }

    /// The Mac's own placeholder, with the identifier on its title (#82); the iPhone's system view.
    @ViewBuilder
    private func placeholder(
        _ title: LocalizedStringKey, systemImage: String, description: Text? = nil, identifier: String
    ) -> some View {
        #if os(macOS)
            PlaceholderView(title: title, systemImage: systemImage, description: description, identifier: identifier)
        #else
            ContentUnavailableView(title, systemImage: systemImage, description: description)
                .accessibilityIdentifier(identifier)
        #endif
    }

    private var title: Text {
        guard let id = model.selectedDocumentID,
            let document = model.documents.first(where: { $0.instanceID == id })
        else { return Text(verbatim: "") }
        return Text(verbatim: displayTitle(document.title, fallback: String(localized: "Untitled document")))
    }
}
