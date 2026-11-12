import CoreGraphics
import DokumentumCore
import Foundation
import ImageIO
import Observation

/// The photo cleanup of one pick (#5, part 3): the photos picked in Photos, a page each (a multi-page TIFF a page
/// per frame, T8), each with its edit: the detected page edges, applied automatically when found, the filter
/// (Enhanced by default, P3), clockwise quarter turns, and remove page. *Save* hands the kept pages to
/// `importEditedImages` (`ImportController.saveCleanup`); *Cancel* imports nothing.
///
/// **One detection at a time** (finding 3 of the plan review on #5): one task decodes, detects and releases the
/// pages in sequence, the selected page first, then the others in order, so a large pick never holds more than one
/// detection image. Save and Cancel stop it (`stop()`); a page still waiting for its detection is saved with the
/// edit it has then (the full page), so Save never waits for Vision. A detection that ends after the user set the
/// corners does not move them.
///
/// **Memory:** the original bytes of each photo (as Photos handed them over, as the import needs them), a 240 px
/// thumbnail per page, and at most three previews of `previewPixelSize`: the selected page and its neighbours, plus
/// the selected page with its filter applied.
@MainActor @Observable
final class PhotoCleanupModel: Identifiable {
    /// One page of the cleanup.
    struct Page: Identifiable, Equatable {
        /// Its place in the pick; stays when pages before it are removed.
        let id: Int
        /// The photo it comes from (an index into `images`) and the frame of it.
        let image: Int
        let frame: Int
        /// The photo's displayed size (EXIF orientation applied), for the geometry; `nil` when ImageIO gives none.
        let size: CGSize?
        var edit: PageEdit
        var detection: Detection = .waiting
        /// The user set the corners (moved one, Full Page, Detected Edges): a later detection leaves them.
        var cornersSetByUser = false
    }

    /// The page detection's state for one page.
    enum Detection: Equatable {
        case waiting
        case found(PageQuad)
        case notFound
    }

    /// A page of the pick before the cleanup: the photo, its frame and its size.
    struct PageSource: Sendable, Equatable {
        let image: Int
        let frame: Int
        let size: CGSize?
    }

    /// The edit a page starts with (P3): the full page until its edges are detected, Enhanced.
    nonisolated static let initialEdit = PageEdit(corners: .fullPage, quarterTurns: 0, filter: .enhanced)
    /// The longer side of a detection image and of a preview.
    nonisolated static let previewPixelSize = 1600
    /// The longer side of a thumbnail.
    nonisolated static let thumbnailPixelSize = 240

    nonisolated let id = UUID()
    /// The photos' bytes, as Photos handed them over.
    let images: [Data]
    /// The photos of the pick that are not in the cleanup: not handed over by Photos, or not readable. The notice
    /// after Save counts them as left out.
    let leftOut: Int
    private(set) var pages: [Page]
    private(set) var selectedPageID: Int?
    /// Unedited thumbnails, by page.
    private(set) var thumbnails: [Int: CGImage] = [:]
    /// Unedited previews of the selected page and its neighbours, by page.
    private(set) var previews: [Int: CGImage] = [:]
    /// The selected page's preview with its filter applied.
    private(set) var filteredPreview: (pageID: Int, filter: PageFilter, image: CGImage)?

    @ObservationIgnored private let detector: any PageCornerDetecting
    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isStopped = false
    /// Called on the main actor after each page's detection was applied (tests wait for it).
    @ObservationIgnored var detectionApplied: (@MainActor (_ pageID: Int) -> Void)?
    /// Called on the main actor when the detection task ends: every page done, or stopped (tests wait for it).
    @ObservationIgnored var detectionEnded: (@MainActor () -> Void)?
    /// Called after the selected page's filtered preview was set (tests wait for it).
    @ObservationIgnored var previewShown: (@MainActor (_ pageID: Int) -> Void)?

    init(images: [Data], pages: [PageSource], leftOut: Int = 0, detector: any PageCornerDetecting) {
        self.images = images
        self.leftOut = leftOut
        self.pages = pages.enumerated().map { index, source in
            Page(id: index, image: source.image, frame: source.frame, size: source.size, edit: Self.initialEdit)
        }
        self.detector = detector
        selectedPageID = self.pages.first?.id
    }

