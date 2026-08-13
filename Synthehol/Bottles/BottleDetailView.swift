import SwiftUI
import SyntheholKit

struct BottleDetailView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    @State private var draft: BottleSettings
    @State private var showDeleteDialog = false
    @State private var showRenameSheet = false

    init(bottle: Bottle) {
        self.bottle = bottle
        _draft = State(initialValue: bottle.settings)
    }

    private var isBusy: Bool { model.busyBottleIDs.contains(bottle.id) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    HStack {
                        Text(bottle.settings.name)
                        Button("Rename…") { showRenameSheet = true }
                            .controlSize(.small)
                    }
                }
                LabeledContent("Path") {
                    HStack {
                        Text(bottle.url.path(percentEncoded: false))
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Button("Open C: Drive") {
                            NSWorkspace.shared.open(bottle.driveC)
                        }
                        .controlSize(.small)
                    }
                }
                if isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Windows") {
                Picker("Windows Version", selection: $draft.windowsVersion) {
                    ForEach(WindowsVersion.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Enhanced Sync", selection: $draft.enhancedSync) {
                    Text("None").tag(EnhancedSync.none)
                    Text("ESync").tag(EnhancedSync.esync)
                    Text("MSync").tag(EnhancedSync.msync)
                }
                Toggle("Advertise AVX (Rosetta)", isOn: $draft.avxEnabled)
            }

            Section("Graphics") {
                Picker("Backend", selection: $draft.graphicsBackend) {
                    Text("DXMT").tag(GraphicsBackend.dxmt)
                    Text("D3DMetal (GPTK)").tag(GraphicsBackend.d3dMetal)
                    Text("DXVK").tag(GraphicsBackend.dxvk)
                }
                Toggle("Metal HUD", isOn: $draft.metalHUD)
                Toggle("Retina Mode", isOn: $draft.retinaMode)
                Picker("Scaling (DPI)", selection: $draft.dpi) {
                    Text("Automatic (\(draft.retinaMode ? 192 : 96) dpi)").tag(Int?.none)
                    ForEach([96, 120, 144, 168, 192, 216, 240], id: \.self) { value in
                        Text("\(value) dpi").tag(Int?.some(value))
                    }
                }
            }

            Section("Steam") {
                if let progress = model.steamProgress[bottle.id] {
                    SteamProgressView(progress: progress)
                } else if bottle.settings.steamInstalled {
                    HStack {
                        Label("Steam is installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Launch Steam") {
                            model.launchSteam(in: bottle)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Sign in and install games through the Steam window. Installed games appear below (and in the Library in a future phase).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let games = model.installedGames[bottle.id] ?? []
                    if games.isEmpty {
                        Text("No games installed yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(games) { game in
                            LabeledContent(game.name) {
                                Text(game.storeGameID).monospaced().foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else {
                    HStack {
                        Text("Steam is not installed in this bottle.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Install Steam") {
                            Task { await model.installSteam(in: bottle) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.runtime == nil || !bottle.prefixExists)
                    }
                }
            }

            Section("Wine Tools") {
                HStack {
                    ForEach(WineExecutor.WineTool.allCases, id: \.self) { tool in
                        Button(tool.displayName) {
                            model.launchTool(tool, in: bottle)
                        }
                    }
                }
                .disabled(model.runtime == nil || !bottle.prefixExists)
            }

            Section {
                Button("Delete Bottle…", role: .destructive) {
                    showDeleteDialog = true
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.settings.name)
        .task(id: bottle.id) {
            model.refreshGames(in: bottle)
        }
        .onChange(of: draft) {
            let settings = draft
            Task { await model.applySettings(settings, to: bottle) }
        }
        .onChange(of: bottle.settings) {
            draft = bottle.settings
        }
        .confirmationDialog(
            "Delete \"\(bottle.settings.name)\"?",
            isPresented: $showDeleteDialog
        ) {
            Button("Move Files to Trash & Forget", role: .destructive) {
                Task { await model.deleteBottle(bottle, deleteFiles: true) }
            }
            Button("Forget Only (Keep Files)") {
                Task { await model.deleteBottle(bottle, deleteFiles: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting removes the Windows prefix and everything installed in it.")
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameBottleSheet(bottle: bottle)
        }
    }
}

struct SteamProgressView: View {
    let progress: SteamInstaller.Progress

    var body: some View {
        switch progress {
        case .downloading(let done, let total):
            if let total {
                ProgressView(
                    "Downloading Steam installer…",
                    value: Double(done), total: Double(total)
                )
            } else {
                ProgressView("Downloading Steam installer… \(done / 1024) KB")
            }
        case .installing:
            ProgressView("Installing Steam (silent)…")
        case .verifying:
            ProgressView("Verifying…")
        }
    }
}

struct RenameBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle
    @State private var name: String

    init(bottle: Bottle) {
        self.bottle = bottle
        _name = State(initialValue: bottle.settings.name)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Bottle").font(.headline)
            TextField("Name", text: $name)
                .frame(width: 240)
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let newName = name.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    Task { await model.renameBottle(bottle, to: newName) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }
}
