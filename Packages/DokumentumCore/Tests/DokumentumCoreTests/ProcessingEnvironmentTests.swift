import DokumentumCore
import DokumentumTestSupport
import Testing

/// The one seam type: a task-local, so tests running in parallel each see their own.
struct ProcessingEnvironmentTests {
    @Test func liveIsIsolatedWhileTestsRun() {
        #expect(TestEnvironment.isRunningTests)
        #expect(TestEnvironment.isIsolated)
        #expect(ProcessingEnvironment.live.defaultsSuite == nil)
    }

    /// The app itself is no test run; each way to run the tests is one.
    @Test func aTestRunIsDetected() {
        #expect(!TestEnvironment.isRunningTests(environment: [:], processName: "Dokumentum"))
        #expect(!TestEnvironment.isRunningTests(environment: ["PATH": "/usr/bin"], processName: "Dokumentum"))
        for variable in ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"] {
            #expect(TestEnvironment.isRunningTests(environment: [variable: "x"], processName: "Dokumentum"))
        }
        #expect(TestEnvironment.isRunningTests(environment: [:], processName: "swiftpm-testing-helper"))
        #expect(TestEnvironment.isRunningTests(environment: [:], processName: "xctest"))
    }

    @Test func concurrentTasksEachSeeTheirOwnEnvironment() async {
        let suites = ["suite-A", "suite-B"]
        // Both tasks are inside their `withValue` before either reads it.
        let inside = TestSignal()
        let seen = await withTaskGroup(of: String?.self) { group in
            for suite in suites {
                group.addTask {
                    await ProcessingEnvironment.$current.withValue(ProcessingEnvironment(defaultsSuite: suite)) {
                        inside.fire()
                        await inside.wait(for: suites.count)
                        return ProcessingEnvironment.current.defaultsSuite
                    }
                }
            }
            var results: [String?] = []
            for await result in group { results.append(result) }
            return results.compactMap(\.self).sorted()
        }

        #expect(seen == suites)
        #expect(ProcessingEnvironment.current.defaultsSuite == nil, "outside withValue it is live again")
    }

    /// `Task {}` inherits the environment; `Task.detached` does not, which is why code that detaches
    /// captures it first.
    @Test func taskInheritsTheEnvironmentButDetachedDoesNot() async {
        let environment = ProcessingEnvironment(defaultsSuite: "suite-inherited")
        let (inherited, detached) = await ProcessingEnvironment.$current.withValue(environment) {
            let inherited = await Task { ProcessingEnvironment.current.defaultsSuite }.value
            let detached = await Task.detached { ProcessingEnvironment.current.defaultsSuite }.value
            return (inherited, detached)
        }
        #expect(inherited == "suite-inherited")
        #expect(detached == nil)
    }
}
