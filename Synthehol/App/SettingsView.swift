import SwiftUI
import SyntheholKit
import UniformTypeIdentifiers

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil // follow macOS
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static let storageKey = "appearance"

    /// Applies the stored preference app-wide (windows, sheets, menus).
    @MainActor
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        NSApp.appearance = (AppAppearance(rawValue: raw) ?? .system).nsAppearance
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue
    @State private var storageToRemove: BottleStorage?

    var body: some View {
        TabView {
            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }

            storagePane
                .tabItem { Label("Bottle Storage", systemImage: "externaldrive") }

            runtimePane
                .tabItem { Label("Runtime", systemImage: "speedometer") }
        }
        .frame(width: 600, height: 420)
        .onChange(of: appearance) {
            AppAppearance.applyStored()
        }
        .task {
            if model.bottleStorages.isEmpty { await model.refresh() }
        }
        .confirmationDialog(
            "Remove Bottle Storage?", item: $storageToRemove
        ) { storage in
            Button("Remove \(storage.name)", role: .destructive) {
                Task { await model.removeBottleStorage(storage) }
            }
        } message: { storage in
            Text("The folder and configurations inside it will remain on disk.")
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("General")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Appearance")
                        .gridColumnAlignment(.trailing)
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text("System follows your macOS appearance automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(28)
    }

    private var storagePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bottle Storage")
                    .font(.title2.bold())
                Text("Choose where configurations and their installed games are stored.")
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.bottleStorages.enumerated()), id: \.element.id) { index, storage in
                        storageRow(storage)
                        if index < model.bottleStorages.count - 1 { Divider() }
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.separator, lineWidth: 1)
            }

            HStack {
                Button {
                    chooseStorageFolder()
                } label: {
                    Label("Add Storage…", systemImage: "plus")
                }

                Spacer()

                Text("Removing storage never deletes its files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private var runtimePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Runtime")
                .font(.title2.bold())

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.runtime?.version ?? "Not installed")
                            .fontWeight(.medium)
                        Text(model.runtime?.supportsPerformanceProfiles == true
                             ? "Synthehol performance profiles are available."
                             : "This runtime uses standard performance behavior.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.runtime?.supportsPerformanceProfiles == true {
                        Label("Performance", systemImage: "bolt.fill")
                            .foregroundStyle(.green)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(6)
            }

            Text("Import a locally assembled performance runtime using its checksum sidecar. The archive is verified before installation, and the previous runtime is retained for rollback.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Import Performance Runtime…") { choosePerformanceRuntime() }
                    .disabled(model.runtimeProgress != nil)
                if model.runtimeProgress != nil {
                    ProgressView().controlSize(.small)
                    Text(runtimeProgressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(28)
    }

    private var runtimeProgressLabel: String {
        switch model.runtimeProgress {
        case .downloading: "Reading archive…"
        case .verifying: "Verifying checksum…"
        case .extracting: "Extracting…"
        case .finishing: "Activating…"
        case nil: ""
        }
    }

    private func choosePerformanceRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import Runtime"
        panel.message = "Choose the .tar.gz.json checksum sidecar produced with the performance runtime."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.installLocalRuntime(from: url) }
    }

    private func storageRow(_ storage: BottleStorage) -> some View {
        HStack(spacing: 12) {
            Image(systemName: storage.id == BottleStorage.defaultID ? "internaldrive" : "externaldrive")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(storage.name).fontWeight(.medium)
                    if storage.id == BottleStorage.defaultID {
                        Text("DEFAULT")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(storage.url.path(percentEncoded: false))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(storage.url.path(percentEncoded: false))
            }

            Spacer(minLength: 12)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([storage.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")

            if storage.id != BottleStorage.defaultID {
                Button(role: .destructive) {
                    storageToRemove = storage
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this storage location")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Bottle Storage"
        panel.message = "Choose a folder where Synthehol will create configurations."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addBottleStorage(name: url.lastPathComponent, url: url) }
    }
}
