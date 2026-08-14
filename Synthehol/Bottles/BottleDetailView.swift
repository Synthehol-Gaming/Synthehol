import SwiftUI
import SyntheholKit

struct BottleDetailView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    @Binding var showCreateSheet: Bool

    enum Tab: Hashable { case library, settings }

    @State private var tab: Tab = .library
    @State private var draft: BottleSettings
    @State private var showDeleteDialog = false
    @State private var showRenameSheet = false

    init(bottle: Bottle, showCreateSheet: Binding<Bool>) {
        self.bottle = bottle
        _showCreateSheet = showCreateSheet
        _draft = State(initialValue: bottle.settings)
    }

    private var isBusy: Bool { model.busyBottleIDs.contains(bottle.id) }

    var body: some View {
        Group {
            switch tab {
            case .library:
                LibraryView(bottle: bottle)
            case .settings:
                settingsForm
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Picker("Configuration", selection: Binding(
                        get: { bottle.id },
                        set: { model.selectedBottleID = $0 }
                    )) {
                        ForEach(model.bottles) { candidate in
                            Text(candidate.settings.name).tag(candidate.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button("New Configuration…") { showCreateSheet = true }
                } label: {
                    Label(bottle.settings.name, systemImage: "desktopcomputer")
                }
                .help("Switch between configurations or create a new one.")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    Text("Library").tag(Tab.library)
                    Text("Settings").tag(Tab.settings)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if bottle.settings.steamInstalled {
                ToolbarItem(placement: .primaryAction) {
                    if model.steamRunning.contains(bottle.id) {
                        Button("Quit Steam", systemImage: "stop.fill") {
                            Task { await model.quitSteam(in: bottle) }
                        }
                        .help("Steam is running in this configuration. Quits it and cleans up its background processes.")
                    } else {
                        Button("Launch Steam", systemImage: "play.fill") {
                            model.launchSteam(in: bottle)
                        }
                    }
                }
            }
        }
        .navigationTitle(bottle.settings.name)
        .task(id: bottle.id) {
            model.refreshGames(in: bottle)
            if !bottle.settings.steamInstalled { tab = .settings }
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
            Text("Deleting removes this configuration's files and everything installed in it.")
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameBottleSheet(bottle: bottle)
        }
    }

    private var settingsForm: some View {
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

            // Until Steam is installed, setting it up is the user's next step —
            // surface it right below the bottle header instead of mid-form.
            if !bottle.settings.steamInstalled {
                steamSection
            }

            Section("Windows") {
                Picker("Windows Version", selection: $draft.windowsVersion) {
                    ForEach(WindowsVersion.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .disabled(model.steamRunning.contains(bottle.id))
                Text("The Windows release games and launchers see. Changing it is quick and reversible (a registry update, nothing is reinstalled), but it's locked while Steam is running so a live session never sees the version change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Enhanced Sync", selection: $draft.enhancedSync) {
                    Text("None").tag(EnhancedSync.none)
                    Text("ESync").tag(EnhancedSync.esync)
                    Text("MSync").tag(EnhancedSync.msync)
                }
                Text("How Windows thread synchronization is handled. MSync uses Mac-native primitives and is usually fastest; ESync is the older method, still faster than None; None routes everything through a coordinating process — slowest but most compatible. If a game deadlocks, stutters, or hangs while loading, try stepping down to ESync or None. Takes effect the next time Steam or a game starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Advertise AVX (Rosetta)", isOn: $draft.avxEnabled)
                Text("Lets games see the AVX instruction support Rosetta 2 can provide. Some newer games require AVX and refuse to start without it; a few others misbehave when it's advertised, so leave it off unless a game complains about missing CPU features. Takes effect on next launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Graphics") {
                Picker("Backend", selection: $draft.graphicsBackend) {
                    Text("DXMT").tag(GraphicsBackend.dxmt)
                    Text("DXVK").tag(GraphicsBackend.dxvk)
                    if model.d3dMetalOSSupported {
                        Text("D3DMetal (Pre-release)").tag(GraphicsBackend.d3dMetal)
                            .selectionDisabled(!model.d3dMetalReady)
                    }
                }
                .disabled(model.steamRunning.contains(bottle.id))
                Text("How Direct3D graphics are translated to Metal. DXMT translates Direct3D 11 directly and is the recommended default; DXVK goes through Vulkan instead — it also covers older Direct3D 9/10 games and is worth trying if a game misrenders under DXMT. Switching swaps translation libraries in the configuration, so it's locked while Steam is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.d3dMetalOSSupported {
                    d3dMetalSetup
                }

                Toggle("Metal HUD", isOn: $draft.metalHUD)
                Text("Overlays Apple's performance HUD (frame rate, GPU time, resolution) on games. Takes effect the next time a game starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Retina Mode", isOn: $draft.retinaMode)
                Text("Renders games at the display's full Retina resolution — much sharper, but roughly four times the pixels for the GPU to draw. Turn off for more headroom in demanding games.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Capture Displays in Fullscreen", isOn: $draft.captureDisplaysForFullscreen)
                Text("Gives fullscreen games exclusive display access for proper mouse capture and cursor hiding. Turn off if you switch apps constantly while playing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Scaling (DPI)", selection: $draft.dpi) {
                    Text("Automatic (\(draft.retinaMode ? 192 : 96) dpi)").tag(Int?.none)
                    ForEach([96, 120, 144, 168, 192, 216, 240], id: \.self) { value in
                        Text("\(value) dpi").tag(Int?.some(value))
                    }
                }
                Text("How large Windows apps draw text and interface elements. Automatic tracks Retina Mode (192 dpi on, 96 off); raise it if launchers look tiny, lower it if they look oversized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if bottle.settings.steamInstalled {
                steamSection
            }

            Section("Advanced") {
                HStack {
                    ForEach(WineExecutor.WineTool.allCases, id: \.self) { tool in
                        Button(tool.displayName) {
                            model.launchTool(tool, in: bottle)
                        }
                    }
                }
                .disabled(model.runtime == nil || !bottle.prefixExists)
                Button("Stop All Processes", systemImage: "stop.circle") {
                    Task { await model.stopBottle(bottle) }
                }
                .help("Quits Steam if running, then shuts down everything running in this configuration.")
                .disabled(model.runtime == nil)
            }

            Section {
                Button("Delete Configuration…", role: .destructive) {
                    showDeleteDialog = true
                }
            }
        }
        .formStyle(.grouped)
    }

    /// D3DMetal prerequisite status and setup actions. Shown only on macOS
    /// releases that support the GPTK pre-release.
    @ViewBuilder
    private var d3dMetalSetup: some View {
        if model.d3dMetalReady {
            Text("D3DMetal translates Direct3D 9–12 via Apple's Game Porting Toolkit — best for Direct3D 12 games neither DXMT nor DXVK can run. Steam's own window is kept on DXVK (it can't render through D3DMetal). Pre-release: expect rough edges, and keep Retina Mode off — Steam's window scales incorrectly with it on the beta runtime.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("D3DMetal (Apple's Game Porting Toolkit, Direct3D 9–12) needs two one-time steps before it can be selected:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if model.runtimeSupportsD3DMetal {
                        Label("Beta runtime installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if model.runtimeProgress != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install Beta Runtime (~450 MB)") {
                            Task { await model.installBetaRuntime() }
                        }
                        .controlSize(.small)
                    }
                    if model.gptkImported {
                        Label("Game Porting Toolkit imported", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button("Import Game Porting Toolkit…") {
                            Task { await model.importGPTK() }
                        }
                        .controlSize(.small)
                        Button("Get it from Apple…") {
                            NSWorkspace.shared.open(
                                URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
                            )
                        }
                        .controlSize(.small)
                    }
                }
                Text("The toolkit is Apple's “Game Porting Toolkit” from developer.apple.com (sign-in required; Apple's license doesn't allow bundling it — and note it is not the similarly-named third-party “Porting Kit” app). Download it, open the disk image, then import. The beta runtime replaces the stable one; the stable version is kept for rollback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var steamSection: some View {
        Section("Steam") {
            if let progress = model.steamProgress[bottle.id] {
                SteamProgressView(progress: progress)
            } else if bottle.settings.steamInstalled {
                HStack {
                    Label("Steam is installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Quit Steam") {
                        Task { await model.quitSteam(in: bottle) }
                    }
                    Button("Launch Steam") {
                        model.launchSteam(in: bottle)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Sign in and install games through the Steam window. Closing the window exits Steam (its “Exit Steam” interface setting is on by default), and Synthehol then cleans up its background processes automatically. If Steam is ever configured to minimize to the tray instead, use Quit Steam.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Steam is not installed in this configuration. Install it to sign in and build your game library.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Install Steam") {
                        Task { await model.installSteam(in: bottle) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.runtime == nil || !bottle.prefixExists)
                }
                if !bottle.prefixExists {
                    Text("This configuration is still initializing — Install Steam unlocks once it's ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            Text("Rename Configuration").font(.headline)
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
