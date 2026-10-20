import XCTest
@testable import SqueezeCore

final class AppsTests: XCTestCase {
    @discardableResult
    private func makeApp(_ root: URL, _ relPath: String, id: String?, name: String? = nil, appStore: Bool = false) throws -> URL {
        let app = root.appendingPathComponent(relPath)
        var info = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
        if let id { info += "<key>CFBundleIdentifier</key><string>\(id)</string>" }
        if let name { info += "<key>CFBundleName</key><string>\(name)</string>" }
        info += "</dict></plist>"
        try write(info, to: app.appendingPathComponent("Contents/Info.plist"))
        try write(Data(count: 1000), to: app.appendingPathComponent("Contents/MacOS/bin"))
        if appStore { try write("r", to: app.appendingPathComponent("Contents/_MASReceipt/receipt")) }
        return app
    }

    func testFindsAppsInSubfoldersButNotInsideBundles() throws {
        let root = try makeTempDir(self)
        let home = try makeTempDir(self)
        try makeApp(root, "Zed.app", id: "dev.zed")
        try makeApp(root, "Adobe Photoshop 2025/Adobe Photoshop 2025.app", id: "com.adobe.Photoshop", name: "Photoshop")
        // a helper app inside another app is not a separate program
        try makeApp(root, "Zed.app/Contents/Helpers/Helper.app", id: "dev.zed.helper")
        // symbolic links (like Safari in /Applications) are skipped
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Link.app"),
                                                   withDestinationURL: root.appendingPathComponent("Zed.app"))
        let apps = Apps.installed(roots: [root], home: home, excludingBundleIDs: [])
        XCTAssertEqual(apps.map(\.name), ["Photoshop", "Zed"])
        XCTAssertEqual(apps.first?.id, "app:com.adobe.Photoshop")
    }

    func testExcludesSqueezeItselfAndDuplicates() throws {
        let a = try makeTempDir(self), b = try makeTempDir(self), home = try makeTempDir(self)
        try makeApp(a, "Squeeze.app", id: "io.github.yuran1174.squeeze")
        try makeApp(a, "Tool.app", id: "x.tool")
        try makeApp(b, "Tool.app", id: "x.tool") // same app in ~/Applications too
        let apps = Apps.installed(roots: [a, b], home: home, excludingBundleIDs: ["io.github.yuran1174.squeeze"])
        XCTAssertEqual(apps.map(\.name), ["Tool"])
    }

    func testNameFallsBackToFolderName() throws {
        let root = try makeTempDir(self)
        let app = try makeApp(root, "No Info.app", id: nil)
        XCTAssertEqual(Apps.read(bundle: app, home: root)?.name, "No Info")
        XCTAssertNil(Apps.read(bundle: root.appendingPathComponent("Missing.app"), home: root))
    }

    func testAppStoreReceipt() throws {
        let root = try makeTempDir(self)
        let app = try makeApp(root, "Store.app", id: "x.store", appStore: true)
        XCTAssertTrue(try XCTUnwrap(Apps.read(bundle: app, home: root)).fromAppStore)
    }

    func testNeedsAdminWhenBundleIsNotWritable() throws {
        let root = try makeTempDir(self)
        let app = try makeApp(root, "Locked.app", id: "x.locked")
        let contents = app.appendingPathComponent("Contents")
        XCTAssertFalse(try XCTUnwrap(Apps.read(bundle: app, home: root)).needsAdmin)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: contents.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: contents.path) }
        XCTAssertTrue(try XCTUnwrap(Apps.read(bundle: app, home: root)).needsAdmin)
    }

    func testDataFoldersByBundleIDAndName() throws {
        let home = try makeTempDir(self)
        let support = home.appendingPathComponent("Library/Application Support")
        try write("x", to: support.appendingPathComponent("com.example.editor/state"))
        try write("x", to: support.appendingPathComponent("Editor/state"))
        let folders = Apps.dataFolders(bundleID: "com.example.editor", names: ["Editor", "Editor"], home: home)
        XCTAssertEqual(folders.map(\.url.lastPathComponent), ["com.example.editor", "Editor"])
        XCTAssertTrue(folders.allSatisfy(\.skipVolatile))
    }

    func testDataFoldersMissingAndUnsafeNames() throws {
        let home = try makeTempDir(self)
        try write("x", to: home.appendingPathComponent("Library/Application Support/x"))
        XCTAssertTrue(Apps.dataFolders(bundleID: "nothing.here", names: ["Nope", "..", ".", "a/b", ""], home: home).isEmpty)
    }

    func testKnownExtrasAreScannedWhole() throws {
        let home = try makeTempDir(self)
        try write("x", to: home.appendingPathComponent("Library/Android/sdk/platforms/a"))
        let folders = Apps.dataFolders(bundleID: "com.google.android.studio", names: ["Android Studio"], home: home)
        XCTAssertEqual(folders.map(\.url.path), [home.appendingPathComponent("Library/Android/sdk").path])
        XCTAssertEqual(folders.first?.skipVolatile, false)
    }

    func testSteamAndDockerHaveNoDataFolders() throws {
        let home = try makeTempDir(self)
        try write("x", to: home.appendingPathComponent("Library/Application Support/Steam/steamapps/x"))
        XCTAssertTrue(Apps.dataFolders(bundleID: "com.valvesoftware.steam", names: ["Steam"], home: home).isEmpty)
        XCTAssertTrue(Apps.dataFolders(bundleID: "com.docker.docker", names: ["Docker"], home: home).isEmpty)
    }

    func testTargetsStartWithTheBundle() throws {
        let root = try makeTempDir(self)
        let home = try makeTempDir(self)
        let app = try makeApp(root, "Editor.app", id: "com.example.editor", name: "Editor")
        try write("x", to: home.appendingPathComponent("Library/Application Support/Editor/state"))
        let a = try XCTUnwrap(Apps.read(bundle: app, home: home))
        XCTAssertEqual(a.targets.first, ScanTarget(url: app))
        XCTAssertEqual(a.targets.count, 2)
    }
}
