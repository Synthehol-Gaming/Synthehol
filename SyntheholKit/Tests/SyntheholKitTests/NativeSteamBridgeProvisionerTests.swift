import Foundation
import Testing
@testable import SyntheholKit

struct NativeSteamBridgeProvisionerTests {
    @Test func requiresACompleteSteamConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-bridge-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root.appending(path: "Bottle"), settings: BottleSettings(name: "Empty"))

        #expect(throws: NativeSteamBridgeError.self) {
            try NativeSteamBridgeProvisioner.provision(
                from: [bottle], into: root.appending(path: "Bridge")
            )
        }
    }
}
