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

    /// Starts a copy of `sleep` from a temporary folder and checks that it is seen as running inside that folder.
    func testProcessStartedFromFolderIsSeenAsRunning() throws {
        let dir = try makeTempDir(self)
        let exe = dir.appendingPathComponent("fake-game")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: exe)

        // a copied system binary loses its platform signature; sign it again so it can start
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", exe.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()

        let p = Process()
        p.executableURL = exe
        p.arguments = ["30"]
        do { try p.run() } catch { throw XCTSkip("could not start a test process: \(error)") }
        addTeardownBlock { p.terminate() }

        var seen = false
        for _ in 0..<30 where !seen {
            seen = Machine.isRunning(inside: dir)
            if !seen { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertTrue(seen, "ps -axo comm= should list \(exe.path)")
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
