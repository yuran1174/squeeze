import Foundation

/// An installed Steam game, read from its `appmanifest_<id>.acf`.
public struct SteamApp: Equatable, Identifiable {
    public let appID: String
    public let name: String
    public let installDir: URL
    /// 4 = fully installed. Anything else means Steam is installing, updating, validating or moving it.
    public let stateFlags: Int
    public let buildID: String
    public let library: URL

    public var id: String { "steam:" + appID }
    public var manifest: URL { library.appendingPathComponent("steamapps/appmanifest_\(appID).acf") }
}

public enum Steam {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
    }

    /// Steam's own folder plus every library listed in `libraryfolders.vdf` (other disks, external drives).
    public static func libraries(root: URL = defaultRoot) -> [URL] {
        var libs = [root]
        let file = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: file, encoding: .utf8), let vdf = try? VDFParser.parse(text) {
            for e in vdf["libraryfolders"]?.entries ?? [] {
                if let path = e.value["path"]?.string {
                    libs.append(URL(fileURLWithPath: path))
                } else if Int(e.key) != nil, let path = e.value.string {
                    libs.append(URL(fileURLWithPath: path)) // old format: "1" "/Volumes/Games/Steam"
                }
            }
        }
        var seen = Set<String>()
        return libs.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func parseManifest(_ text: String, library: URL) -> SteamApp? {
        guard let vdf = try? VDFParser.parse(text), let st = vdf["AppState"],
              let appID = st["appid"]?.string, let dir = st["installdir"]?.string, !dir.isEmpty,
              !dir.contains("/"), dir != "..", dir != "."
        else { return nil }
        return SteamApp(
            appID: appID,
            name: st["name"]?.string ?? dir,
            installDir: library.appendingPathComponent("steamapps/common").appendingPathComponent(dir),
            stateFlags: Int(st["StateFlags"]?.string ?? "") ?? 0,
            buildID: st["buildid"]?.string ?? "",
            library: library
        )
    }

    /// Installed games whose folder exists, sorted by name. Skips Steam's shared redistributables.
    public static func installedApps(root: URL = defaultRoot) -> [SteamApp] {
        var apps: [SteamApp] = []
        for lib in libraries(root: root) {
            let dir = lib.appendingPathComponent("steamapps")
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.lastPathComponent.hasPrefix("appmanifest_") && f.pathExtension == "acf" {
                guard let text = try? String(contentsOf: f, encoding: .utf8),
                      let app = parseManifest(text, library: lib),
                      FileManager.default.fileExists(atPath: app.installDir.path)
                else { continue }
                apps.append(app)
            }
        }
        return apps
            .filter { $0.appID != "228980" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The manifest read again from disk: Steam rewrites it when an update starts or ends.
    public static func reload(_ app: SteamApp) -> SteamApp? {
        guard let text = try? String(contentsOf: app.manifest, encoding: .utf8) else { return nil }
        return parseManifest(text, library: app.library)
    }

    /// Steam is installing or updating the game right now: its files must not be touched.
    public static func isBusy(_ app: SteamApp) -> Bool {
        let current = reload(app) ?? app
        if current.stateFlags != 4 { return true }
        let downloading = app.library.appendingPathComponent("steamapps/downloading/\(app.appID)")
        if let items = try? FileManager.default.contentsOfDirectory(atPath: downloading.path), !items.isEmpty { return true }
        return false
    }
}
