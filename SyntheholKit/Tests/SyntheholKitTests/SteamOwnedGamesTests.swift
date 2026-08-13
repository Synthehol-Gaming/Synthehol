import Foundation
import Testing
@testable import SyntheholKit

struct SteamOwnedGamesTests {
    @Test func parsesGetOwnedGamesJSON() throws {
        let json = #"""
        {"response": {"game_count": 3, "games": [
            {"appid": 620, "name": "Portal 2", "playtime_forever": 744,
             "img_icon_url": "abc123", "has_community_visible_stats": true},
            {"appid": 975370, "name": "Dwarf Fortress", "playtime_forever": 60},
            {"appid": 999999, "playtime_forever": 0}
        ]}}
        """#
        let games = try SteamOwnedGamesFetcher.parse(json: Data(json.utf8))
        // The nameless entry (delisted app) is dropped; rest sorted by name.
        #expect(games.map(\.name) == ["Dwarf Fortress", "Portal 2"])
        #expect(games.map(\.appID) == [975370, 620])
    }

    @Test func emptyOrPrivateResponseYieldsNoGames() throws {
        // GetOwnedGames returns an empty response object when the target
        // account's list is hidden from the requesting key.
        let games = try SteamOwnedGamesFetcher.parse(json: Data(#"{"response": {}}"#.utf8))
        #expect(games.isEmpty)
    }

    @Test func parsesLoginUsersMostRecentFirst() throws {
        let temp = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-users-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let config = temp.appending(path: "drive_c/Program Files (x86)/Steam/config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let vdf = #"""
        "users"
        {
        	"76561198000000001"
        	{
        		"AccountName"		"altaccount"
        		"PersonaName"		"Alt"
        		"MostRecent"		"0"
        	}
        	"76561198000000002"
        	{
        		"AccountName"		"mainaccount"
        		"PersonaName"		"Main"
        		"MostRecent"		"1"
        	}
        }
        """#
        try Data(vdf.utf8).write(to: config.appending(path: "loginusers.vdf"))

        let bottle = Bottle(url: temp, settings: BottleSettings(name: "B"))
        let users = SteamStore().loginUsers(in: bottle)
        #expect(users.count == 2)
        #expect(users.first?.accountName == "mainaccount")
        #expect(users.first?.mostRecent == true)
    }
}
