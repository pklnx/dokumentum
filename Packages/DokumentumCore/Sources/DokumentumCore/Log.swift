import Foundation
import os

/// The app's loggers (unified logging). Console filters by the subsystem and the category.
/// `scripts/check-logging.py` enforces that every logger comes from here and that app code never prints.
///
/// **Privacy:**
/// - `.public`: counts, durations, enum states (the store choice), error domain and code (`code(of:)`).
/// - `.private`: titles, names, file names, paths, extracted text, and an error's `localizedDescription`
///   (it can contain a path).
///
/// **Levels:** `.notice` for what a diagnosis needs later (the store opened, sync events, repair
/// reports); `.error` for failures; `.fault` only for what should never happen. `.info` and `.debug` are
/// for Console while developing: unified logging does not keep them.
public enum Log {
    public static let subsystem = "space.pklnx.Dokumentum"

    /// The store: which one opened, fallbacks, failures.
    public static let store = Logger(subsystem: subsystem, category: "store")
    /// CloudKit sync events and the account state (#2, part 4).
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    /// Repair runs and their reports (#2, part 3).
    public static let repair = Logger(subsystem: subsystem, category: "repair")

    /// An error's domain and code, such as "NSCocoaErrorDomain 134110": safe to log as `.public`. Log the
    /// `localizedDescription` separately, as `.private`.
    public static func code(of error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}
