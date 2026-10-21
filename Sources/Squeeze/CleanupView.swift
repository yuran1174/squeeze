import AppKit
import SqueezeCore
import SwiftUI

/// The Clean Up tab: preview with the cleanup engine, choose, clean.
@MainActor
final class CleanupModel: ObservableObject {
    static let shared = CleanupModel()

    enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case cleaning
        case done(freed: Int64)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: [CleanupSection] = []
    @Published private(set) var currentSection: String?
    @Published var selected: Set<String> = []
    @Published var expanded: Set<String> = []

    let engine = CleanupEngine.locate()
    private var stop: StopFlag?
    private let home = NSHomeDirectory()

    private var workDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Squeeze/cleanup")
    }

    var totalBytes: Int64 { plan.map(\.bytes).reduce(0, +) }
    var selectedBytes: Int64 {
        plan.flatMap(\.topItems).filter { selected.contains($0.path) }.compactMap(\.bytes).reduce(0, +)
    }
    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    func scan() {
        guard let engine, !isBusy else { return }
        let flag = StopFlag()
        stop = flag
        phase = .scanning
        currentSection = nil
        let dir = workDir
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[CleanupSection], Error> in
                Result {
                    try CleanupEngine.preview(engine: engine, workDir: dir, onSection: { name in
                        Task { @MainActor in CleanupModel.shared.currentSection = name }
                    }, isCancelled: { flag.isSet })
                }
            }.value
            guard let model = self else { return }
            model.currentSection = nil
            switch result {
            case .success(let plan):
                model.plan = plan.sorted { $0.bytes > $1.bytes }
                // everything ticked except the Trash, which cannot be brought back
                model.selected = Set(plan.flatMap(\.topItems).map(\.path).filter { !CleanupEngine.isTrash($0, home: model.home) })
                model.phase = .ready
            case .failure(let error):
                model.phase = (error as? CleanupError) == .failed("Cancelled.") ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func clean() {
        guard let engine, phase == .ready, !selected.isEmpty else { return }
        let keep = CleanupEngine.keepList(plan: plan, selected: selected)
        let flag = StopFlag()
        stop = flag
        phase = .cleaning
        currentSection = nil
        let dir = workDir
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = selectedBytes
        Task { [weak self] in
            let freeBefore = Scanner.availableSpace(at: home) ?? 0
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CleanupEngine.Outcome, Error> in
                Result {
                    try CleanupEngine.run(engine: engine, dryRun: false, keep: keep, workDir: dir, onLine: { line in
                        if let name = CleanupEngine.sectionTitle(fromOutputLine: line) {
                            Task { @MainActor in CleanupModel.shared.currentSection = name }
                        }
                    }, isCancelled: { flag.isSet })
                }
            }.value
            guard let model = self else { return }
            model.currentSection = nil
            let freeAfter = Scanner.availableSpace(at: home) ?? freeBefore
            // free space moves for other reasons too; trust it only when it is in the expected range
            var freed = freeAfter - freeBefore
            if freed <= 0 || freed > expected * 2 + (1 << 30) { freed = expected }
            switch result {
            case .success(let outcome) where outcome.status == 0 || outcome.cancelled:
                if freed > 0 {
                    AppModel.shared.settings.record(HistoryEntry(name: "Clean up", action: .cleanup, bytes: freed))
                }
                model.plan = []
                model.selected = []
                model.phase = .done(freed: outcome.cancelled ? max(0, freeAfter - freeBefore) : freed)
            case .success(let outcome):
                model.phase = .failed(outcome.outputTail.isEmpty ? "The cleanup engine exited with code \(outcome.status)." : outcome.outputTail)
            case .failure(let error):
                model.phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { stop?.set() }

    // MARK: selection

    enum Tick { case on, off, mixed }

    func tick(_ section: CleanupSection) -> Tick {
        let paths = section.topItems.map(\.path)
        let n = paths.filter { selected.contains($0) }.count
        return n == 0 ? .off : (n == paths.count ? .on : .mixed)
    }

    func toggle(_ section: CleanupSection) {
        let paths = section.topItems.map(\.path)
        if tick(section) == .on { paths.forEach { selected.remove($0) } } else { paths.forEach { selected.insert($0) } }
    }

    func toggle(_ item: CleanupItem) {
        if selected.contains(item.path) { selected.remove(item.path) } else { selected.insert(item.path) }
    }

    func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    func isTrash(_ path: String) -> Bool { CleanupEngine.isTrash(path, home: home) }
}

struct CleanupView: View {
    @ObservedObject var model: CleanupModel
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            if model.engine == nil {
                message(icon: "exclamationmark.triangle", title: "The cleanup engine is missing",
                        text: CleanupError.engineMissing.localizedDescription)
            } else {
                switch model.phase {
                case .idle:
                    intro
                case .scanning:
                    working(title: "Looking for caches, logs and leftovers…", stopTitle: "Cancel")
                case .ready:
                    planList
                case .cleaning:
                    working(title: "Cleaning…", stopTitle: "Stop")
                case .done(let freed):
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.green)
                        Text(freed > 0 ? "Freed about \(Format.bytes(freed))" : "Done").font(.title2.weight(.semibold))
                        Text("Programs will rebuild their caches when they need them.")
                            .foregroundStyle(.secondary)
                        Button("Scan Again") { model.scan() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let text):
                    VStack(spacing: 12) {
                        message(icon: "exclamationmark.triangle", title: "Something went wrong", text: text)
                        Button("Scan Again") { model.scan() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            Text("Cleanup engine: Mole by tw93 (GPL-3.0), included unmodified except for two settings. Squeeze is not affiliated with Mole.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .onAppear {
            // SQUEEZE_AUTOSCAN=1 starts a preview right away (used by the CI screenshot)
            if ProcessInfo.processInfo.environment["SQUEEZE_AUTOSCAN"] == "1", model.phase == .idle { model.scan() }
        }
        .confirmationDialog("Remove \(Format.bytes(model.selectedBytes))?", isPresented: $confirm) {
            Button("Clean", role: .destructive) { model.clean() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.selected.contains(where: model.isTrash)
                 ? "Caches, logs and leftovers are deleted for good; programs rebuild what they need. The Trash will be emptied."
                 : "Caches, logs and leftovers are deleted for good; programs rebuild what they need. Your documents and settings are not touched.")
        }
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Clean up caches, logs and leftovers").font(.title2.weight(.semibold))
            Text("Squeeze looks for files that programs rebuild on their own: caches, old logs, leftovers of removed apps, developer tool caches. You see everything first and choose; nothing is removed until you press Clean.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button("Scan") { model.scan() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Text("System-wide caches that need an administrator password are not included.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func working(title: String, stopTitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).font(.headline)
            Text(model.currentSection ?? " ").foregroundStyle(.secondary)
            Button(stopTitle) { model.cancel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.orange)
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var planList: some View {
        VStack(spacing: 0) {
            if model.plan.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.green)
                    Text("Nothing to clean").font(.title3.weight(.semibold))
                    Button("Scan Again") { model.scan() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.plan) { section in
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expanded.contains(section.name) },
                            set: { if $0 { model.expanded.insert(section.name) } else { model.expanded.remove(section.name) } }
                        )) {
                            ForEach(section.topItems) { item in
                                HStack(spacing: 8) {
                                    TickBox(state: model.selected.contains(item.path) ? .on : .off) { model.toggle(item) }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(model.display(item.path)).lineLimit(1).truncationMode(.middle)
                                        if model.isTrash(item.path) {
                                            Text("Emptying the Trash cannot be undone").font(.caption).foregroundStyle(.orange)
                                        }
                                    }
                                    .help(item.path)
                                    Spacer()
                                    Text(item.bytes.map(Format.bytes) ?? "—").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                TickBox(state: model.tick(section)) { model.toggle(section) }
                                Text(section.name).fontWeight(.medium)
                                Text("\(section.topItems.count)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(Format.bytes(section.bytes)).monospacedDigit()
                            }
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text("Selected: \(Format.bytes(model.selectedBytes)) of \(Format.bytes(model.totalBytes))")
                    .monospacedDigit()
                Spacer()
                Button("Scan Again") { model.scan() }
                Button("Clean…") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct TickBox: View {
    let state: CleanupModel.Tick
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .foregroundStyle(state == .off ? Color.secondary : Color.accentColor)
                .font(.system(size: 14))
        }
        .buttonStyle(.plain)
    }
}
