import AppKit
import SqueezeCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Squeeze").font(.headline)
                Spacer()
                Text("Saved \(Format.bytes(model.totalSaved))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

    var body: some View {
        if model.items.isEmpty {
            Text("No Steam games found. Add any folder with “Add Folder…”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.items) { ItemRow(item: $0) }
                }
            }
            .frame(height: min(CGFloat(model.items.count) * 78, 440))
        }
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
            Toggle("Keep compressed after updates", isOn: $model.settings.autoRecompress)
            Text("Every 30 minutes Squeeze checks games and folders that are already compressed and compresses files that updates have added.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Only when plugged in", isOn: $model.settings.requireACPower)
            Stepper("Only after \(model.settings.idleMinutes) min without input", value: $model.settings.idleMinutes, in: 0 ... 120, step: 5)
            Stepper("Only when \(model.settings.minNewMB) MB or more are new", value: $model.settings.minNewMB, in: 10 ... 5000, step: 50)
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

struct ToolMissingView: View {
    @EnvironmentObject var model: AppModel
    private let command = "brew install afsctool"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("afsctool is needed").font(.subheadline.weight(.semibold))
            Text("Squeeze uses the free afsctool utility to compress files. Install it with Homebrew, then press Check again.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Button("Check again") { model.reload() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}
