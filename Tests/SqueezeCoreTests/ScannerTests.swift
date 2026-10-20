import XCTest
@testable import SqueezeCore

final class ScannerTests: XCTestCase {
    func testScanCountsFilesAndSizes() throws {
        let dir = try makeTempDir(self)
        try write(Data(count: 1000), to: dir.appendingPathComponent("a.bin"))
        try write(Data(count: 2500), to: dir.appendingPathComponent("sub/b.bin"))
        try write(Data(), to: dir.appendingPathComponent("sub/empty"))
        try write(Data(count: 10), to: dir.appendingPathComponent(".hidden"))

        let (stats, pending) = Scanner.scan(dir, collectUncompressed: true)
        XCTAssertEqual(stats.files, 4)
        XCTAssertEqual(stats.logicalBytes, 3510)
        XCTAssertEqual(stats.compressedFiles, 0)
        XCTAssertEqual(stats.uncompressedBytes, 3510)
        XCTAssertEqual(stats.compressedShare, 0, accuracy: 0.0001)
        // empty files are not worth compressing
        XCTAssertEqual(pending.count, 3)
        XCTAssertFalse(pending.contains { $0.url.lastPathComponent == "empty" })
    }

    func testScanDoesNotCollectUnlessAsked() throws {
        let dir = try makeTempDir(self)
        try write(Data(count: 100), to: dir.appendingPathComponent("a"))
        XCTAssertTrue(Scanner.scan(dir).1.isEmpty)
    }

    func testScanSkipsSymbolicLinks() throws {
        let dir = try makeTempDir(self)
        let target = try write(Data(count: 500), to: dir.appendingPathComponent("real"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: target)
        let (stats, _) = Scanner.scan(dir)
        XCTAssertEqual(stats.files, 1)
        XCTAssertEqual(stats.logicalBytes, 500)
    }

    func testScanStopsWhenCancelled() throws {
        let dir = try makeTempDir(self)
        for i in 0..<10 { try write(Data(count: 10), to: dir.appendingPathComponent("f\(i)")) }
        let (stats, _) = Scanner.scan(dir, isCancelled: { true })
        XCTAssertEqual(stats.files, 0)
    }

    func testScanMissingFolder() {
        let (stats, pending) = Scanner.scan(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertEqual(stats.files, 0)
        XCTAssertTrue(pending.isEmpty)
    }

    func testIsCompressedOnPlainFileAndMissingFile() throws {
        let dir = try makeTempDir(self)
        let f = try write(Data(count: 100), to: dir.appendingPathComponent("plain"))
        XCTAssertFalse(Scanner.isCompressed(f.path))
        XCTAssertFalse(Scanner.isCompressed(dir.appendingPathComponent("nope").path))
    }

    func testFolderStatsMath() {
        var s = FolderStats()
        s.logicalBytes = 1000
        s.allocatedBytes = 400
        s.uncompressedBytes = 250
        XCTAssertEqual(s.savedBytes, 600)
        XCTAssertEqual(s.compressedShare, 0.75, accuracy: 0.0001)
        s.allocatedBytes = 2000 // never negative
        XCTAssertEqual(s.savedBytes, 0)
    }

    func testAvailableSpace() throws {
        let dir = try makeTempDir(self)
        let free = try XCTUnwrap(Scanner.availableSpace(at: dir))
        XCTAssertGreaterThan(free, 0)
    }
}
