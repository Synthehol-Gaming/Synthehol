# Synthehol — Implementation Plan

Synthehol is a macOS app for playing Windows games on Apple Silicon Macs. It creates
Wine-based Windows "bottles", bootstraps Steam inside them, and presents installed games
in a movie-poster-style library from which they can be launched. It is a spiritual
successor to [Whisky](https://github.com/Whisky-App/Whisky) (archived April 2025),
narrowed to a single job: **managing and launching Windows games**, not arbitrary
Windows applications.

## Product requirements

- Apple Silicon only (M1+), Metal required. No Intel support.
- One or more bottles per user; Synthehol fully automates bottle setup including Steam.
- Steam is the install channel for games (v1), but it is **provider #1, not a structural
  assumption**: game discovery, artwork, and launch go through a `GameStoreProvider`
  abstraction so other stores (GOG first — via GOG Galaxy or offline installers — then
  possibly Epic/Battle.net) can be added without reworking the library UI.
- Installed games appear as poster tiles ("movie poster" UX) and launch with one click.
- Optional: exportable per-game launcher `.app`s (Wineskin-style shells) so games appear
  in Spotlight/Launchpad and get macOS Game Mode.

## What we learned from Whisky

The full architectural review of the Whisky repo is summarized here because it drives
most decisions below.

### Worth copying

- **Bottle = WINEPREFIX + `Metadata.plist`** in a UUID directory; a registry file that
  is just a list of bottle paths. Simple, relocatable, easy to back up.
- **Separately-downloaded Wine runtime** in `~/Library/Application Support/<bundle-id>/Libraries/`
  (app bundle stays small and signable; GPTK's D3DMetal is not redistributable under a
  GPL/MIT app's license umbrella, and the runtime needs a writable home).
- **Process wrapper** around `wine64` using `Process` + `AsyncStream<ProcessOutput>`,
  with per-run log files in `~/Library/Logs/` and old-log cleanup.
- **Env-var driven feature toggles** (all set per-launch, no prefix mutation):
  `WINEPREFIX`, `WINEDEBUG=fixme-all`, `WINEESYNC`/`WINEMSYNC` (msync must *also* set
  `WINEESYNC=1` — D3DMetal sniffs ESYNC and misbehaves otherwise; hardcoded in
  `lid3dshared.dylib`), `MTL_HUD_ENABLED`, `METAL_CAPTURE_ENABLED`,
  `ROSETTA_ADVERTISE_AVX`, `D3DM_SUPPORT_DXR`, `DXVK_ASYNC`, `DXVK_HUD`,
  `WINEDLLOVERRIDES=dxgi,d3d9,d3d10core,d3d11=n,b` (when DXVK).
- **Registry edits via `wine reg add/query`**, Windows version via `winecfg -v win10`.
  The first `winecfg` invocation is what actually creates the prefix.
- **PE parser** for icon extraction and 32/64-bit detection (Whisky's
  `WhiskyKit/PE/` is clean-room Swift and a good reference; we need much less of it
  since Steam supplies artwork).
- **Rosetta 2 detection/install**: check `/Library/Apple/usr/libexec/oah/libRosettaRuntime`,
  install via `softwareupdate --install-rosetta --agree-to-license`.
- **Entitlements** (hardened runtime, sandbox off):
  `com.apple.security.cs.allow-unsigned-executable-memory`, apple-events, camera,
  audio-input. Wine binaries run as separate processes with their own signatures.
- Sparkle for app updates; String Catalog for localization (later phases).

### Mistakes to fix

1. **Unverified runtime download** — Whisky fetched `Libraries.tar.gz` over HTTPS with
   no checksum/signature, from a single hardcoded host that is now a dead point of
   failure for the archived app. → Synthehol pins runtime releases in a versioned
   manifest with SHA-256, verifies before install, and keeps N-1 runtime for rollback.
2. **Settings wiped on Wine upgrade** — `BottleSettings.decode` reset all bottle
   settings whenever the stored wine version didn't match the current default.
   → Migrate, never reset.
3. **DXVK enabled by deleting system32 DLLs** with no backup (`makeOriginalCopy: false`),
   so toggling DXVK off left a broken prefix. Also a `return`-instead-of-`continue` bug
   aborted the copy on the first non-DLL file. → Use `WINEDLLOVERRIDES` +
   copy-with-backup, or per-launch DLL redirection; never destroy prefix files.
4. **Per-program settings keyed by exe filename** (`Program Settings/Launch.exe.plist`)
   — collides when two games ship `Launch.exe` (bug acknowledged in a code comment).
   → Key by Steam appid (v1 games are all Steam) or path hash.
5. **`@unchecked Sendable` everywhere** with TODOs; settings persisted from `didSet` on
   arbitrary threads. → Actors from day one (`BottleStore`, `RuntimeStore`), Swift 6
   strict concurrency clean.
6. **No tests.** → SyntheholKit is a pure SPM package; parsers (ACF/VDF, PE if needed),
   settings migration, and env construction get unit tests from the start.
7. **Ad-hoc shell escaping** for Terminal/AppleScript command strings. → Never build
   shell strings for the primary launch path; always `Process` with argv arrays.
8. **No Steam awareness at all** (zero Steam code in Whisky) — games were generic
   `.exe`s found by walking `Program Files`. → Steam-native model (below) is the core
   of Synthehol.

### Lessons from Whisky's issue tracker (reviewed 2026-08-14)

- **Scope DLL overrides per-app, never bottle-wide** (whisky#836: a `dwrite`
  override added for a game broke steamwebhelper). Everything launches through
  steam.exe, so per-game `WINEDLLOVERRIDES` env leaks into Steam. Future per-game
  overrides (incl. per-game graphics backend, whisky#1213) must use
  `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides` registry keys.
- **Steam self-updates can break under any pinned Wine overnight**
  (whisky#1199/#1336). Escape hatch: downgrade via
  `-forcesteamupdate -forcepackagedownload -overridepackageurl <archived client url>
  -exitsteam`, then pin with `-noverifyfiles -nobootstrapupdate -skipinitialbootstrap
  -norepairfiles`. `SteamInstaller.defaultLaunchArguments` is the injection point.
- **Never branch on Wine's textual output** (whisky#435: `reg` errors are localized
  and arrive mojibake in non-UTF-8 locales). Use exit codes or write-then-read.
- **Wine-under-Rosetta can livelock, not just crash** (Core Keeper, diagnosed
  2026-08-14): Mono's Boehm-GC suspend-retry loop spins forever during Unity
  asset loads; SIGSTOP+SIGCONT of the process breaks it. `GameNudger` +
  per-game "Nudge stuck loading" setting are the workaround.
- **D3DMetal on the 4.0 beta runtime (learned live, 2026-08-14)**: GPTK's Windows-side
  bridge DLLs are Wine builtin PE modules and must replace the runtime's
  `x86_64-windows` modules (copying them into a prefix does not select them);
  otherwise Wine's stock PE modules silently route games to wined3d/Vulkan even
  when the Mac-side pieces are present. GPTK's Mac-side
  libs go in `Wine/lib/external/` with `x86_64-unix/{d3d10,d3d11,d3d12,dxgi}.so` as
  *symlinks* to `../../external/libd3dshared.dylib` (per the runtime's README —
  copies break `@loader_path` fatally). A runtime switch triggers a prefix update
  that overwrites deployed backend DLLs — run `wineboot -u` then redeploy every
  bottle's backend after installing a runtime. Steam's client cannot render through
  the GPTK shims *or* this runtime's builtin wined3d (both black-screen): scope
  Steam to DXVK by copying DXVK DLLs into Steam's own directories (app-local wins
  over system32). D3DMetal needs `ROSETTA_ADVERTISE_AVX=1` unconditionally. Retina
  Mode mis-scales the DXVK-scoped Steam window (2x UI in a 1x window) — keep it
  off in D3DMetal bottles.
- Deferred, verify-before-applying: CrossOver's Steam bottle registry provisioning
  (whisky#41: `GPUAccelWebViews=0`, steamwebhelper `LargeAddressAware=1`, corefonts)
  only if login/render regressions appear; legacy-audio per-game tweaks
  (whisky#637 native dsound, whisky#233 faudio — Wine 9+ ships FAudio builtin);
  44.1 kHz host sample-rate workaround (whisky#445).

## Architecture

```
Synthehol.xcodeproj  (generated by XcodeGen from project.yml — not committed)
├── Synthehol/            SwiftUI app (macOS 15+, arm64 only, Swift 6)
│   ├── App/              SyntheholApp, AppDelegate glue
│   ├── Library/          Poster grid, game detail, launch UI
│   ├── Bottles/          Bottle list/create/config views
│   └── Setup/            First-run wizard (Rosetta → runtime → bottle → Steam)
└── SyntheholKit/         Local SPM package, no UI, unit-tested
    ├── Bottle/           Bottle, BottleSettings (versioned, migrating)
    ├── Wine/             WineRuntime (manifest, download, verify, install), WineProcess
    ├── Steam/            SteamInstaller, SteamLibrary (ACF/VDF), SteamArtwork
    └── Support/          Paths, logging, process utilities
```

- **App storage**: `~/Library/Application Support/com.colinobrien.Synthehol/`
  - `Runtime/<version>/` — installed Wine runtime(s), current + previous
  - `Bottles/<UUID>/` — default bottle location (`Metadata.plist` + `drive_c/`)
  - `Artwork/` — cached poster images
- **Config storage**: bottle registry (list of bottle paths) in Application Support,
  not in the sandbox-container path trick Whisky used.

### Wine runtime strategy

The runtime is the riskiest external dependency. Design: a `RuntimeManifest` (JSON:
`version`, `url`, `sha256`, `notes`) shipped in-app and overridable remotely, so the
source can be swapped without an app update. Candidate builds (evaluate in Phase 1):

| Source | Notes |
|---|---|
| frankea/Whisky community fork runtime | Active (v3.6.0, Aug 2026); Wine + **DXMT** (default), DXVK 1.10.3, D3DMetal in progress; closest to our needs |
| MythicApp/wine (Mythic Engine successor) | LGPL, GPTK-based, actively developed; no public GitHub release assets — distributed via their CDN |
| Gcenx Wine-Crossover builds | Long-maintained generic builds; no D3DMetal bundled |
| Build our own (fork whisky-wine) | Most control, most work; defer unless needed |

Decision (Phase 1, verified 2026-08-13): **adopt the frankea/Whisky fork's runtime**,
pinned by SHA-256 in the manifest.
- Stable default: **Wine Libraries v3.1.1** (Wine 11.0, DXVK 1.10.3, DXMT 0.80) —
  `https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz`,
  SHA-256 `01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3`
  (published in the release notes; ~332 MB).
- Beta channel (later): **v4.0.0-beta.2**, GPTK-capable, built from CrossOver 25
  sources (`frankea/winecx-gptk`); fixes Steam login + video playback. No published
  checksum — compute and pin our own when adopting. Two gotchas from its notes:
  (a) D3DMetal requires the *user's own* GPTK download imported separately (matches
  our no-redistribution stance); (b) CrossOver-lineage runtimes look for the profile
  under `users/crossover` while stock prefixes use `users/<name>` — bottles need a
  compat symlink when switching engines. D3DMetal itself is pulled per Apple's
GPTK license terms the same way Whisky/Mythic handle it — never redistributed in our
repo. Graphics backend defaults: **DXMT for D3D11, D3DMetal where available, DXVK as
fallback** — per-bottle and per-game overridable.

### Bottle model

`BottleSettings` (versioned `fileVersion`, additive migrations):
- Info: `name`, `created`
- Wine: `runtimeVersion`, `windowsVersion` (default `win10`), `enhancedSync`
  (default msync), `avxEnabled`
- Graphics: `backend` (dxmt | d3dmetal | dxvk), `metalHUD`, `dxvkAsync`, `dxvkHUD`,
  `retinaMode`, `dpi`
- Steam: `steamInstalled`, `steamAutoLogin` hint

Bottle creation: `mkdir Bottles/<UUID>` → `winecfg -v win10` (creates prefix) →
registry defaults (retina mode, DPI) → record runtime version.

### Steam bootstrap (the v1 differentiator)

1. Download `SteamSetup.exe` from Valve's CDN
   (`https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe`; checksum
   recorded at download time, size ~2 MB — the real payload self-updates).
2. Run `SteamSetup.exe /S` (NSIS silent install) into the bottle.
3. First launch of `steam.exe` under Wine with the flag set required for the CEF-based
   client to render under Wine. Known candidates from the Whisky/AppleGamingWiki era —
   validate empirically in Phase 3 against the current Steam client:
   `-noverifyfiles -nobootstrapupdate -skipinitialbootstrap -norepairfiles`, and if the
   new CEF UI misrenders, the DXMT backend vs `-cef-force-occlusion` style flags.
   Whatever works is captured as the default "Steam launch profile" in SyntheholKit.
4. User signs in through Steam's own UI (we never touch credentials).
5. Synthehol shows Steam install/download progress by watching `steamapps/*.acf` state.

### Game library

- **Discovery**: parse `steamapps/libraryfolders.vdf` +
  `appmanifest_<appid>.acf` (Valve KeyValues text format — parser in
  SyntheholKit with unit tests). `StateFlags == 4` ⇒ fully installed.
- **Artwork**: Steam CDN `https://steamcdn-a.akamaihd.net/steam/apps/<appid>/library_600x900_2x.jpg`
  (exactly the movie-poster aspect), fallbacks: `library_600x900.jpg`, `header.jpg`,
  then Steam's local `appcache/librarycache/`. Cached in `Artwork/`, refreshed lazily.
- **Launch**: `wine64 start /unix <steam.exe> -applaunch <appid> [game args]` so Steam
  handles DRM/overlay; per-game settings (env, args, backend override, locale) keyed by
  appid. Direct-exe launch stays as an escape hatch (uses the launch options recorded in
  the ACF/registry when possible).
- **Poster UI**: `LazyVGrid` of 2:3 tiles, hover play button, running badge,
  name/playtime footer; game detail sheet for settings; bottle picker only when >1
  bottle contains Steam.

### Multi-store abstraction (GOG and beyond)

SyntheholKit defines:

```swift
protocol GameStoreProvider {           // one per store
    static var storeID: String         // "steam", "gog", ...
    func isInstalled(in bottle: Bottle) -> Bool
    func installedGames(in bottle: Bottle) throws -> [InstalledGame]
}
struct InstalledGame { store, storeGameID, name, posterURL, ... }
```

The library UI, artwork cache, and per-game settings key on `store:gameID`, never on
Steam appids directly. Steam ships in v1; GOG later — likely via GOG Galaxy in-bottle
(its `galaxy-2.0.db` SQLite holds the installed-game list) or offline installers, with
artwork from the GOG API. Store bootstrap (Phase 3's Steam installer) gets the same
treatment: a per-provider "install the store client silently" step.

## Phases

**Phase 0 — Scaffold (this session)**
Repo, XcodeGen project, app target + SyntheholKit package, entitlements, ACF parser
with tests, CI-less but lint-clean. Builds and launches to a placeholder library window.

**Phase 1 — Wine runtime plumbing**
`RuntimeManifest` + downloader with SHA-256 verify, progress reporting, install/rollback
in `Runtime/<version>/`; `WineProcess` (env construction per table above, AsyncStream
output, log files); Rosetta check. *Acceptance: `swift test` green; a CLI harness can
create a prefix and run `winecfg`.*

**Phase 2 — Bottles**
Bottle model + `BottleStore` actor, versioned settings with migration tests, create/
delete/rename, registry edits (DPI/retina/build number), config UI. *Acceptance: create
a bottle from the UI, run wine control panel apps.*

**Phase 3 — Steam bootstrap**
SteamInstaller (download, silent install, first-run flag validation), setup wizard
(Rosetta → runtime → bottle → Steam sign-in), kill/status handling (`wineserver -k`,
tasklist). *Acceptance: fresh Mac → signed-in Steam client in a bottle, fully guided.*

**Phase 4 — Library & launch**
ACF/VDF watcher (FSEvents on `steamapps/`), artwork pipeline with disk cache, poster
grid + detail view, launch pipeline with per-game settings, running-state tracking.
*Acceptance: install a game via Steam, see its poster appear, launch and play it.*

**Phase 5 — Launchers & polish**
Per-game `.app` launcher export (script shell + `LSApplicationCategoryType =
public.app-category.games` for Game Mode, poster as icon), Sparkle updates, log
viewer/diagnostics export, shader-cache management (`getconf DARWIN_USER_CACHE_DIR` →
`d3dm` wipe), multiple-bottle QoL.

**Phase 6 — Hardening**
Notarized Developer ID releases, runtime update flow (verify → side-by-side install →
per-bottle migration prompt, never silent reset), localization scaffold, docs.

## Risks / open questions

- **Steam close-vs-tray** (resolved, Phase 3): current Steam clients default the
  "Exit Steam" interface setting to on, so closing the window fully exits and
  Synthehol's launch monitor then shuts the bottle down (verified live; no config
  key is written for the default, so there is nothing to seed). If a user flips
  Steam to minimize-to-tray, the tray is invisible under Wine — the Quit Steam /
  Stop Bottle buttons cover that case.
- **winebrowser vs native Steam** (observed in Phase 3): when the in-bottle Steam
  bootstrapper opens `steam://` URLs, Wine's winebrowser forwards them to macOS,
  which launches the user's *native* Steam client if installed. Confusing during
  setup. Candidate fix: disable winebrowser in bottles
  (`WINEDLLOVERRIDES=winebrowser.exe=d`) or register a no-op steam:// handler
  in the prefix — validate neither breaks in-client store links we care about.

- **Steam client drift**: Valve ships CEF/UI changes that periodically break Wine; the
  launch-flag profile must be remotely updatable (same manifest mechanism as runtime).
- **Runtime sourcing**: redistribution terms of candidate builds need verification in
  Phase 1; worst case we build and host our own fork (LGPL Wine + GPTK terms).
- **macOS 26/27 changes**: Whisky targeted macOS 14; verify msync availability and
  Game Mode behavior on current OSes early in Phase 1.
- **Anti-cheat games** (EAC/BattlEye) mostly won't run under Wine — out of scope; the
  library UI should not pretend otherwise (later: compatibility badges via ProtonDB-style
  data, TBD).
