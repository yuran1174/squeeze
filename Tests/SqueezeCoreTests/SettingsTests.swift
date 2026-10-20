import XCTest
@testable import SqueezeCore

final class SettingsTests: XCTestCase {
    func testEmptyJSONGivesDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(s, Settings())
        XCTAssertTrue(s.autoRecompress)
        XCTAssertTrue(s.requireACPower)
        XCTAssertEqual(s.idleMinutes, 5)
        XCTAssertEqual(s.minNewMB, 100)
    }

    func testPartialJSONKeepsGivenValues() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"idleMinutes": 20, "customFolders": ["/a"]}"#.utf8))
        XCTAssertEqual(s.idleMinutes, 20)
        XCTAssertEqual(s.customFolders, ["/a"])
        XCTAssertTrue(s.autoRecompress)
    }

    func testSaveAndLoadRoundTrip() throws {
        let url = try makeTempDir(self).appendingPathComponent("nested/settings.json")
        var s = Settings()
        s.idleMinutes = 12
        s.autoRecompress = false
        s.customFolders = ["/Users/x/Games"]
        s.baselines = ["steam:570": 12345]
        s.record(HistoryEntry(date: Date(timeIntervalSince1970: 1_700_000_000), name: "Dota 2", action: .compress, bytes: 34 << 30))
        s.save(to: url)
        XCTAssertEqual(Settings.load(from: url), s)
    }

    func testLoadMissingOrBrokenFileGivesDefaults() throws {
        let dir = try makeTempDir(self)
        XCTAssertEqual(Settings.load(from: dir.appendingPathComponent("none.json")), Settings())
        let bad = dir.appendingPathComponent("bad.json")
        try write("{ not json", to: bad)
        XCTAssertEqual(Settings.load(from: bad), Settings())
    }

    func testHistoryKeepsNewestFirstAndIsCapped() {
        var s = Settings()
        for i in 0..<60 { s.record(HistoryEntry(name: "g\(i)", action: .auto, bytes: Int64(i))) }
        XCTAssertEqual(s.history.count, 50)
        XCTAssertEqual(s.history.first?.name, "g59")
        XCTAssertEqual(s.history.last?.name, "g10")
    }

    func testProtectedPaths() {
        let home = "/Users/test"
        for p in ["/", "/System/Library", "/usr/local", "/Applications", "/Applications/Steam.app", "/Library/Foo",
                  "/private/var", "/var/db", "/etc/hosts", "/tmp/x", "/opt/homebrew", "/Users", "/Volumes", "/Volumes/Games", home, home + "/Library",
                  home + "/Library/Mobile Documents/com~apple~CloudDocs", home + "/Library/CloudStorage/Dropbox"] {
            XCTAssertTrue(Settings.isProtected(p, home: home), "\(p) must be protected")
        }
        for p in ["/Volumes/Games/Steam", home + "/Games", home + "/Library/Application Support/Steam",
                  home + "/Documents/Stuff", "/Users/other/Games"] {
            XCTAssertFalse(Settings.isProtected(p, home: home), "\(p) must be allowed")
        }
    }

    func testProtectedPathsAreNormalised() {
        let home = "/Users/test"
        XCTAssertTrue(Settings.isProtected("/Users/test/Games/../..", home: home)) // resolves to /Users
        XCTAssertTrue(Settings.isProtected("/usr/../System", home: home))
        XCTAssertTrue(Settings.isProtected("/Users/test/Games/..", home: home)) // resolves to the home folder
    }

    func testByteFormat() {
        XCTAssertFalse(Format.bytes(34_000_000_000).isEmpty)
    }
}
