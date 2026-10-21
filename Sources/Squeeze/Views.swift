import AppKit
import SqueezeCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - main window: the table of programs

struct ProgramsView: View {
    @EnvironmentObject var model: AppModel
    @State private var sortOrder = [KeyPathComparator(\Item.sizeOnDisk, order: .reverse)]
    @State private var search = ""
    @State private var selection: Item.ID?
    @State private var dropTargeted = false

    private var rows: [Item] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? model.items : model.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return list.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.toolAvailable { ToolMissingView().padding([.horizontal, .top], 12) }
            if model.appManagementNeeded { AppManagementBanner().padding([.horizontal, .top], 12) }
            if let note = model.notes["_"] {
                Text(note).font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 12)
            }
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { item in
                    NameCell(model: model, item: item)
                }
                .width(min: 220, ideal: 320)
                TableColumn("On disk", value: \.sizeOnDisk) { item in
                    Text(item.stats.map { Format.bytes($0.allocatedBytes) } ?? "…")
                        .monospacedDigit()
                        .foregroundStyle(item.stats == nil ? .secondary : .primary)
                }
                .width(min: 80, ideal: 90)
                TableColumn("Can free", value: \.canFree) { item in
                    Text(model.freeText(item))
                        .foregroundStyle(.secondary)
                }
                .width(min: 150, ideal: 210)
                TableColumn("") { item in
                    ActionCell(model: model, item: item)
                }
                .width(min: 150, ideal: 170)
            }
            .contextMenu(forSelectionType: Item.ID.self) { ids in
                if let id = ids.first, let item = model.items.first(where: { $0.id == id }) {
                    Button("Show in Finder") { model.reveal(item) }
                    if item.kind == .folder { Button("Remove from List") { model.remove(item) } }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .opacity(dropTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in model.add([url]) }
                    }
                }
                return true
            }
            Divider()
            HStack {
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text("Measuring programs…").foregroundStyle(.secondary)
                } else {
                    Text("\(model.items.count) items").foregroundStyle(.secondary)
                }
                Spacer()
                if model.totalSaved > 0 {
                    Text("Freed by Squeeze: \(Format.bytes(model.totalSaved))").fontWeight(.medium)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .searchable(text: $search, prompt: "Search programs")
        .toolbar {
            ToolbarItemGroup {
                Button { model.addFolder() } label: { Label("Add Folder…", systemImage: "folder.badge.plus") }
                    .help("Add any folder that is not a program")
                Button { model.reload() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                    .help("Measure everything again")
            }
        }
        .onAppear { model.refreshIfStale() }
    }
}

/// The window: Compress (programs table) and Clean Up (caches, logs, leftovers).
struct MainView: View {
    enum Tab: String, CaseIterable {
        case compress = "Compress"
        case cleanup = "Clean Up"
    }

    // SQUEEZE_START_TAB=cleanup opens the Clean Up tab (used by the CI screenshot)
    @State private var tab = ProcessInfo.processInfo.environment["SQUEEZE_START_TAB"] == "cleanup" ? Tab.cleanup : Tab.compress

