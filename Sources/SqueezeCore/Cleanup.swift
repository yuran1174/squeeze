import Foundation

/// One thing the cleanup engine would remove.
public struct CleanupItem: Equatable, Identifiable {
    public let path: String
    /// nil when the engine could not measure it.
    public let bytes: Int64?
    public let count: Int
    /// Already counted under this parent row (removing the parent removes it too).
    public let coveredBy: String?

    public var id: String { path }

    public init(path: String, bytes: Int64?, count: Int = 1, coveredBy: String? = nil) {
        self.path = path
        self.bytes = bytes
        self.count = count
        self.coveredBy = coveredBy
    }
}

public struct CleanupSection: Equatable, Identifiable {
    public let name: String
    public var items: [CleanupItem]

    public var id: String { name }
    /// Rows that stand on their own (not inside another row).
    public var topItems: [CleanupItem] { items.filter { $0.coveredBy == nil } }
    public var bytes: Int64 { topItems.compactMap(\.bytes).reduce(0, +) }
}

public enum CleanupError: LocalizedError, Equatable {
    case engineMissing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .engineMissing: return "The cleanup engine is not included in this copy of Squeeze. Download Squeeze from its Releases page."
        case .failed(let text): return text
        }
    }
}

/// Runs the cleanup engine (Mole's `mo clean`, GPL-3, shipped in Resources/CleanupEngine) as a separate program.
/// See third_party/mole/README.md.
public enum CleanupEngine {
    /// `SQUEEZE_CLEANUP_ENGINE` (a folder with bin/clean.sh; for tests and development), then the app bundle.
    public static func locate(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [URL] = []
        if let dir = environment["SQUEEZE_CLEANUP_ENGINE"] { candidates.append(URL(fileURLWithPath: dir)) }
        candidates.append(bundle.bundleURL.appendingPathComponent("Contents/Resources/CleanupEngine"))
        return candidates
            .map { $0.appendingPathComponent("bin/clean.sh") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Never empty the Trash unless the user ticks it: deleting from there cannot be undone.
    public static func isTrash(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        path == home + "/.Trash" || path.hasPrefix(home + "/.Trash/")
    }

    // MARK: - preview file

    /// "1.23GB", "5.4MB", "12KB", "5B" (decimal units, as the engine prints them).
    public static func parseSize(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where t.hasSuffix(suffix) {
            guard let n = Double(t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return Int64((n * factor).rounded())
        }
        return nil
    }

    /// Reads the engine's preview: `=== Section ===` headers and `path  # 1.2GB, 5 items, counted under …` rows.
    public static func parsePreview(_ text: String) -> [CleanupSection] {
        var sections: [CleanupSection] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("=== "), line.hasSuffix(" ==="), line.count > 8 {
                let name = String(line.dropFirst(4).dropLast(4))
                if !sections.contains(where: { $0.name == name }) { sections.append(CleanupSection(name: name, items: [])) }
                continue
            }
            guard line.hasPrefix("/"), let sep = line.range(of: "  # ", options: .backwards) else { continue }
            let path = String(line[..<sep.lowerBound])
            var meta = String(line[sep.upperBound...])
            var coveredBy: String?
            if let r = meta.range(of: ", counted under ") {
                coveredBy = String(meta[r.upperBound...])
                meta = String(meta[..<r.lowerBound])
            }
            let parts = meta.components(separatedBy: ", ")
            let bytes = parts.first.flatMap { $0 == "size unknown" ? nil : parseSize($0) }
            var count = 1
            for p in parts.dropFirst() where p.hasSuffix(" items") {
                count = Int(p.dropLast(6)) ?? 1
            }
            if sections.isEmpty { sections.append(CleanupSection(name: "Other", items: [])) }
            sections[sections.count - 1].items.append(CleanupItem(path: path, bytes: bytes, count: count, coveredBy: coveredBy))
        }
        return sections.filter { !$0.items.isEmpty }
    }

    /// Section name from a progress line (`➤ Browsers`), colors removed.
    public static func sectionTitle(fromOutputLine line: String) -> String? {
        let clean = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard clean.hasPrefix("➤ ") else { return nil }
        return String(clean.dropFirst(2))
    }

    // MARK: - running

    public struct Outcome {
        public let status: Int32
        /// The last lines the engine printed.
        public let outputTail: String
        public let cancelled: Bool
    }

    /// Runs `clean.sh` (preview with `dryRun`). `keep` are paths to protect this time (what the user unticked).
    /// The engine runs without a terminal, so it never asks for a password and skips system-wide caches.
    /// `onLine` gets every output line; `isCancelled` is checked a few times a second and interrupts the engine.
    public static func run(engine: URL, dryRun: Bool, keep: [String], workDir: URL, previewFile: URL? = nil,
                           onLine: @escaping (String) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }) throws -> Outcome {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let keepFile = workDir.appendingPathComponent("keep.txt")
        let safeKeep = keep.filter { $0.hasPrefix("/") && !$0.contains("\n") }
        try (safeKeep.joined(separator: "\n") + "\n").write(to: keepFile, atomically: true, encoding: .utf8)

        // its own process group, so Stop reaches the engine and whatever it is running (du, find), like Ctrl-C
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "setpgrp(0, 0); exec @ARGV or die", "/bin/bash", engine.path] + (dryRun ? ["--dry-run"] : [])
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["MOLE_EXTRA_WHITELIST_FILE"] = keepFile.path
        env["MOLE_PREVIEW_FILE"] = (previewFile ?? workDir.appendingPathComponent("preview.txt")).path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env.removeValue(forKey: "SQUEEZE_CLEANUP_ENGINE")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let lock = NSLock()
        var buffer = Data()
        var tail: [String] = []
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock()
            buffer.append(chunk)
            var lines: [String] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            tail = Array((tail + lines).suffix(12))
            lock.unlock()
            lines.forEach(onLine)
        }
        try p.run()
        var cancelled = false
        var cancelledAt = Date.distantFuture
        var escalation = 0
        while p.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            let group = -p.processIdentifier
            if !cancelled, isCancelled() {
                cancelled = true
                cancelledAt = Date()
                kill(group, SIGINT) // the engine stops cleanly on SIGINT
            } else if cancelled {
                // it should be gone in a moment; if not, insist
                let waited = Date().timeIntervalSince(cancelledAt)
                if escalation == 0, waited > 10 { kill(group, SIGTERM); escalation = 1 }
                if escalation == 1, waited > 20 { kill(group, SIGKILL); escalation = 2 }
            }
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        buffer.append(rest)
        if !buffer.isEmpty { tail = Array((tail + [String(decoding: buffer, as: UTF8.self)]).suffix(12)) }
        let text = tail.joined(separator: "\n")
        lock.unlock()
        return Outcome(status: p.terminationStatus, outputTail: text, cancelled: cancelled)
    }

    /// Preview: what would be removed, by section.
    public static func preview(engine: URL, keep: [String] = [], workDir: URL,
                               onSection: @escaping (String) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }) throws -> [CleanupSection] {
        let file = workDir.appendingPathComponent("preview.txt")
        try? FileManager.default.removeItem(at: file)
        let outcome = try run(engine: engine, dryRun: true, keep: keep, workDir: workDir, previewFile: file,
                              onLine: { if let s = sectionTitle(fromOutputLine: $0) { onSection(s) } }, isCancelled: isCancelled)
        if outcome.cancelled { throw CleanupError.failed("Cancelled.") }
        guard outcome.status == 0, let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw CleanupError.failed(outcome.outputTail.isEmpty ? "The cleanup engine exited with code \(outcome.status)." : outcome.outputTail)
        }
        return parsePreview(text)
    }

    /// Paths the user left unticked: every top row of the plan that is not in `selected`.
    public static func keepList(plan: [CleanupSection], selected: Set<String>) -> [String] {
        plan.flatMap(\.topItems).map(\.path).filter { !selected.contains($0) }
    }
}
