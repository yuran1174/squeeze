import AppKit
import Foundation
import ServiceManagement
import SqueezeCore
import UserNotifications

/// Set from the UI, read by the background worker between batches.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// One row: a program (with its data folders), a Steam game, or a folder the user added.
struct Item: Identifiable, Equatable {
    enum Kind: Equatable {
        case app(InstalledApp)
        case steam(SteamApp)
        case folder
    }

    let id: String
    let name: String
    let kind: Kind
    /// The first one is the main folder (the app itself, the game, the folder).
    let targets: [ScanTarget]
    /// The files belong to the system: compressing asks for an admin password.
    let needsAdmin: Bool
    var stats: FolderStats?
    /// Bytes that compressing the remaining uncompressed files would free (estimate).
    var estimate: Int64?

    var url: URL { targets[0].url }

    var steamApp: SteamApp? {
        if case .steam(let app) = kind { return app }
        return nil
    }

    var app: InstalledApp? {
        if case .app(let app) = kind { return app }
        return nil
    }

    // for sorting the table; unknown values go last
    var sizeOnDisk: Int64 { stats?.allocatedBytes ?? -1 }
    var canFree: Int64 { estimate ?? -1 }
    var freed: Int64 { stats?.savedBytes ?? 0 }
}

enum Activity: Equatable {
    case scanning
    case compressing(done: Int64, total: Int64)
    case decompressing
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var items: [Item] = []
    @Published private(set) var activity: [String: Activity] = [:]
    /// Per item: why an action did not run, or an error. Key "_" is a general message.
    @Published var notes: [String: String] = [:]
    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.suggestSteam != oldValue.suggestSteam { reload() }
        }
    }
    @Published private(set) var toolAvailable = Afsctool.locate() != nil
    @Published private(set) var installingTool = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// macOS blocked changes to an app: the user has to turn on App Management for Squeeze.
    @Published var appManagementNeeded = false
    @Published private(set) var scanning = false
    let canInstallTool = Afsctool.homebrew() != nil

    /// Opens the main window; set by the menu bar label, which can reach SwiftUI's openWindow.
    var openMainWindow: (() -> Void)?

    private var stops: [String: StopFlag] = [:]
    private var scanTask: Task<Void, Never>?
    private var timer: Timer?
    private var autoRunning = false
    private var lastScan = Date.distantPast

    private init() {
        settings = Settings.load()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.autoPass() }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            self?.autoPass()
        }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    // MARK: - list

    var totalSaved: Int64 { items.map(\.freed).reduce(0, +) }

    /// Items that are mostly compressed: what the menu bar shows.
    var compressedItems: [Item] {
        items.filter { ($0.stats?.compressedShare ?? 0) >= 0.5 && $0.freed > 0 }.sorted { $0.freed > $1.freed }
    }

    var busyItems: [Item] { items.filter { isBusy($0.id) } }

    /// Programs, Steam games and the user's folders; known numbers stay on screen while everything is rescanned.
    func reload() {
        toolAvailable = Afsctool.locate() != nil
        var list: [Item] = Apps.installed().map { app in
            Item(id: app.id, name: app.name, kind: .app(app), targets: app.targets, needsAdmin: app.needsAdmin)
        }
        if settings.suggestSteam {
            list += Steam.installedApps().map {
                Item(id: $0.id, name: $0.name, kind: .steam($0), targets: [ScanTarget(url: $0.installDir)], needsAdmin: false)
            }
        }
        list += settings.customFolders.map { path in
            let url = URL(fileURLWithPath: path)
            return Item(id: "folder:" + path, name: url.lastPathComponent, kind: .folder, targets: [ScanTarget(url: url)], needsAdmin: false)
        }
        let old = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        items = list.map { item in
            var i = item
            i.stats = old[item.id]?.stats
            i.estimate = old[item.id]?.estimate
            return i
        }
        scan(items.map(\.id))
    }

    /// Rescan when a window opens and the numbers are older than a few minutes.
    func refreshIfStale() {
        if Date().timeIntervalSince(lastScan) > 5 * 60 { reload() }
    }

    /// Sizes first for everything (quick), then estimates, biggest first (they read file contents).
    private func scan(_ ids: [String]) {
        scanTask?.cancel()
        lastScan = Date()
        let targets = items.filter { ids.contains($0.id) && !isBusy($0.id) }.map { ($0.id, $0.targets) }
        scanning = true
        scanTask = Task { [weak self] in
            var pendingByID: [String: [FileItem]] = [:]
            for (id, folders) in targets {
                if Task.isCancelled { return }
                guard let model = self, !model.isBusy(id) else { continue }
                model.activity[id] = .scanning
                let (stats, pending) = await Task.detached(priority: .utility) {
                    Scanner.scan(folders, collectUncompressed: true)
                }.value
                if model.activity[id] == .scanning { model.activity[id] = nil }
                model.update(id) { $0.stats = stats }
                pendingByID[id] = pending
            }
            let order = pendingByID.sorted { a, b in a.value.reduce(0) { $0 + $1.size } > b.value.reduce(0) { $0 + $1.size } }
            for (id, pending) in order {
                if Task.isCancelled { return }
                let total = pending.reduce(Int64(0)) { $0 + $1.size }
                // small programs need a small sample; big ones up to 96 MB
                let sample = min(Int64(96 << 20), max(Int64(8 << 20), total / 50))
                let estimate = await Task.detached(priority: .utility) {
                    Estimator.estimateSavings(of: pending, sampleBytes: sample)
                }.value
                self?.update(id) { $0.estimate = estimate }
            }
            self?.scanning = false
        }
    }

    private func update(_ id: String, _ change: (inout Item) -> Void) {
        if let i = items.firstIndex(where: { $0.id == id }) { change(&items[i]) }
    }

    /// Compressing or decompressing (scanning does not count).
    func isBusy(_ id: String) -> Bool {
        switch activity[id] {
        case .compressing?, .decompressing?: return true
        default: return false
        }
    }

    func progress(_ id: String) -> (done: Int64, total: Int64)? {
        if case .compressing(let done, let total)? = activity[id] { return (done, total) }
        return nil
    }

    // MARK: - what a row shows

    private func worthCompressing(_ s: FolderStats) -> Int64 { max(20 << 20, s.logicalBytes / 200) }

    func canCompress(_ item: Item) -> Bool {
        guard toolAvailable, let s = item.stats, let e = item.estimate else { return false }
        return e >= worthCompressing(s)
    }

    func canDecompress(_ item: Item) -> Bool {
        guard toolAvailable, let s = item.stats else { return false }
        return s.compressedFiles > 0 && s.savedBytes > 0
    }

    /// "Compressed −40%", "≈ 3 GB", "Scanning…", or nothing worth doing.
    func freeText(_ item: Item) -> String {
        guard let s = item.stats else { return activity[item.id] == .scanning ? "Scanning…" : "" }
        var parts: [String] = []
        if s.logicalBytes > 0, s.savedBytes > s.logicalBytes / 100 {
            let pct = Int((Double(s.savedBytes) / Double(s.logicalBytes) * 100).rounded())
            parts.append("compressed −\(pct)%")
        }
        if let e = item.estimate {
            if e >= worthCompressing(s) { parts.append("≈ \(Format.bytes(e)) more") } else if parts.isEmpty { parts.append("little to gain") }
        } else {
            parts.append("estimating…")
        }
        return parts.joined(separator: ", ")
    }

    func summary(_ item: Item) -> String {
        guard let s = item.stats else { return activity[item.id] == .scanning ? "Scanning…" : "Not scanned yet" }
        return "\(Format.bytes(s.allocatedBytes)) on disk · " + freeText(item)
    }

    func subtitle(_ item: Item) -> String {
        switch item.kind {
        case .app(let app):
            var parts: [String] = []
            if app.fromAppStore { parts.append("App Store") }
            if !app.dataFolders.isEmpty { parts.append("+ \(app.dataFolders.count) data folder\(app.dataFolders.count == 1 ? "" : "s")") }
            if app.needsAdmin { parts.append("asks for password") }
            return parts.joined(separator: " · ")
        case .steam: return "Steam game"
        case .folder: return (item.url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    func historyText(_ e: HistoryEntry) -> String {
        let when = e.date.formatted(date: .abbreviated, time: .shortened)
        switch e.action {
        case .compress: return "freed \(Format.bytes(e.bytes)) · \(when)"
        case .auto: return "new files, freed \(Format.bytes(e.bytes)) · \(when)"
        case .decompress: return "decompressed, used \(Format.bytes(-e.bytes)) · \(when)"
        }
    }

    // MARK: - actions

    /// Why the item cannot be touched right now, if so.
    func blockedReason(_ item: Item) -> String? {
        if !toolAvailable { return "afsctool was not found" }
        if Machine.isRunning(inside: item.url) {
            return item.app != nil ? "\(item.name) is open. Quit it first." : "A program from this folder is running. Close it first."
        }
        if let app = item.steamApp, Steam.isBusy(app) { return "Steam is installing or updating it. Try again later." }
        return nil
    }

    /// Checks whether macOS lets Squeeze change the item. Returns nil when it must not go on.
    private func accessMode(_ item: Item) -> (admin: Bool, ok: Bool) {
        if item.needsAdmin { return (true, true) }
        guard let app = item.app else { return (false, true) }
        switch Access.probe(app: app.bundleURL) {
        case .allowed:
            appManagementNeeded = false
            return (false, true)
        case .needsAdmin:
            return (true, true)
        case .blockedByMacOS:
            appManagementNeeded = true
            notes[item.id] = "macOS does not let Squeeze change other programs yet. Turn on Squeeze in Privacy & Security → App Management."
            return (false, false)
        case .readOnly:
            notes[item.id] = "The disk is read-only."
            return (false, false)
        }
    }

    func compress(_ item: Item, auto: Bool = false) {
        guard !isBusy(item.id) else { return }
        if let reason = blockedReason(item) {
            notes[item.id] = reason
            return
        }
        let mode = accessMode(item)
        guard mode.ok else { return }
        if mode.admin && auto { return } // never ask for a password in the background
        notes[item.id] = nil
        let stop = StopFlag()
        stops[item.id] = stop
        activity[item.id] = .compressing(done: 0, total: item.stats?.uncompressedBytes ?? 0)
        if mode.admin {
            compressAsAdmin(item, stop: stop)
            return
        }
        let id = item.id, name = item.name, folders = item.targets, main = item.url, app = item.steamApp
        let report: @Sendable (Int64, Int64) -> Void = { [weak self] done, total in
            guard let model = self else { return }
            Task { @MainActor in
                if model.isBusy(id) { model.activity[id] = .compressing(done: done, total: total) }
            }
        }
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> (FolderStats, FolderStats, String?) in
                let (before, pending) = Scanner.scan(folders, collectUncompressed: true)
                let total = pending.reduce(Int64(0)) { $0 + $1.size }
                report(0, total)
                var failure: String?
                var lastCheck = Date.distantPast
                var blocked = false
                do {
                    try Afsctool.compress(pending, progress: { report($0, total) }, shouldStop: {
                        if stop.isSet { return true }
                        // the program was started or Steam began an update: stop between batches
                        if Date().timeIntervalSince(lastCheck) > 5 {
                            lastCheck = Date()
                            blocked = Machine.isRunning(inside: main) || (app.map(Steam.isBusy) ?? false)
                        }
                        return blocked
                    })
                } catch {
                    failure = error.localizedDescription
                }
                if blocked { failure = "Stopped: the program was opened or Steam began an update." }
                let (after, _) = Scanner.scan(folders)
                return (before, after, failure)
            }.value
            self?.finish(id: id, name: name, action: auto ? .auto : .compress, before: outcome.0, after: outcome.1, failure: outcome.2)
        }
    }

    /// System-owned files: one admin password, then a root job that Squeeze watches through its job folder.
    private func compressAsAdmin(_ item: Item, stop: StopFlag) {
        let id = item.id, name = item.name, folders = item.targets, main = item.url
        Task { [weak self] in
            let (before, pending) = await Task.detached(priority: .utility) {
                Scanner.scan(folders, collectUncompressed: true)
            }.value
            guard let model = self else { return }
            let batches = Afsctool.batches(pending)
            model.runAdminJob(id: id, name: name, folders: folders, main: main, before: before, batches: batches,
                              arguments: ["-c", "-T", "LZFSE"], action: .compress, stop: stop,
                              prompt: "Squeeze needs an administrator password to compress “\(name)”, which belongs to the system.")
        }
    }

    private func runAdminJob(id: String, name: String, folders: [ScanTarget], main: URL, before: FolderStats, batches: [[FileItem]],
                             arguments: [String], action: HistoryEntry.Action, stop: StopFlag, prompt: String) {
        guard !batches.isEmpty else {
            finish(id: id, name: name, action: action, before: before, after: before, failure: nil)
            return
        }
        guard let tool = Afsctool.locate() else {
            finish(id: id, name: name, action: action, before: before, after: before, failure: SqueezeError.toolMissing.localizedDescription)
            return
        }
        let job: PrivilegedJob.Job
        let sha: String
        do {
            job = try PrivilegedJob.prepare(batches)
            sha = try PrivilegedJob.sha256(of: tool)
        } catch {
            finish(id: id, name: name, action: action, before: before, after: before, failure: error.localizedDescription)
            return
        }
        let command = PrivilegedJob.command(job, tool: tool, toolSHA: sha, arguments: arguments)
        var error: NSDictionary?
        NSAppleScript(source: PrivilegedJob.appleScript(command: command, prompt: prompt))?.executeAndReturnError(&error)
        if let error {
            PrivilegedJob.cleanup(job)
            let cancelled = (error[NSAppleScript.errorNumber] as? Int) == -128
            finish(id: id, name: name, action: action, before: before, after: before,
                   failure: cancelled ? "Cancelled." : (error[NSAppleScript.errorMessage] as? String ?? "Could not get administrator rights."))
            return
        }
        Task { [weak self] in
            var stopped = false
            var lastCheck = Date.distantPast
            var p = PrivilegedJob.progress(of: job)
            while !p.finished {
                try? await Task.sleep(nanoseconds: 500_000_000)
                p = PrivilegedJob.progress(of: job)
                guard let model = self else { return }
                if action != .decompress, model.isBusy(id) {
                    model.activity[id] = .compressing(done: p.bytesDone, total: job.totalBytes)
                }
                if !stopped, Date().timeIntervalSince(lastCheck) > 5 || stop.isSet {
                    lastCheck = Date()
                    if stop.isSet || Machine.isRunning(inside: main) {
                        PrivilegedJob.requestStop(job)
                        stopped = true
                    }
                }
            }
            let after = await Task.detached(priority: .utility) { Scanner.scan(folders).0 }.value
            PrivilegedJob.cleanup(job)
            guard let model = self else { return }
            var failure = p.error
            if failure == nil, p.blockedByMacOS, after.allocatedBytes >= before.allocatedBytes {
                model.appManagementNeeded = true
                failure = "macOS blocked the changes. Turn on Squeeze in Privacy & Security → App Management, then try again."
            }
            if failure == nil, stopped, !stop.isSet { failure = "Stopped: the program was opened." }
            model.finish(id: id, name: name, action: action, before: before, after: after, failure: failure)
        }
    }

    func stop(_ item: Item) {
        stops[item.id]?.set()
        notes[item.id] = "Stopping after the current batch…"
    }

    func decompress(_ item: Item) {
        guard !isBusy(item.id) else { return }
        if let reason = blockedReason(item) {
            notes[item.id] = reason
            return
        }
        let need = item.stats?.savedBytes ?? 0
        if let free = Scanner.availableSpace(at: item.url), need + (2 << 30) > free {
            notes[item.id] = "Not enough free space: decompressing needs \(Format.bytes(need)), \(Format.bytes(free)) is free."
            return
        }
        let mode = accessMode(item)
        guard mode.ok else { return }
        notes[item.id] = nil
        activity[item.id] = .decompressing
        let id = item.id, name = item.name, folders = item.targets
        if mode.admin {
            let before = item.stats ?? FolderStats()
            let batch = folders.map { FileItem(url: $0.url, size: 0) }
            runAdminJob(id: id, name: name, folders: folders, main: item.url, before: before, batches: [batch],
                        arguments: ["-d"], action: .decompress, stop: StopFlag(),
                        prompt: "Squeeze needs an administrator password to decompress “\(name)”, which belongs to the system.")
            return
        }
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> (FolderStats, FolderStats, String?) in
                let (before, _) = Scanner.scan(folders)
                var failure: String?
                for f in folders {
                    do { try Afsctool.decompress(f.url) } catch { failure = error.localizedDescription }
                }
                let (after, _) = Scanner.scan(folders)
                return (before, after, failure)
            }.value
            self?.finish(id: id, name: name, action: .decompress, before: outcome.0, after: outcome.1, failure: outcome.2)
        }
    }

    private func finish(id: String, name: String, action: HistoryEntry.Action, before: FolderStats, after: FolderStats, failure: String?) {
        activity[id] = nil
        stops[id] = nil
        let freed = before.allocatedBytes - after.allocatedBytes
        if let failure { notes[id] = failure } else if notes[id]?.hasPrefix("Stopping") == true { notes[id] = nil }
        if action == .decompress {
            settings.baselines[id] = nil
        } else {
            settings.baselines[id] = after.uncompressedBytes
        }
        if freed != 0 { settings.record(HistoryEntry(name: name, action: action, bytes: freed)) }
        if action == .auto, freed > 0 { notify("\(name): freed \(Format.bytes(freed)) by compressing new files") }
        update(id) {
            $0.stats = after
            $0.estimate = nil
        }
        scan([id])
        if action == .auto {
            autoRunning = false
            autoPass()
        }
    }

    // MARK: - background

    /// Keeps compressed things compressed: when enough new uncompressed data has appeared
    /// in a mostly compressed item (an app or game update, new files), compress it. One item at a time.
    /// Items that need an admin password are never done in the background.
    func autoPass() {
        guard settings.autoRecompress, toolAvailable, !autoRunning, !activity.keys.contains(where: isBusy) else { return }
        if settings.requireACPower, !Machine.onACPower { return }
        if Machine.idleSeconds < Double(settings.idleMinutes * 60) { return }
        autoRunning = true
        let targets = items.filter { !$0.needsAdmin && ($0.stats?.compressedShare ?? 0) >= 0.5 }.map { ($0.id, $0.targets) }
        Task { [weak self] in
            for (id, folders) in targets {
                let stats = await Task.detached(priority: .background) { Scanner.scan(folders).0 }.value
                guard let model = self else { return }
                model.update(id) { $0.stats = stats }
                guard let item = model.items.first(where: { $0.id == id }), model.needsRecompression(item, stats) else { continue }
                guard model.blockedReason(item) == nil else { continue }
                if let app = item.app, Access.probe(app: app.bundleURL) != .allowed { continue }
                model.compress(item, auto: true) // finish() continues with the next item
                return
            }
            self?.autoRunning = false
        }
    }

    func needsRecompression(_ item: Item, _ s: FolderStats) -> Bool {
        let base = settings.baselines[item.id] ?? 0
        return s.compressedShare >= 0.5 && s.uncompressedBytes - base >= Int64(settings.minNewMB) << 20
    }

    private func notify(_ text: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Squeeze"
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - folders and settings

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with large files you rarely change: old projects, SDKs, archives…"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// Adds folders from the open panel or dropped from Finder. System and cloud folders are refused.
    func add(_ urls: [URL]) {
        var refused: [String] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let path = url.standardizedFileURL.path
            if Settings.isProtected(path) {
                refused.append(url.lastPathComponent)
            } else if !settings.customFolders.contains(path) {
                settings.customFolders.append(path)
            }
        }
        notes["_"] = refused.isEmpty ? nil : "Not added (system or cloud folder; programs are listed on their own): " + refused.joined(separator: ", ")
        reload()
    }

    func remove(_ item: Item) {
        guard case .folder = item.kind, !isBusy(item.id) else { return }
        settings.customFolders.removeAll { $0 == item.url.path }
        settings.baselines[item.id] = nil
        reload()
    }

    func reveal(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openAppManagementSettings() {
        NSWorkspace.shared.open(Access.appManagementSettings)
    }

    /// For a build without its own afsctool: install it with Homebrew from the app.
    func installTool() {
        guard !installingTool else { return }
        installingTool = true
        notes["_"] = nil
        Task { [weak self] in
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try Afsctool.installWithHomebrew(); return nil } catch { return error.localizedDescription }
            }.value
            guard let model = self else { return }
            model.installingTool = false
            if let error { model.notes["_"] = "Could not install afsctool: \(error)" }
            model.reload()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            notes["_"] = "Open at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
