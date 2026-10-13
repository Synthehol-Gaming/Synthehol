# Synthehol Performance Runtime

This directory defines the boundary between Synthehol's MIT-licensed app and an
optional patched Wine/DXMT runtime. The app never assumes that a downloaded stock
runtime contains these changes. A compatible build advertises them by installing:

`Libraries/Wine/share/synthehol/performance-capabilities.json`

The native Mac Steam runner clones `Libraries/Wine`, so the marker and patched
binaries travel together. Bottle launches inspect the same marker. Removing or
rolling back the runtime therefore disables enhanced profiles without altering
saved per-game settings.

## Recall-derived patch set

The initial runtime target follows the source and patch ordering documented by
[AsherJN/recall](https://github.com/AsherJN/recall), pinned there in
`docs/SOURCES.json`:

1. DXMT commit `c5dc3a0dfe9108e667da43de871324bd298c9c02`
2. `dxmt-v1-private.patch`
3. `dxmt-v1-performance.patch`
4. `dxmt-portable-metal.patch`
5. CrossOver 26.3 Wine sources, followed by Recall's Wine patches in their
   documented order

The hash-pinned Skyrim resource lifetime fix in
`Compatibility/dxmt-skyrim-destroyed-object-release.patch` is optional. Build it
explicitly with `apply-dxmt-patches.sh /path/to/source --fix=dxmt-resource-lifetime`;
the default patch sequence leaves it out. Provenance is recorded in
`Compatibility/SOURCES.json`. The patch makes
the resource/view base classes tolerate Skyrim's extra `Release` call after
destruction, avoiding the pure-virtual abort described in
[DXMT issue #231](https://github.com/3Shain/dxmt/issues/231).

Local validation on 2026-10-13: rebuilt the x64 DXMT PE modules at the pinned
revision with the existing Recall patches and this fix. The diagnostic build
linked against the installed `winemetal.dll` exports and reused the installed
renderer’s embedded Metal shader library (unchanged by this C++ patch), because
the local Xcode installation lacked the Metal toolchain component. With the
patched modules selected only for Skyrim's launcher/game executables, Skyrim
reached the main menu and the user confirmed it. Gameplay has not been validated.
The test DLLs are installed locally, not distributed with Synthehol. Full runtime
distribution still requires the reproducible clean-source build described below.

Synthehol's compatibility catalog tracks versioned patched renderers independently
of game recommendations. Users import a fix package folder containing
`FixPackage.json` (`fixID` and `version`) and the catalog-pinned DLLs. Importing is
inert. From a game's settings they explicitly select **Compatibility Fixes →
Apply to Game Executable** to try a version, including with games absent from the
affected-games list. DLLs go beside the selected executable and registry overrides
are scoped to its filename. **Remove Fix** restores the backed-up files and values,
preserving unrelated settings and refusing to overwrite subsequent user changes.
Packages are rejected if their hashes or the runtime's Wine Metal bridge differ
from the catalog. New verified versions need a new catalog entry; a user-supplied
manifest cannot redefine trusted checksums. No discovery, recommendation, import,
or launch automatically enables a fix.

The selected patches are vendored under `Recall/patches`; `Recall/LICENSE` and
`Recall/NOTICE` are retained verbatim. Run `./verify.sh` before every build to
verify all patch bytes against `Recall/patches.sha256` and validate the runtime
capability contract.

Do not publish a runtime until its complete source archive, patch inputs, build
recipe, and SHA-256 are reproducible. Runtime archives must be added through a
`RuntimeManifest`; Synthehol will verify their SHA-256 before installation.

The enabled initial capability set deliberately excludes MetalFX/NVAPI emulation
and executable-specific mouse-look rules. Those need per-title validation rather
than a global Maximum FPS switch.

## Capability contract

The current launcher treats the marker as an all-or-nothing v1 contract and applies:

- Balanced: three drawables and the default persistent Metal cache.
- Maximum FPS: Balanced plus eager shader preparation, early shader IR release,
  and eight normal-priority compiler workers.

Copy `performance-capabilities.example.json` into the runtime only after all listed
features are present and validated. Future partial capability sets must increment
the schema and update both Swift and the native Steam parser before shipping.

For local integration testing, `package-recall-runtime.py` converts Recall's
published `runtime.tar.gz` into Synthehol's `Libraries/Wine` archive layout. It
requires the expected archive SHA-256, verifies every file against Recall's inner
`runtime.json`, preserves the runtime's component licenses, adds Recall attribution
and the v1 capability manifest, and emits a sidecar manifest containing the final
archive checksum. This is a packaging bridge, not a dependency on an installed
copy of Recall.

For Mac Steam, pass `--base-libraries` pointing at Synthehol's supported
CrossOver 26.3 `Libraries` directory. This retains the exact Wine and `ntdll.dll`
binaries verified by the Steam IPC bridge and overlays only Recall's four DXMT PE
modules and `winemetal.so`. The resulting sidecar version ends in `-steam`.

```sh
./package-recall-runtime.py /path/to/recall-runtime.tar.gz \
  /path/to/SyntheholPerformance-Libraries.tar.gz \
  --expected-sha256 <recall-runtime-sha256> \
  --base-libraries /path/to/Runtime/4.5.105-beta.1/Libraries
```

Install the generated `.tar.gz.json` from **Synthehol → Settings → Runtime →
Import Performance Runtime…**, or with `synthehol-dev runtime install-local`.
