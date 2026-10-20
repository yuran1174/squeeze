import CryptoKit
import Darwin
import Foundation

/// Can Squeeze change files in this folder right now?
public enum ModifyAccess: Equatable {
    case allowed
    /// The files belong to the system (App Store apps): an admin password is needed.
    case needsAdmin
    /// macOS refused: the "App Management" privacy setting protects other programs from being changed.
    case blockedByMacOS
    /// The disk is read-only.
    case readOnly
}

public enum Access {
    static let probeName = "io.github.yuran1174.squeeze.probe"

    /// Tries to set and remove a harmless extended attribute on `url`.
    /// macOS answers EPERM when App Management blocks changes to another app, EACCES when the file is not ours.
    public static func probe(_ url: URL) -> ModifyAccess {
        let value: [UInt8] = [49]
        if setxattr(url.path, probeName, value, value.count, 0, XATTR_NOFOLLOW) == 0 {
            removexattr(url.path, probeName, XATTR_NOFOLLOW)
            return .allowed
        }
        switch errno {
        case EPERM: return .blockedByMacOS
        case EACCES: return .needsAdmin
        case EROFS: return .readOnly
        default: return .allowed // let afsctool try and report
        }
    }

    /// For an app: probe a file inside the bundle (that is what App Management guards).
    public static func probe(app bundle: URL) -> ModifyAccess {
        probe(bundle.appendingPathComponent("Contents/Info.plist"))
    }

    /// System Settings → Privacy & Security → App Management.
    public static let appManagementSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
}

/// Runs afsctool as root, for files that belong to the system. One admin password per job.
///
/// The work is described by files in a job folder that Squeeze owns: `batch-NNNN` (NUL-separated paths).
/// The root shell copies afsctool to a private temporary folder, checks it is the same file Squeeze checked
/// (SHA-256), then processes the batches in the background, appending each finished batch name to `done`
/// and stopping when a `stop` file appears. `finished` marks the end; `error` and `log` explain problems.
public enum PrivilegedJob {
    public struct Job: Equatable {
        public let dir: URL
        public let batchBytes: [Int64]
        public var totalBytes: Int64 { batchBytes.reduce(0, +) }
    }

    public struct Progress: Equatable {
        public var batchesDone = 0
        public var bytesDone: Int64 = 0
        public var finished = false
        public var error: String?
        /// Last lines afsctool wrote to stderr.
        public var log = ""

        /// macOS blocked the changes (App Management), judging by afsctool's errors.
        public var blockedByMacOS: Bool { log.contains("Operation not permitted") }
    }

    /// Writes the batches into a new job folder.
    public static func prepare(_ batches: [[FileItem]], in parent: URL = FileManager.default.temporaryDirectory) throws -> Job {
        let dir = parent.appendingPathComponent("squeeze-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (i, batch) in batches.enumerated() {
            var data = Data()
            for f in batch {
                data.append(contentsOf: Array(f.url.path.utf8))
                data.append(0)
            }
            try data.write(to: dir.appendingPathComponent(String(format: "batch-%05d", i + 1)))
        }
        return Job(dir: dir, batchBytes: batches.map { $0.reduce(Int64(0)) { $0 + $1.size } })
    }

    /// Single-quoted for /bin/sh.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Inside an AppleScript string literal.
    public static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The /bin/sh command that starts the job in the background and returns at once.
    public static func command(_ job: Job, tool: URL, toolSHA: String, arguments: [String]) -> String {
        let j = shellQuote(job.dir.path)
        let args = arguments.map(shellQuote).joined(separator: " ")
        return """
        J=\(j); T=$(/usr/bin/mktemp -d /tmp/squeeze.XXXXXX) || exit 1; \
        /bin/cp \(shellQuote(tool.path)) "$T/afsctool" && /bin/chmod 755 "$T/afsctool"; \
        if [ "$(/usr/bin/shasum -a 256 "$T/afsctool" | /usr/bin/cut -d' ' -f1)" != \(shellQuote(toolSHA)) ]; then \
        echo 'afsctool changed on disk; download Squeeze again' > "$J/error"; /bin/rm -rf "$T"; /usr/bin/touch "$J/finished"; exit 0; fi; \
        ( for f in "$J"/batch-*; do [ -e "$J/stop" ] && break; \
        /usr/bin/xargs -0 "$T/afsctool" \(args) < "$f" >/dev/null 2>>"$J/log"; \
        echo "${f##*/}" >> "$J/done"; done; /bin/rm -rf "$T"; /usr/bin/touch "$J/finished" ) </dev/null >/dev/null 2>&1 &
        """
    }

    /// The AppleScript that runs `command` with an admin password prompt.
    public static func appleScript(command: String, prompt: String) -> String {
        "do shell script \(appleScriptQuote(command)) with prompt \(appleScriptQuote(prompt)) with administrator privileges"
    }

    public static func progress(of job: Job) -> Progress {
        var p = Progress()
        let done = (try? String(contentsOf: job.dir.appendingPathComponent("done"), encoding: .utf8)) ?? ""
        let names = Set(done.split(separator: "\n").map(String.init))
        p.batchesDone = names.count
        for (i, bytes) in job.batchBytes.enumerated() where names.contains(String(format: "batch-%05d", i + 1)) {
            p.bytesDone += bytes
        }
        p.finished = FileManager.default.fileExists(atPath: job.dir.appendingPathComponent("finished").path)
        p.error = (try? String(contentsOf: job.dir.appendingPathComponent("error"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let log = (try? String(contentsOf: job.dir.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        p.log = log.split(separator: "\n").suffix(5).joined(separator: "\n")
        return p
    }

    /// Asks the job to stop after the current batch.
    public static func requestStop(_ job: Job) {
        FileManager.default.createFile(atPath: job.dir.appendingPathComponent("stop").path, contents: Data())
    }

    public static func cleanup(_ job: Job) {
        try? FileManager.default.removeItem(at: job.dir)
    }
}
