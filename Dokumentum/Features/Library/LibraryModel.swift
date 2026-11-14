import DokumentumCore
import DokumentumKit
import Foundation
import Observation
import PDFKit

#if os(iOS)
    import UIKit
#endif

/// What the detail column shows.
enum DetailState: Equatable {
    /// No document is selected, or the selected one is gone.
    case noSelection
    /// The PDF of the selected document is being read.
    case loading
    /// "Still downloading": the document has no file yet, or its file has no data yet.
    case stillDownloading
    /// "This PDF cannot be shown": the data is not a readable PDF.
    case unreadable
    case pdf(instanceID: UUID, data: Data)
}

/// The library's state for the views: the sidebar's rows and counts, the selected list, and the open
/// document. The views see only values from a `LibrarySource`, never model objects (plan of #3,
/// T1). Sidebar filters and counts run in memory (`LibrarySelection`, `LibraryCounts`).
@MainActor @Observable
final class LibraryModel {
    let source: any LibrarySource
    /// The app's one search index (#7, part 2), shared by every window; `nil` for fixture sources in unit tests.
    /// The search field queries it.
    let searcher: (any DocumentSearching)?
    /// The index's newest state: `observeSearchIndex()` follows its updates. `nil` until the first one.
    private(set) var searchIndexState: SearchIndexState?
    /// "Try again" for a failed document (#6, P2): the app's processing scheduler, or for an in-memory store a queue
    /// that no scheduler runs; `nil` for fixture sources in unit tests, which then show no button.
    let retrier: (any ProcessingRetrying)?
    /// The document whose "Try again" is being written, so the button is not pressed twice.
    private(set) var retrying: UUID?

    /// Counts the reads of the source: a row's thumbnail that has not arrived is looked for again at each one, so it
    /// shows once it arrives by sync (#6, part 4).
    private(set) var revision = 0

    /// The search field's text, filter chips and scope (#7, part 3). It stays when the sidebar's selection changes
    /// (P7); on the iPhone it ends when the stack goes back to the sidebar. A new text runs a query at once, without a
    /// debounce (T10); chips and scope filter the last result again without a query.
    var search = LibrarySearch() {
        didSet {
            if search.tokens.count > oldValue.tokens.count, !search.text.isEmpty {
                // A chip picked from the suggestions stands for the words typed for it (every word had to match its
                // name), so they go, as the iPhone's field drops them by itself. (No second `didSet`.)
                search.text = ""
            }
            guard search != oldValue else { return }
            if search.text != oldValue.text {
                runSearch()
            } else {
                applySelection()
            }
        }
    }
    /// Counts Edit › Find… (⌘F) on the Mac: each change puts the focus into the search field (P7).
    private(set) var searchFocusRequests = 0
    /// The index's answer to the newest query that came back; `nil` without a text.
    private(set) var searchResult: SearchResult?
    /// The newest query, for tests: they await its `value`.
    private(set) var searchTask: Task<Void, Never>?
    /// Counts queries: only the newest one's result is shown (T10).
    private var searchGeneration = 0

    private(set) var snapshot = LibrarySnapshot.empty
    private(set) var tree = TagTree([])
    private(set) var counts = LibraryCounts()

    /// The local day the deadlines' status and the Deadlines count are computed for (#12, part 2a): `AppDay`'s, read
    /// again at each read of the library and when the day changes (`observeDayChanges`).
    private(set) var today: DeadlineDay
    /// Where "today" comes from: `AppDay`, or a test's fixed day.
    private let readToday: @MainActor () -> DeadlineDay
    /// The Deadlines count's lead time in days (maintainer decision Q7 on #12): a deadline at most this many days
    /// ahead counts. In the app this device's reminder lead time (#12, part 3, `ReminderSettingsModel`), read at each
    /// count; `LibraryCounts.defaultDeadlineLeadDays` (3) without one (unit tests).
    private let deadlineLeadDays: @MainActor () -> Int
    /// Called after a user's edit on this device saved a deadline's day (a new deadline, by hand or from a suggestion):
    /// the app may then ask for permission to remind (#12, part 3, maintainer decision Q4). Never after a read of the
    /// library, so a sync never asks.
    private let deadlineSaved: @MainActor () -> Void
    /// The documents of `selection`, in list order.
    private(set) var documents: [LibraryDocument] = []
    private(set) var detail = DetailState.noSelection

