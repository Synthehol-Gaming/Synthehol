import SwiftUI
import SyntheholKit

struct NativeSteamView: View {
    @Environment(AppModel.self) private var model
    @Binding var showCreateSheet: Bool
    @State private var artworkGame: InstalledGame?
    @State private var settingsGame: InstalledGame?
    @State private var newSteamKeyName = ""
    @State private var newSteamKeyValue = ""

    private var filteredGames: [InstalledGame] {
        let games: [InstalledGame]
        switch model.selectedGameFilter {
        case .all: games = model.nativeSteamGames
        case .genre(let genre):
            games = model.nativeSteamGames.filter {
                model.gameMetadata[$0.id]?.genres.contains(genre) == true
            }
        }
        return games.filter {
            model.showNativeSteamVRGames || model.gameMetadata[$0.id]?.supportsVR != true
        }
    }

    private var availableGames: [InstalledGame] {
        model.nativeOwnedGames.filter {
            model.showNativeSteamVRGames || model.gameMetadata[$0.id]?.supportsVR != true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                compatibilityBanner
                if model.nativeSteamGames.isEmpty {
                    ContentUnavailableView {
                        Label("No Mac Steam Games Found", systemImage: "gamecontroller")
                    } description: {
                        Text("Install a game in the macOS Steam client and it will appear here. At least one Synthehol configuration with Steam installed is required for Windows games to work.")
                    } actions: {
                        Button("Open Steam") { model.launchNativeSteam() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    if filteredGames.isEmpty {
                        Text("No games match the current display options.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)],
                            spacing: 24
                        ) {
                            ForEach(filteredGames) { game in
                                NativeSteamGameTile(
                                    game: game,
                                    onSettings: { settingsGame = game },
                                    onArtwork: { artworkGame = game }
                                )
                            }
                        }
                    }
                }
                if model.selectedGameFilter == .all {
                    availableSection
                }
            }
            .padding(20)
        }
        .navigationTitle("Mac Steam")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Mac Steam", systemImage: "checkmark") {}
                    ForEach(model.bottles) { bottle in
                        Button(bottle.settings.name) { model.selectBottle(bottle.id) }
                    }
                    Divider()
                    Button("New Configuration…") { showCreateSheet = true }
                } label: {
                    Label("Mac Steam", systemImage: "apple.logo")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Toggle("Show VR Games", isOn: Binding(
                        get: { model.showNativeSteamVRGames },
                        set: { model.showNativeSteamVRGames = $0 }
                    ))
                } label: {
                    Label("Display Options", systemImage: "eye")
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refreshNativeSteam()
                    Task { await model.refreshNativeOwnedGames() }
                }
                Button("Steam Play Log", systemImage: "doc.text.magnifyingglass") {
                    model.showNativeSteamPlayLog()
                }
                Button("Open Steam", systemImage: "play.fill") { model.launchNativeSteam() }
                    .disabled(!model.nativeSteamStore.isInstalled)
            }
        }
        .task(id: model.nativeSteamWebAPIKeyID ?? "none") {
            model.refreshNativeSteam()
            await model.refreshNativeOwnedGames()
        }
        .sheet(item: $artworkGame) { game in
            ArtworkSheet(game: game, bottle: nil)
        }
        .sheet(item: $settingsGame) { game in
            NativeSteamGameSettingsSheet(game: game)
        }
    }

    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Available to Install").font(.title3.bold())
                if model.loadingNativeOwnedGames { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshNativeOwnedGames() }
                }
                .labelStyle(.iconOnly)
                .disabled(model.nativeSteamWebAPIKey() == nil)
            }

            Picker("Library Key", selection: Binding(
                get: { model.nativeSteamWebAPIKeyID },
                set: { model.nativeSteamWebAPIKeyID = $0 }
            )) {
                Text("None").tag(String?.none)
                ForEach(model.steamWebAPIKeys) { profile in
                    Text(profile.displayName).tag(String?.some(profile.id))
                }
            }
            .frame(maxWidth: 360)

            if model.nativeSteamWebAPIKey() == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a Steam Web API key to show games owned by the account signed into the macOS Steam client.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Key name", text: $newSteamKeyName).frame(maxWidth: 160)
                        SecureField("Steam Web API key", text: $newSteamKeyValue)
                            .frame(maxWidth: 320)
                        Button("Add") {
                            model.nativeSteamWebAPIKeyID = model.addSteamWebAPIKey(
                                name: newSteamKeyName, key: newSteamKeyValue
                            )
                            newSteamKeyName = ""
                            newSteamKeyValue = ""
                        }
                        .disabled(newSteamKeyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Get a Key…") {
                            NSWorkspace.shared.open(URL(string: "https://steamcommunity.com/dev/apikey")!)
                        }
                    }
                }
            } else if let error = model.nativeOwnedGamesError {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else if availableGames.isEmpty && !model.nativeOwnedGames.isEmpty {
                Text("No games match the current display options.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if model.nativeOwnedGames.isEmpty && !model.loadingNativeOwnedGames {
                Text("Everything you own is installed.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)],
                spacing: 18
            ) {
                ForEach(availableGames) { game in
                    NativeAvailableGameTile(game: game)
                }
            }
        }
    }

    @ViewBuilder private var compatibilityBanner: some View {
        switch model.nativeSteamStatus.deployment {
        case .installed:
            HStack {
                Label("Synthehol Steam Play is installed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Repair") { Task { await model.installNativeSteamCompatibility() } }
            }
        case .steamMissing:
            Label("Install the macOS Steam client to use this library.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .componentsUnavailable:
            Label(
                "Native Steam discovery is ready. This build is missing one or more compatibility components.",
                systemImage: "hammer"
            )
            .foregroundStyle(.secondary)
        case .notInstalled:
            HStack {
                Label("Synthehol Steam Play is ready to install.", systemImage: "arrow.down.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Install") {
                    Task { await model.installNativeSteamCompatibility() }
                }
                .buttonStyle(.borderedProminent)
            }
        case .foreignInjection:
            HStack {
                Label("Steam contains another compatibility injection. Synthehol will not overwrite it.", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Restore Steam") { Task { await model.repairNativeSteam() } }
            }
        }
    }
}

private struct NativeAvailableGameTile: View {
    @Environment(AppModel.self) private var model
    let game: InstalledGame
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    if let poster = model.posterImages[game.id] {
                        Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                            .opacity(hovering ? 0.9 : 0.5)
                            .grayscale(hovering ? 0 : 0.6)
                    } else {
                        LinearGradient(
                            colors: [.gray.opacity(0.4), .gray.opacity(0.25)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .overlay {
                            Text(game.name).font(.callout.bold()).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).padding(6)
                        }
                    }
                }
                .overlay {
                    if hovering {
                        Button { model.installNativeOwnedGame(game) } label: {
                            Label("Install", systemImage: "arrow.down.circle.fill")
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.black.opacity(0.65), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
            Text(game.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .onHover { hovering = $0 }
        .task(id: game.id) { _ = await model.nativePoster(for: game) }
        .contextMenu {
            Button("Install via Steam") { model.installNativeOwnedGame(game) }
        }
        .help(game.name)
    }
}

private struct NativeSteamGameTile: View {
    @Environment(AppModel.self) private var model
    let game: InstalledGame
    let onSettings: () -> Void
    let onArtwork: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    if let poster = model.posterImages[game.id] {
                        Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [.blue.opacity(0.75), .indigo.opacity(0.55)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay { Text(game.name).font(.title3.bold()).foregroundStyle(.white).padding() }
                    }
                }
                .overlay {
                    if hovering {
                        Color.black.opacity(0.35)
                        Button { model.launchNativeGame(game) } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 52)).foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
                .shadow(radius: hovering ? 8 : 3)
                .scaleEffect(hovering ? 1.03 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
            Text(game.name).font(.callout.weight(.medium)).lineLimit(1)
        }
        .onHover { hovering = $0 }
        .task(id: game.id) { _ = await model.nativePoster(for: game) }
        .contextMenu {
            Button("Play") { model.launchNativeGame(game) }
            Button("Show Game Logs", systemImage: "doc.text.magnifyingglass") {
                model.showNativeGameLogs(for: game)
            }
            Button("Nudge Frozen Game") { model.nudgeGame(game) }
            Button("Force Quit Game", systemImage: "xmark.octagon", role: .destructive) {
                model.forceQuitGame(game)
            }
            Divider()
            Button("Game Settings…") { onSettings() }
            Button("Change Artwork…") { onArtwork() }
            Divider()
            if let prefix = model.nativeSteamStore.prefix(for: game) {
                Button("Show Compatibility Prefix") { NSWorkspace.shared.open(prefix) }
            }
            if let path = game.installPath {
                Button("Show Game Files") { NSWorkspace.shared.open(URL(filePath: path)) }
            }
        }
    }
}

private struct NativeSteamGameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    @State private var nudgeStuckLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(game.name).font(.title3.bold())
            Toggle("Nudge stuck loading screens", isOn: $nudgeStuckLoading)
            Text("Briefly pauses and resumes the game during startup to work around a Unity/Mono loading freeze under Rosetta. Healthy games only experience a short pause.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var settings = model.nativeGameSettings(for: game)
                    settings.nudgeStuckLoading = nudgeStuckLoading
                    model.saveNativeGameSettings(settings, for: game)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            nudgeStuckLoading = model.nativeGameSettings(for: game).nudgeStuckLoading
        }
    }
}
