import DokumentumKit
import Foundation

/// Accessibility identifiers for the views UI tests touch. UI tests query these, never the localized
/// text, so changing a label does not break them. `DokumentumUITests` repeats the ones it uses: a UI
/// test cannot see the app's code.
enum AccessibilityID {
    static let sidebar = "sidebar"
    static let sidebarInbox = "sidebar.inbox"
    static let sidebarAll = "sidebar.all"
    static let sidebarTrash = "sidebar.trash"

    static func sidebarRow(_ selection: LibrarySelection) -> String {
        switch selection {
        case .inbox: sidebarInbox
        case .all: sidebarAll
        case .trash: sidebarTrash
        case .tag(let id): "sidebar.tag.\(id.uuidString)"
        case .correspondent(let id): "sidebar.correspondent.\(id.uuidString)"
        case .documentType(let id): "sidebar.documentType.\(id.uuidString)"
        }
    }

    /// The chevron that expands or collapses a tag's nested tags.
    static func tagDisclosure(_ id: UUID) -> String { "sidebar.tagDisclosure.\(id.uuidString)" }

    static let documentList = "documentList"
    static let documentListEmpty = "documentList.empty"
    static func documentRow(_ id: UUID) -> String { "documentList.row.\(id.uuidString)" }

    /// The detail column in each of its states.
    static let detailPDF = "documentDetail.pdf"
    static let detailStillDownloading = "documentDetail.stillDownloading"
    static let detailUnreadable = "documentDetail.unreadable"
    static let detailNoSelection = "documentDetail.noSelection"
    static let detailLoading = "documentDetail.loading"

    /// The detail's toolbar button that shows the info panel.
    static let detailShowInfo = "documentDetail.showInfo"

    /// The info panel (plan of #3, part 3) and its controls.
    static let info = "documentInfo"
    static let infoTitle = "documentInfo.title"
    /// The line under the title field when its save failed.
    static let infoTitleNotSaved = "documentInfo.titleNotSaved"
    static let infoDate = "documentInfo.date"
    static let infoInbox = "documentInfo.inbox"
    static let infoCorrespondent = "documentInfo.correspondent"
    static let infoDocumentType = "documentInfo.documentType"
    static func infoTag(_ id: UUID) -> String { "documentInfo.tag.\(id.uuidString)" }
    static let infoNewTag = "documentInfo.newTag"
    static let infoNewName = "documentInfo.newName"
    /// The iPhone sheet's "Done".
    static let infoDone = "documentInfo.done"

    /// The sidebar footer's "Sync off" line.
    static let syncOffLine = "sidebar.syncOff"

    /// The list toolbar's "+" menu, its "Scan…" (#5, part 2), "Files…" and "Photos…" items, and the import
    /// notice's OK button (#4, parts 2 and 3).
    static let importMenu = "import.menu"
    static let importScan = "import.scan"
    /// The "Saving scan…" indicator while a scan is encoded and imported.
    static let importSavingScan = "import.savingScan"
    /// The "Saving photos…" indicator while the cleaned photos are imported (#5, part 3).
    static let importSavingPhotos = "import.savingPhotos"
    static let importFiles = "import.files"
    static let importPhotos = "import.photos"
    static let importNoticeOK = "import.notice.ok"

    /// The photo cleanup sheet (#5, part 3): the sheet, its large page, the corner handles (named by where they
    /// show), the thumbnails by position, and its buttons.
    static let cleanup = "cleanup"
    static let cleanupPage = "cleanup.page"
    static func cleanupCorner(_ corner: QuadCorner) -> String {
        switch corner {
        case .topLeft: "cleanup.corner.topLeft"
        case .topRight: "cleanup.corner.topRight"
        case .bottomRight: "cleanup.corner.bottomRight"
        case .bottomLeft: "cleanup.corner.bottomLeft"
        }
    }
    static func cleanupThumbnail(_ position: Int) -> String { "cleanup.thumbnail.\(position)" }
    static let cleanupCancel = "cleanup.cancel"
    static let cleanupSave = "cleanup.save"
    static let cleanupRotate = "cleanup.rotate"
    static let cleanupFilter = "cleanup.filter"
    static let cleanupEdges = "cleanup.edges"
    static let cleanupRemove = "cleanup.remove"

    /// The iPhone sidebar's Debug menu and its "Add Sample Documents" (Debug builds).
    static let debugMenu = "debug.menu"
    static let debugAddSampleDocuments = "debug.addSampleDocuments"
}
