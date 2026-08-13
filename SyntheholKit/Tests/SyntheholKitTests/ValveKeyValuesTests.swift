import Foundation
import Testing
@testable import SyntheholKit

private let portal2Manifest = #"""
"AppState"
{
	"appid"		"620"
	"universe"		"1"
	"name"		"Portal 2"
	"StateFlags"		"4"
	"installdir"		"Portal 2"
	"SizeOnDisk"		"12813887942"
	"buildid"		"12087429"
	"UserConfig"
	{
		"language"		"english"
	}
	"InstalledDepots"
	{
		"620"
		{
			"manifest"		"7381680853011875880"
		}
	}
}
"""#

struct ValveKeyValuesTests {
    @Test func parsesNestedObjects() throws {
        let root = try ValveKeyValues.parse(portal2Manifest)
        #expect(root["AppState"]?["name"]?.stringValue == "Portal 2")
        #expect(root["AppState"]?["UserConfig"]?["language"]?.stringValue == "english")
        #expect(root["AppState"]?["InstalledDepots"]?["620"]?["manifest"]?.stringValue == "7381680853011875880")
    }

    @Test func keyLookupIsCaseInsensitive() throws {
        let root = try ValveKeyValues.parse(portal2Manifest)
        #expect(root["appstate"]?["stateflags"]?.intValue == 4)
    }

    @Test func skipsLineComments() throws {
        let root = try ValveKeyValues.parse(#"""
        // libraryfolders.vdf style comment
        "libraryfolders"
        {
        	"0"
        	{
        		"path"		"C:\\Program Files (x86)\\Steam"
        	}
        }
        """#)
        #expect(root["libraryfolders"]?["0"]?["path"]?.stringValue == #"C:\Program Files (x86)\Steam"#)
    }

    @Test func rejectsTruncatedInput() {
        #expect(throws: ValveKeyValuesError.unexpectedEnd) {
            _ = try ValveKeyValues.parse(#""AppState" { "appid" "#)
        }
    }

    @Test func parsesSteamApp() throws {
        let app = try #require(SteamApp(acf: portal2Manifest))
        #expect(app.appID == 620)
        #expect(app.name == "Portal 2")
        #expect(app.installDirectory == "Portal 2")
        #expect(app.isFullyInstalled)
        #expect(app.sizeOnDisk == 12_813_887_942)
        #expect(app.posterURL.absoluteString.contains("620/library_600x900_2x.jpg"))
    }
}

struct BottleSettingsTests {
    @Test func defaultsAreGameFriendly() {
        let settings = BottleSettings(name: "Steam")
        #expect(settings.windowsVersion == .win10)
        #expect(settings.enhancedSync == .msync)
        #expect(settings.graphicsBackend == .dxmt)
    }

    @Test func msyncAlsoAdvertisesEsync() {
        var settings = BottleSettings(name: "Test")
        settings.enhancedSync = .msync
        let env = settings.wineEnvironment()
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == "1")
    }

    @Test func decodingUnknownFieldsFallsBackToDefaultsWithoutFailing() throws {
        // Simulates opening a bottle written by a newer/older Synthehol:
        // decode must migrate leniently, never reset (Whisky lesson).
        let minimal = #"{"name": "Old Bottle"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BottleSettings.self, from: minimal)
        #expect(decoded.name == "Old Bottle")
        #expect(decoded.enhancedSync == .msync)
        #expect(decoded.fileVersion == 1)
    }
}
