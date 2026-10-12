import SwiftUI
import SyntheholKit

/// The poster-grid game library for a bottle.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    @State private var settingsGame: InstalledGame?
    @State private var artworkGame: InstalledGame?
    @State private var uninstallCandidate: InstalledGame?
    @State private var showingAddGame = false
    private var allGames: [InstalledGame] { model.installedGames[bottle.id] ?? [] }

    /// Installed games matching the sidebar filter. Games whose metadata
    /// hasn't loaded yet only appear under All Games.
    private var games: [InstalledGame] {
        switch model.selectedGameFilter {
        case .all:
            allGames
        case .genre(let genre):
            allGames.filter { model.gameMetadata[$0.id]?.genres.contains(genre) == true }
        }
    }

    var body: some View {
        Group {
            if !bottle.settings.steamInstalled && allGames.isEmpty {
                ContentUnavailableView {
                    Label("No Games Yet", systemImage: "gamecontroller")
                } description: {
                    Text("Add an installed Windows game, run an installer, or install Steam.")
                } actions: {
                    if model.installerRunning.contains(bottle.id) {
                        ProgressView("Installer Running…")
                    } else {
                      HStack {
                        Button("Add Game…") { showingAddGame = true }
                            .buttonStyle(.borderedProminent)
                        Button("Run Installer…") { chooseInstaller() }
                        if let progress = model.steamProgress[bottle.id] {
                            SteamProgressView(progress: progress).frame(maxWidth: 260)
                        } else {
                            Button("Install Steam") {
                                Task { await model.installSteam(in: bottle) }
                            }
                            .disabled(model.runtime == nil || !bottle.prefixExists)
                        }
                      }
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Text("Games").font(.title2.bold())
                            Spacer()
                            if model.installerRunning.contains(bottle.id) {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small)
                                    Text("Installer Running…")
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Menu {
                                    Button("Add Game…", systemImage: "plus") {
                                        showingAddGame = true
                                    }
                                    Button("Run Installer…", systemImage: "shippingbox") {
                                        chooseInstaller()
                                    }
                                } label: {
                                    Label("Add", systemImage: "plus")
                                }
                            }
                        }
                        if allGames.isEmpty {
                            VStack(spacing: 10) {
                                Label("No Games Installed", systemImage: "gamecontroller")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text("Install games below or through the Steam client — they appear here automatically.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                if model.steamTransitions[bottle.id] == .starting {
                                    ProgressView("Starting Steam…")
                                } else {
                                    Button("Launch Steam") { model.launchSteam(in: bottle) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                        } else if games.isEmpty {
                            Text("No installed games match this filter.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)],
                                spacing: 24
                            ) {
                                ForEach(games) { game in
                                    GameTile(
                                        game: game,
                                        bottle: bottle,
                                        onSettings: { settingsGame = game },
                                        onArtwork: { artworkGame = game },
                                        onUninstall: { uninstallCandidate = game }
                                    )
                                }
                            }
                        }

                        // Install-browsing belongs to the unfiltered view;
                        // owned-but-not-installed games have no metadata yet.
                        if bottle.settings.steamInstalled && model.selectedGameFilter == .all {
                            availableSection
                        }
                    }
                    .padding(20)
                }
                .task(id: "\(bottle.id)|\(bottle.settings.steamWebAPIKeyID ?? "none")") {
                    await model.refreshOwnedGames(in: bottle)
                }
            }
        }
        .sheet(item: $settingsGame) { game in
            GameSettingsSheet(game: game, bottle: bottle)
        }
        .sheet(item: $artworkGame) { game in
            ArtworkSheet(game: game, bottle: bottle)
        }
        .sheet(isPresented: $showingAddGame) {
            AddCustomGameSheet(bottle: bottle)
        }
        .confirmationDialog(
            "Uninstall \"\(uninstallCandidate?.name ?? "")\"?",
            isPresented: Binding(
                get: { uninstallCandidate != nil },
                set: { if !$0 { uninstallCandidate = nil } }
            )
        ) {
            Button(
                uninstallCandidate?.store == CustomGameStore.storeID
                    ? "Remove from Library" : "Uninstall via Steam",
                role: .destructive
            ) {
                if let game = uninstallCandidate {
                    if game.store == CustomGameStore.storeID {
                        model.removeCustomGame(game, in: bottle)
                    } else {
                        model.uninstallGame(game, in: bottle)
                    }
                }
                uninstallCandidate = nil
            }
            Button("Cancel", role: .cancel) { uninstallCandidate = nil }
        } message: {
            if uninstallCandidate?.store == CustomGameStore.storeID {
                Text("This only removes the library entry. The game and its files will remain on disk.")
            } else {
                Text("Steam will open and ask you to confirm. Steam removes the game's files; the tile disappears once the uninstall completes.")
            }
        }
    }

    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.item]
        panel.prompt = "Run Installer"
        panel.message = "Choose a Windows installer to run inside \(bottle.settings.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.runInstaller(url, in: bottle)
    }
}

