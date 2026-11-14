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

    /// The detail's processing status line in each state, and its "Try again" (#6, P2).
    static let detailProcessingPending = "documentDetail.processing.pending"
    static let detailProcessingRunning = "documentDetail.processing.running"
    static let detailProcessingFailed = "documentDetail.processing.failed"
    static let detailProcessingRetry = "documentDetail.processing.retry"
    /// The line while suggestions are made for the document (#8, part 3).
    static let detailProcessingClassify = "documentDetail.processing.classify"

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

    /// The sidebar footer's "Sync off" line of a store that does not sync.
    static let syncOffLine = "sidebar.syncOff"
    /// The sidebar footer's line of a CloudKit store (#31), and its "iCloud Sync" detail: the view, its line, the
    /// CloudKit code of a problem, and the iPhone sheet's "Done".
    static let syncStatusLine = "sidebar.syncStatus"
    static let syncStatusDetail = "syncStatus.detail"
    static let syncStatusDetailLine = "syncStatus.detail.line"
    static let syncStatusDetailCode = "syncStatus.detail.code"
    static let syncStatusDone = "syncStatus.detail.done"

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

    /// The search (#7, part 3): the empty result, the "Indexing texts…" line, the chips and suggestions, and the scope
    /// switch's two segments.
    static let searchEmpty = "search.empty"
    static let searchIndexing = "search.indexing"
    static func searchToken(_ token: SearchToken) -> String {
        switch token {
        case .tag(let id): "search.token.tag.\(id.uuidString)"
        case .correspondent(let id): "search.token.correspondent.\(id.uuidString)"
        case .documentType(let id): "search.token.documentType.\(id.uuidString)"
        case .inbox: "search.token.inbox"
        }
    }
    static func searchScope(_ scope: SearchScope) -> String {
        switch scope {
        case .selection: "search.scope.selection"
        case .all: "search.scope.all"
        }
    }

    /// The settings (#8, part 3): the view, the iPhone sidebar's button that opens it and the sheet's "Done", and the
    /// "Suggestions" section's switch, availability note and privacy statement.
    static let settings = "settings"
    static let settingsOpen = "settings.open"
    static let settingsDone = "settings.done"
    static let settingsSuggestionsSwitch = "settings.suggestions.switch"
    static let settingsSuggestionsAvailability = "settings.suggestions.availability"
    static let settingsSuggestionsPrivacy = "settings.suggestions.privacy"

    /// The settings' "Matching" section (#10, part 2): "Apply Matching Rules to All Documents…", its confirmation's
    /// Apply and Cancel, the progress line with its Cancel, and the last run's result.
    static let settingsMatchingApply = "settings.matching.apply"
    static let settingsMatchingConfirm = "settings.matching.confirm"
    static let settingsMatchingConfirmCancel = "settings.matching.confirmCancel"
    static let settingsMatchingProgress = "settings.matching.progress"
    static let settingsMatchingCancel = "settings.matching.cancel"
    static let settingsMatchingResult = "settings.matching.result"

    /// The rule sheet (#10, part 2): the sidebar rows' "Edit Matching…", the sheet, its mode picker and each mode,
    /// the pattern field, the explanation, the line under the field, Save and Cancel, and the states of a record with
    /// copies and of a gone one.
    static let matchingEdit = "matching.edit"
    static let matchingSheet = "matching.sheet"
    static let matchingMode = "matching.mode"
    static func matchingMode(_ mode: MatchMode) -> String {
        switch mode {
        case .none: "matching.mode.none"
        case .any: "matching.mode.any"
        case .all: "matching.mode.all"
        case .exact: "matching.mode.exact"
        case .regex: "matching.mode.regex"
        case .unknown: "matching.mode.unknown"
        }
    }
    static let matchingPattern = "matching.pattern"
    static let matchingExplanation = "matching.explanation"
    static let matchingError = "matching.error"
    static let matchingSave = "matching.save"
    static let matchingCancel = "matching.cancel"
    static let matchingCopies = "matching.copies"
    static let matchingGone = "matching.gone"

    /// The iPhone sidebar's Debug menu and its "Add Sample Documents" (Debug builds).
    static let debugMenu = "debug.menu"
    static let debugAddSampleDocuments = "debug.addSampleDocuments"
}
