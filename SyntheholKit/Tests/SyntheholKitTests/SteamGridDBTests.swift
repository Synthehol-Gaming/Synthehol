import Foundation
import Testing
@testable import SyntheholKit

struct SteamGridDBTests {
    @Test func decodesGridEnvelope() throws {
        let json = #"""
        {"success": true, "data": [
            {"id": 1, "url": "https://cdn.example/full1.png",
             "thumb": "https://cdn.example/thumb1.png", "width": 600, "height": 900},
            {"id": 2, "url": "https://cdn.example/full2.png",
             "thumb": "https://cdn.example/thumb2.png", "width": 600, "height": 900}
        ]}
        """#
        let envelope = try JSONDecoder().decode(
            SteamGridDBClient.Envelope<[SteamGridDBClient.Grid]>.self,
            from: Data(json.utf8)
        )
        #expect(envelope.data.count == 2)
        #expect(envelope.data[0].thumb.absoluteString == "https://cdn.example/thumb1.png")
        #expect(envelope.data[1].url.absoluteString == "https://cdn.example/full2.png")
    }

    @Test func decodesSearchEnvelopeIgnoringExtraFields() throws {
        let json = #"""
        {"success": true, "data": [
            {"id": 5259, "name": "Dwarf Fortress", "types": ["steam"], "verified": true}
        ]}
        """#
        let envelope = try JSONDecoder().decode(
            SteamGridDBClient.Envelope<[SteamGridDBClient.Game]>.self,
            from: Data(json.utf8)
        )
        #expect(envelope.data.first?.name == "Dwarf Fortress")
    }
}
