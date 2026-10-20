import XCTest
@testable import SqueezeCore

final class AfsctoolTests: XCTestCase {
    private func items(_ sizes: [Int64]) -> [FileItem] {
        sizes.enumerated().map { FileItem(url: URL(fileURLWithPath: "/f\($0.offset)"), size: $0.element) }
    }

    func testBatchesSplitByFileCount() {
        let out = Afsctool.batches(items(Array(repeating: 1, count: 150)))
        XCTAssertEqual(out.map(\.count), [64, 64, 22])
    }

    func testBatchesSplitByBytes() {
        let out = Afsctool.batches(items([100 << 20, 100 << 20, 100 << 20, 10]), maxFiles: 64, maxBytes: 256 << 20)
        // the third file pushes the batch over 256 MB and closes it
        XCTAssertEqual(out.map(\.count), [3, 1])
    }

    func testOneHugeFileGetsItsOwnBatch() {
        let out = Afsctool.batches(items([10 << 30, 5]))
        XCTAssertEqual(out.map(\.count), [1, 1])
    }

    func testBatchesKeepEveryFileInOrder() {
        let files = items(Array(repeating: 7, count: 200))
        XCTAssertEqual(Afsctool.batches(files).flatMap { $0 }, files)
    }

    func testBatchesOfNothing() {
        XCTAssertTrue(Afsctool.batches([]).isEmpty)
    }

    func testToolMissingMessage() {
        XCTAssertTrue(SqueezeError.toolMissing.errorDescription?.contains("brew install afsctool") == true)
        XCTAssertEqual(SqueezeError.failed("boom").errorDescription, "boom")
    }

    func testLocatePrefersEnvironmentVariable() throws {
        let dir = try makeTempDir(self)
        let fake = dir.appendingPathComponent("afsctool")
        try write("#!/bin/sh\n", to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertEqual(Afsctool.locate(environment: ["SQUEEZE_AFSCTOOL": fake.path])?.path, fake.path)
        // a path that is not executable is ignored
        let notExe = dir.appendingPathComponent("plain")
        try write("x", to: notExe)
        XCTAssertNotEqual(Afsctool.locate(environment: ["SQUEEZE_AFSCTOOL": notExe.path])?.path, notExe.path)
    }

    func testBundledCopyIsFoundInsideAppBundle() throws {
        let dir = try makeTempDir(self)
        let app = dir.appendingPathComponent("Squeeze.app")
        let helper = app.appendingPathComponent("Contents/Helpers/afsctool")
        try write("#!/bin/sh\n", to: helper)
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.squeeze</string></dict></plist>
        """, to: app.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertNil(Afsctool.bundled(in: bundle), "not executable yet")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertEqual(Afsctool.bundled(in: bundle)?.lastPathComponent, "afsctool")
        XCTAssertEqual(Afsctool.locate(bundle: bundle, environment: [:])?.path, Afsctool.bundled(in: bundle)?.path)
    }

    /// Real compression: needs afsctool (brew install afsctool) and an APFS volume.
    func testCompressThenScanThenDecompress() throws {
        try XCTSkipIf(Afsctool.locate() == nil, "afsctool is not installed")
        let dir = try makeTempDir(self)
        let file = try write(zeros(4 << 20), to: dir.appendingPathComponent("big.bin"))
        XCTAssertFalse(Scanner.isCompressed(file.path))

        let (_, pending) = Scanner.scan(dir, collectUncompressed: true)
        XCTAssertEqual(pending.count, 1)

        var reported: Int64 = 0
        let done = try Afsctool.compress(pending, progress: { reported = $0 }, shouldStop: { false })
        XCTAssertEqual(done, 4 << 20)
        XCTAssertEqual(reported, done)

        let (after, left) = Scanner.scan(dir, collectUncompressed: true)
        try XCTSkipIf(after.compressedFiles == 0, "this volume does not support transparent compression")
        XCTAssertEqual(after.compressedFiles, 1)
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(after.logicalBytes, 4 << 20) // apps still see the full size
        XCTAssertLessThan(after.allocatedBytes, 1 << 20)
        XCTAssertEqual(try Data(contentsOf: file), zeros(4 << 20)) // contents unchanged

        try Afsctool.decompress(dir)
        XCTAssertFalse(Scanner.isCompressed(file.path))
        XCTAssertEqual(try Data(contentsOf: file), zeros(4 << 20))
    }

    func testCompressHonoursStop() throws {
        try XCTSkipIf(Afsctool.locate() == nil, "afsctool is not installed")
        let dir = try makeTempDir(self)
        let file = try write(zeros(1 << 20), to: dir.appendingPathComponent("a"))
        let done = try Afsctool.compress([FileItem(url: file, size: 1 << 20)], progress: { _ in }, shouldStop: { true })
        XCTAssertEqual(done, 0)
        XCTAssertFalse(Scanner.isCompressed(file.path))
    }
}
