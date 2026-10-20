import Foundation

public enum SqueezeError: LocalizedError, Equatable {
    case toolMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing: return "afsctool is not installed. Run in Terminal: brew install afsctool"
        case .failed(let text): return text
        }
    }
}

/// Runs `afsctool` (Homebrew), the tool that does the actual APFS compression.
/// It is GPL software, so Squeeze does not bundle it: it calls the copy installed by Homebrew.
public enum Afsctool {
    public static let searchPaths = ["/opt/homebrew/bin/afsctool", "/usr/local/bin/afsctool", "/opt/local/bin/afsctool"]

    public static func locate() -> URL? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Files are compressed in small batches so progress can be shown and stopping never interrupts a file midway.
    public static func batches(_ files: [FileItem], maxFiles: Int = 64, maxBytes: Int64 = 256 << 20) -> [[FileItem]] {
        var out: [[FileItem]] = []
        var cur: [FileItem] = []
        var bytes: Int64 = 0
        for f in files {
            cur.append(f)
            bytes += f.size
            if cur.count >= maxFiles || bytes >= maxBytes {
                out.append(cur)
                cur = []
                bytes = 0
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    @discardableResult
    static func run(_ args: [String]) throws -> (status: Int32, output: String) {
        guard let tool = locate() else { throw SqueezeError.toolMissing }
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Compresses the files with LZFSE. `shouldStop` is checked before every batch
    /// (the user pressed Stop, the game was started, Steam began an update).
    /// Returns the bytes processed. Files afsctool cannot compress (in use, no permission) are left as they are.
    @discardableResult
    public static func compress(_ files: [FileItem], progress: (Int64) -> Void, shouldStop: () -> Bool) throws -> Int64 {
        guard locate() != nil else { throw SqueezeError.toolMissing }
        var done: Int64 = 0
        for batch in batches(files) {
            if shouldStop() { break }
            try run(["-c", "-T", "LZFSE"] + batch.map { $0.url.path })
            done += batch.reduce(Int64(0)) { $0 + $1.size }
            progress(done)
        }
        return done
    }

    /// Restores a folder to ordinary, uncompressed files.
    public static func decompress(_ folder: URL) throws {
        let r = try run(["-d", folder.path])
        if r.status != 0 {
            let tail = r.output.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw SqueezeError.failed(tail.isEmpty ? "afsctool exited with code \(r.status)" : tail)
        }
    }
}
