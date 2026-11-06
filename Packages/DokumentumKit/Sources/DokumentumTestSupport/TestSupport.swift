import Foundation

/// The helpers shared by all test targets. The waits are in `Waiting.swift`.
public enum TestSupport {
    /// The factor every test wait multiplies its timeout by: the environment variable
    /// `DOKUMENTUM_TEST_TIMEOUT_SCALE`, 1 when it is missing or not a positive number. For a run that
    /// is slowed down on purpose, such as one with a sanitizer (docs/development/index.md, "Waiting
    /// in tests").
    public static let timeoutScale = timeoutScale(from: ProcessInfo.processInfo.environment)

    public static func timeoutScale(from environment: [String: String]) -> Double {
        guard let value = environment["DOKUMENTUM_TEST_TIMEOUT_SCALE"].flatMap(Double.init),
            value.isFinite, value > 0
        else { return 1 }
        return value
    }

    /// A wait's timeout, scaled by `timeoutScale`. Every wait for something asynchronous uses it.
    public static func scaled(_ timeout: Duration) -> Duration {
        scaled(timeout, by: timeoutScale)
    }

    /// `timeout` times `scale`; separate from `scaled(_:)` so a test can check it with a fixed scale.
    public static func scaled(_ timeout: Duration, by scale: Double) -> Duration {
        timeout * scale
    }
}
