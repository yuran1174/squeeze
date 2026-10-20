import XCTest
@testable import SqueezeCore

final class SteamTests: XCTestCase {
    private let lib = URL(fileURLWithPath: "/tmp/lib")

    func testParseManifest() {
        let text = """
        "AppState"
        {
            "appid" "570"
            "name" "Dota 2"
            "StateFlags" "4"
            "installdir" "dota 2 beta"
            "buildid" "42"
        }
        """
        let app = Steam.parseManifest(text, library: lib)
        XCTAssertEqual(app?.appID, "570")
        XCTAssertEqual(app?.name, "Dota 2")
        XCTAssertEqual(app?.stateFlags, 4)
        XCTAssertEqual(app?.buildID, "42")
        XCTAssertEqual(app?.installDir.path, "/tmp/lib/steamapps/common/dota 2 beta")
        XCTAssertEqual(app?.id, "steam:570")
    }

    func testParseManifestRejectsPathTricks() {
        for dir in ["..", ".", "a/b", "../x", ""] {
            let text = #""AppState" { "appid" "1" "installdir" "\#(dir)" }"#
            XCTAssertNil(Steam.parseManifest(text, library: lib), "installdir \(dir) must be rejected")
        }
    }

    func testParseManifestWithoutNameUsesFolder() {
        let text = #""AppState" { "appid" "1" "installdir" "Folder" }"#
        XCTAssertEqual(Steam.parseManifest(text, library: lib)?.name, "Folder")
        XCTAssertEqual(Steam.parseManifest(text, library: lib)?.stateFlags, 0)
    }

    func testParseManifestGarbage() {
        XCTAssertNil(Steam.parseManifest("not vdf {", library: lib))
        XCTAssertNil(Steam.parseManifest(#""Other" { "appid" "1" }"#, library: lib))
    }

    func testLibrariesNewFormat() throws {
        let root = try makeTempDir(self)
        try write("""
        "libraryfolders"
        {
            "0" { "path" "\(root.path)" "label" "" }
            "1" { "path" "/Volumes/Games/SteamLibrary" "label" "" }
        }
        """, to: root.appendingPathComponent("steamapps/libraryfolders.vdf"))
        let libs = Steam.libraries(root: root).map(\.path)
        XCTAssertEqual(libs, [root.path, "/Volumes/Games/SteamLibrary"]) // the root is listed once
    }

    func testLibrariesOldFormat() throws {
        let root = try makeTempDir(self)
        try write("""
        "LibraryFolders"
        {
            "TimeNextStatsReport" "1"
            "1" "/Volumes/Old/Steam"
        }
        """, to: root.appendingPathComponent("steamapps/libraryfolders.vdf"))
        XCTAssertEqual(Steam.libraries(root: root).map(\.path), [root.path, "/Volumes/Old/Steam"])
    }

    func testLibrariesWithoutFile() throws {
        let root = try makeTempDir(self)
        XCTAssertEqual(Steam.libraries(root: root).map(\.path), [root.path])
    }

    func testInstalledAppsSortedAndFiltered() throws {
        let root = try makeTempDir(self)
        try makeSteamGame(root: root, id: "2", name: "zeta", dir: "Zeta")
        try makeSteamGame(root: root, id: "1", name: "Alpha", dir: "Alpha")
        try makeSteamGame(root: root, id: "228980", name: "Steamworks Common Redistributables", dir: "Steamworks Shared")
        // manifest whose game folder does not exist
        try write(#""AppState" { "appid" "3" "name" "Ghost" "installdir" "Missing" "StateFlags" "4" }"#,
                  to: root.appendingPathComponent("steamapps/appmanifest_3.acf"))
        let names = Steam.installedApps(root: root).map(\.name)
        XCTAssertEqual(names, ["Alpha", "zeta"])
    }

    func testIsBusyWhenNotFullyInstalled() throws {
        let root = try makeTempDir(self)
        try makeSteamGame(root: root, id: "10", name: "Updating", dir: "Updating", stateFlags: 1026)
        let app = try XCTUnwrap(Steam.installedApps(root: root).first)
        XCTAssertTrue(Steam.isBusy(app))
    }

    func testIsBusyWhenDownloadFolderHasFiles() throws {
        let root = try makeTempDir(self)
        try makeSteamGame(root: root, id: "11", name: "Game", dir: "Game")
        let app = try XCTUnwrap(Steam.installedApps(root: root).first)
        XCTAssertFalse(Steam.isBusy(app))
        try write("x", to: root.appendingPathComponent("steamapps/downloading/11/chunk"))
        XCTAssertTrue(Steam.isBusy(app))
    }

    func testIsBusyRereadsManifest() throws {
        let root = try makeTempDir(self)
        try makeSteamGame(root: root, id: "12", name: "Game", dir: "Game")
        let app = try XCTUnwrap(Steam.installedApps(root: root).first)
        XCTAssertFalse(Steam.isBusy(app))
        // Steam starts an update and rewrites the manifest
        try makeSteamGame(root: root, id: "12", name: "Game", dir: "Game", stateFlags: 1026)
        XCTAssertTrue(Steam.isBusy(app))
    }
}
