#if DEBUG && os(macOS)
    import AppKit

    /// `-UITestAppearance dark` (Debug builds on the Mac only): the app alone in dark mode, for UI test runs and
    /// screenshots in dark whatever the system's appearance (#82); the system setting is never changed. Light needs
    /// no code: `-NSRequiresAquaSystemAppearance YES`. A dark counterpart in the argument domain does not exist:
    /// `-AppleInterfaceStyle Dark` left the app light on a Mac whose appearance is "Auto" and light by day (measured,
    /// #82).
    enum UITestAppearance {
        static let argument = "-UITestAppearance"

        /// The appearance `arguments` ask for: dark for `-UITestAppearance dark`, otherwise `nil` (the system's).
        static func requested(arguments: [String]) -> NSAppearance.Name? {
            guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count,
                arguments[index + 1] == "dark"
            else { return nil }
            return .darkAqua
        }

        /// Sets the app's appearance at launch when `arguments` ask for one.
        @MainActor
        static func apply(arguments: [String]) {
            guard let name = requested(arguments: arguments) else { return }
            NSApplication.shared.appearance = NSAppearance(named: name)
        }
    }
#endif