    var body: some View {
        Group {
            switch tab {
            case .compress: ProgramsView()
            case .cleanup: CleanupView(model: CleanupModel.shared)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear {
            // a menu bar app gets a Dock icon and the app menu while its window is open
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Table cells are hosted outside the window's view tree on macOS and do not get environment objects,
/// so the model is passed in.
struct NameCell: View {
    @ObservedObject var model: AppModel
    let item: Item

    var body: some View {
        HStack(spacing: 8) {
            ItemIcon(item: item).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                let sub = model.subtitle(item)
                if let note = model.notes[item.id] {
                    Text(note).font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else if !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .help(item.targets.map { ($0.url.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n"))
    }
}

struct ItemIcon: View {
    let item: Item

    var body: some View {
        switch item.kind {
        case .app(let app):
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path)).resizable()
        case .steam:
            Image(systemName: "gamecontroller").font(.system(size: 16)).foregroundStyle(.secondary)
        case .folder:
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable()
        }
    }
}

struct ActionCell: View {
    @ObservedObject var model: AppModel
    let item: Item

    var body: some View {
        if let p = model.progress(item.id) {
            HStack(spacing: 6) {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: 70)
                Button("Stop") { model.stop(item) }.controlSize(.small)
            }
        } else if model.activity[item.id] == .decompressing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Decompressing…").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                if model.canCompress(item) {
                    Button(item.needsAdmin ? "Compress…" : "Compress") { model.compress(item) }
                        .buttonStyle(.borderedProminent)
                }
                if model.canDecompress(item) {
                    Button("Decompress") { model.decompress(item) }
                }
            }
            .controlSize(.small)
        }
    }
}

struct AppManagementBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow Squeeze to change programs").font(.headline)
                Text("macOS protects programs from being changed by other apps. Open Privacy & Security → App Management and turn on Squeeze, then press Compress again. Compression does not change what is inside the files.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Settings") { model.openAppManagementSettings() }
                    Button("Done") { model.appManagementNeeded = false }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - menu bar

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Squeeze").font(.headline)
                Spacer()
                if model.totalSaved > 0 {
                    Text("Freed \(Format.bytes(model.totalSaved))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !model.toolAvailable { ToolMissingView() }
            if showSettings {
                SettingsPanel()
            } else {
                MenuSummary()
            }
            Button {
                model.openMainWindow?()
            } label: {
                Text("Open Squeeze…").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Divider()
            HStack(spacing: 12) {
                Button { showSettings.toggle() } label: {
                    Label(showSettings ? "Back" : "Settings", systemImage: showSettings ? "chevron.left" : "gearshape")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// What is happening now and what is kept compressed.
struct MenuSummary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.busyItems) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.name).lineLimit(1)
                        Spacer()
                        if model.progress(item.id) != nil {
                            Button("Stop") { model.stop(item) }.controlSize(.small)
                        }
                    }
                    if let p = model.progress(item.id) {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            let kept = model.compressedItems.filter { !model.isBusy($0.id) }
            if kept.isEmpty && model.busyItems.isEmpty {
                Text("Nothing is compressed yet. Open Squeeze to see which programs take the most space.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !kept.isEmpty {
                Text("Kept compressed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(kept.prefix(6)) { item in
                    HStack {
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Text("−\(Format.bytes(item.freed))").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Keep programs compressed", isOn: $model.settings.autoRecompress)
            Text("Every 30 minutes Squeeze checks what is already compressed and compresses new files, for example after an update. Programs that ask for a password are not touched in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Only when plugged in", isOn: $model.settings.requireACPower)
            Stepper("Only after \(model.settings.idleMinutes) min without input", value: $model.settings.idleMinutes, in: 0 ... 120, step: 5)
            Stepper("Only when \(model.settings.minNewMB) MB or more are new", value: $model.settings.minNewMB, in: 10 ... 5000, step: 50)
            Toggle("Show Steam games", isOn: $model.settings.suggestSteam)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Divider()
            Text("Recent").font(.subheadline.weight(.semibold))
            if model.settings.history.isEmpty {
                Text("Nothing yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.settings.history.prefix(6).enumerated()), id: \.offset) { _, entry in
                HStack {
                    Text(entry.name).lineLimit(1)
                    Spacer()
                    Text(model.historyText(entry)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

/// Shown only for builds without their own afsctool (the released app carries one).
struct ToolMissingView: View {
    @EnvironmentObject var model: AppModel
    private let command = "brew install afsctool"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The compression tool is missing").font(.subheadline.weight(.semibold))
            Text(model.canInstallTool
                 ? "This copy of Squeeze does not include afsctool. Install it with Homebrew in one click."
                 : "This copy of Squeeze does not include afsctool. Download Squeeze from its Releases page, or install afsctool with Homebrew.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.canInstallTool {
                    Button(model.installingTool ? "Installing…" : "Install") { model.installTool() }
                        .disabled(model.installingTool)
                    if model.installingTool { ProgressView().controlSize(.small) }
                } else {
                    Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
                Spacer()
                Button("Check Again") { model.reload() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}
