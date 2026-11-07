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

    /// The sidebar footer's "Sync off" line.
    static let syncOffLine = "sidebar.syncOff"

    /// The iPhone sidebar's Debug menu and its "Add Sample Documents" (Debug builds).
    static let debugMenu = "debug.menu"
    static let debugAddSampleDocuments = "debug.addSampleDocuments"
}
