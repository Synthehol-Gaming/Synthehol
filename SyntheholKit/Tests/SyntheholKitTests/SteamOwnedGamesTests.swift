import Foundation
import Testing
@testable import SyntheholKit

struct SteamOwnedGamesTests {
    @Test func parsesGamesListXML() throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <gamesList>
            <steamID64>76561198000000000</steamID64>
            <games>
                <game>
                    <appID>620</appID>
                    <name><![CDATA[Portal 2]]></name>
                    <logo><![CDATA[https://cdn.example/620.jpg]]></logo>
                    <hoursOnRecord>12.4</hoursOnRecord>
                </game>
                <game>
                    <appID>975370</appID>
                    <name><![CDATA[Dwarf Fortress]]></name>
                </game>
            </games>
        </gamesList>
        """#
        let games = try SteamOwnedGamesFetcher.parse(xml: Data(xml.utf8))
        #expect(games.map(\.name) == ["Dwarf Fortress", "Portal 2"])
        #expect(games.map(\.appID) == [975370, 620])
    }

    @Test func privateProfileThrowsWithSteamMessage() {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <response><error><![CDATA[This profile is private.]]></error></response>
        """#
        #expect(throws: SteamOwnedGamesFetcher.FetchError.profileUnavailable("This profile is private.")) {
            _ = try SteamOwnedGamesFetcher.parse(xml: Data(xml.utf8))
        }
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
