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
        // Single-window app: a Window scene (not WindowGroup) so incoming
        // synthehol:// URLs land in the existing window instead of spawning
        // a new one per launcher invocation.
        Window("Synthehol", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in
                    Task { await model.handleLaunchURL(url) }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Open Logs Folder") {
                    NSWorkspace.shared.open(SyntheholPaths.logs)
                }
                Button("Clear D3D Shader Caches") {
                    Task { await ShaderCache.wipe() }
                }
            }
        }
    }
}
