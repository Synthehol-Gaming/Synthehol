import SwiftUI
import SyntheholKit

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showCreateSheet = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selectedBottleID) {
                Section("Bottles") {
                    if model.bottles.isEmpty {
                        Label("No bottles yet", systemImage: "waterbottle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.bottles) { bottle in
                        Label(bottle.settings.name, systemImage: "waterbottle")
                            .tag(bottle.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button("New Bottle", systemImage: "plus") {
                        showCreateSheet = true
                    }
                }
            }
        } detail: {
            if let bottle = model.selectedBottle {
                BottleDetailView(bottle: bottle)
                    .id(bottle.id) // reset draft state when switching bottles
            } else {
                EmptyLibraryView(showCreateSheet: $showCreateSheet)
            }
        }
        .navigationTitle("Synthehol")
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
                set: { if !$0 { model.lastError = nil } }
            )
        ) {
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
            Label("No Bottle Selected", systemImage: "gamecontroller")
        } description: {
            Text("Create a bottle and install Steam to build your game library.")
        } actions: {
            Button("Create Bottle…") { showCreateSheet = true }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel())
}