    /// The pages of `images`: one per photo, one per frame of a multi-page TIFF (T8), in order. A photo ImageIO
    /// cannot read gives none and is counted.
    @concurrent
    nonisolated static func pageSources(of images: [Data]) async -> (pages: [PageSource], unreadable: Int) {
        var pages: [PageSource] = []
        var unreadable = 0
        for (index, data) in images.enumerated() {
            guard let source = ImageCoding.imageSource(for: data), CGImageSourceGetCount(source) > 0 else {
                unreadable += 1
                continue
            }
            for frame in 0..<ImageCoding.pageCount(of: source) {
                pages.append(
                    PageSource(image: index, frame: frame, size: ImageCoding.displayedSize(of: source, at: frame)))
            }
        }
        return (pages, unreadable)
    }

    // MARK: Selection and edits

    var selectedPage: Page? {
        pages.first { $0.id == selectedPageID }
    }

    /// At least one page is left.
    var canSave: Bool { !pages.isEmpty }

    func select(_ pageID: Int) {
        guard pages.contains(where: { $0.id == pageID }), pageID != selectedPageID else { return }
        selectedPageID = pageID
        updatePreviews()
    }

    /// Turns the selected page a quarter clockwise (P3: clockwise only).
    func rotate() {
        updateSelected { $0.edit.quarterTurns += 1 }
    }

    func setFilter(_ filter: PageFilter) {
        updateSelected { $0.edit.filter = filter }
        updatePreviews()
    }

    /// Moves a corner of the selected page to `point` (normalised, in the unturned photo). Refused, with the last
    /// convex corners kept, when the page would not be convex. Returns whether it moved.
    @discardableResult
    func moveCorner(_ corner: QuadCorner, to point: CGPoint) -> Bool {
        guard let page = selectedPage, let moved = QuadGeometry.moving(corner, of: page.edit.corners, to: point)
        else { return false }
        updateSelected {
            $0.edit.corners = moved
            $0.cornersSetByUser = true
        }
        return true
    }

    /// The whole photo, no crop.
    func useFullPage() {
        updateSelected {
            $0.edit.corners = .fullPage
            $0.cornersSetByUser = true
        }
    }

    /// The detected edges again, when a page was found.
    func useDetectedEdges() {
        updateSelected {
            guard case .found(let quad) = $0.detection else { return }
            $0.edit.corners = quad
            $0.cornersSetByUser = true
        }
    }

    /// What the edges button does for the selected page: "Full Page" while the page is cropped, "Detected Edges"
    /// (only when a page was found) while it is not.
    enum EdgesAction: Equatable {
        case fullPage
        case detectedEdges(available: Bool)
    }

    var edgesAction: EdgesAction {
        guard let page = selectedPage else { return .detectedEdges(available: false) }
        if page.edit.corners != .fullPage { return .fullPage }
        if case .found = page.detection { return .detectedEdges(available: true) }
        return .detectedEdges(available: false)
    }

    /// Removes the selected page; the next one (or the one before, at the end) is selected.
    func removeSelectedPage() {
        guard let index = pages.firstIndex(where: { $0.id == selectedPageID }) else { return }
        let removed = pages.remove(at: index)
        thumbnails[removed.id] = nil
        previews[removed.id] = nil
        selectedPageID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
        updatePreviews()
    }

    private func updateSelected(_ change: (inout Page) -> Void) {
        guard let index = pages.firstIndex(where: { $0.id == selectedPageID }) else { return }
        change(&pages[index])
    }

    // MARK: Save

    /// The kept pages, grouped by photo in their order, with their edits as they are now: a page still waiting
    /// for its detection has the full page.
    var editedImages: [EditedImage] {
        var result: [(image: Int, pages: [EditedPage])] = []
        for page in pages {
            let edited = EditedPage(frame: page.frame, edit: page.edit)
            if let last = result.last, last.image == page.image {
                result[result.count - 1].pages.append(edited)
            } else {
                result.append((page.image, [edited]))
            }
        }
        return result.map { EditedImage(data: images[$0.image], pages: $0.pages) }
    }

    // MARK: Detection and previews

    /// Starts the detection and the previews; once.
    func start() {
        guard detectionTask == nil, !isStopped else { return }
        detectionTask = Task { await self.detectPages() }
        updatePreviews()
    }

    /// Ends the detection and the previews (Save, Cancel) and lets the decoded images go. A detection that is
    /// running then is not applied.
    func stop() {
        isStopped = true
        detectionTask?.cancel()
        previewTask?.cancel()
        previews = [:]
        filteredPreview = nil
        thumbnails = [:]
    }

