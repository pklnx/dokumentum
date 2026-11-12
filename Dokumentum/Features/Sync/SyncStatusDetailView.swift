import DokumentumCore
import DokumentumKit
import SwiftUI

/// "iCloud Sync" (plan of #31, P1): the footer's line, and for a CloudKit store the account, the last download and the
/// last upload (relative and absolute) and, for a problem, its CloudKit code ("CKError 25"), so a screenshot is
/// enough for a diagnosis. A popover on the Mac, a sheet on the iPhone.
struct SyncStatusDetailView: View {
    let source: SyncStatusSource
    @Environment(\.locale) private var locale

    var body: some View {
        TimelineView(.everyMinute) { context in
            let content = source.content
            Form {
                Section {
                    Label {
                        Text(content.text(now: context.date, locale: locale))
                    } icon: {
                        Image(systemName: content.symbol)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.syncStatusDetailLine)
                    if let code = Self.problemCode(content: content, status: source.status) {
                        Text(verbatim: SyncStatusText.code(code))
                            .font(.callout.monospaced())
                            .accessibilityIdentifier(AccessibilityID.syncStatusDetailCode)
                    }
                }
                if let status = source.status {
                    Section {
                        LabeledContent("Account") {
                            Text(SyncStatusText.account(status.accountState))
                        }
                        time("Last download", status.lastImport, now: context.date)
                        time("Last upload", status.lastExport, now: context.date)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("iCloud Sync")
        #if os(macOS)
            .frame(minWidth: 360, idealWidth: 400)
            .fixedSize(horizontal: false, vertical: true)
        #else
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier(AccessibilityID.syncStatusDetail)
    }

    private func time(_ title: LocalizedStringResource, _ date: Date?, now: Date) -> some View {
        LabeledContent {
            if let date {
                VStack(alignment: .trailing) {
                    Text(verbatim: SyncStatusText.relative(date, now: now, locale: locale))
                    Text(date, format: .dateTime.day().month().year().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Never")
            }
        } label: {
            Text(title)
        }
    }

    /// The CloudKit code behind a problem line: 25 for storage full (which stays after the failure itself is
    /// cleared); the last failure's code for a line that failure decided (offline, reset, other problem, and "Sync off"
    /// while the account's answer still says available, Revision 1, note 1); none for a line the account decided.
    static func problemCode(content: SyncFooterContent, status: SyncStatus?) -> Int? {
        guard case .status(let line) = content, let status else { return nil }
        switch line {
        case .storageFull: return CloudErrorCategory.quotaExceeded
        case .offline, .reset, .problem: return status.lastErrorCode
        case .syncOff:
            return status.accountState == nil || status.accountState == .available ? status.lastErrorCode : nil
        case .accountChanged, .checking, .on: return nil
        }
    }
}
