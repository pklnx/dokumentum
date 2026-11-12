import DokumentumCore
import SwiftUI

/// The photo cleanup sheet (#5, part 3), the same on both devices: the selected page large, the whole photo
/// turned as it will be saved, with the page's outline and four corner handles; the pages as thumbnails below;
/// Rotate, Filter, Full Page / Detected Edges and Remove Page in the bottom bar; Cancel and Save.
struct PhotoCleanupView: View {
    let model: PhotoCleanupModel
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PageEditorView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                PageStripView(model: model)
                Divider()
                CleanupBar(model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier(AccessibilityID.cleanupCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(!model.canSave)
                        .accessibilityIdentifier(AccessibilityID.cleanupSave)
                }
            }
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
            // At least 720 wide; 560 high, so the sheet with its button bar fits a library window of 720 pt (the
            // UI test's window cut a 640 pt sheet's Save button off).
            .frame(minWidth: 720, idealWidth: 860, minHeight: 560, idealHeight: 680)
        #endif
        .accessibilityIdentifier(AccessibilityID.cleanup)
        .task { model.start() }
    }
}

/// The selected page: the photo fitted into the view, turned by the edit's quarter turns, with the outline and the
/// handles. A drag moves a corner (`QuadGeometry`); VoiceOver moves it with the adjustable action.
private struct PageEditorView: View {
    let model: PhotoCleanupModel

    var body: some View {
        GeometryReader { proxy in
            if let page = model.selectedPage {
                let image = shownImage(of: page)
                let size =
                    page.size ?? image.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 3, height: 4)
                let geometry = QuadGeometry(
                    imageSize: size, quarterTurns: page.edit.quarterTurns,
                    bounds: CGRect(origin: .zero, size: proxy.size))
                let frame = geometry.imageFrame
                ZStack(alignment: .topLeading) {
                    Group {
                        if let image {
                            Image(decorative: image, scale: 1, orientation: Self.orientation(page.edit.quarterTurns))
                                .resizable()
                        } else {
                            Rectangle().fill(.quaternary)
                                .overlay { ProgressView() }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityElement()
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel(Text("Page \(position(of: page))"))
                    .accessibilityIdentifier(AccessibilityID.cleanupPage)

                    QuadOutline(points: page.edit.corners.points.map(geometry.viewPoint(for:)))
                        .stroke(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    ForEach(QuadCorner.allCases, id: \.self) { corner in
                        CornerHandle(
                            corner: corner, shownAs: corner.shown(turnedBy: page.edit.quarterTurns),
                            position: geometry.viewPoint(for: corner.point(in: page.edit.corners)),
                            move: { location in model.moveCorner(corner, to: geometry.photoPoint(for: location)) },
                            nudge: { outward in nudge(corner, of: page, outward: outward) })
                    }
                }
                .coordinateSpace(.named(CornerHandle.space))
            }
        }
    }

    /// The filtered preview when it is the selected page's with its filter, else the unfiltered preview, else the
    /// thumbnail.
    private func shownImage(of page: PhotoCleanupModel.Page) -> CGImage? {
        if let shown = model.filteredPreview, shown.pageID == page.id, shown.filter == page.edit.filter {
            return shown.image
        }
        return model.previews[page.id] ?? model.thumbnails[page.id]
    }

    private func position(of page: PhotoCleanupModel.Page) -> Int {
        (model.pages.firstIndex { $0.id == page.id } ?? 0) + 1
    }

    /// The adjustable action: 2 % of the photo towards the photo's own corner (outward) or away from it.
    private func nudge(_ corner: QuadCorner, of page: PhotoCleanupModel.Page, outward: Bool) {
        let step: CGFloat = outward ? 0.02 : -0.02
        let direction: (CGFloat, CGFloat) =
            switch corner {
            case .topLeft: (-1, -1)
            case .topRight: (1, -1)
            case .bottomRight: (1, 1)
            case .bottomLeft: (-1, 1)
            }
        let point = corner.point(in: page.edit.corners)
        model.moveCorner(corner, to: CGPoint(x: point.x + direction.0 * step, y: point.y + direction.1 * step))
    }

    /// The SwiftUI orientation that shows an image turned `turns` quarters clockwise, as `PageCleanup` turns it.
    static func orientation(_ turns: Int) -> Image.Orientation {
        switch QuadCorner.normalized(turns) {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
    }
}

/// The page's outline through its four corners.
private struct QuadOutline: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// One corner handle: a 44 pt hit area around a visible dot.
private struct CornerHandle: View {
    static let space = "cleanup.page"

    let corner: QuadCorner
    /// Where the corner shows, for its label: the photo's top left shows at the top right after a quarter turn.
    let shownAs: QuadCorner
    let position: CGPoint
    let move: (CGPoint) -> Void
    let nudge: (_ outward: Bool) -> Void

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay { Circle().stroke(.white, lineWidth: 2) }
            .frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { move($0.location) }
            )
            // For VoiceOver a stepper: its role is known on both devices (the Mac's audit, review 5867292360), and
            // increment and decrement move the corner 2 % outwards and inwards.
            .accessibilityRepresentation {
                Stepper {
                    label
                } onIncrement: {
                    nudge(true)
                } onDecrement: {
                    nudge(false)
                }
            }
            .accessibilityIdentifier(AccessibilityID.cleanupCorner(shownAs))
    }

    private var label: Text {
        switch shownAs {
        case .topLeft: Text("Top left corner")
        case .topRight: Text("Top right corner")
        case .bottomRight: Text("Bottom right corner")
        case .bottomLeft: Text("Bottom left corner")
        }
    }
}

/// The pages as thumbnails, turned as they will be saved; a tap selects one.
private struct PageStripView: View {
    let model: PhotoCleanupModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        model.select(page.id)
                    } label: {
                        thumbnail(page)
                            .frame(width: 56, height: 72)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(
                                        page.id == model.selectedPageID ? Color.accentColor : .clear, lineWidth: 3)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Page \(index + 1)"))
                    .accessibilityAddTraits(page.id == model.selectedPageID ? .isSelected : [])
                    .accessibilityIdentifier(AccessibilityID.cleanupThumbnail(index))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func thumbnail(_ page: PhotoCleanupModel.Page) -> some View {
        if let image = model.thumbnails[page.id] {
            Image(decorative: image, scale: 1, orientation: PageEditorView.orientation(page.edit.quarterTurns))
                .resizable()
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
        }
    }
}

/// Rotate, Filter, Full Page / Detected Edges, Remove Page.
private struct CleanupBar: View {
    let model: PhotoCleanupModel

