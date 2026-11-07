import PDFKit
import SwiftUI

/// The PDF viewer for iOS and macOS, ported from the predecessor's `Platform/PDFKitView.swift`
/// without find. Put an accessibility identifier on a SwiftUI container around it: on macOS XCUITest
/// does not find one on the representable itself (measured in the plan of #3).
struct PDFKitView: View {
    let data: Data
    /// Which document the data belongs to; the view reloads only when this or the data changes.
    let id: UUID

    var body: some View {
        Representable(data: data, id: id)
    }
}

#if os(macOS)
private struct Representable: NSViewRepresentable {
    let data: Data
    let id: UUID

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#else
private struct Representable: UIViewRepresentable {
    let data: Data
    let id: UUID

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        configure(view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}
#endif

private final class Coordinator {
    var shownID: UUID?
    var shownSize = -1
}

extension Representable {
    fileprivate func configure(_ view: PDFView) {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        #if os(iOS)
        view.backgroundColor = .secondarySystemBackground
        #endif
    }

    fileprivate func update(_ view: PDFView, coordinator: Coordinator) {
        // Reload only when the document or its data changed, not on every SwiftUI update. The size
        // stands in for the data: comparing a large PDF's bytes on every update costs too much.
        guard coordinator.shownID != id || coordinator.shownSize != data.count else { return }
        coordinator.shownID = id
        coordinator.shownSize = data.count
        view.document = PDFDocument(data: data)
        view.autoScales = true
    }
}
