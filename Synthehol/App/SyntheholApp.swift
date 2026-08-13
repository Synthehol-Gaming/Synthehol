import SwiftUI
import SyntheholKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quitting Synthehol shuts down all bottles so no Wine service processes
    /// linger in the Dock after the app is gone.
    func applicationWillTerminate(_ notification: Notification) {
        WineShutdown.killAllBottlesSync()
    }
}

@main
struct SyntheholApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
