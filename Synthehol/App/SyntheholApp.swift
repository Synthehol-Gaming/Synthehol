import SwiftUI

@main
struct SyntheholApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}
