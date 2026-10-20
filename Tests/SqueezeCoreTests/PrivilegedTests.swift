import XCTest
@testable import SqueezeCore

final class PrivilegedTests: XCTestCase {
    func testShellQuote() {
        XCTAssertEqual(PrivilegedJob.shellQuote("plain"), "'plain'")
        XCTAssertEqual(PrivilegedJob.shellQuote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(PrivilegedJob.shellQuote("$(rm -rf /) `x` \"q\""), #"'$(rm -rf /) `x` "q"'"#)
    }

    func testAppleScriptQuote() {
        XCTAssertEqual(PrivilegedJob.appleScriptQuote(#"a "b" \c"#), #""a \"b\" \\c""#)
    }

    /// Paths with quotes, spaces and $ go through the shell untouched.
    func testShellQuoteRoundTrip() throws {
        for s in ["/Applications/My App.app", "it's", "$HOME `id` \"x\"", "a\\b", "ünïcödé ✓"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf %s " + PrivilegedJob.shellQuote(s)]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            XCTAssertEqual(out, s)
        }
    }

    func testPrepareWritesBatches() throws {
        let dir = try makeTempDir(self)
        let files = (0..<3).map { FileItem(url: URL(fileURLWithPath: "/x/file \($0)"), size: Int64(10 * ($0 + 1))) }
        let job = try PrivilegedJob.prepare([Array(files[0..<2]), [files[2]]], in: dir)
        XCTAssertEqual(job.batchBytes, [30, 30])
        XCTAssertEqual(job.totalBytes, 60)
        let first = try Data(contentsOf: job.dir.appendingPathComponent("batch-00001"))
        XCTAssertEqual(first, Data("/x/file 0\0/x/file 1\0".utf8))
        PrivilegedJob.cleanup(job)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.dir.path))
    }

    /// A stand-in for afsctool that records its arguments.
    private func fakeTool(in dir: URL, sleep: Double = 0) throws -> (URL, URL) {
        let log = dir.appendingPathComponent("calls.txt")
        let tool = dir.appendingPathComponent("fake-afsctool")
        try write("#!/bin/sh\nsleep \(sleep)\nfor a in \"$@\"; do printf '%s|' \"$a\" >> '\(log.path)'; done\necho >> '\(log.path)'\n", to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool, log)
    }

    private func run(_ command: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    private func waitFinished(_ job: PrivilegedJob.Job, timeout: Double = 20) -> PrivilegedJob.Progress {
        let end = Date().addingTimeInterval(timeout)
        var p = PrivilegedJob.progress(of: job)
        while !p.finished, Date() < end {
            Thread.sleep(forTimeInterval: 0.1)
            p = PrivilegedJob.progress(of: job)
        }
        return p
    }

    /// The job script itself, run without a password (as the current user).
    func testJobRunsEveryBatchInTheBackground() throws {
        let dir = try makeTempDir(self)
        let (tool, calls) = try fakeTool(in: dir)
        let files = ["/a/one", "/a/it's two", "/b/$three"].map { FileItem(url: URL(fileURLWithPath: $0), size: 5) }
        let job = try PrivilegedJob.prepare([Array(files[0..<2]), [files[2]]], in: dir)
        try run(PrivilegedJob.command(job, tool: tool, toolSHA: try PrivilegedJob.sha256(of: tool), arguments: ["-c", "-T", "LZFSE"]))
        let p = waitFinished(job)
        XCTAssertTrue(p.finished)
        XCTAssertNil(p.error)
        XCTAssertEqual(p.batchesDone, 2)
        XCTAssertEqual(p.bytesDone, 15)
        let lines = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines, ["-c|-T|LZFSE|/a/one|/a/it's two|", "-c|-T|LZFSE|/b/$three|"])
    }

    func testJobRefusesAToolThatChanged() throws {
        let dir = try makeTempDir(self)
        let (tool, calls) = try fakeTool(in: dir)
        let job = try PrivilegedJob.prepare([[FileItem(url: URL(fileURLWithPath: "/a"), size: 1)]], in: dir)
        try run(PrivilegedJob.command(job, tool: tool, toolSHA: String(repeating: "0", count: 64), arguments: ["-c"]))
        let p = waitFinished(job)
        XCTAssertTrue(p.finished)
        XCTAssertNotNil(p.error)
        XCTAssertEqual(p.batchesDone, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
    }

    func testJobStopsBetweenBatches() throws {
        let dir = try makeTempDir(self)
        let (tool, _) = try fakeTool(in: dir, sleep: 0.5)
        let batches = (0..<10).map { [FileItem(url: URL(fileURLWithPath: "/f\($0)"), size: 1)] }
        let job = try PrivilegedJob.prepare(batches, in: dir)
        try run(PrivilegedJob.command(job, tool: tool, toolSHA: try PrivilegedJob.sha256(of: tool), arguments: ["-c"]))
        Thread.sleep(forTimeInterval: 0.7)
        PrivilegedJob.requestStop(job)
        let p = waitFinished(job)
        XCTAssertTrue(p.finished)
        XCTAssertGreaterThanOrEqual(p.batchesDone, 1)
        XCTAssertLessThan(p.batchesDone, 10)
    }

    func testBlockedByMacOSFromLog() {
        var p = PrivilegedJob.Progress()
        XCTAssertFalse(p.blockedByMacOS)
        p.log = "/Applications/X.app/Contents/Info.plist: Operation not permitted"
        XCTAssertTrue(p.blockedByMacOS)
    }

    func testAppleScriptHasPromptAndAdmin() {
        let s = PrivilegedJob.appleScript(command: "echo 'hi'", prompt: "Need \"rights\"")
        XCTAssertTrue(s.hasPrefix("do shell script \"echo 'hi'\""))
        XCTAssertTrue(s.contains(#"with prompt "Need \"rights\"""#))
        XCTAssertTrue(s.hasSuffix("with administrator privileges"))
    }

    func testProbe() throws {
        let dir = try makeTempDir(self)
        let file = try write(Data(count: 1), to: dir.appendingPathComponent("f"))
        XCTAssertEqual(Access.probe(file), .allowed)
        // the probe leaves nothing behind
        XCTAssertEqual(getxattr(file.path, Access.probeName, nil, 0, 0, 0), -1)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        XCTAssertEqual(Access.probe(file), .needsAdmin)
    }
}
