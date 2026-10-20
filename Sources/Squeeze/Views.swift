import AppKit
import SqueezeCore
import SwiftUI
import UniformTypeIdentifiers

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
            if let note = model.notes["_"] {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            if showSettings { SettingsPanel() } else { ItemList() }
            Divider()
            HStack(spacing: 12) {
                Button("Add Folder…") { model.addFolder() }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Scan again")
                Spacer()
                Button { showSettings.toggle() } label: {
                    Image(systemName: showSettings ? "list.bullet" : "gearshape")
                }
                .help(showSettings ? "Back to the list" : "Settings")
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 420)
        .onAppear { model.refreshIfStale() }
    }
}

struct ItemList: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if model.items.isEmpty {
                EmptyState()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.folders.isEmpty {
                            ForEach(model.folders) { ItemRow(item: $0) }
                        } else {
                            Text("Add folders with large files you rarely change. Squeeze shows how much space compression would free before changing anything.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.suggestions.isEmpty {
                            Text("Found automatically")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                            ForEach(model.suggestions) { ItemRow(item: $0) }
                        }
                    }
                }
                .frame(height: min(CGFloat(model.items.count) * 78 + (model.suggestions.isEmpty ? 0 : 24) + (model.folders.isEmpty ? 40 : 0), 460))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .opacity(dropTargeted ? 1 : 0)
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
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Free disk space without deleting anything")
                .font(.callout.weight(.medium))
            Text("Choose a folder. Squeeze estimates how much APFS compression would save; files stay where they are and open as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose a Folder…") { model.addFolder() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("or drop a folder here")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: Item

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: item.steamApp != nil ? "gamecontroller" : "folder")
                    .foregroundStyle(.secondary)
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
                if item.steamApp != nil {
                    Text("Steam").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                actions
            }
            Text(model.summary(item))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let p = model.progress(item.id) {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                Text("\(Format.bytes(p.done)) of \(Format.bytes(p.total))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.activity[item.id] == .decompressing {
                ProgressView().progressViewStyle(.linear)
            }
            if let note = model.notes[item.id] {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .contextMenu {
            Button("Show in Finder") { model.reveal(item) }
            if item.steamApp == nil {
                Button("Remove from List") { model.remove(item) }
            } else {
                Button("Hide Steam Games") { model.settings.suggestSteam = false }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if model.progress(item.id) != nil {
            Button("Stop") { model.stop(item) }
        } else if model.activity[item.id] == .decompressing {
            Text("Decompressing…").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                if model.canCompress(item) {
                    Button("Compress") { model.compress(item) }
                }
                if model.canDecompress(item) {
                    Button("Decompress") { model.decompress(item) }
                }
            }
            .controlSize(.small)
        }
    }
}

struct SettingsPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Keep folders compressed", isOn: $model.settings.autoRecompress)
            Text("Every 30 minutes Squeeze checks folders that are already compressed and compresses new files, for example after an app or game update.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Only when plugged in", isOn: $model.settings.requireACPower)
            Stepper("Only after \(model.settings.idleMinutes) min without input", value: $model.settings.idleMinutes, in: 0 ... 120, step: 5)
            Stepper("Only when \(model.settings.minNewMB) MB or more are new", value: $model.settings.minNewMB, in: 10 ... 5000, step: 50)
            Toggle("Show Steam games automatically", isOn: $model.settings.suggestSteam)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Divider()
            Text("Recent").font(.subheadline.weight(.semibold))
            if model.settings.history.isEmpty {
                Text("Nothing yet").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(model.settings.history.prefix(8).enumerated()), id: \.offset) { _, entry in
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
