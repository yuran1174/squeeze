import Foundation

public struct FileItem: Equatable {
    public let url: URL
    public let size: Int64

    public init(url: URL, size: Int64) {
        self.url = url
        self.size = size
    }
}

/// What a folder looks like on disk.
public struct FolderStats: Equatable {
    public var files = 0
    public var compressedFiles = 0
    /// Size the files report to apps (what Finder calls "size").
    public var logicalBytes: Int64 = 0
    /// Space the files really take on disk.
    public var allocatedBytes: Int64 = 0
    /// Logical size of files that are not compressed yet.
    public var uncompressedBytes: Int64 = 0

    public init() {}

    public var savedBytes: Int64 { max(0, logicalBytes - allocatedBytes) }

    public static func + (a: FolderStats, b: FolderStats) -> FolderStats {
        var s = a
        s.files += b.files
        s.compressedFiles += b.compressedFiles
        s.logicalBytes += b.logicalBytes
        s.allocatedBytes += b.allocatedBytes
        s.uncompressedBytes += b.uncompressedBytes
        return s
    }

    /// Share of the data (by size) that is already compressed, 0…1.
    public var compressedShare: Double {
        logicalBytes > 0 ? Double(logicalBytes - uncompressedBytes) / Double(logicalBytes) : 0
    }
}

public enum Scanner {
    /// `UF_COMPRESSED` from `<sys/stat.h>`: the file is stored with APFS/HFS+ transparent compression.
    static let compressedFlag: UInt32 = 0x20

    public static func isCompressed(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return st.st_flags & compressedFlag != 0
    }

    /// Folder names programs keep rewriting (caches, browser storage, logs); skipped in app data folders.
    static let volatileFolders: Set<String> = [
        "cache", "caches", "cacheddata", "code cache", "gpucache", "shadercache", "grshadercache", "service worker",
        "indexeddb", "local storage", "session storage", "blob_storage", "databases", "crashpad", "logs", "log", "tmp", "temp",
    ]
    /// Database, log and lock files: rewritten all the time.
    static let volatileExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "sqlite-wal", "sqlite-shm", "db-wal", "db-shm", "wal", "shm", "ldb", "log", "lock", "tmp",
    ]

    public static func isVolatileFolder(_ name: String) -> Bool {
        let n = name.lowercased()
        return volatileFolders.contains(n) || n.contains("cache")
    }

    public static func isVolatileFile(_ name: String) -> Bool {
        volatileExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Several folders counted as one (an app and its data). Folders listed twice or inside each other are counted once.
    public static func scan(_ targets: [ScanTarget], collectUncompressed: Bool = false, isCancelled: () -> Bool = { false }) -> (FolderStats, [FileItem]) {
        var total = FolderStats()
        var pending: [FileItem] = []
        var done: [String] = []
        for t in targets {
            let p = t.url.standardizedFileURL.path
            if done.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { continue }
            done.append(p)
            let (s, items) = scan(t.url, skipVolatile: t.skipVolatile, collectUncompressed: collectUncompressed, isCancelled: isCancelled)
            total = total + s
            pending += items
        }
        return (total, pending)
    }

    /// Walks a folder (including hidden files and app bundles inside it; symbolic links are not followed).
    /// With `collectUncompressed`, also returns the regular files that are not compressed yet.
    /// With `skipVolatile`, caches, databases and logs are left out entirely.
    public static func scan(_ root: URL, skipVolatile: Bool = false, collectUncompressed: Bool = false, isCancelled: () -> Bool = { false }) -> (FolderStats, [FileItem]) {
        var stats = FolderStats()
        var pending: [FileItem] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return (stats, pending)
        }
        for case let url as URL in walker {
            if isCancelled() { break }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if skipVolatile {
                if v.isDirectory == true, isVolatileFolder(url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                if isVolatileFile(url.lastPathComponent) { continue }
            }
            guard v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            let allocated = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            stats.files += 1
            stats.logicalBytes += size
            stats.allocatedBytes += allocated
            if isCompressed(url.path) {
                stats.compressedFiles += 1
            } else {
                stats.uncompressedBytes += size
                if collectUncompressed, size > 0 { pending.append(FileItem(url: url, size: size)) }
            }
        }
        return (stats, pending)
    }

    /// Free space on the volume of `url`, for checking that decompression fits.
    public static func availableSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
