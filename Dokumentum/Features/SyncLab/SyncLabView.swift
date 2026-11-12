#if DEBUG
    import DokumentumCore
    import DokumentumKit
    import SwiftData
    import SwiftUI

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    // The Sync lab's screen (plan of #31, part 2). Debug builds only; its texts are English and `verbatim`, outside the
    // catalog, like the other debug UI. The protocol that uses it: `docs/development/sync.md`.

    /// The lab's sections: this device, create, documents, metadata, search probe, export state, CloudKit schema.
    struct SyncLabView: View {
        @Bindable var lab: SyncLab
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            #if os(macOS)
                content
                    .frame(minWidth: 620, minHeight: 640)
            #else
                NavigationStack {
                    content
                        .navigationTitle(Text(verbatim: "Sync Lab"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    dismiss()
                                } label: {
                                    Text(verbatim: "Done")
                                }
                            }
                        }
                }
            #endif
        }

        private var content: some View {
            Form {
                if let message = lab.message {
                    Section {
                        Text(verbatim: message)
                            .font(.callout)
                            .textSelection(.enabled)
                            .accessibilityIdentifier(SyncLabID.message)
                    }
                }
                ThisDeviceSection(lab: lab)
                CreateSection(lab: lab)
                DocumentsSection(lab: lab)
                MetadataSection(lab: lab)
                SearchProbeSection(lab: lab)
                ExportSection(lab: lab)
                if lab.canInitializeSchema {
                    Section {
                        Button {
                            Task { await lab.initializeSchema() }
                        } label: {
                            Text(verbatim: "Initialize CloudKit schema")
                        }
                        .disabled(lab.isBusy)
                    } header: {
                        Text(verbatim: "CloudKit schema (Development)")
                    }
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier(SyncLabID.root)
            .task { await lab.refresh() }
            .confirmationDialog(
                Text(verbatim: "Write to the synced store?"), isPresented: $lab.isConfirmingWrite
            ) {
                Button {
                    lab.confirmWrites()
                } label: {
                    Text(verbatim: "Write")
                }
                Button(role: .cancel) {
                    lab.cancelWrite()
                } label: {
                    Text(verbatim: "Cancel")
                }
            } message: {
                Text(
                    verbatim:
                        "The Sync lab writes to the store on disk; with CloudKit it syncs to Development with this device's iCloud account. Asked once per launch."
                )
            }
        }
    }

    /// The lab's accessibility identifiers.
    enum SyncLabID {
        static let root = "syncLab.root"
        static let message = "syncLab.message"
        static let menuItem = "debug.syncLab"
    }

    // MARK: - This device

    private struct ThisDeviceSection: View {
        let lab: SyncLab
        @State private var searchSummary = "…"

        var body: some View {
            Section {
                // The scheduler, the repair and the index are not observable: the section reads them once a second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        line("Device", lab.shortDeviceID)
                        line("Store", "\(lab.launchStore.opened.rawValue)")
                        line("Takeover interval", "\(Int(lab.takeoverInterval)) s")
                        line("Re-queue flag", lab.isRequeueDone ? "set (pass completed)" : "not set")
                        line("Classification", lab.isClassificationEnabled ? "on" : "off")
                        line("Processing", lab.processingState)
                        line("Last run", lab.lastProcessingReport)
                        line("Repair", lab.lastRepairCounts)
                        line("Search index", searchSummary)
                    }
                    .task(id: context.date) { searchSummary = await lab.searchIndexSummary() }
                }
                Toggle(
                    isOn: Binding(get: { lab.isHeld }, set: { lab.setHold($0) })
                ) {
                    Text(verbatim: "Hold processing on this device")
                }
                .disabled(lab.processing == nil)
                Toggle(
                    isOn: Binding(get: { lab.isClassificationEnabled }, set: { lab.setClassification($0) })
                ) {
                    Text(verbatim: "Classify on this device (#8; off for run 1 except M1/M2)")
                }
                .disabled(!lab.canChangeDeviceSettings)
                HStack {
                    Button {
                        lab.resetRequeueFlag()
                    } label: {
                        Text(verbatim: "Reset re-queue flag")
                    }
                    .disabled(!lab.canChangeDeviceSettings)
                    Button {
                        lab.runRepair()
                    } label: {
                        Text(verbatim: "Run repair now")
                    }
                    .disabled(lab.repair == nil)
                }
                if let monitor = lab.monitor {
                    SyncMonitorRows(monitor: monitor)
                } else {
                    line("Sync", "no CloudKit store: \(lab.launchStore.syncOffReason.map { "\($0)" } ?? "in memory")")
                }
            } header: {
                Text(verbatim: "This device")
            }
        }
    }

    /// The raw status, the CloudKit user and the event log: the protocol's clock.
    private struct SyncMonitorRows: View {
        let monitor: CloudSyncMonitor

        var body: some View {
            line("Status", String(describing: monitor.status))
            line("CloudKit user", monitor.lastKnownUserRecordID.map { String($0.prefix(12)) } ?? "none")
            DisclosureGroup {
                ForEach(monitor.events.reversed(), id: \.identifier) { event in
                    Text(verbatim: Self.describe(event))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } label: {
                Text(verbatim: "Event log (\(monitor.events.count), newest first)")
            }
        }

        static func describe(_ event: CloudSyncEvent) -> String {
            let codes = event.errorChain.map { "\($0.domain) \($0.code)" }.joined(separator: ", ")
            let end = event.ended.map { SyncLabFormat.time($0) } ?? "running"
            let outcome = event.ended == nil ? "" : (event.succeeded ? " ok" : " FAILED \(codes)")
            return "\(event.kind) \(SyncLabFormat.time(event.started)) → \(end)\(outcome)"
        }
    }

    // MARK: - Create

    private struct CreateSection: View {
        let lab: SyncLab
        @State private var kind = SyncLabGenerator.Kind.text
        @State private var pages = 3
        @State private var names = SyncLab.Names()
        @State private var letter = false

        var body: some View {
            Section {
                Picker(selection: $kind) {
                    ForEach(SyncLabGenerator.Kind.allCases) { kind in
                        Text(verbatim: kind.label).tag(kind)
                    }
                } label: {
                    Text(verbatim: "Kind")
                }
                if kind != .large {
                    Stepper(value: $pages, in: 1...40) {
                        Text(verbatim: "Pages: \(pages)")
                    }
                }
                if kind == .text || kind == .scan {
                    Toggle(isOn: $letter) { Text(verbatim: "Letter page (M1/M2 only)") }
                }
                if kind == .text {
                    TextField(text: $names.tags) { Text(verbatim: "Tags (comma-separated)") }
                    TextField(text: $names.correspondent) { Text(verbatim: "Correspondent") }
                    TextField(text: $names.documentType) { Text(verbatim: "Type") }
                }
                Button {
                    lab.create(kind, pages: pages, names: names, letter: letter && kind != .large && kind != .legacy)
                } label: {
                    Text(verbatim: lab.isBusy ? "Working…" : "Create")
                }
                .disabled(lab.isBusy)
                if let word = lab.lastWord {
                    HStack {
                        Text(verbatim: "Last word: \(word)")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            SyncLabFormat.copy(word)
                        } label: {
                            Text(verbatim: "Copy")
                        }
                    }
                }
            } header: {
                Text(verbatim: "Create (lab documents: SyncLab- prefix)")
            }
        }
    }

    // MARK: - Documents

    private struct DocumentsSection: View {
        let lab: SyncLab
        @State private var selected: PersistentIdentifier?

        var body: some View {
            Section {
                HStack {
                    Button {
                        Task { await lab.refresh() }
                    } label: {
                        Text(verbatim: "Refresh")
                    }
                    Spacer()
                    Button(role: .destructive) {
                        lab.emptyTrash()
                    } label: {
                        Text(verbatim: "Empty lab trash")
                    }
                }
                ForEach(lab.rows ?? []) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            selected = selected == row.id ? nil : row.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(
                                    verbatim: (row.isTrashed ? "[trash] " : "") + (row.title.isEmpty ? "—" : row.title)
                                )
                                .font(.headline)
                                Text(verbatim: SyncLabFormat.summary(row, thisDevice: lab.deviceID))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if selected == row.id {
                            DocumentPanel(lab: lab, row: row)
                        }
                    }
                }
            } header: {
                Text(verbatim: "Documents (\(lab.rows?.count ?? 0), trashed included)")
            }
        }
    }

    /// One document's details and actions.
    private struct DocumentPanel: View {
        let lab: SyncLab
        let row: SyncLabDocuments.Row
        @State private var title = ""
        @State private var date = Date()
        @State private var name = ""
        @State private var megabytes = 2

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if let details = lab.details[row.instanceID] {
                    Text(verbatim: "text: \(details.text)\nfile: \(details.file)\nthumbnail: \(details.thumbnail)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Button {
                        Task { await lab.loadDetails(row.instanceID) }
                    } label: {
                        Text(verbatim: "Read text, file and thumbnail")
                    }
                }
                Text(verbatim: SyncLabFormat.metadata(row))
                    .font(.caption)
                HStack {
                    TextField(text: $title) { Text(verbatim: "Title") }
                    Button {
                        lab.edit(.title(title), of: row.instanceID)
                    } label: {
                        Text(verbatim: "Set title")
                    }
                }
                HStack {
                    DatePicker(selection: $date) { Text(verbatim: "Date") }
                    Button {
                        lab.edit(.documentDate(date), of: row.instanceID)
                    } label: {
                        Text(verbatim: "Set date")
                    }
                }
                Button {
                    lab.edit(.inbox(!row.isInbox), of: row.instanceID)
                } label: {
                    Text(verbatim: row.isInbox ? "Remove from inbox" : "Move to inbox")
                }
                HStack {
                    TextField(text: $name) { Text(verbatim: "Name (gets SyncLab-)") }
                    Menu {
                        Button {
                            lab.editByName(.tag, name: name, add: true, of: row.instanceID)
                        } label: {
                            Text(verbatim: "Add tag")
                        }
                        Button {
                            lab.editByName(.tag, name: name, add: false, of: row.instanceID)
                        } label: {
                            Text(verbatim: "Remove tag")
                        }
                        Button {
                            lab.editByName(.correspondent, name: name, add: true, of: row.instanceID)
                        } label: {
                            Text(verbatim: "Set correspondent")
                        }
                        Button {
                            lab.edit(.correspondent(nil), of: row.instanceID)
                        } label: {
                            Text(verbatim: "Clear correspondent")
                        }
                        Button {
                            lab.editByName(.documentType, name: name, add: true, of: row.instanceID)
                        } label: {
                            Text(verbatim: "Set type")
                        }
                        Button {
                            lab.edit(.documentType(nil), of: row.instanceID)
                        } label: {
                            Text(verbatim: "Clear type")
                        }
                    } label: {
                        Text(verbatim: "Metadata")
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    if row.isTrashed {
                        Button {
                            lab.restore(row.instanceID)
                        } label: {
                            Text(verbatim: "Restore")
                        }
                    } else {
                        Button {
                            lab.trash(row.instanceID)
                        } label: {
                            Text(verbatim: "Move to trash")
                        }
                    }
                }
                if row.isLabDocument {
                    HStack {
                        Stepper(value: $megabytes, in: 1...20) {
                            Text(verbatim: "\(megabytes) MB")
                        }
                        Button {
                            lab.writeLargeText(row.instanceID, megabytes: megabytes)
                        } label: {
                            Text(verbatim: "Write large text")
                        }
                        .disabled(row.state != "done" || lab.isBusy)
                    }
                    Button(role: .destructive) {
                        lab.deleteDirectly(row.instanceID)
                    } label: {
                        Text(verbatim: "Delete directly (no trash)")
                    }
                } else {
                    Text(verbatim: "Not a lab document: no direct writes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 8)
            .onAppear {
                title = row.title
                date = row.documentDate
            }
        }
    }

    // MARK: - Metadata

    private struct MetadataSection: View {
        let lab: SyncLab
        @State private var kind = MetadataKind.tag
        @State private var name = ""
        @State private var child: UUID?
        @State private var parent: UUID?

        private var labTags: [SyncLabDocuments.Metadata.Item] {
            lab.metadata.tags.filter { SyncLabActions.isLabName($0.name) }
        }

        var body: some View {
            Section {
                Picker(selection: $kind) {
                    Text(verbatim: "Tag").tag(MetadataKind.tag)
                    Text(verbatim: "Correspondent").tag(MetadataKind.correspondent)
                    Text(verbatim: "Type").tag(MetadataKind.documentType)
                } label: {
                    Text(verbatim: "Kind")
                }
                HStack {
                    TextField(text: $name) { Text(verbatim: "Name (gets SyncLab-)") }
                    Button {
                        lab.createMetadata(kind, name: name)
                    } label: {
                        Text(verbatim: "Create")
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker(selection: $child) {
                    Text(verbatim: "—").tag(UUID?.none)
                    ForEach(labTags) { tag in
                        Text(verbatim: SyncLabFormat.tagName(tag)).tag(UUID?.some(tag.instanceID))
                    }
                } label: {
                    Text(verbatim: "Move tag")
                }
                Picker(selection: $parent) {
                    Text(verbatim: "top level").tag(UUID?.none)
                    ForEach(labTags) { tag in
                        Text(verbatim: SyncLabFormat.tagName(tag)).tag(UUID?.some(tag.instanceID))
                    }
                } label: {
                    Text(verbatim: "under")
                }
                Button {
                    if let child { lab.moveTag(child, under: parent) }
                } label: {
                    Text(verbatim: "Move")
                }
                .disabled(child == nil)
                Text(verbatim: SyncLabFormat.metadataList(lab.metadata))
                    .font(.caption)
                    .textSelection(.enabled)
            } header: {
                Text(verbatim: "Metadata")
            }
        }
    }

    // MARK: - Search probe

    private struct SearchProbeSection: View {
        let lab: SyncLab
        @State private var query = ""

        var body: some View {
            Section {
                HStack {
                    TextField(text: $query) { Text(verbatim: "Word") }
                        .autocorrectionDisabled()
                    Button {
                        Task { await lab.probe(query) }
                    } label: {
                        Text(verbatim: "Search")
                    }
                }
                if let answer = lab.searchAnswer {
                    Text(verbatim: answer)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            } header: {
                Text(verbatim: "Search probe (the library's index)")
            }
        }
    }

    // MARK: - Export state

    private struct ExportSection: View {
        let lab: SyncLab
        @State private var dates = SyncLabExport.DateRounding.nearest

        var body: some View {
            Section {
                Picker(selection: $dates) {
                    Text(verbatim: "round to nearest ms").tag(SyncLabExport.DateRounding.nearest)
                    Text(verbatim: "truncate to ms").tag(SyncLabExport.DateRounding.towardZero)
                } label: {
                    Text(verbatim: "Dates")
                }
                Button {
                    Task { await lab.export(dates: dates) }
                } label: {
                    Text(verbatim: lab.isBusy ? "Working…" : "Export state")
                }
                .disabled(lab.isBusy)
                if let dump = lab.dump {
                    Text(verbatim: "dump \(dump.hash.prefix(16))")
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    ForEach(SyncLabExport.entityNames, id: \.self) { name in
                        Text(verbatim: "\(name) \(dump.entityHashes[name]?.prefix(12) ?? "")")
                            .font(.system(.caption, design: .monospaced))
                    }
                    HStack {
                        Button {
                            SyncLabFormat.copy(dump.text)
                        } label: {
                            Text(verbatim: "Copy dump")
                        }
                        ShareLink(item: dump.text) {
                            Text(verbatim: "Share dump")
                        }
                    }
                    DisclosureGroup {
                        ScrollView(.horizontal) {
                            Text(verbatim: dump.text)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } label: {
                        Text(verbatim: "Dump text")
                    }
                }
            } header: {
                Text(verbatim: "Export state")
            }
        }
    }

    // MARK: - Formatting

    @ViewBuilder
    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(verbatim: value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
    }

    enum SyncLabFormat {
        private static let formatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter
        }()

        static func time(_ date: Date) -> String {
            formatter.string(from: date)
        }

        static func age(_ date: Date?, now: Date = Date()) -> String {
            guard let date else { return "" }
            let seconds = Int(now.timeIntervalSince(date))
            if seconds < 120 { return "\(seconds) s" }
            if seconds < 7200 { return "\(seconds / 60) min" }
            return "\(seconds / 3600) h"
        }

        static func summary(_ row: SyncLabDocuments.Row, thisDevice: String) -> String {
            let claim = row.claim(thisDevice: thisDevice)
            let age = row.claimedAt == nil ? "" : " (\(age(row.claimedAt)))"
            return """
                \(row.state) · claim \(claim)\(age) · text \(row.textSource) · \(row.pageCount) p · \(row.fileSize) B\
                \(row.isLabDocument ? " · lab" : "")
                """
        }

        static func metadata(_ row: SyncLabDocuments.Row) -> String {
            """
            inbox \(row.isInbox) · date \(row.documentDate.formatted(date: .numeric, time: .shortened)) · \
            correspondent \(row.correspondent ?? "none") · type \(row.documentType ?? "none") · \
            tags \(row.tags.isEmpty ? "none" : row.tags.joined(separator: ", "))
            """
        }

        static func tagName(_ tag: SyncLabDocuments.Metadata.Item) -> String {
            tag.parent.map { "\($0) › \(tag.name)" } ?? tag.name
        }

        static func metadataList(_ metadata: SyncLabDocuments.Metadata) -> String {
            """
            tags: \(metadata.tags.map(tagName).joined(separator: ", "))
            correspondents: \(metadata.correspondents.map(\.name).joined(separator: ", "))
            types: \(metadata.types.map(\.name).joined(separator: ", "))
            """
        }

        static func copy(_ text: String) {
            #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            #else
                UIPasteboard.general.string = text
            #endif
        }
    }
#endif
