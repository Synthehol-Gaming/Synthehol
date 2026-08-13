import SwiftUI
import SyntheholKit

/// The poster-grid game library for a bottle.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    @State private var settingsGame: InstalledGame?
    @State private var artworkGame: InstalledGame?
    @State private var uninstallCandidate: InstalledGame?

    private var games: [InstalledGame] { model.installedGames[bottle.id] ?? [] }

    var body: some View {
        Group {
            if !bottle.settings.steamInstalled {
                ContentUnavailableView {
                    Label("Steam Not Installed", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Install Steam to sign in and build your game library.")
                } actions: {
                    if let progress = model.steamProgress[bottle.id] {
                        SteamProgressView(progress: progress)
                            .frame(maxWidth: 320)
                    } else {
                        Button("Install Steam") {
                            Task { await model.installSteam(in: bottle) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.runtime == nil || !bottle.prefixExists)
                        if !bottle.prefixExists {
                            Text("The bottle is still initializing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if games.isEmpty {
                            VStack(spacing: 10) {
                                Label("No Games Installed", systemImage: "gamecontroller")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text("Install games below or through the Steam client — they appear here automatically.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Button("Launch Steam") { model.launchSteam(in: bottle) }
                                    .buttonStyle(.borderedProminent)
                            }
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

                        availableSection
                    }
                    .padding(20)
                }
                .task(id: bottle.id) {
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
        .confirmationDialog(
            "Uninstall \"\(uninstallCandidate?.name ?? "")\"?",
            isPresented: Binding(
                get: { uninstallCandidate != nil },
                set: { if !$0 { uninstallCandidate = nil } }
            )
        ) {
            Button("Uninstall via Steam", role: .destructive) {
                if let game = uninstallCandidate {
                    model.uninstallGame(game, in: bottle)
                }
                uninstallCandidate = nil
            }
            Button("Cancel", role: .cancel) { uninstallCandidate = nil }
        } message: {
            Text("Steam will open and ask you to confirm. Steam removes the game's files; the tile disappears once the uninstall completes.")
        }
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
            }
            if let error = model.ownedGamesError[bottle.id] {
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

    var body: some View {
        VStack(spacing: 8) {
            // Color.clear owns the 2:3 layout; the poster renders in an overlay
            // so oversized/wide artwork can never inflate the tile's bounds.
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { posterView }
                .overlay {
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
            Button("Game Settings…") { onSettings() }
            Button("Change Artwork…") { onArtwork() }
            Divider()
            Button("Create App Launcher…") {
                Task { await model.exportLauncher(for: game, in: bottle) }
            }
            Divider()
            Button("Uninstall…", role: .destructive) { onUninstall() }
        }
        .help(game.name)
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
struct GameSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    let bottle: Bottle

    @State private var launchArguments = ""
    @State private var environmentText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(game.name)
                .font(.title3.bold())

            Form {
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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: load)
    }

    private func load() {
        let settings = GameSettings.load(for: game, in: bottle)
        launchArguments = settings.launchArguments
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
            environment: environment
        )
        try? settings.save(for: game, in: bottle)
    }
}
