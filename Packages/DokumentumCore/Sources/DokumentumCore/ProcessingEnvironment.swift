/// Everything the import and analysis pipeline reads from outside. The app uses `live`; a test runs
/// its body in `ProcessingEnvironment.$current.withValue(…) { … }`, so tests running in parallel each
/// see their own settings. This is the only seam type: no other global state is replaced by tests.
/// Each step adds the fields it needs.
///
/// `current` is a task-local: `Task {}` inherits it, `Task.detached` does not. Code that leaves the
/// task with `Task.detached` captures `ProcessingEnvironment.current` before detaching and passes it
/// on.
public struct ProcessingEnvironment: Sendable {
    /// The `UserDefaults` suite of the per-device settings; `nil` is `UserDefaults.standard`. A name
    /// and not the object, because `UserDefaults` is not `Sendable`.
    public var defaultsSuite: String?

    /// Tests only: runs in `DocumentImporter` after a file was checked and before its document is inserted,
    /// with the first duplicate check behind it (#4, part 2). `nil` in the app.
    public var importWillCommit: (@Sendable () async -> Void)?

    public init(defaultsSuite: String?, importWillCommit: (@Sendable () async -> Void)? = nil) {
        self.defaultsSuite = defaultsSuite
        self.importWillCommit = importWillCommit
    }

    /// The app's environment.
    public static let live = ProcessingEnvironment(defaultsSuite: nil)

    @TaskLocal public static var current: ProcessingEnvironment = .live
}
