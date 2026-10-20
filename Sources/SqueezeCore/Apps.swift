import Foundation

/// A folder to scan and compress. App data folders skip caches and databases: programs rewrite those all the time,
/// so compressing them saves nothing for long.
public struct ScanTarget: Equatable {
    public let url: URL
    public let skipVolatile: Bool

    public init(url: URL, skipVolatile: Bool = false) {
        self.url = url
        self.skipVolatile = skipVolatile
    }
}

/// An installed program and the folders that belong to it.
public struct InstalledApp: Equatable, Identifiable {
    public let bundleURL: URL
    public let bundleID: String?
    public let name: String
    public let fromAppStore: Bool
    /// The app's own files belong to the system (App Store apps, some installers): changing them needs an admin password.
    public let needsAdmin: Bool
    /// Data folders found for the app, besides the app itself.
    public let data: [ScanTarget]

    public var id: String { "app:" + (bundleID ?? bundleURL.path) }
    public var dataFolders: [URL] { data.map(\.url) }
    public var targets: [ScanTarget] { [ScanTarget(url: bundleURL)] + data }
}

public enum Apps {
    public static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// Big data that some programs keep outside `Application Support`. Paths starting with `~/` are in the home folder.
    static let extraFolders: [String: [String]] = [
        "com.apple.dt.Xcode": [
            "~/Library/Developer/Xcode/iOS DeviceSupport",
            "~/Library/Developer/Xcode/watchOS DeviceSupport",
            "~/Library/Developer/Xcode/tvOS DeviceSupport",
            "~/Library/Developer/Xcode/visionOS DeviceSupport",
            "~/Library/Developer/Xcode/macOS DeviceSupport",
        ],
        "com.google.android.studio": ["~/Library/Android/sdk"],
        "com.epicgames.EpicGamesLauncher": ["/Users/Shared/Epic Games"],
    ]

    /// Programs whose data is listed separately or must not be touched.
    static let noDataFolders: Set<String> = [
        "com.valvesoftware.steam", // games are separate rows; the rest is Steam's own database
        "com.docker.docker", // virtual machine disk
    ]

    static func expand(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix("~/") ? home + path.dropFirst(1) : path
    }

    /// Installed programs in `roots`, including ones in subfolders (`/Applications/Adobe Photoshop 2025/…`), sorted by name.
    public static func installed(roots: [URL] = defaultRoots, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 excludingBundleIDs: Set<String> = [Bundle.main.bundleIdentifier ?? ""]) -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for root in roots {
            for bundle in findBundles(in: root, depth: 3) {
                guard let app = read(bundle: bundle, home: home) else { continue }
                if let id = app.bundleID, excludingBundleIDs.contains(id) { continue }
                guard seen.insert(app.id).inserted else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `.app` bundles in a folder; does not look inside bundles and skips symbolic links (Safari in /Applications is one).
    static func findBundles(in folder: URL, depth: Int) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard depth > 0, let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for e in entries.sorted(by: { $0.path < $1.path }) {
            guard let v = try? e.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true, v.isDirectory == true else { continue }
            if e.pathExtension == "app" {
                out.append(e)
            } else if v.isPackage != true {
                out += findBundles(in: e, depth: depth - 1)
            }
        }
        return out
    }

    public static func read(bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstalledApp? {
        let contents = bundle.appendingPathComponent("Contents")
        guard FileManager.default.fileExists(atPath: contents.path) else { return nil }
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String
        let fallback = bundle.deletingPathExtension().lastPathComponent
        let name = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fallback
        return InstalledApp(
            bundleURL: bundle,
            bundleID: bundleID,
            name: name,
            fromAppStore: FileManager.default.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path),
            needsAdmin: !FileManager.default.isWritableFile(atPath: contents.path),
            data: dataFolders(bundleID: bundleID, names: [name, fallback], home: home)
        )
    }

    /// `~/Library/Application Support/<bundle id or name>` (caches and databases inside are skipped)
    /// and the known extras (SDKs, game installs; scanned whole). Only folders that exist.
    /// Sandboxed apps keep data in `~/Library/Containers`, which macOS protects; those are left alone.
    public static func dataFolders(bundleID: String?, names: [String], home: URL) -> [ScanTarget] {
        if let id = bundleID, noDataFolders.contains(id) { return [] }
        let support = home.appendingPathComponent("Library/Application Support")
        var candidates: [ScanTarget] = []
        if let id = bundleID, !id.isEmpty { candidates.append(ScanTarget(url: support.appendingPathComponent(id), skipVolatile: true)) }
        for n in names where !n.isEmpty && !n.contains("/") && n != "." && n != ".." {
            candidates.append(ScanTarget(url: support.appendingPathComponent(n), skipVolatile: true))
        }
        if let id = bundleID {
            candidates += (extraFolders[id] ?? []).map { ScanTarget(url: URL(fileURLWithPath: expand($0, home: home.path))) }
        }
        var seen = Set<String>()
        return candidates.filter { t in
            var isDir: ObjCBool = false
            let link = (try? t.url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            // the disk is usually case-insensitive: "Code" and "code" are one folder
            return !link && FileManager.default.fileExists(atPath: t.url.path, isDirectory: &isDir) && isDir.boolValue
                && seen.insert(t.url.standardizedFileURL.path.lowercased()).inserted
        }
    }
}
