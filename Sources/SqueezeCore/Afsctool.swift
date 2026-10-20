import Foundation

public enum SqueezeError: LocalizedError, Equatable {
    case toolMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolMissing: return "afsctool was not found. Download Squeeze again or run in Terminal: brew install afsctool"
        case .failed(let text): return text
        }
    }
}

/// Runs `afsctool`, the tool that does the actual APFS compression.
/// afsctool is GPL software by its own authors. The released Squeeze.app carries a copy built from its
/// published source in `Contents/Helpers` and runs it as a separate program; otherwise a Homebrew copy is used.
public enum Afsctool {
    public static let searchPaths = ["/opt/homebrew/bin/afsctool", "/usr/local/bin/afsctool", "/opt/local/bin/afsctool"]

    /// The copy inside the app bundle, if this is a built Squeeze.app that includes one.
    public static func bundled(in bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/afsctool")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// `SQUEEZE_AFSCTOOL` (for tests and development), then the bundled copy, then Homebrew and MacPorts.
    public static func locate(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let p = environment["SQUEEZE_AFSCTOOL"], FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        if let b = bundled(in: bundle) { return b }
        return searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Homebrew's `brew`, for installing afsctool when the app does not carry its own copy.
    public static func homebrew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Runs `brew install afsctool`. Returns the last lines of output on failure.
    public static func installWithHomebrew() throws {
        guard let brew = homebrew() else { throw SqueezeError.failed("Homebrew is not installed.") }
        let p = Process()
        p.executableURL = brew
        p.arguments = ["install", "afsctool"]
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["PATH"] = brew.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 || locate() == nil {
            let tail = String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: "\n")
            throw SqueezeError.failed(tail.isEmpty ? "brew exited with code \(p.terminationStatus)" : tail)
        }
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