    /// The sidebar's selection; Inbox at the start (PQ1). `nil` on the iPhone when the stack is back
    /// at the sidebar.
    var selection: LibrarySelection? = .inbox {
        didSet {
            guard selection != oldValue else { return }
            #if os(iOS)
                // `nil` on the iPhone, back at the sidebar: the list was left, and its search ends with it (P7).
                if selection == nil, search != LibrarySearch() {
                    search = LibrarySearch()
                }
            #endif
            applySelection()
        }
    }

    /// The open document's `instanceID`. The detail column loads it with `loadDetail(for:)`. When it clears (the
    /// document left the list, or the iPhone went back), the info panel closes: it has nothing to show.
    var selectedDocumentID: UUID? {
        didSet {
            if selectedDocumentID == nil { isInfoPresented = false }
            if selectedDocumentID != oldValue { titleSaveFailure = nil }
        }
    }

    /// The document whose last title edit could not be saved (the save failed and was rolled back): the info
    /// panel says so under the title field until the next edit or until another document opens (maintainer
    /// decision on #74). A title refused because the document was trashed or deleted on the other device sets
    /// nothing: the document leaves the list and the panel closes with it.
    private(set) var titleSaveFailure: UUID?

    /// The tags whose nested tags are shown.
    var expandedTags: Set<UUID> = []

    /// Whether the open document's info panel is shown (Document › Show Info, ⌘I).
    var isInfoPresented = false

    /// Whether the source has been read at least once.
    private(set) var isLoaded = false
    /// Counts `loadDetail` calls: only the newest one's result is shown.
    private var detailGeneration = 0

    /// - Parameters:
    ///   - loadNow: reads the source at once; a view passes `false` and calls `loadIfNeeded()` when it appears,
    ///     because SwiftUI may create it again on any re-evaluation and discards that model.
    ///   - today: the local day (`AppDay`); tests fix one.
    ///   - deadlineLeadDays: the Deadlines count's lead time (#12, Q7): this device's reminder lead time in the app.
    ///   - deadlineSaved: a user's edit saved a deadline's day (#12, part 3).
    init(
        source: any LibrarySource, searcher: (any DocumentSearching)? = nil,
        retrier: (any ProcessingRetrying)? = nil, loadNow: Bool = true,
        today: @escaping @MainActor () -> DeadlineDay = { AppDay.today() },
        deadlineLeadDays: @escaping @MainActor () -> Int = { LibraryCounts.defaultDeadlineLeadDays },
        deadlineSaved: @escaping @MainActor () -> Void = {}
    ) {
        self.source = source
        self.searcher = searcher
        self.retrier = retrier
        readToday = today
        self.today = today()
        self.deadlineLeadDays = deadlineLeadDays
        self.deadlineSaved = deadlineSaved
        if loadNow { reload() }
    }

    /// Reads the source unless it was read before.
    func loadIfNeeded() {
        if !isLoaded { reload() }
    }

    /// Reads the source again and refilters. A selected document that left the list is deselected.
    func reload() {
        isLoaded = true
        revision += 1
        snapshot = source.snapshot()
        tree = TagTree(snapshot.tags)
        today = readToday()
        recount()
        dropGoneTokens()
        applySelection()
    }

    private func recount() {
        counts = LibraryCounts(snapshot.documents, tree: tree, today: today, deadlineLeadDays: deadlineLeadDays())
    }

