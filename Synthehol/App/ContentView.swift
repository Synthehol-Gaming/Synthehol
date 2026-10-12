import SwiftUI
import SyntheholKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showCreateSheet = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selectedGameFilter) {
                Section("Library") {
                    Label("All Games", systemImage: "square.grid.2x2")
                        .tag(AppModel.GameFilter.all)
                    ForEach(model.sidebarGenres, id: \.genre) { entry in
                        Label(entry.genre, systemImage: "tag")
                            .badge(entry.count)
                            .tag(AppModel.GameFilter.genre(entry.genre))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if model.nativeSteamSelected {
                NativeSteamView(showCreateSheet: $showCreateSheet)
            } else if let bottle = model.selectedBottle {
                BottleDetailView(bottle: bottle, showCreateSheet: $showCreateSheet)
                    .id(bottle.id) // reset draft state when switching bottles
            } else {
                EmptyLibraryView(showCreateSheet: $showCreateSheet)
            }
        }
        .navigationTitle("Synthehol")
        .onChange(of: model.selectedBottleID) {
            // Genres are per-configuration; a filter can't carry across.
            model.selectedGameFilter = .all
        }
        .task {
            AppAppearance.applyStored()
            await model.refresh()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateBottleSheet()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: {
                    if !$0 {
                        model.lastError = nil
                        model.needsAppManagementPermission = false
                    }
                }
            )
        ) {
            if model.needsAppManagementPermission {
                Button("Open System Settings") {
                    model.openAppManagementSettings()
                    model.lastError = nil
                    model.needsAppManagementPermission = false
                }
            }
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct EmptyLibraryView: View {
    @Binding var showCreateSheet: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No Configuration Selected", systemImage: "gamecontroller")
        } description: {
            Text("Create a configuration and install Steam to build your game library.")
        } actions: {
            Button("Create Configuration…") { showCreateSheet = true }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
