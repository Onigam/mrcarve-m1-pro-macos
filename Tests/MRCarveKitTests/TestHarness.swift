import Foundation

// Minimal test harness: register test functions with `test("name") { ... }` in a suite's
// `register()` and use `expect` / `expectEqual`. Run with `swift run mrcarve-tests [filter]`.

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let location: String
    var description: String { "\(location): \(message)" }
}

final class TestRegistry {
    nonisolated(unsafe) static let shared = TestRegistry()
    var tests: [(name: String, body: () throws -> Void)] = []
    var failures: [String] = []
}

func test(_ name: String, _ body: @escaping () throws -> Void) {
    TestRegistry.shared.tests.append((name, body))
}

func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "expectation failed",
            file: StaticString = #fileID, line: UInt = #line) {
    if !condition() { TestRegistry.shared.failures.append("\(file):\(line): \(message())") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) {
    if a != b { TestRegistry.shared.failures.append("\(file):\(line): \(a) != \(b)") }
}

func expectClose(_ a: Double, _ b: Double, tolerance: Double = 1e-9, file: StaticString = #fileID, line: UInt = #line) {
    if abs(a - b) > tolerance { TestRegistry.shared.failures.append("\(file):\(line): \(a) != \(b) (±\(tolerance))") }
}

func runRegisteredTests(filter: String?) -> Int32 {
    let reg = TestRegistry.shared
    var failed = 0, ran = 0
    for t in reg.tests where filter == nil || t.name.localizedCaseInsensitiveContains(filter!) {
        ran += 1
        let before = reg.failures.count
        do { try t.body() } catch { reg.failures.append("\(t.name): threw \(error)") }
        if reg.failures.count > before {
            failed += 1
            print("✗ \(t.name)")
            for f in reg.failures[before...] { print("    \(f)") }
        } else {
            print("✓ \(t.name)")
        }
    }
    print("\n\(ran - failed)/\(ran) tests passed")
    return failed == 0 ? 0 : 1
}
