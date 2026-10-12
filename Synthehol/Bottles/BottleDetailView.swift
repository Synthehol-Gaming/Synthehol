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
    @State private var newSteamKeyName = ""
    @State private var newSteamKeyValue = ""
    @State private var newDriveLetter = "D"

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
                        set: { model.selectBottle($0) }
                    )) {
                        ForEach(model.bottles) { candidate in
                            Text(candidate.settings.name).tag(candidate.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Button("Mac Steam", systemImage: "apple.logo") {
                        model.selectNativeSteam()
                    }
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
                ToolbarItemGroup(placement: .primaryAction) {
                    if let transition = model.steamTransitions[bottle.id] {
                        if transition == .stopTimedOut {
                            Button("Force Quit Steam", systemImage: "xmark.octagon.fill", role: .destructive) {
                                Task { await model.forceQuitSteam(in: bottle) }
                            }
                            .help("Steam did not quit within 15 seconds. Force-stop every process in this configuration.")
                        } else {
                            Button {} label: {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(transition == .starting ? "Starting Steam" : "Stopping Steam")
                                }
                            }
                            .disabled(true)
                            .help(transition == .starting
                                ? "Waiting for Steam to start (45-second timeout)."
                                : "Waiting for Steam to quit (15-second timeout).")
                        }
                    } else if model.steamRunning.contains(bottle.id) {
                        Button(
                            model.steamClientVisible.contains(bottle.id)
                                ? "Hide Steam" : "Show Steam",
                            systemImage: model.steamClientVisible.contains(bottle.id)
                                ? "eye.slash" : "eye"
                        ) {
                            model.toggleSteamClient(in: bottle)
                        }
                        .help("Show or hide the Steam client without affecting running games.")
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
            Button("Delete Files and Forget", role: .destructive) {
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

            Section("Drives") {
                ForEach(draft.drives) { drive in
                    HStack(spacing: 10) {
                        Text("\(drive.letter):")
                            .font(.body.monospaced().bold())
                            .frame(width: 28, alignment: .leading)
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(drive.url.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(drive.url.path(percentEncoded: false))
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([drive.url])
                        } label: {
                            Image(systemName: "arrow.forward.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        Button(role: .destructive) {
                            draft.drives.removeAll { $0.id == drive.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove drive mapping")
                    }
                }

                HStack {
                    Picker("Drive Letter", selection: $newDriveLetter) {
                        ForEach(unusedDriveLetters, id: \.self) { letter in
                            Text("\(letter):").tag(letter)
                        }
                    }
                    .frame(width: 150)
                    Button("Choose Folder…") { chooseDriveFolder() }
                        .disabled(unusedDriveLetters.isEmpty)
                }
                Text("Adds a Windows drive that points directly to a folder on this Mac. The folder is not copied, and the same folder can be used by multiple configurations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Graphics") {
                Picker("Backend", selection: $draft.graphicsBackend) {
                    Text("DXMT").tag(GraphicsBackend.dxmt)
                    Text("DXVK").tag(GraphicsBackend.dxvk)
                    if model.d3dMetalOSSupported {
                        Text("D3DMetal (GPTK 4)").tag(GraphicsBackend.d3dMetal)
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

            Section("Steam Web API") {
                Picker("Library Key", selection: $draft.steamWebAPIKeyID) {
                    Text("None").tag(String?.none)
                    ForEach(model.steamWebAPIKeys) { profile in
                        Text(profile.displayName).tag(String?.some(profile.id))
                    }
                }

                HStack {
                    TextField("Key name", text: $newSteamKeyName)
                        .frame(maxWidth: 180)
                    SecureField("Steam Web API key", text: $newSteamKeyValue)
                    Button("Add") {
                        let id = model.addSteamWebAPIKey(
                            name: newSteamKeyName, key: newSteamKeyValue
                        )
                        draft.steamWebAPIKeyID = id
                        newSteamKeyName = ""
                        newSteamKeyValue = ""
                    }
                    .disabled(newSteamKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack {
                    Button("Get a Key…") {
                        NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/dev/apikey")!)
                    }
                    if let selected = draft.steamWebAPIKeyID {
                        Button("Delete Selected Key", role: .destructive) {
                            model.removeSteamWebAPIKey(id: selected)
                            draft.steamWebAPIKeyID = nil
                        }
                    }
                }
                Text("Keys are saved once and can be selected by multiple configurations. Each configuration still uses its own signed-in Steam account, so configurations can show different libraries even when they share a key. Steam’s key page accepts any label for its “domain name,” such as localhost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var unusedDriveLetters: [String] {
        let managed = Set(draft.drives.map { $0.letter.uppercased() })
        // Managed links appear in dosdevices too, but only unmanaged Wine or
        // mounted-volume links should block a new mapping.
        let occupied = BottleDriveManager.occupiedLetters(in: bottle).subtracting(managed)
        return BottleDriveManager.availableLetters.filter {
            !managed.contains($0) && !occupied.contains($0)
        }
    }

    private func chooseDriveFolder() {
        guard let letter = unusedDriveLetters.contains(newDriveLetter)
            ? newDriveLetter : unusedDriveLetters.first
        else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Map as \(letter):"
        panel.message = "Choose the Mac folder to make available as drive \(letter): in this configuration."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.drives.append(BottleDrive(letter: letter, url: url))
        newDriveLetter = unusedDriveLetters.first ?? "D"
    }

    /// D3DMetal prerequisite status and setup actions for GPTK 4.
    @ViewBuilder
    private var d3dMetalSetup: some View {
        if model.d3dMetalReady {
            Text("D3DMetal translates Direct3D 9–12 through Apple's Game Porting Toolkit 4 and Metal 4. Steam's own web interface uses app-local DXVK, while games continue to use D3DMetal.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("D3DMetal (Game Porting Toolkit 4 beta 2, Direct3D 9–12) needs two one-time steps before it can be selected:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if model.runtimeSupportsD3DMetal {
                        Label("Wine 11.15 GPTK runtime installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if model.runtimeProgress != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install Wine 11.15 GPTK Runtime (~450 MB)") {
                            Task { await model.installD3DMetalRuntime() }
                        }
                        .controlSize(.small)
                    }
                    if model.gptkImported {
                        Label("Game Porting Toolkit 4 beta 2 imported", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button("Import GPTK 4…") {
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
                Text("Download the latest Game Porting Toolkit 4 beta from Apple Developer, open its evaluation-environment disk image, then import it. Synthehol currently supports beta 2 or newer. Apple's license does not allow Synthehol to bundle these libraries.")
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
                    if let transition = model.steamTransitions[bottle.id] {
                        if transition == .stopTimedOut {
                            Button("Force Quit Steam", role: .destructive) {
                                Task { await model.forceQuitSteam(in: bottle) }
                            }
                        } else {
                            ProgressView(transition == .starting ? "Starting…" : "Stopping…")
                                .controlSize(.small)
                        }
                    } else {
                        Button("Quit Steam") {
                            Task { await model.quitSteam(in: bottle) }
                        }
                        .disabled(!model.steamRunning.contains(bottle.id))
                        Button("Launch Steam") {
                            model.launchSteam(in: bottle)
                        }
                        .disabled(model.steamRunning.contains(bottle.id))
                        .buttonStyle(.borderedProminent)
                    }
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
                    .frame(maxWidth: .infinity)
            }
        case .installing:
            ProgressView("Installing Steam (silent)…")
                .frame(maxWidth: .infinity)
        case .verifying:
            ProgressView("Verifying…")
                .frame(maxWidth: .infinity)
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
