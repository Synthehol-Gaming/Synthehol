import SwiftUI
import SyntheholKit
import UniformTypeIdentifiers

/// Artwork picker for a game: official Steam variants, a local file, or a
/// SteamGridDB browse link, plus reset to default.
struct ArtworkSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    let bottle: Bottle

    @State private var showFileImporter = false
    @State private var applying = false

    /// Official artwork variants Valve hosts for every Steam app.
    private var officialCandidates: [(label: String, url: URL)] {
        guard game.store == SteamStore.storeID else { return [] }
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

            HStack {
                Button("Choose Image File…") { showFileImporter = true }
                Button("Browse SteamGridDB…") {
                    let term = game.name.addingPercentEncoding(
                        withAllowedCharacters: .urlQueryAllowed
                    ) ?? game.name
                    NSWorkspace.shared.open(
                        URL(string: "https://www.steamgriddb.com/search/grids?term=\(term)")!
                    )
                }
                .help("Opens the community artwork site in your browser — download an image there, then use Choose Image File.")
                Spacer()
                Button("Reset to Default") {
                    Task {
                        await model.resetPoster(for: game, in: bottle)
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
