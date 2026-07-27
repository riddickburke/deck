import Foundation

/// A ~60-line test harness. XCTest and swift-testing both require a full Xcode install;
/// this project targets Command Line Tools, so the suite runs as a normal executable
/// and signals failure through its exit code.
enum T {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var currentTest = ""
    nonisolated(unsafe) static var currentFailed = false
    nonisolated(unsafe) static var currentSuite = ""

    static func suite(_ name: String) {
        currentSuite = name
        print("\n\u{1B}[1m\(name)\u{1B}[0m")
    }

    static func test(_ name: String, _ body: () async throws -> Void) async {
        currentTest = name
        currentFailed = false
        do {
            try await body()
        } catch {
            fail("threw: \(error)")
        }
        if currentFailed {
            print("  \u{1B}[31m✗\u{1B}[0m \(name)")
        } else {
            passed += 1
            print("  \u{1B}[32m✓\u{1B}[0m \(name)")
        }
    }

    /// Marks a test as skipped rather than passed, so an unmet precondition never
    /// masquerades as a green run.
    static func skip(_ name: String, _ why: String) {
        print("  \u{1B}[33m-\u{1B}[0m \(name) (skipped: \(why))")
    }

    static func fail(_ message: String, line: Int = #line) {
        currentFailed = true
        failures.append("\(currentSuite) › \(currentTest) [line \(line)]: \(message)")
    }

    static func expect(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition { fail(message, line: line) }
    }

    static func equal<V: Equatable>(
        _ actual: V, _ expected: V, _ label: String = "", line: Int = #line
    ) {
        if actual != expected {
            let prefix = label.isEmpty ? "" : "\(label): "
            fail("\(prefix)expected \(expected), got \(actual)", line: line)
        }
    }

    static func notNil<V>(_ value: V?, _ label: String, line: Int = #line) -> V? {
        if value == nil { fail("\(label) was nil", line: line) }
        return value
    }

    static func isNil<V>(_ value: V?, _ label: String, line: Int = #line) {
        if value != nil { fail("\(label) should have been nil, got \(value!)", line: line) }
    }

    static func report() -> Int32 {
        print("")
        if failures.isEmpty {
            print("\u{1B}[32m\(passed) passed, 0 failed\u{1B}[0m")
            return 0
        }
        print("\u{1B}[31m\(passed) passed, \(failures.count) failed\u{1B}[0m")
        for failure in failures { print("  \u{1B}[31m•\u{1B}[0m \(failure)") }
        return 1
    }
}

// MARK: - Temp fixtures

enum Fixture {
    /// A throwaway directory that cleans itself up via `remove()`.
    static func tempDirectory(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("deck-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