    var body: some View {
        HStack {
            Button {
                model.rotate()
            } label: {
                Label("Rotate", systemImage: "rotate.right")
            }
            .accessibilityIdentifier(AccessibilityID.cleanupRotate)
            Spacer()
            // VoiceOver's name for the menu, "Filter" (the iPhone's label, the Mac's title; asserted in `ScanSmokeTests`).
            // The label's title gives the same name today; the modifier keeps it if the label ever becomes an icon,
            // whose symbol's own name is read otherwise (measured, #136).
            filterControl
                .accessibilityLabel(Text("Filter"))
                .accessibilityIdentifier(AccessibilityID.cleanupFilter)
            Spacer()
            edgesButton
                .accessibilityIdentifier(AccessibilityID.cleanupEdges)
            Spacer()
            Button(role: .destructive) {
                model.removeSelectedPage()
            } label: {
                Label("Remove Page", systemImage: "trash")
            }
            .accessibilityIdentifier(AccessibilityID.cleanupRemove)
        }
        .labelStyle(BarLabelStyle())
        .disabled(model.selectedPage == nil)
    }

    /// The filter menu, in the bar's look. The Mac's accessibility audit reports "Action is missing" on it, as on the
    /// "+" menu and also on a pop-up picker in its place (measured, #112 fix round 1): accepted in `UITestApp`.
    private var filterControl: some View {
        Menu {
            Picker(selection: filter) {
                filterOptions
            } label: {
                Text("Filter")
            }
            .pickerStyle(.inline)
        } label: {
            Label("Filter", systemImage: "camera.filters")
        }
    }

    private var filterOptions: some View {
        ForEach(PageFilter.allCases, id: \.self) { filter in
            Text(Self.name(of: filter)).tag(filter)
        }
    }

    @ViewBuilder
    private var edgesButton: some View {
        switch model.edgesAction {
        case .fullPage:
            Button {
                model.useFullPage()
            } label: {
                Label("Full Page", systemImage: "rectangle.dashed")
            }
        case .detectedEdges(let available):
            Button {
                model.useDetectedEdges()
            } label: {
                Label("Detected Edges", systemImage: "crop")
            }
            .disabled(!available)
        }
    }

    private var filter: Binding<PageFilter> {
        Binding(
            get: { model.selectedPage?.edit.filter ?? PhotoCleanupModel.initialEdit.filter },
            set: { model.setFilter($0) })
    }

    static func name(of filter: PageFilter) -> LocalizedStringKey {
        switch filter {
        case .original: "Original"
        case .enhanced: "Enhanced"
        case .grayscale: "Grayscale"
        case .blackAndWhite: "Black & White"
        }
    }
}

/// The bar's labels: the symbol above a short title, so four fit next to each other on the iPhone.
private struct BarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon
                .font(.title3)
            configuration.title
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: 64)
    }
}
