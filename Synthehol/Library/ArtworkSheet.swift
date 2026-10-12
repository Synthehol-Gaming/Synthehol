import SwiftUI
import SyntheholKit
import UniformTypeIdentifiers

/// Artwork picker for a game: official Steam variants, a local file, or a
/// SteamGridDB browse link, plus reset to default.
struct ArtworkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    let bottle: Bottle?

    @AppStorage("steamGridDBAPIKey") private var apiKey = ""
    @State private var showFileImporter = false
    @State private var applying = false
    @State private var grids: [SteamGridDBClient.Grid] = []
    @State private var gridError: String?
    @State private var loadingGrids = false
    @State private var keyDraft = ""

    /// Official artwork variants Valve hosts for every Steam app.
    private var officialCandidates: [(label: String, url: URL)] {
        guard game.store == SteamStore.storeID || game.store == NativeSteamStore.storeID
        else { return [] }
        let base = "https://steamcdn-a.akamaihd.net/steam/apps/\(game.storeGameID)"
        return [
            ("Poster", URL(string: "\(base)/library_600x900_2x.jpg")!),
            ("Header", URL(string: "\(base)/header.jpg")!),
            ("Capsule", URL(string: "\(base)/capsule_616x353.jpg")!),
            ("Hero", URL(string: "\(base)/library_hero.jpg")!)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Artwork — \(game.name)")
                .font(.title3.bold())

            if !officialCandidates.isEmpty {
                Text("Official artwork — click to use")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(officialCandidates, id: \.label) { candidate in
                        VStack(spacing: 4) {
                            Button {
                                apply(from: candidate.url)
                            } label: {
                                AsyncImage(url: candidate.url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    case .failure:
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .foregroundStyle(.tertiary)
                                    default:
                                        ProgressView().controlSize(.small)
                                    }
                                }
                                .frame(width: 110, height: 110)
                            }
                            .buttonStyle(.plain)
                            Text(candidate.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            steamGridDBSection

            Divider()

            HStack {
                Button("Choose Image File…") { showFileImporter = true }
                Spacer()
                Button("Reset to Default") {
                    Task {
                        if let bottle {
                            await model.resetPoster(for: game, in: bottle)
                        } else {
                            await model.resetNativePoster(for: game)
                        }
                        dismiss()
                    }
                }
            }

            HStack {
                if applying {
                    ProgressView().controlSize(.small)
                    Text("Applying…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image]
        ) { result in
            guard case .success(let url) = result else { return }
            Task {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    model.lastError = "Couldn't read that file."
                    return
                }
                await model.setCustomPoster(data, for: game)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var steamGridDBSection: some View {
        if apiKey.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Community artwork (SteamGridDB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Browse thousands of community posters right here. It needs a free personal API key — one-time setup.")
                    .font(.callout)
                HStack {
                    SecureField("Paste your SteamGridDB API key", text: $keyDraft)
                        .frame(maxWidth: 280)
                    Button("Save") {
                        apiKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await loadGrids() }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Get a Key…") {
                        NSWorkspace.shared.open(
                            URL(string: "https://www.steamgriddb.com/profile/preferences/api")!
                        )
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Community artwork (SteamGridDB) — click to use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if loadingGrids { ProgressView().controlSize(.small) }
                    Button("Change Key") {
                        keyDraft = ""
                        apiKey = ""
                        grids = []
                    }
                    .controlSize(.small)
                }
                if let gridError {
                    Text(gridError).font(.callout).foregroundStyle(.orange)
                }
                if !grids.isEmpty {
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: 10)],
                            spacing: 10
                        ) {
                            ForEach(grids) { grid in
                                Button {
                                    apply(from: grid.url)
                                } label: {
                                    AsyncImage(url: grid.thumb) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        case .failure:
                                            Image(systemName: "photo.badge.exclamationmark")
                                                .foregroundStyle(.tertiary)
                                        default:
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                    .frame(width: 92, height: 138)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(height: 300)
                } else if !loadingGrids && gridError == nil {
                    Text("No community posters found for this game.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: game.id) { await loadGrids() }
        }
    }

    private func loadGrids() async {
        guard !apiKey.isEmpty else { return }
        loadingGrids = true
        gridError = nil
        defer { loadingGrids = false }
        let client = SteamGridDBClient(apiKey: apiKey)
        do {
            var results: [SteamGridDBClient.Grid] = []
            if game.store == SteamStore.storeID || game.store == NativeSteamStore.storeID {
                results = (try? await client.grids(forSteamAppID: game.storeGameID)) ?? []
            }
            if results.isEmpty,
               let match = try await client.search(game.name).first {
                results = try await client.grids(forGameID: match.id)
            }
            grids = results
        } catch SteamGridDBClient.ClientError.unauthorized {
            gridError = "SteamGridDB rejected the API key. Check it and try again."
            apiKey = ""
        } catch {
            gridError = "Couldn't reach SteamGridDB: \(error.localizedDescription)"
        }
    }

    private func apply(from url: URL) {
        applying = true
        Task {
            defer { applying = false }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else {
                model.lastError = "Couldn't download that artwork."
                return
            }
            await model.setCustomPoster(data, for: game)
            dismiss()
        }
    }
}
