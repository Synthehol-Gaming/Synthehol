import SwiftUI
import SyntheholKit

/// The poster-grid game library for a bottle.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    @State private var settingsGame: InstalledGame?

    private var games: [InstalledGame] { model.installedGames[bottle.id] ?? [] }

    var body: some View {
        Group {
            if !bottle.settings.steamInstalled {
                ContentUnavailableView {
                    Label("Steam Not Installed", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Install Steam in this bottle's Configuration tab to build your library.")
                }
            } else if games.isEmpty {
                ContentUnavailableView {
                    Label("No Games Installed", systemImage: "gamecontroller")
                } description: {
                    Text("Install games through the Steam client. They appear here automatically.")
                } actions: {
                    Button("Launch Steam") { model.launchSteam(in: bottle) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)],
                        spacing: 24
                    ) {
                        ForEach(games) { game in
                            GameTile(game: game, bottle: bottle) {
                                settingsGame = game
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .sheet(item: $settingsGame) { game in
            GameSettingsSheet(game: game, bottle: bottle)
        }
    }
}

/// A 2:3 movie-poster tile with a hover play overlay.
struct GameTile: View {
    @Environment(AppModel.self) private var model
    let game: InstalledGame
    let bottle: Bottle
    var onSettings: () -> Void

    @State private var poster: NSImage?
    @State private var hovering = false

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
            poster = await model.poster(for: game, in: bottle)
        }
        .contextMenu {
            Button("Play") { model.launchGame(game, in: bottle) }
            Button("Game Settings…") { onSettings() }
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
