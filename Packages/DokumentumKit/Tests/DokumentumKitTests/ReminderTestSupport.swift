import DokumentumKit
import Foundation

// Shared helpers of the reminder tests (#12, part 3): fixed instants in named time zones, deadlines, and one device
// (its in-memory center, its scheduled set and its reconciler) whose clock, zone, settings and deadlines the test sets.
// Nothing reads the real clock.

enum Zones {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
}

/// The instant of a wall-clock time in `zone`.
func at(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
    in zone: TimeZone = Zones.berlin
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

func ymd(_ year: Int, _ month: Int, _ day: Int) -> DeadlineDay {
    DeadlineDay(year: year, month: month, day: day)!
}

func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> ReminderMoment {
    ReminderMoment(year: year, month: month, day: day, hour: hour, minute: minute)
}

/// The document of most cases: "A".
let documentA = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
let documentB = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!

func deadline(
    _ instanceID: UUID = documentA, day: DeadlineDay = ymd(2026, 11, 27), setAt: Date? = at(2026, 11, 1, 10),
    done: Bool = false, trashed: Bool = false, label: String = "Pay", title: String = "Water bill"
) -> ReminderDeadline {
    ReminderDeadline(
        instanceID: instanceID,
        deadline: DocumentDeadline(
            day: day, label: label, setAt: setAt, doneAt: done ? at(2026, 11, 1) : nil),
        title: title, isTrashed: trashed)
}

/// Texts that show what they were made from: the title, and "<days ahead>|<day>|<label>".
let identifyingText = ReminderText(
    title: { $0.title }, body: { "\($0.daysAhead)|\($0.day.storedValue)|\($0.label)" })

/// A value behind a lock, shared by a test and the closures it hands to the reconciler.
final class Locked<Value: Sendable>: @unchecked Sendable {
    // Guarded by `lock`.
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }
}

/// One device: its center (delivering in its own calendar), its scheduled set and its reconciler, with the clock, the
/// zone, the settings and the store's deadlines under the test's control.
final class ReminderDevice: @unchecked Sendable {
    struct World: Sendable {
        var deadlines: [ReminderDeadline]
        var settings: ReminderSettings
        var now: Date
        var timeZone: TimeZone
        /// The next reads throw.
        var readFails = false
        /// The next read finds no deadlines, once (an empty fallback store).
        var nextReadEmpty = false
    }

    let world: Locked<World>
    let center: InMemoryNotificationCenter
    let scheduled: InMemoryScheduledSet
    /// Replaced by `relaunch()`: a new reconciler on the same center and set.
    private(set) var reconciler: ReminderReconciler

    init(
        _ deadlines: [ReminderDeadline] = [deadline()], settings: ReminderSettings = ReminderSettings(),
        status: ReminderAuthorizationStatus = .authorized, timeZone: TimeZone = Zones.berlin,
        scheduled: InMemoryScheduledSet = InMemoryScheduledSet(),
        hooks: InMemoryNotificationCenter.Hooks = .init()
    ) {
        let world = Locked(
            World(deadlines: deadlines, settings: settings, now: at(2026, 11, 1), timeZone: timeZone))
        self.world = world
        center = InMemoryNotificationCenter(
            status: status, calendar: InMemoryNotificationCenter.gregorian(timeZone), hooks: hooks)
        self.scheduled = scheduled
        reconciler = Self.makeReconciler(world: world, center: center, scheduled: scheduled)
    }

    private static func makeReconciler(
        world: Locked<World>, center: InMemoryNotificationCenter, scheduled: InMemoryScheduledSet
    ) -> ReminderReconciler {
        ReminderReconciler(
            center: center, scheduledSet: scheduled,
            readDeadlines: {
                try world.withLock { world in
                    if world.readFails { throw ReadFailure() }
                    if world.nextReadEmpty {
                        world.nextReadEmpty = false
                        return []
                    }
                    return world.deadlines
                }
            },
            settings: { world.withLock { $0.settings } }, text: identifyingText,
            now: { world.withLock { $0.now } },
            calendar: { InMemoryNotificationCenter.gregorian(world.withLock { $0.timeZone }) })
    }

    struct ReadFailure: Error {}

    /// A reconcile at `now`.
    @discardableResult
    func reconcile(at now: Date) async -> ReminderReconcileReport {
        world.withLock { $0.now = now }
        return await reconciler.reconcile()
    }

    /// The system delivers what is due at `now`.
    func deliver(upTo now: Date) async {
        await center.deliver(upTo: now)
    }

    /// The pending moment of `identifier`, `nil` when it is not pending.
    func pendingMoment(_ identifier: String = deadline().identifier) async -> ReminderMoment? {
        await center.pendingRequest(identifier)?.moment
    }

    func shown(_ identifier: String = deadline().identifier) async -> Int {
        await center.shown[identifier] ?? 0
    }

    func set(deadlines: [ReminderDeadline]) { world.withLock { $0.deadlines = deadlines } }
    func set(settings: ReminderSettings) { world.withLock { $0.settings = settings } }

    /// The device moves to another time zone: the reconciler's calendar and the center's delivery follow.
    func move(to zone: TimeZone) async {
        world.withLock { $0.timeZone = zone }
        await center.setCalendar(InMemoryNotificationCenter.gregorian(zone))
    }

    /// The app launches again: a new reconciler, the same center and scheduled set.
    func relaunch() {
        reconciler = Self.makeReconciler(world: world, center: center, scheduled: scheduled)
    }
}
