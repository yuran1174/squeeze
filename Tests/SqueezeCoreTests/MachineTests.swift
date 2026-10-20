import XCTest
@testable import SqueezeCore

final class MachineTests: XCTestCase {
    /// The game check relies on `ps -axo comm=` printing full executable paths.
    func testRunningExecutablesAreFullPaths() throws {
        let list = Machine.runningExecutables()
        XCTAssertFalse(list.isEmpty)
        XCTAssertTrue(list.contains { $0.hasPrefix("/") }, "expected absolute paths, got: \(list.prefix(5))")
        let paths = list.filter { $0.hasPrefix("/") }
        XCTAssertGreaterThan(paths.count, list.count / 2)
    }

    func testOwnProcessIsListedInsideItsFolder() throws {
        let exe = try XCTUnwrap(Bundle.main.executableURL).resolvingSymlinksInPath()
        let folder = exe.deletingLastPathComponent()
        XCTAssertTrue(Machine.isRunning(inside: folder), "the test runner \(exe.path) should count as running")
    }

    func testIsRunningInsideMatchesFolderBoundary() {
        let exes = ["/Games/Dota 2/bin/dota2", "/Games/Dota 2 Beta/bin/other"]
        XCTAssertTrue(Machine.isRunning(inside: URL(fileURLWithPath: "/Games/Dota 2"), executables: exes))
        XCTAssertFalse(Machine.isRunning(inside: URL(fileURLWithPath: "/Games/Dota"), executables: exes))
        XCTAssertFalse(Machine.isRunning(inside: URL(fileURLWithPath: "/Games/Other"), executables: exes))
        XCTAssertFalse(Machine.isRunning(inside: URL(fileURLWithPath: "/Games/Dota 2"), executables: []))
    }

    func testIdleAndPowerDoNotCrash() {
        XCTAssertGreaterThanOrEqual(Machine.idleSeconds, 0)
        _ = Machine.onACPower
    }
}
