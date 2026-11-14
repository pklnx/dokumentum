import DokumentumCore
import DokumentumKit
import DokumentumTestSupport
import Foundation
import SwiftData
import Testing

@testable import Dokumentum

/// The app's side of the reminders (#12, part 3; plan §7, §8; D7): the environment of a launch (center, suite and `S`
/// chosen together, the in-memory state emptied at every in-memory launch), the permission flow that asks only on a
/// user action on this device, the settings in the chosen suite, the Deadlines count from the lead time, the router of
/// tapped reminders, and the texts in English and German. Only in-memory centers: nothing here reaches the system's.
@MainActor
struct ReminderAppTests {
    private nonisolated static let today = DeadlineDay(year: 2026, month: 11, day: 14)!
    private static let waterBill = FixtureCatalog.documentID(3)
    private static let carInsurance = FixtureCatalog.documentID(7)
    private static let electricityBill = FixtureCatalog.documentID(1)

    private static func suite() -> String { "DokumentumTests-Reminders-\(UUID().uuidString)" }

    // MARK: The environment (N10, N2, D7)

    /// The hosted tests run inside the app, which launched on the in-memory center, suite and `S`, and never asked.
    @Test func theTestHostLaunchedOnTheInMemoryCenterAndNeverAsked() async throws {
        let launched = try #require(ReminderEnvironment.launched)
        #expect(launched.choice == .inMemory)
        let center = try #require(launched.center as? InMemoryNotificationCenter)
        #expect(launched.scheduledSet is InMemoryScheduledSet)
        #expect(launched.settingsSuite == ReminderEnvironment.inMemorySettingsSuite)
        #expect(await center.authorizationRequests == 0)
    }

    /// N2: an in-memory launch empties the suite and starts with an empty `S`, also after a launch that wrote them,
    /// for every UI-test argument, `-UITestLocalStore` included.
    @Test(arguments: ["-UITestLocalStore", "-UITestSeed", "-UITestEmptyStore", "-UITestImportLetter", "-UITestToday"])
    func anInMemoryLaunchStartsEmpty(argument: String) throws {
        let suite = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let arguments = [argument, "x"]
        let choice = NotificationCenterChoice.decide(isRunningTests: false, arguments: arguments, storeIsOnDisk: true)
        #expect(choice == .inMemory)

        let first = ReminderEnvironment.make(choice, arguments: arguments, inMemorySuite: suite)
        ReminderSettingsModel(suite: first.settingsSuite).setLeadDays(14)
        try first.scheduledSet.save(["deadline.00000000-0000-4000-8000-00000000000A.2026-11-27"])
        #expect(ReminderSettingsModel.read(suite: suite).leadDays == 14)

        let next = ReminderEnvironment.make(choice, arguments: arguments, inMemorySuite: suite)
        #expect(next.settingsSuite == suite)
        #expect(ReminderSettingsModel.read(suite: suite) == ReminderSettings())
        #expect(UserDefaults(suiteName: suite)?.object(forKey: ReminderSettingsModel.leadDaysKey) == nil)
        #expect(try next.scheduledSet.load().isEmpty)
        #expect(next.center is InMemoryNotificationCenter)
    }

