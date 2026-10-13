import SwiftUI
import SyntheholKit

struct CompatibilityFixesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: InstalledGame
    let bottle: Bottle?
    @State private var selectedFixID = CompatibilityFixCatalog.fixes[0].id
    @State private var selectedVersion = CompatibilityFixCatalog.fixes[0].versions[0].id
    @State private var importedVersions: Set<String> = []
    @State private var applications: [AppliedCompatibilityFix] = []
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?

    private var fix: CompatibilityFix { CompatibilityFixCatalog.fixes.first { $0.id == selectedFixID }! }
    private var package: CompatibilityFixPackage { .init(fixID: fix.id, version: selectedVersion) }
    private var prefix: URL? { bottle?.url ?? model.nativeSteamStore.prefix(for: game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compatibility Fixes · \(game.name)").font(.title3.bold())
            Text("Fixes are optional. Recommendations and imports never apply a fix. You can try a version with any compatible game and remove it afterward.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Fix", selection: $selectedFixID) {
                ForEach(CompatibilityFixCatalog.fixes) { fix in Text(fix.title).tag(fix.id) }
            }
            if fix.recommended(for: game) {
                Label("Recommended for this game if you encounter this issue", systemImage: "lightbulb")
                    .foregroundStyle(.orange)
            } else {
                Text("This game is not on the affected-games list. You can still try this fix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(fix.symptom)
            Text("Known affected games: " + fix.steamAppIDs.map { fix.knownGameNames[$0] ?? "Steam \($0)" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
            Text(fix.validation).font(.caption).foregroundStyle(.secondary)
            Link("Issue and patch details", destination: fix.source)
            Picker("Patched Version", selection: $selectedVersion) {
                ForEach(fix.versions) { version in
                    Text(version.id + (importedVersions.contains(version.id) ? " — imported" : " — not imported"))
                        .tag(version.id)
                }
            }
            HStack {
                Button("Import Fix Package…") { importPackage() }
                Button("Apply to Game Executable…") { apply() }
                    .disabled(prefix == nil || !importedVersions.contains(selectedVersion))
            }
            Text("Quit the game and Steam (or stop its configuration) first. Applying a fix backs up existing DLLs and overrides, and changes only the selected executable's renderer. Use DXMT with this renderer.")
                .font(.caption).foregroundStyle(.secondary)
            if prefix == nil { Text("Launch the game once to create its compatibility prefix.").font(.caption) }
            ForEach(applications) { application in
                HStack {
                    VStack(alignment: .leading) {
                        Text("Applied: \(application.version)")
                        Text(application.executable.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove Fix") { remove(application) }
                }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.green) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 540)
        .disabled(busy).interactiveDismissDisabled(busy)
        .task { await refresh() }
        .onChange(of: selectedFixID) {
            selectedVersion = fix.versions[0].id
            Task { await refresh() }
        }
    }

    private func refresh() async {
        var versions: Set<String> = []
        for version in fix.versions {
            if await model.compatibilityFixStore.isImported(.init(fixID: fix.id, version: version.id)) { versions.insert(version.id) }
        }
        importedVersions = versions
        if let prefix { applications = await model.compatibilityFixStore.applications(for: game, prefix: prefix) }
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose a compatibility fix package folder. Importing it does not apply it to a game."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        busy = true; error = nil; status = nil
        Task {
            defer { busy = false }
            do {
                let imported = try await model.compatibilityFixStore.importPackage(at: directory)
                selectedFixID = imported.fixID; selectedVersion = imported.version
                await refresh(); status = "Version imported. Choose Apply to Game Executable to try it."
            } catch { self.error = error.localizedDescription }
        }
    }

    private func apply() {
        guard let prefix else { return }
        do { try model.requireIdleForCompatibilityFix(in: bottle) }
        catch { self.error = error.localizedDescription; return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        if let path = game.installPath { panel.directoryURL = URL(filePath: path) }
        panel.message = "Choose this game's main .exe. You can apply the fix again to its launcher if needed."
        guard panel.runModal() == .OK, let executable = panel.url else { return }
        busy = true; error = nil; status = nil
        let chosenPackage = package
        Task {
            defer { busy = false }
            do {
                try model.requireIdleForCompatibilityFix(in: bottle)
                _ = try await model.compatibilityFixStore.apply(chosenPackage, to: game, executable: executable, prefix: prefix)
                await refresh(); status = "Fix applied to this executable. Reopen Steam and test the game."
            } catch { self.error = error.localizedDescription }
        }
    }

    private func remove(_ application: AppliedCompatibilityFix) {
        busy = true; error = nil; status = nil
        Task {
            defer { busy = false }
            do {
                try model.requireIdleForCompatibilityFix(in: bottle)
                try await model.compatibilityFixStore.remove(application)
                await refresh(); status = "Previous DLLs and overrides restored."
            } catch { self.error = error.localizedDescription }
        }
    }
}