    /// Reads "today" again at each change of the calendar day (`NSCalendarDayChanged`: midnight, a time zone or clock
    /// change that moves the day), so the deadlines' status and the Deadlines count follow it while the window stays
    /// open, until the calling task is cancelled. The root view runs it in `.task`.
    func observeDayChanges(center: NotificationCenter = .default) async {
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let tokens = Self.dayChangeNotifications.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield() }
        }
        defer { for token in tokens { center.removeObserver(token) } }
        for await _ in changes {
            dayMayHaveChanged()
        }
    }

    /// The notifications after which "today" is read again. On the iPhone also the significant time change, which iOS
    /// queues for a suspended app (review N4 of #219: whether a suspended app gets `NSCalendarDayChanged` after midnight
    /// is not documented). The root view also reads it again when the scene becomes active.
    nonisolated static var dayChangeNotifications: [Notification.Name] {
        #if os(iOS)
            [.NSCalendarDayChanged, UIApplication.significantTimeChangeNotification]
        #else
            [.NSCalendarDayChanged]
        #endif
    }

    /// Reads "today" again; a new day recounts. The list itself does not depend on the day: it lists every open
    /// deadline.
    func dayMayHaveChanged() {
        let day = readToday()
        guard day != today else { return }
        today = day
        recount()
    }

    /// This device's reminder lead time changed (#12, part 3): the Deadlines count follows it (Q7).
    func leadTimeMayHaveChanged() {
        recount()
    }

    /// A tapped reminder (#12, part 3, `ReminderRouter`): reads the library, ends a search that could hide the document,
    /// and selects Deadlines and the document; a document whose deadline is done meanwhile opens in All Documents, one in
    /// the trash in the Trash. A document that is gone opens nothing.
    func openFromReminder(_ instanceID: UUID) {
        reload()
        guard let document = snapshot.documents.first(where: { $0.instanceID == instanceID }) else { return }
        if search != LibrarySearch() { search = LibrarySearch() }
        selection = document.isTrashed ? .trash : document.openDeadline != nil ? .upcoming : .all
        selectedDocumentID = instanceID
    }

    /// The status of the open document's or a row's deadline on `today`; `nil` without a deadline.
    func deadlineStatus(of document: LibraryDocument) -> DeadlineStatus? {
        document.deadline.map { DeadlineStatus($0, today: today) }
    }

    /// The documents of the selection, narrowed by the search when it is active (`LibrarySearch.apply`).
    private func applySelection() {
        documents =
            selection.map {
                search.apply(searchResult, to: snapshot.documents, selection: $0, tree: tree)
            } ?? []
        if let selectedDocumentID, !documents.contains(where: { $0.instanceID == selectedDocumentID }) {
            self.selectedDocumentID = nil
        }
    }

    /// Re-reads the source on every `changes` event, and the open document with it, until the
    /// calling task is cancelled. The root view runs it in `.task`.
    func observeChanges() async {
        loadIfNeeded()
        for await _ in source.changes {
            reload()
            if let selectedDocumentID { await loadDetail(for: selectedDocumentID) }
        }
    }

    /// Follows the search index's updates, one subscription per window (Revision 1, B3), until the calling task is
    /// cancelled. The root view runs it in `.task`.
    func observeSearchIndex() async {
        guard let searcher else { return }
        let updates = searcher.updates()
        searchIndexState = await searcher.state
        for await state in updates {
            searchIndexState = state
            // The index changed (a text was processed, a batch of the build is in): the active query again.
            if search.hasText { runSearch() }
        }
    }

    // MARK: Search

    /// Whether the list shows search results.
    var isSearchActive: Bool { search.isActive && selection != nil }

    /// "Indexing texts… 12 of 40" while the index's texts are being read and a search is active (P5).
    var indexingProgress: (indexed: Int, total: Int)? {
        guard isSearchActive, case .building(let indexed, let total) = searchIndexState, total > 0 else { return nil }
        return (indexed, total)
    }

    /// The chips offered for the text typed (P3): tags, correspondents, types and the Inbox (not in the Trash).
    var searchSuggestions: [SearchToken] {
        guard let selection else { return [] }
        return search.suggestions(
            in: snapshot, tree: tree, selection: selection, inboxName: String(localized: "Inbox"))
    }

    /// The chip's name: the tag's display path, the correspondent's or type's name; empty for the Inbox.
    func name(of token: SearchToken) -> String {
        switch token {
        case .tag(let id): tree.displayPath(of: id)
        case .correspondent(let id): snapshot.correspondents.first { $0.instanceID == id }?.name ?? ""
        case .documentType(let id): snapshot.documentTypes.first { $0.instanceID == id }?.name ?? ""
        case .inbox: ""
        }
    }

    /// Edit › Find… (⌘F): the list's search field takes the focus.
    func focusSearch() {
        searchFocusRequests += 1
    }

    /// Asks the index for the current text. Each query has a generation; a result that comes back after a newer query
    /// started is dropped (T10), as `loadDetail` does. Until the answer comes, the list keeps the previous result.
    private func runSearch() {
        searchGeneration += 1
        let generation = searchGeneration
        guard search.hasText, let searcher else {
            searchResult = nil
            searchTask = nil
            applySelection()
            return
        }
        let text = search.text
        searchTask = Task { [weak self] in
            let result = await searcher.search(text)
            guard let self, generation == self.searchGeneration else { return }
            self.searchResult = result
            self.applySelection()
        }
    }

    /// A chip whose tag, correspondent or type is gone (deleted, merged away) is dropped: it would match nothing and
    /// have no name.
    private func dropGoneTokens() {
        let kept = search.tokens.filter { token in
            switch token {
            case .tag(let id): tree.tags[id] != nil
            case .correspondent(let id): snapshot.correspondents.contains { $0.instanceID == id }
            case .documentType(let id): snapshot.documentTypes.contains { $0.instanceID == id }
            case .inbox: true
            }
        }
        if kept != search.tokens { search.tokens = kept }
    }

    /// Loads the detail of `instanceID` (`nil`: nothing selected). The PDF is read and checked off
    /// the main actor. A result that arrives after the selection moved on, or after a newer load of the
    /// same document started, is dropped: an older read must not replace a newer one.
    func loadDetail(for instanceID: UUID?) async {
        detailGeneration += 1
        let generation = detailGeneration
        guard let instanceID else {
            detail = .noSelection
            return
        }
        if case .pdf(let shown, _) = detail, shown == instanceID {
            // Keep showing the PDF while it is read again after a change.
        } else {
            detail = .loading
        }
        let state = await source.loadPDF(instanceID: instanceID)
        let next: DetailState
        switch state {
        case .noDocument: next = .noSelection
        case .noFile, .noData: next = .stillDownloading
        case .data(let data):
            next = await Self.isReadablePDF(data) ? .pdf(instanceID: instanceID, data: data) : .unreadable
        }
        guard !Task.isCancelled, generation == detailGeneration, selectedDocumentID == instanceID else { return }
        detail = next
    }

    /// Whether PDFKit can open `data`; off the main actor, since a large PDF takes a while.
    @concurrent
    nonisolated static func isReadablePDF(_ data: Data) async -> Bool {
        guard let document = PDFDocument(data: data) else { return false }
        return document.pageCount > 0
    }

    // MARK: Editing

    /// The open document's row, while it is in the list.
    var selectedDocument: LibraryDocument? {
        selectedDocumentID.flatMap { id in documents.first { $0.instanceID == id } }
    }

    /// Whether the source takes edits (the store does; the fixtures of unit tests do not).
    var canEdit: Bool { source.editor != nil }

    /// Applies one edit to the document with `instanceID` (plan of #3, part 3) and reads the library again at
    /// once, so the info panel shows the new value without waiting for the change event. An edit that was not
    /// saved (the document was trashed or deleted meanwhile, or the save failed and was rolled back) reads it
    /// again too, so the panel shows what the store holds now. `nil`: the source takes no edits, or the save
    /// failed (logged).
    @discardableResult
    func edit(_ change: DocumentEditor.Change, of instanceID: UUID) -> DocumentEditor.Outcome? {
        guard let editor = source.editor else { return nil }
        // The next edit ends the "could not be saved" line; `commitTitle` sets it again if this one fails too.
        titleSaveFailure = nil
        do {
            let outcome = try editor.apply(change, to: instanceID)
            if outcome != .unchanged { reload() }
            if outcome == .saved, Self.savesADeadline(change) { deadlineSaved() }
            return outcome
        } catch {
            Log.store.error("Could not save an edit: \(Log.code(of: error), privacy: .public)")
            reload()
            return nil
        }
    }

    /// Whether `change` saves a deadline's day: a new deadline, by hand ("Add Deadline", the date picker) or from the
    /// text's suggestion. A label, done or a removal is no new deadline.
    static func savesADeadline(_ change: DocumentEditor.Change) -> Bool {
        switch change {
        case .deadline, .deadlineDay: true
        default: false
        }
    }

    /// Saves the info panel's title draft to its own document if the user changed it (`TitleDraft`). When the
    /// edit is not saved (the document was trashed or deleted meanwhile, or the save failed and was rolled back),
    /// the draft starts again from the stored title: the field never keeps a title that is not stored and that
    /// would not be saved again (reviews of #57).
    func commitTitle(_ draft: inout TitleDraft) {
        guard let commit = draft.commit() else { return }
        let outcome = edit(.title(commit.title), of: commit.document)
        if outcome == nil, canEdit { titleSaveFailure = commit.document }
        switch outcome {
        case .saved, .unchanged:
            return
        case .noDocument, .trashed, .noMetadata, .noDeadline, nil:
            // A document that is gone has no title to show: it left the list, and the panel closed with it.
            guard let stored = snapshot.documents.first(where: { $0.instanceID == commit.document }) else { return }
            draft.show(commit.document, title: stored.title)
        }
    }

    /// The correspondent, type or tag named `name` (an existing one with the same merge key, or a new one),
    /// set on the document with `instanceID`; a tag is added. An empty name does nothing.
    @discardableResult
    func assignMetadata(_ kind: MetadataKind, named name: String, to instanceID: UUID) -> DocumentEditor.Outcome? {
        guard let editor = source.editor else { return nil }
        let record: UUID
        do {
            record = try editor.createMetadata(kind: kind, name: name)
        } catch DocumentEditor.MetadataError.emptyName {
            return nil
        } catch {
            Log.store.error("Could not save new metadata: \(Log.code(of: error), privacy: .public)")
            return nil
        }
        let change: DocumentEditor.Change =
            switch kind {
            case .correspondent: .correspondent(record)
            case .documentType: .documentType(record)
            case .tag: .tag(record, true)
            }
        let outcome = edit(change, of: instanceID)
        // A reused record the document already had saves nothing, and `edit` reads nothing then; the new record
        // itself was saved.
        if outcome == .unchanged { reload() }
        return outcome
    }

    /// Saves the info panel's deadline label draft to its own document if the user changed it (#12, part 2a). A label-only
    /// edit (`.deadlineLabel`, review N1 of #219): it carries no day, so a snapshot older than the store can never send
    /// an old day back, set `deadlineSetAt` or clear `deadlineDoneAt`. A draft that was not saved (the deadline was
    /// removed, the document trashed or gone, the save failed) starts again from the stored label.
    func commitDeadlineLabel(_ draft: inout TitleDraft) {
        guard let commit = draft.commit() else { return }
        switch edit(.deadlineLabel(commit.title), of: commit.document) {
        case .saved, .unchanged:
            return
        case .noDocument, .trashed, .noMetadata, .noDeadline, nil:
            guard let stored = snapshot.documents.first(where: { $0.instanceID == commit.document }) else { return }
            draft.show(commit.document, title: stored.deadline?.label ?? "")
        }
    }

    // MARK: Deadline suggestion (#12, part 2b)

    /// The suggestion the open document's text gives, with the document it was read for
    /// (`LibrarySource.loadDeadlineSuggestion`): also while the document has a deadline, so "Remove Deadline" can
    /// compare with it (review N9). `nil` until the first read.
    private(set) var loadedSuggestion: LoadedDeadlineSuggestion?
    /// Counts `loadDeadlineSuggestion` calls: only the newest one's result is kept.
    private var suggestionGeneration = 0

    /// The text's suggestion for one document; `candidate` is `nil` when the text gives none.
    struct LoadedDeadlineSuggestion: Equatable {
        let instanceID: UUID
        let candidate: DueDateCandidate?
    }

    /// What makes the detail read the suggestion again (`DocumentDetailView`): another document, another day, or any
    /// read of the library (`revision`: an edit such as a dismissal, a sync, a text the queue wrote).
    struct DeadlineSuggestionKey: Hashable {
        let instanceID: UUID?
        let revision: Int
        let today: DeadlineDay
    }

    var deadlineSuggestionKey: DeadlineSuggestionKey {
        DeadlineSuggestionKey(instanceID: selectedDocumentID, revision: revision, today: today)
    }

    /// Reads the open document's suggestion, off the main actor. A result that arrives after the selection moved on,
    /// or after a newer read started, is dropped, as in `loadDetail`.
    func loadDeadlineSuggestion() async {
        suggestionGeneration += 1
        let generation = suggestionGeneration
        guard let instanceID = selectedDocumentID else {
            loadedSuggestion = nil
            return
        }
        let candidate = await source.loadDeadlineSuggestion(instanceID: instanceID, today: today)
        guard !Task.isCancelled, generation == suggestionGeneration, selectedDocumentID == instanceID else { return }
        loadedSuggestion = LoadedDeadlineSuggestion(instanceID: instanceID, candidate: candidate)
    }

    /// The suggestion the detail's bar offers (maintainer decision Q2): the open document's, while it has no deadline,
    /// is processed and not in the trash, and its day is today or later and after the dismissed day
    /// (`DueDateDetector.offers`, checked against the library's current values, so a dismissal or a deadline hides it at
    /// once).
    var deadlineSuggestion: DueDateCandidate? {
        guard let document = selectedDocument, let loaded = loadedSuggestion, loaded.instanceID == document.instanceID,
            let candidate = loaded.candidate, DueDateDetector.offers(candidate, for: document, today: today)
        else { return nil }
        return candidate
    }

    /// "Add Deadline" on the suggestion: its day as the deadline, with the kind's name as the label ("Payment").
    @discardableResult
    func addSuggestedDeadline(_ candidate: DueDateCandidate, to instanceID: UUID) -> DocumentEditor.Outcome? {
        edit(.deadline(candidate.day, label: DeadlineText.kindName(candidate.kind)), of: instanceID)
    }

    /// "Dismiss" on the suggestion: suggestions are dismissed up to its day (synced; the `max` rule), and the text is read
    /// again, so a later candidate is offered next (review B3).
    @discardableResult
    func dismissDeadlineSuggestion(_ candidate: DueDateCandidate, of instanceID: UUID) async -> DocumentEditor.Outcome?
    {
        let outcome = edit(.dismissDeadlineSuggestion(candidate.day), of: instanceID)
        await loadDeadlineSuggestion()
        return outcome
    }

    /// The info panel's "Remove Deadline" (review N9): when the removed day is the one the text suggests, the same save
    /// dismisses it, so removing a deadline right after adding the suggestion does not offer that day again. Another
    /// day is removed without a dismissal, and the suggestion comes back.
    @discardableResult
    func removeDeadline(of instanceID: UUID) -> DocumentEditor.Outcome? {
        let day = snapshot.documents.first { $0.instanceID == instanceID }?.deadline?.day
        let suggested = loadedSuggestion.flatMap { $0.instanceID == instanceID ? $0.candidate?.day : nil }
        return edit(.clearDeadline(dismissing: day != nil && day == suggested ? day : nil), of: instanceID)
    }

    /// "Add Deadline" in the info panel: the suggestion when one is offered (its day and kind), else 7 days after today
    /// with no label.
    @discardableResult
    func addDeadline(to instanceID: UUID) -> DocumentEditor.Outcome? {
        if selectedDocumentID == instanceID, let suggestion = deadlineSuggestion {
            return addSuggestedDeadline(suggestion, to: instanceID)
        }
        return edit(.deadline(today.adding(days: 7) ?? today, label: ""), of: instanceID)
    }

    /// The user typed in the title field again: the "could not be saved" line goes away.
    func titleEditStarted() {
        titleSaveFailure = nil
    }

    /// Every live tag with its display path, sorted by it: the info panel's tag list.
    var tagChoices: [(instanceID: UUID, path: String)] {
        tree.tags.keys.map { ($0, tree.displayPath(of: $0)) }
            .sorted { lhs, rhs in
                switch lhs.1.localizedStandardCompare(rhs.1) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: lhs.0.uuidString < rhs.0.uuidString
                }
            }
    }

    // MARK: Matching rules

    /// The rule sheet's draft while the sheet is shown (#10, part 2).
    var matchingRuleDraft: MatchingRuleDraft?

    /// Whether the sidebar offers "Edit Matching…": the source saves rules.
    var canEditMatching: Bool { source.ruleEditor != nil }

    /// Opens the rule sheet for the tag, correspondent or type with `instanceID`.
    func editMatching(_ kind: MetadataKind, _ instanceID: UUID, name: String) {
        guard let editor = source.ruleEditor else { return }
        matchingRuleDraft = MatchingRuleDraft(
            target: MatchingRuleTarget(kind: kind, instanceID: instanceID, name: name), editor: editor)
    }

    // MARK: Processing

    /// Whether "Try again" can be offered: the library has a retrier.
    var canRetryProcessing: Bool { retrier != nil }

    /// "Try again" for the failed document with `instanceID` (#6, P2): the queue sets it back to `pending` with this
    /// device's claim and clears this device's failure counter (`ProcessingQueue.retry(_:)`); the library is read
    /// again at once, so the status line shows the new state without waiting for the change event. Nothing while a
    /// retry is being written.
    @discardableResult
    func retryProcessing(of instanceID: UUID) async -> ProcessingRetryOutcome? {
        guard let retrier, retrying == nil else { return nil }
        retrying = instanceID
        defer { retrying = nil }
        let outcome = await retrier.retry(instanceID)
        reload()
        return outcome
    }

    // MARK: Sidebar

    /// The display path of each of the document's tags, sorted, for rows and VoiceOver. A tag the
    /// sidebar does not list (a tombstone whose chain ends nowhere) shows by its name.
    func tagPaths(of document: LibraryDocument) -> [String] {
        document.tagIDs.map { tree.tags[$0] == nil ? snapshot.unlistedTagNames[$0] ?? "" : tree.displayPath(of: $0) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func toggleExpanded(_ tag: UUID) {
        if expandedTags.contains(tag) { expandedTags.remove(tag) } else { expandedTags.insert(tag) }
    }
}