struct AddCustomGameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle

    @State private var name = ""
    @State private var executable: URL?
    @State private var workingDirectory: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Game").font(.title2.bold())
            Form {
                TextField("Title", text: $name, prompt: Text("Game title"))
                LabeledContent("Executable") {
                    pathChooser(url: executable, title: "Choose Executable…") {
                        chooseExecutable()
                    }
                }
                LabeledContent("Working Directory") {
                    pathChooser(url: workingDirectory, title: "Choose Folder…") {
                        chooseWorkingDirectory()
                    }
                }
                Text("The working directory defaults to the executable's folder. Launch arguments and artwork can be configured from the game tile afterward.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Game") {
                    guard let executable else { return }
                    let directory = workingDirectory ?? executable.deletingLastPathComponent()
                    Task {
                        if await model.addCustomGame(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            executable: executable, workingDirectory: directory, in: bottle
                        ) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || executable == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func pathChooser(url: URL?, title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(url?.path(percentEncoded: false) ?? "Not selected")
                .foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 290, alignment: .trailing)
            Button(title, action: action)
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Choose Executable"
        panel.message = "Choose the Windows executable for this game."
        panel.directoryURL = bottle.driveC
        guard panel.runModal() == .OK, let url = panel.url else { return }
        executable = url
        workingDirectory = url.deletingLastPathComponent()
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose Folder"
        panel.directoryURL = workingDirectory ?? executable?.deletingLastPathComponent() ?? bottle.driveC
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectory = url
    }
}

extension LibraryView {
    @ViewBuilder
    var availableSection: some View {
        let available = model.ownedGames[bottle.id] ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Available to Install")
                    .font(.title3.bold())
                if model.loadingOwnedGames.contains(bottle.id) {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshOwnedGames(in: bottle) }
                }
                .labelStyle(.iconOnly)
                .disabled(model.steamWebAPIKey(for: bottle) == nil)
            }
            if model.steamWebAPIKey(for: bottle) == nil {
                apiKeySetup
            } else if let error = model.ownedGamesError[bottle.id] {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if available.isEmpty && !model.loadingOwnedGames.contains(bottle.id) {
                Text("Everything you own is installed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)],
                spacing: 18
            ) {
                ForEach(available) { game in
                    AvailableGameTile(game: game, bottle: bottle)
                }
            }
        }
    }
}