    /// Without `-UITestNotifications` the in-memory center answers `notDetermined` and a request `denied`; with it, the
    /// status given.
    @Test func theInMemoryCenterFollowsUITestNotifications() async throws {
        let suite = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let plain = try #require(
            ReminderEnvironment.make(.inMemory, arguments: ["-UITestSeed", "YES"], inMemorySuite: suite).center
                as? InMemoryNotificationCenter)
        #expect(await plain.authorizationStatus() == .notDetermined)
        #expect(await plain.requestAuthorization() == .denied)
        let allowed = try #require(
            ReminderEnvironment.make(
                .inMemory, arguments: ["-UITestSeed", "YES", "-UITestNotifications", "authorized"], inMemorySuite: suite
            ).center as? InMemoryNotificationCenter)
        #expect(await allowed.authorizationStatus() == .authorized)
        #expect(UITestNotifications.status(arguments: ["-UITestNotifications", "denied"]) == (.denied, .denied))
        #expect(
            UITestNotifications.status(arguments: ["-UITestNotifications", "nonsense"]) == (.notDetermined, .denied))
        #expect(
            UITestNotifications.status(arguments: ["-UITestNotifications", "notDetermined"]) == (
                .notDetermined, .authorized
            ))
    }

    // MARK: The permission (Q4)

    private func authorization(
        _ center: InMemoryNotificationCenter, isOn: Bool = true, answered: @escaping @MainActor () -> Void = {}
    ) -> ReminderAuthorization {
        ReminderAuthorization(center: center, isOn: { isOn }, answered: answered)
    }

    /// Not determined: a user's saved deadline asks once and the answer reconciles; afterwards (denied) nothing asks.
    @Test func aSavedDeadlineAsksOnceWhileNotDetermined() async {
        let center = InMemoryNotificationCenter()
        var answers = 0
        let authorization = authorization(center) { answers += 1 }
        #expect(await authorization.userAction(.savedDeadline))
        #expect(await center.authorizationRequests == 1)
        #expect(authorization.status == .denied)
        #expect(answers == 1)
        #expect(!(await authorization.userAction(.savedDeadline)))
        #expect(!(await authorization.userAction(.tappedAllow)))
        #expect(!(await authorization.userAction(.turnedOn)))
        #expect(await center.authorizationRequests == 1)
    }

    /// With reminders off, a saved deadline does not ask; turning them on does, and so does "Allow Notifications".
    @Test(arguments: [ReminderAuthorization.Action.turnedOn, .tappedAllow])
    func turningOnOrAllowAsks(action: ReminderAuthorization.Action) async {
        let center = InMemoryNotificationCenter(requestAnswer: .authorized)
        let authorization = authorization(center, isOn: false)
        #expect(!(await authorization.userAction(.savedDeadline)))
        #expect(await center.authorizationRequests == 0)
        #expect(await authorization.userAction(action))
        #expect(await center.authorizationRequests == 1)
        #expect(authorization.status == .authorized)
    }

    /// Denied: nothing asks, and the settings offer the system's settings instead.
    @Test func deniedNeverAsks() async {
        let center = InMemoryNotificationCenter(status: .denied)
        let authorization = authorization(center)
        for action in [ReminderAuthorization.Action.savedDeadline, .turnedOn, .tappedAllow] {
            #expect(!(await authorization.userAction(action)))
        }
        #expect(await center.authorizationRequests == 0)
        #expect(authorization.status == .denied)
        #expect(AccessibilityID.settingsRemindersStatus(.denied) == "settings.reminders.status.denied")
        #expect(ReminderSettingsSection.systemNotificationSettings != nil)
    }

    /// A user's save of a deadline in the library asks; a read of the library (a sync) and the scheduler's reconciles
    /// never do. The library and the reminders on one in-memory store, as in the app.
    @Test func aUserSaveAsksAndASyncNever() async throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: Self.today)
        let suite = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let environment = ReminderEnvironment.make(.inMemory, arguments: [], inMemorySuite: suite)
        let center = try #require(environment.center as? InMemoryNotificationCenter)
        let reminders = Reminders(environment: environment, container: container, storeChanges: nil)
        let finished = TestSignal()
        reminders.scheduler.didFinishReconcile = { _ in finished.fire() }
        reminders.start()
        defer { reminders.scheduler.stop() }
        await finished.wait(for: 1)
        let model = LibraryModel(
            source: StoreLibrarySource(container: container), today: { Self.today },
            deadlineLeadDays: { reminders.settings.settings.leadDays }, deadlineSaved: { reminders.deadlineSaved() })

        // A sync: the library reads again, and the store's change reconciles.
        model.reload()
        reminders.scheduler.requestReconcile()
        await finished.wait(for: 2)
        #expect(await center.authorizationRequests == 0)

        // A label edit is no new deadline.
        #expect(model.edit(.deadlineLabel("Zahlen"), of: Self.waterBill) == .saved)
        #expect(model.edit(.deadline(Self.today.adding(days: 20)!, label: "Pay"), of: Self.electricityBill) == .saved)
        // The request's answer (`denied` without `-UITestNotifications`) is the signal that it was asked.
        try await TestSupport.waitUntil { reminders.authorization.status == .denied }
        #expect(await center.authorizationRequests == 1)
        #expect(LibraryModel.savesADeadline(.deadlineDay(Self.today)))
        #expect(!LibraryModel.savesADeadline(.deadlineLabel("x")))
        #expect(!LibraryModel.savesADeadline(.deadlineDone(false)))
        #expect(!LibraryModel.savesADeadline(.clearDeadline(dismissing: nil)))
    }

    // MARK: Settings (Q3) and the count (Q7)

    /// The settings live in the chosen suite, default to on, 3 days and 09:00, and report each change.
    @Test func theSettingsUseTheChosenSuite() {
        let suite = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var changes: [ReminderSettingsModel.Change] = []
        let model = ReminderSettingsModel(suite: suite) { changes.append($0) }
        #expect(model.settings == ReminderSettings())
        model.setOn(false)
        model.setOn(true)
        model.setLeadDays(7)
        model.setLeadDays(5)
        model.setMinuteOfDay(18 * 60 + 30)
        #expect(changes == [.turnedOff, .turnedOn, .leadDays, .time])
        #expect(
            ReminderSettingsModel.read(suite: suite) == ReminderSettings(isOn: true, leadDays: 7, minuteOfDay: 1110))
        let defaults = UserDefaults(suiteName: suite)
        #expect(defaults?.integer(forKey: ReminderSettingsModel.leadDaysKey) == 7)
        #expect(ReminderSettingsModel(suite: suite).settings.minuteOfDay == 1110, "read again at the next launch")
    }

    /// The Deadlines count follows this device's lead time (Q7): 3 days counts 2, 14 days 3, on the day 1.
    @Test func theCountFollowsTheLeadTime() {
        let suite = Self.suite()
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = ReminderSettingsModel(suite: suite)
        let model = LibraryModel(
            source: FixtureLibrarySource(today: Self.today), today: { Self.today },
            deadlineLeadDays: { settings.settings.leadDays })
        #expect(model.counts.count(for: .upcoming) == 2)
        settings.setLeadDays(14)
        model.leadTimeMayHaveChanged()
        #expect(model.counts.count(for: .upcoming) == 3)
        settings.setLeadDays(0)
        model.leadTimeMayHaveChanged()
        #expect(model.counts.count(for: .upcoming) == 1)
    }

    // MARK: The router (plan §8)

    /// A tapped reminder goes to the window that was active last; with none open, a window opens and takes it.
    @Test func theRouterGivesATapToTheLastActiveWindow() {
        let router = ReminderRouter()
        var opened = 0
        router.openWindow = { opened += 1 }
        let first = UUID()
        let second = UUID()
        router.register(first)
        router.register(second)
        router.windowBecameActive(first)
        router.open(Self.waterBill)
        #expect(router.take(for: second) == nil)
        #expect(router.take(for: first) == Self.waterBill)
        #expect(router.take(for: first) == nil, "taken once")
        #expect(opened == 0)

        router.unregister(first)
        router.unregister(second)
        router.open(Self.carInsurance)
        #expect(opened == 1)
        let new = UUID()
        router.register(new)
        #expect(router.take(for: new) == Self.carInsurance)
    }

    /// The window selects Deadlines and the document, ending a search; a done one opens in All Documents, a gone one
    /// nowhere.
    @Test func aTapSelectsDeadlinesAndTheDocument() {
        let model = LibraryModel(source: FixtureLibrarySource(today: Self.today), today: { Self.today })
        model.selection = .inbox
        model.search.text = "nothing matches this"
        model.openFromReminder(Self.waterBill)
        #expect(model.selection == .upcoming)
        #expect(model.selectedDocumentID == Self.waterBill)
        #expect(model.search == LibrarySearch())

        model.openFromReminder(Self.carInsurance)
        #expect(model.selection == .all, "its deadline is done")
        #expect(model.selectedDocumentID == Self.carInsurance)

        model.openFromReminder(UUID())
        #expect(model.selectedDocumentID == Self.carInsurance, "a gone document opens nothing")
    }

    /// A tapped reminder of a document in the trash opens it in the Trash (review B N3 of #222).
    @Test func aTapOnATrashedDocumentOpensTheTrash() throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: Self.today)
        let document = try #require(
            try container.mainContext.fetch(FetchDescriptor<Document>()).first { $0.instanceID == Self.waterBill })
        document.deletedAt = Date(timeIntervalSince1970: 1_793_000_000)
        try container.mainContext.save()
        let model = LibraryModel(source: StoreLibrarySource(container: container), today: { Self.today })
        model.selection = .inbox
        model.openFromReminder(Self.waterBill)
        #expect(model.selection == .trash)
        #expect(model.selectedDocumentID == Self.waterBill)
    }

    /// The gate in `LibraryModel.edit` (review B N1 of #222): only a saved deadline day calls `deadlineSaved`; a label,
    /// done, a removal and an edit that changes nothing never do. Counted synchronously, right after each edit.
    @Test func onlyASavedDeadlineDayCallsDeadlineSaved() throws {
        let container = try makeInMemoryContainer()
        FixtureSeeder.seedForUITests(container.mainContext, today: Self.today)
        var saved = 0
        let model = LibraryModel(
            source: StoreLibrarySource(container: container), today: { Self.today }, deadlineSaved: { saved += 1 })
        let accountStatement = FixtureCatalog.documentID(4)

        #expect(model.edit(.deadlineLabel("Zahlen"), of: Self.waterBill) == .saved)
        #expect(saved == 0, "a label")
        #expect(model.edit(.deadlineDone(true), of: Self.waterBill) == .saved)
        #expect(model.edit(.deadlineDone(false), of: Self.waterBill) == .saved)
        #expect(saved == 0, "done and undone")
        #expect(model.edit(.clearDeadline(dismissing: nil), of: accountStatement) == .saved)
        #expect(saved == 0, "a removal")
        model.reload()
        #expect(saved == 0, "a read of the library")

        let day = Self.today.adding(days: 20)!
        #expect(model.edit(.deadline(day, label: "Pay"), of: Self.electricityBill) == .saved)
        #expect(saved == 1, "a new deadline")
        #expect(model.edit(.deadline(day, label: "Pay"), of: Self.electricityBill) == .unchanged)
        #expect(saved == 1, "the same value saves nothing")
        #expect(model.edit(.deadlineDay(day.adding(days: 1)!), of: Self.electricityBill) == .saved)
        #expect(saved == 2, "a new day from the picker")
    }

    // MARK: Texts (Q5, N6)

    private static let english = Locale(identifier: "en_GB")
    private static let german = Locale(identifier: "de_DE")

    private func content(daysAhead: Int, label: String = "Pay", title: String = "Water bill") -> ReminderContent {
        let day = DeadlineDay(year: 2026, month: 11, day: 27)!
        return ReminderContent(title: title, label: label, day: day, momentDay: day.adding(days: -daysAhead)!)
    }

    @Test func theTextsInEnglish() {
        #expect(ReminderTexts.body(content(daysAhead: 0), locale: Self.english) == "Due today · Pay")
        #expect(ReminderTexts.body(content(daysAhead: 1), locale: Self.english) == "Due tomorrow · Pay")
        #expect(ReminderTexts.body(content(daysAhead: 3), locale: Self.english) == "Due 27 Nov 2026 · Pay")
        #expect(ReminderTexts.body(content(daysAhead: 3, label: "  "), locale: Self.english) == "Due 27 Nov 2026")
        #expect(ReminderTexts.title(content(daysAhead: 3), locale: Self.english) == "Water bill")
        #expect(ReminderTexts.title(content(daysAhead: 3, title: " "), locale: Self.english) == "Untitled document")
    }

    @Test func theTextsInGerman() {
        #expect(
            ReminderTexts.body(content(daysAhead: 0, label: "Zahlen"), locale: Self.german) == "Heute fällig · Zahlen")
        #expect(
            ReminderTexts.body(content(daysAhead: 1, label: "Zahlen"), locale: Self.german) == "Morgen fällig · Zahlen")
        #expect(
            ReminderTexts.body(content(daysAhead: 3, label: "Zahlen"), locale: Self.german)
                == "Fällig am 27. Nov. 2026 · Zahlen")
        #expect(ReminderTexts.title(content(daysAhead: 3, title: ""), locale: Self.german) == "Dokument ohne Titel")
    }

    /// The settings' texts exist in both languages, per platform, and the footnote names "Show Previews" (Q5).
    @Test func theSettingsTextsInBothLanguages() {
        func rendered(_ resource: LocalizedStringResource, _ locale: Locale) -> String {
            var resource = resource
            resource.locale = locale
            return String(localized: resource)
        }
        #expect(rendered(ReminderSettingsText.footnote, Self.english).contains("“Show Previews”"))
        #expect(rendered(ReminderSettingsText.footnote, Self.german).contains("„Vorschauen zeigen“"))
        #expect(rendered(ReminderSettingsText.lead(1), Self.english) == "1 day before")
        #expect(rendered(ReminderSettingsText.lead(3), Self.german) == "3 Tage vorher")
        #expect(rendered(ReminderSettingsText.lead(1), Self.german) == "1 Tag vorher")
        #expect(rendered(ReminderSettingsText.lead(0), Self.german) == "Am Fälligkeitstag")
        #expect(rendered(ReminderSettingsText.lead(14), Self.german) == "2 Wochen vorher")
        #expect(rendered(ReminderSettingsText.section, Self.german) == "Erinnerungen")
        #expect(rendered(ReminderSettingsText.allow, Self.german) == "Mitteilungen erlauben")
        #if os(macOS)
            #expect(
                rendered(ReminderSettingsText.status(.authorized), Self.german)
                    == "Mitteilungen sind auf diesem Mac erlaubt.")
        #else
            #expect(
                rendered(ReminderSettingsText.status(.authorized), Self.german)
                    == "Mitteilungen sind auf diesem iPhone erlaubt.")
        #endif
        #expect(AccessibilityID.settingsRemindersTime(9 * 60) == "settings.reminders.time.0900")
        #expect(AccessibilityID.settingsRemindersTime(18 * 60 + 5) == "settings.reminders.time.1805")
        #expect(AccessibilityID.settingsRemindersLead(3) == "settings.reminders.lead.3")
    }
}
