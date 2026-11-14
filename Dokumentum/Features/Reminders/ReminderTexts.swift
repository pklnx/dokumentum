import DokumentumCore
import DokumentumKit
import Foundation

/// A reminder's texts (#12, part 3; plan §4, maintainer decision Q5): the title is the document's title (its fallback
/// when it has none), the body the due day relative to the day the reminder shows ("Due today", "Due tomorrow", "Due
/// 27 Nov 2026"; N6) and the deadline's label, "Due tomorrow · Pay". Never any text of the document. What the lock
/// screen shows of them follows the system's "Show Previews".
enum ReminderTexts {
    /// The reconciler's texts, in the app's language.
    static let app = ReminderText(title: { title($0) }, body: { body($0) })

    static func title(_ content: ReminderContent, locale: Locale = .current) -> String {
        var fallback = LocalizedStringResource("Untitled document")
        fallback.locale = locale
        return displayTitle(content.title, fallback: String(localized: fallback))
    }

    static func body(_ content: ReminderContent, locale: Locale = .current) -> String {
        var due: LocalizedStringResource
        switch content.daysAhead {
        case 0:
            due = LocalizedStringResource("Due today", comment: "A deadline's status: it is due today.")
        case 1:
            due = LocalizedStringResource(
                "Due tomorrow", comment: "A reminder's text: the deadline is due on the day after the reminder.")
        default:
            let formatted = DeadlineText.date(of: content.day).formatted(
                Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
            due = LocalizedStringResource("Due \(formatted)", comment: "A deadline's day, e.g. “Due 16 Nov 2026”.")
        }
        due.locale = locale
        let label = content.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return [String(localized: due), label].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
