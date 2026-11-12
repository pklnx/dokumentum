import DokumentumCore
import DokumentumKit
import SwiftUI

/// Where the sidebar footer's line comes from (plan of #31, P1): the store of the launch when it does not sync,
/// otherwise the CloudKit store's monitor.
@MainActor
enum SyncStatusSource {
    /// A store that does not sync: "Sync off: <reason>", decided by the store alone.
    case store(StoreSyncOffReason)
    /// A CloudKit store: the monitor's status.
    case cloud(CloudSyncMonitor)
    /// A status injected by `-UITestSyncStatus` (Debug builds), in place of either.
    case injected(SyncStatus)

    /// The source of this launch. An injected status wins; then a store that does not sync; then the monitor, which
    /// exists exactly for a CloudKit store. `nil` only if neither is there, which no launch has.
    static func forLaunch(
        _ launchStore: LaunchStore, monitor: CloudSyncMonitor?, injected: SyncStatus? = nil
    ) -> SyncStatusSource? {
        if let injected { return .injected(injected) }
        if let reason = launchStore.syncOffReason { return .store(reason) }
        return monitor.map { .cloud($0) }
    }

    /// The status behind the line; `nil` for a store that does not sync. Read in a view body, it follows the monitor.
    var status: SyncStatus? {
        switch self {
        case .store: nil
        case .cloud(let monitor): monitor.status
        case .injected(let status): status
        }
    }

    /// What the footer shows.
    var content: SyncFooterContent {
        switch self {
        case .store(let reason): .store(reason)
        case .cloud, .injected: .status(SyncStatusLine(status ?? SyncStatus()))
        }
    }
}

/// The footer's one line.
enum SyncFooterContent: Hashable {
    case store(StoreSyncOffReason)
    case status(SyncStatusLine)

    /// `sidebar.syncOff` for a store that does not sync (the identifier of #3's "Sync off" line, kept for its tests),
    /// `sidebar.syncStatus` for a CloudKit store's line.
    var accessibilityIdentifier: String {
        switch self {
        case .store: AccessibilityID.syncOffLine
        case .status: AccessibilityID.syncStatusLine
        }
    }

    func text(now: Date, locale: Locale) -> LocalizedStringResource {
        switch self {
        case .store(let reason): SyncStatusText.storeLine(reason)
        case .status(let line): SyncStatusText.line(line, now: now, locale: locale)
        }
    }

    var symbol: String {
        switch self {
        case .store: "icloud.slash"
        case .status(let line):
            switch line {
            case .on: "checkmark.icloud"
            case .checking: "icloud"
            case .storageFull, .problem: "exclamationmark.icloud"
            case .accountChanged: "person.crop.circle.badge.exclamationmark"
            case .syncOff, .offline: "icloud.slash"
            case .reset: "arrow.clockwise.icloud"
            }
        }
    }
}

/// The sidebar footer for every store, on the iPhone and the Mac (plan of #31, P1): one line, which opens "iCloud
/// Sync" (a popover on the Mac, a sheet on the iPhone). It keeps the look of #3's "Sync off" line.
struct SyncStatusFooter: View {
    let source: SyncStatusSource
    @State private var isDetailPresented = false
    @Environment(\.locale) private var locale

    var body: some View {
        let content = source.content
        Button {
            isDetailPresented = true
        } label: {
            // "last synced 5 minutes ago" moves on once a minute.
            TimelineView(.everyMinute) { context in
                Label {
                    Text(content.text(now: context.date, locale: locale))
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: content.symbol)
                }
            }
            .font(.footnote)
            // Primary, not secondary: over the bar background the secondary colour measured 4.04:1 in light mode on
            // the Mac, below 4.5:1 (maintainer decision on #74, round 3). The background stays.
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(iOS)
                // A button's hit area on the iPhone is at least 44 pt high.
                .frame(minHeight: 44)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // The rows scroll beneath the footer: without a background they showed through its text, at large
        // Dynamic Type sizes over a whole row (iPhone, XXXL; plan of #3, part 5).
        .background(.bar)
        .accessibilityIdentifier(content.accessibilityIdentifier)
        #if os(macOS)
            // Anchored at the footer's trailing end, not its centre: the detail is wider than the sidebar, and centred
            // on the footer it ran past the window's left edge (review of #149, N1). A one-point view there carries
            // the popover: with `attachmentAnchor: .point(.topTrailing)` on the footer, the UI test saw none open.
            .overlay(alignment: .topTrailing) {
                Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .popover(isPresented: $isDetailPresented, arrowEdge: .top) {
                    SyncStatusDetailView(source: source)
                }
            }
        #else
            .sheet(isPresented: $isDetailPresented) {
                NavigationStack {
                    SyncStatusDetailView(source: source)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isDetailPresented = false }
                            .accessibilityIdentifier(AccessibilityID.syncStatusDone)
                        }
                    }
                }
            }
        #endif
    }
}
