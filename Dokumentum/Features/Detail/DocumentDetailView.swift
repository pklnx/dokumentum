import DokumentumCore
import DokumentumKit
import SwiftUI

/// The detail column: the open document's PDF, or why there is none (PQ12), and its info panel.
struct DocumentDetailView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        content
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .task(id: model.selectedDocumentID) {
                await model.loadDetail(for: model.selectedDocumentID)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isInfoPresented.toggle()
                    } label: {
                        Label("Show Info", systemImage: "info.circle")
                    }
                    .disabled(model.selectedDocument == nil)
                    .accessibilityIdentifier(AccessibilityID.detailShowInfo)
                }
            }
            #if os(macOS)
                // A trailing column on the Mac (plan of #3, part 3).
                .inspector(isPresented: $model.isInfoPresented) {
                    DocumentInfoView(model: model)
                }
            #else
                // A sheet on the iPhone. Not `.inspector`, which also becomes a sheet here: it put the panel's
                // toolbar ("Done") into the detail's bar beneath the sheet, where it cannot be reached
                // (measured on iOS 27.0).
                .sheet(isPresented: $model.isInfoPresented) {
                    DocumentInfoView(model: model)
                }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        switch model.detail {
        case .noSelection:
            ContentUnavailableView("No document selected", systemImage: "doc.text.magnifyingglass")
                .accessibilityIdentifier(AccessibilityID.detailNoSelection)
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(AccessibilityID.detailLoading)
        case .stillDownloading:
            ContentUnavailableView(
                "Still downloading", systemImage: "icloud.and.arrow.down",
                description: Text("The file is being downloaded from iCloud.")
            )
            .accessibilityIdentifier(AccessibilityID.detailStillDownloading)
        case .unreadable:
            ContentUnavailableView(
                "This PDF cannot be shown", systemImage: "exclamationmark.triangle",
                description: Text("The file is damaged or not a PDF.")
            )
            .accessibilityIdentifier(AccessibilityID.detailUnreadable)
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

    private var title: Text {
        guard let id = model.selectedDocumentID,
            let document = model.documents.first(where: { $0.instanceID == id })
        else { return Text(verbatim: "") }
        return Text(verbatim: displayTitle(document.title, fallback: String(localized: "Untitled document")))
    }
}
