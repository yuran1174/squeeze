import Foundation
import XCTest

/// A fresh temporary folder, removed when the test ends.
func makeTempDir(_ test: XCTestCase, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("squeeze-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir.resolvingSymlinksInPath()
}

@discardableResult
func write(_ data: Data, to url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
}

func write(_ text: String, to url: URL) throws {
    try write(Data(text.utf8), to: url)
}

/// Data that compresses very well.
func zeros(_ count: Int) -> Data { Data(count: count) }

/// Data that does not compress.
func randomBytes(_ count: Int) -> Data {
    var g = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
}

/// A fake Steam root with one game: `appmanifest_<id>.acf` and a folder in `steamapps/common`.
@discardableResult
func makeSteamGame(root: URL, id: String, name: String, dir: String, stateFlags: Int = 4) throws -> URL {
    let manifest = """
    "AppState"
    {
        "appid"        "\(id)"
        "name"         "\(name)"
        "StateFlags"   "\(stateFlags)"
        "installdir"   "\(dir)"
        "buildid"      "123"
    }
    """
    try write(manifest, to: root.appendingPathComponent("steamapps/appmanifest_\(id).acf"))
    let game = root.appendingPathComponent("steamapps/common/\(dir)", isDirectory: true)
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    return game
}