extension LibraryView {
    @ViewBuilder
    var apiKeySetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose or add a Steam Web API key in this configuration’s Settings to browse the signed-in account’s complete library.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Get a Key…") {
                NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/dev/apikey")!)
            }
            Text("Steam's key page asks for a “domain name” — it's only a label and is never checked. Enter anything, e.g. localhost.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A dimmed poster tile for an owned-but-not-installed game.
struct AvailableGameTile: View {
    @Environment(AppModel.self) private var model
    let game: InstalledGame
    let bottle: Bottle

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    if let poster = model.posterImages[game.id] {
                        Image(nsImage: poster)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(hovering ? 0.9 : 0.5)
                            .grayscale(hovering ? 0 : 0.6)
                    } else {
                        LinearGradient(
                            colors: [.gray.opacity(0.4), .gray.opacity(0.25)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .overlay {
                            Text(game.name)
                                .font(.callout.bold())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(6)
                        }
                    }
                }
                .overlay {
                    if hovering {
                        Button {
                            model.installOwnedGame(game, in: bottle)
                        } label: {
                            Label("Install", systemImage: "arrow.down.circle.fill")
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.65), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))

            Text(game.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .onHover { hovering = $0 }
        .task(id: game.id) {
            _ = await model.poster(for: game, in: bottle)
        }
        .contextMenu {
            Button("Install via Steam") { model.installOwnedGame(game, in: bottle) }
        }
        .help(game.name)
    }
}

/// A 2:3 movie-poster tile with a hover play overlay.
struct GameTile: View {
    @Environment(AppModel.self) private var model
    let game: InstalledGame
    let bottle: Bottle
    var onSettings: () -> Void
    var onArtwork: () -> Void
    var onUninstall: () -> Void

    @State private var hovering = false

    private var poster: NSImage? { model.posterImages[game.id] }
    private var runState: AppModel.GameRunState? { model.gameRunStates[game.id] }

    var body: some View {
        VStack(spacing: 8) {
            // Color.clear owns the 2:3 layout; the poster renders in an overlay
            // so oversized/wide artwork can never inflate the tile's bounds.
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { posterView }
                .overlay {
                    switch runState {
                    case .starting:
                        Color.black.opacity(0.55)
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.large)
                                .tint(.white)
                            Text("Starting…")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white)
                            forceQuitButton
                        }
                    case .running:
                        VStack {
                            HStack {
                                Spacer()
                                Label("Running", systemImage: "play.fill")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.green.opacity(0.9), in: Capsule())
                                    .padding(6)
                            }
                            Spacer()
                            if hovering { forceQuitButton.padding(.bottom, 12) }
                        }
                    case nil:
                        if hovering {
                            Color.black.opacity(0.35)
                            Button {
                                model.launchGame(game, in: bottle)
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 52))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .shadow(radius: hovering ? 8 : 3)
            .scaleEffect(hovering ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.12), value: hovering)

            Text(game.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .onHover { hovering = $0 }
        .task(id: game.id) {
            _ = await model.poster(for: game, in: bottle)
        }
        .contextMenu {
            Button("Play") { model.launchGame(game, in: bottle) }
                .disabled(runState != nil)
            Button("Play with Debug Log") {
                model.launchGame(game, in: bottle, debugLogging: true)
            }
            .disabled(runState != nil)
            Button("Nudge Frozen Game") { model.nudgeGame(game) }
                .disabled(runState == nil)
            Button("Force Quit Game", systemImage: "xmark.octagon", role: .destructive) {
                model.forceQuitGame(game)
            }
            .disabled(runState == nil)
            Button("Show Session Logs") { model.showSessionLogs() }
            Divider()
            Button("Game Settings…") { onSettings() }
            Button("Change Artwork…") { onArtwork() }
            Divider()
            Button("Create App Launcher…") {
                Task { await model.exportLauncher(for: game, in: bottle) }
            }
            Divider()
            Button(
                game.store == CustomGameStore.storeID ? "Remove from Library…" : "Uninstall…",
                role: .destructive
            ) { onUninstall() }
        }
        .help(game.name)
    }

    private var forceQuitButton: some View {
        Button("Force Quit", systemImage: "xmark.octagon.fill", role: .destructive) {
            model.forceQuitGame(game)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.small)
    }

    @ViewBuilder
    private var posterView: some View {
        if let poster {
            Image(nsImage: poster)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(
                colors: [.indigo.opacity(0.7), .purple.opacity(0.5)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay {
                Text(game.name)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(8)
            }
        }
    }
}

/// Per-game launch arguments and environment variables.
/// Custom games can also be renamed here; only the display name changes —
/// artwork and per-game settings are keyed by the game's stable ID.
struct GameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    let bottle: Bottle

    @State private var name = ""
    @State private var launchArguments = ""
    @State private var environmentText = ""
    @State private var nudgeStuckLoading = false

    private var isCustomGame: Bool { game.store == CustomGameStore.storeID }
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(game.name)
                .font(.title3.bold())

            Form {
                if isCustomGame {
                    TextField("Title", text: $name, prompt: Text("Game title"))
                }
                TextField("Launch Arguments", text: $launchArguments,
                          prompt: Text("e.g. -novid -fullscreen"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Environment Variables (one KEY=VALUE per line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $environmentText)
                    .font(.body.monospaced())
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Nudge stuck loading screens", isOn: $nudgeStuckLoading)
                Text("Works around a compatibility bug that freezes some games on their loading screen: briefly pauses and resumes the game a few times during startup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCustomGame && trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: load)
    }

    private func load() {
        name = game.name
        let settings = GameSettings.load(for: game, in: bottle)
        launchArguments = settings.launchArguments
        nudgeStuckLoading = settings.nudgeStuckLoading
        environmentText = settings.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    private func save() {
        var environment: [String: String] = [:]
        for line in environmentText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            environment[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        let settings = GameSettings(
            launchArguments: launchArguments.trimmingCharacters(in: .whitespaces),
            environment: environment,
            nudgeStuckLoading: nudgeStuckLoading
        )
        try? settings.save(for: game, in: bottle)
        if isCustomGame && trimmedName != game.name {
            model.renameCustomGame(game, to: trimmedName, in: bottle)
        }
    }
}
