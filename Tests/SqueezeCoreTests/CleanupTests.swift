import XCTest
@testable import SqueezeCore

final class CleanupTests: XCTestCase {
    func testParseSize() {
        XCTAssertEqual(CleanupEngine.parseSize("1.23GB"), 1_230_000_000)
        XCTAssertEqual(CleanupEngine.parseSize("5.4MB"), 5_400_000)
        XCTAssertEqual(CleanupEngine.parseSize("12KB"), 12_000)
        XCTAssertEqual(CleanupEngine.parseSize("5B"), 5)
        XCTAssertEqual(CleanupEngine.parseSize(" 2TB "), 2_000_000_000_000)
        XCTAssertNil(CleanupEngine.parseSize("size unknown"))
        XCTAssertNil(CleanupEngine.parseSize("lots"))
    }

    func testParsePreview() {
        let text = """
        # Mole Cleanup Preview - 2026-10-21 12:00:00
        #
        # Example:
        #   /Users/*/Library/Caches/com.example.app
        #

        === User essentials ===
        /Users/me/Library/Caches/com.example.app  # 1.20GB, 3 items
        /Users/me/Library/Caches/com.example.app/sub  # 5.0MB, counted under /Users/me/Library/Caches/com.example.app
        /Users/me/.Trash  # 300.0MB, 12 items

        === Browsers ===
        /Users/me/Library/Caches/Google/Chrome/Default/Cache  # size unknown
        /Users/me/Library/Caches/odd  # name/x  # 2KB

        === Empty section ===
        """
        let sections = CleanupEngine.parsePreview(text)
        XCTAssertEqual(sections.map(\.name), ["User essentials", "Browsers"])
        let first = sections[0]
        XCTAssertEqual(first.items.count, 3)
        XCTAssertEqual(first.items[0], CleanupItem(path: "/Users/me/Library/Caches/com.example.app", bytes: 1_200_000_000, count: 3))
        XCTAssertEqual(first.items[1].coveredBy, "/Users/me/Library/Caches/com.example.app")
        XCTAssertEqual(first.topItems.count, 2)
        XCTAssertEqual(first.bytes, 1_500_000_000) // the covered row is not counted twice
        XCTAssertNil(sections[1].items[0].bytes)
        // a path containing "  # " keeps everything before the last separator
        XCTAssertEqual(sections[1].items[1].path, "/Users/me/Library/Caches/odd  # name/x")
        XCTAssertEqual(sections[1].items[1].bytes, 2_000)
    }

    func testKeepListHasEveryUntickedTopRow() {
        let plan = [
            CleanupSection(name: "A", items: [CleanupItem(path: "/a", bytes: 1), CleanupItem(path: "/a/b", bytes: 1, coveredBy: "/a")]),
            CleanupSection(name: "B", items: [CleanupItem(path: "/c", bytes: 1), CleanupItem(path: "/d", bytes: nil)]),
        ]
        XCTAssertEqual(CleanupEngine.keepList(plan: plan, selected: ["/a", "/d"]), ["/c"])
        XCTAssertEqual(CleanupEngine.keepList(plan: plan, selected: []), ["/a", "/c", "/d"])
    }

    func testSectionTitleFromOutput() {
        XCTAssertEqual(CleanupEngine.sectionTitle(fromOutputLine: "➤ Browsers"), "Browsers")
        XCTAssertEqual(CleanupEngine.sectionTitle(fromOutputLine: "\u{1B}[1;35m➤ Developer tools\u{1B}[0m"), "Developer tools")
        XCTAssertNil(CleanupEngine.sectionTitle(fromOutputLine: "  ✓ Nothing to tidy"))
    }

    func testTrash() {
        XCTAssertTrue(CleanupEngine.isTrash("/Users/me/.Trash", home: "/Users/me"))
        XCTAssertTrue(CleanupEngine.isTrash("/Users/me/.Trash/old.dmg", home: "/Users/me"))
        XCTAssertFalse(CleanupEngine.isTrash("/Users/me/.Trashy", home: "/Users/me"))
    }

    func testLocate() throws {
        let dir = try makeTempDir(self)
        XCTAssertNil(CleanupEngine.locate(bundle: Bundle(for: CleanupTests.self), environment: ["SQUEEZE_CLEANUP_ENGINE": dir.path]))
        try write("#!/bin/bash\n", to: dir.appendingPathComponent("bin/clean.sh"))
        XCTAssertEqual(CleanupEngine.locate(environment: ["SQUEEZE_CLEANUP_ENGINE": dir.path])?.lastPathComponent, "clean.sh")
    }

    /// A stand-in engine: checks the environment Squeeze gives it and writes a preview.
    func testRunPassesKeepListAndPreviewFile() throws {
        let dir = try makeTempDir(self)
        let engine = dir.appendingPathComponent("engine/bin/clean.sh")
        try write("""
        #!/bin/bash
        [ -t 0 ] && { echo "stdin must not be a terminal"; exit 3; }
        [ "$NO_COLOR" = 1 ] || exit 4
        echo "➤ Section one"
        if [ "$1" = "--dry-run" ]; then
          { echo "=== Section one ==="; echo "/tmp/a  # 1.0MB"; echo "/tmp/b  # 2.0MB"; } > "$MOLE_PREVIEW_FILE"
        fi
        cp "$MOLE_EXTRA_WHITELIST_FILE" "$(dirname "$MOLE_PREVIEW_FILE")/seen-keep.txt"
        """, to: engine)
        let work = dir.appendingPathComponent("work")
        var sections: [String] = []
        let plan = try CleanupEngine.preview(engine: engine, keep: ["/tmp/b", "relative/ignored"], workDir: work, onSection: { sections.append($0) })
        XCTAssertEqual(plan.first?.items.map(\.path), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(sections, ["Section one"])
        XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("seen-keep.txt"), encoding: .utf8), "/tmp/b\n")
    }

    func testFailureReportsOutput() throws {
        let dir = try makeTempDir(self)
        let engine = dir.appendingPathComponent("bin/clean.sh")
        try write("#!/bin/bash\necho 'something broke'\nexit 2\n", to: engine)
        XCTAssertThrowsError(try CleanupEngine.preview(engine: engine, workDir: dir.appendingPathComponent("w"))) { error in
            XCTAssertEqual(error as? CleanupError, .failed("something broke"))
        }
    }

    func testCancelInterruptsTheEngine() throws {
        let dir = try makeTempDir(self)
        let engine = dir.appendingPathComponent("bin/clean.sh")
        try write("#!/bin/bash\nsleep 30\n", to: engine)
        let start = Date()
        let outcome = try CleanupEngine.run(engine: engine, dryRun: false, keep: [], workDir: dir.appendingPathComponent("w"),
                                            isCancelled: { Date().timeIntervalSince(start) > 0.5 })
        XCTAssertTrue(outcome.cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
