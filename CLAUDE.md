# Synthehol

macOS SwiftUI app (arm64 only, macOS 15+, Swift 6 strict concurrency) that creates
Wine bottles, bootstraps Steam in them, and launches installed games from a
poster-grid library. Roadmap and architecture rationale: PLAN.md (read it before
starting a new phase — it encodes lessons from the Whisky codebase this project
succeeds, including specific bugs not to reintroduce).

## Layout

- `project.yml` — XcodeGen spec; `Synthehol.xcodeproj` is generated, never committed.
  Regenerate with `xcodegen generate` after adding/removing files or targets.
- `Synthehol/` — SwiftUI app target (UI only).
- `SyntheholKit/` — local SPM package with all non-UI logic (bottles, wine process
  management, Steam parsing). Keep it UI-free and unit-tested.

## Commands

- Generate project: `xcodegen generate`
- Build app: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Synthehol.xcodeproj -scheme Synthehol build`
  (`DEVELOPER_DIR` needed because system xcode-select points at CommandLineTools)
- Kit tests: `cd SyntheholKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
  (plain `swift test` fails: the CommandLineTools toolchain is missing the Swift Testing macro plugin)

## Conventions

- Never build shell command strings for process launches — use `Process` with argv
  arrays. AppleScript/Terminal paths are the exception, isolated and escaped.
- Bottle settings decode leniently (`decodeIfPresent ?? default`) and migrate;
  never reset user settings on version mismatch.
- Runtime/asset downloads must be SHA-256 verified before install.
- Wine env quirk: enabling msync must also set `WINEESYNC=1` (D3DMetal sniffs it).
