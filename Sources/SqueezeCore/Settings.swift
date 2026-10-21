import Foundation

/// User settings and history, stored in `~/Library/Application Support/Squeeze/settings.json`.
public struct Settings: Codable, Equatable {
    /// Compress new files of already compressed games and folders after updates, in the background.
    public var autoRecompress = true
    /// Background work only when plugged in.
    public var requireACPower = true
    /// Background work only after this many minutes without input.
    public var idleMinutes = 5
    /// Background work only when at least this much new uncompressed data has appeared (MB).
    public var minNewMB = 100
    /// Folders added by the user.
    public var customFolders: [String] = []
    /// Also list installed Steam games, found automatically.
    public var suggestSteam = true
    /// Recent actions, newest first.
    public var history: [HistoryEntry] = []
    /// Uncompressed bytes left after the last compression, per item (files that do not compress stay as they are).
    /// Background work starts only when new data appears beyond this.
    public var baselines: [String: Int64] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        autoRecompress = try c.decodeIfPresent(Bool.self, forKey: .autoRecompress) ?? d.autoRecompress
        requireACPower = try c.decodeIfPresent(Bool.self, forKey: .requireACPower) ?? d.requireACPower
        idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? d.idleMinutes
        minNewMB = try c.decodeIfPresent(Int.self, forKey: .minNewMB) ?? d.minNewMB
        customFolders = try c.decodeIfPresent([String].self, forKey: .customFolders) ?? d.customFolders
        suggestSteam = try c.decodeIfPresent(Bool.self, forKey: .suggestSteam) ?? d.suggestSteam
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? d.history
        baselines = try c.decodeIfPresent([String: Int64].self, forKey: .baselines) ?? d.baselines
    }

    /// Paths Squeeze refuses to work on: system locations and whole volumes or the home folder itself.
    public static func isProtected(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = (path as NSString).standardizingPath
        if p == "/" || p == home || p == "/Volumes" || p == "/Users" { return true }
        if p.hasPrefix("/Volumes/"), p.split(separator: "/").count <= 2 { return true }
        // standardizingPath turns /private/var, /private/etc and /private/tmp into /var, /etc and /tmp
        for root in ["/System", "/usr", "/bin", "/sbin", "/private", "/var", "/etc", "/tmp", "/Library", "/Applications", "/opt", "/cores", "/dev"] {
            if p == root || p.hasPrefix(root + "/") { return true }
        }
        if p == home + "/Library" { return true }
        // iCloud Drive and other cloud folders: their sync engines manage these files
        for sub in ["Library/Mobile Documents", "Library/CloudStorage"] {
            let s = home + "/" + sub
            if p == s || p.hasPrefix(s + "/") { return true }
        }
        return false
    }

    public mutating func record(_ entry: HistoryEntry, keep: Int = 50) {
        history.insert(entry, at: 0)
        if history.count > keep { history.removeLast(history.count - keep) }
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Squeeze/settings.json")
    }

    public static func load(from url: URL = defaultURL) -> Settings {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let s = try? dec.decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    public func save(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(self).write(to: url, options: .atomic)
    }
}

public struct HistoryEntry: Codable, Equatable {
    public enum Action: String, Codable { case compress, decompress, auto, cleanup }
    public var date: Date
    public var name: String
    public var action: Action
    /// Disk space freed (negative for decompression).
    public var bytes: Int64

    public init(date: Date = Date(), name: String, action: Action, bytes: Int64) {
        self.date = date
        self.name = name
        self.action = action
        self.bytes = bytes
    }
}

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