    /// The pages in sequence, one at a time: the selected page first while it waits, then the first waiting one.
    private func detectPages() async {
        defer { detectionEnded?() }
        while !Task.isCancelled, let page = nextPageToDetect() {
            let data = images[page.image]
            let result = await Self.detect(
                data, frame: page.frame, preview: previews[page.id], detector: detector)
            guard !Task.isCancelled else { return }
            apply(result, to: page.id)
        }
    }

    private func nextPageToDetect() -> Page? {
        if let selected = selectedPage, selected.detection == .waiting { return selected }
        return pages.first { $0.detection == .waiting }
    }

    /// What one detection gives: the quad (nil: no page found, or the frame could not be decoded), the thumbnail,
    /// and the decoded image for the previews.
    struct DetectionResult: Sendable {
        let quad: PageQuad?
        let thumbnail: CGImage?
        let image: CGImage?
    }

    /// Decodes the frame (unless its preview is there), makes its thumbnail and detects the page, off the main
    /// actor.
    @concurrent
    nonisolated static func detect(
        _ data: Data, frame: Int, preview: CGImage?, detector: any PageCornerDetecting
    ) async -> DetectionResult {
        let image =
            preview
            ?? ImageCoding.imageSource(for: data).flatMap {
                ImageCoding.orientedImage(from: $0, at: frame, maxPixelSize: previewPixelSize)
            }
        guard let image else { return DetectionResult(quad: nil, thumbnail: nil, image: nil) }
        let thumbnail = ImageCoding.scaled(image, maxPixelSize: thumbnailPixelSize)
        let quad = await detector.detect(in: image)?.quad
        return DetectionResult(quad: quad, thumbnail: thumbnail, image: image)
    }

    private func apply(_ result: DetectionResult, to pageID: Int) {
        if let index = pages.firstIndex(where: { $0.id == pageID }) {
            if let quad = result.quad {
                pages[index].detection = .found(quad)
                if !pages[index].cornersSetByUser { pages[index].edit.corners = quad }
            } else {
                pages[index].detection = .notFound
            }
            if let thumbnail = result.thumbnail { thumbnails[pageID] = thumbnail }
            if let image = result.image, previews[pageID] == nil, wantedPreviewIDs.contains(pageID) {
                previews[pageID] = image
                updatePreviews()
            }
        }
        detectionApplied?(pageID)
    }

    /// The selected page and its neighbours.
    private var wantedPreviewIDs: [Int] {
        guard let index = pages.firstIndex(where: { $0.id == selectedPageID }) else { return [] }
        return [index, index - 1, index + 1].filter(pages.indices.contains).map { pages[$0].id }
    }

    /// Keeps the previews of the selected page and its neighbours, decodes the missing ones (the selected first),
    /// then renders the selected one with its filter. One task; a new selection or filter replaces it.
    private func updatePreviews() {
        guard !isStopped else { return }
        let wanted = wantedPreviewIDs
        for id in previews.keys where !wanted.contains(id) { previews[id] = nil }
        if let shown = filteredPreview, shown.pageID != selectedPageID { filteredPreview = nil }
        previewTask?.cancel()
        previewTask = Task { await self.loadPreviews(wanted) }
    }

    private func loadPreviews(_ wanted: [Int]) async {
        for id in wanted where previews[id] == nil {
            guard let page = pages.first(where: { $0.id == id }) else { continue }
            let image = await Self.decodePreview(images[page.image], frame: page.frame)
            guard !Task.isCancelled else { return }
            if let image { previews[id] = image }
        }
        guard let page = selectedPage, let preview = previews[page.id] else { return }
        let filter = page.edit.filter
        if let shown = filteredPreview, shown.pageID == page.id, shown.filter == filter { return }
        let filtered = await Self.filtered(preview, filter)
        guard !Task.isCancelled, let filtered else { return }
        filteredPreview = (page.id, filter, filtered)
        previewShown?(page.id)
    }

    @concurrent
    nonisolated static func decodePreview(_ data: Data, frame: Int) async -> CGImage? {
        ImageCoding.imageSource(for: data).flatMap {
            ImageCoding.orientedImage(from: $0, at: frame, maxPixelSize: previewPixelSize)
        }
    }

    /// The whole preview with `filter`, not cropped or turned: the large page shows the photo with the corners on
    /// it, turned by the view.
    @concurrent
    nonisolated static func filtered(_ image: CGImage, _ filter: PageFilter) async -> CGImage? {
        PageCleanup.render(image, edit: PageEdit(corners: .fullPage, quarterTurns: 0, filter: filter))
    }
}
