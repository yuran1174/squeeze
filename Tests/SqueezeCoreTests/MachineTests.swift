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

    /// Builds a tiny program in a temporary folder, starts it and checks that it is seen as running inside that folder.
    func testProcessStartedFromFolderIsSeenAsRunning() throws {
        let dir = try makeTempDir(self)
        let src = dir.appendingPathComponent("game.c")
        let exe = dir.appendingPathComponent("fake-game")
        try write("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n", to: src)

        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-o", exe.path, src.path]
        do { try cc.run() } catch { throw XCTSkip("no C compiler: \(error)") }
        cc.waitUntilExit()
        try XCTSkipIf(cc.terminationStatus != 0, "cc failed")

        let p = Process()
        p.executableURL = exe
        try p.run()
        addTeardownBlock { if p.isRunning { p.terminate() } }

        var seen = false
        for _ in 0..<30 where !seen {
            seen = Machine.isRunning(inside: dir)
            if !seen { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertTrue(p.isRunning, "test process exited early, status \(p.terminationStatus)")
        XCTAssertTrue(seen, "ps -axo comm= should list \(exe.path); matching lines: \(Machine.runningExecutables().filter { $0.contains("fake-game") })")
        XCTAssertFalse(Machine.isRunning(inside: dir.appendingPathComponent("other")))

        p.terminate()
        p.waitUntilExit()
        XCTAssertFalse(Machine.isRunning(inside: dir))
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
