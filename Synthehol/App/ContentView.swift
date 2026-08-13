import SwiftUI
import SyntheholKit

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Section("Bottles") {
                    Label("No bottles yet", systemImage: "waterbottle")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            LibraryPlaceholderView()
        }
        .navigationTitle("Synthehol")
    }
}

/// Placeholder for the poster-grid game library (Phase 4).
struct LibraryPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Games Yet", systemImage: "gamecontroller")
        } description: {
            Text("Create a bottle and install Steam to build your library.")
        } actions: {
            Button("Create Bottle…") {
                // Phase 2: bottle creation wizard
            }
            .disabled(true)
        }
    }
}

#Preview {
    ContentView()
}
