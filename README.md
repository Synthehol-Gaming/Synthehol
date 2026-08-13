# Synthehol

Play Windows games on your Mac. Synthehol creates Wine-based Windows "bottles" on
Apple Silicon Macs, sets up Steam inside them automatically, and presents your
installed games in a poster-style library ready to launch.

A spiritual successor to [Whisky](https://github.com/Whisky-App/Whisky) (archived
April 2025), focused specifically on managing and launching Windows *games* rather
than arbitrary Windows applications.

> Synthehol: all of the flavor, none of the side effects.

## Status

Early development — Phase 0 (scaffold). See [PLAN.md](PLAN.md) for the roadmap.

## Requirements

- Apple Silicon Mac (M1 or later)
- macOS 15+
- Rosetta 2 (Synthehol installs it during setup)

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Synthehol.xcodeproj
```

SyntheholKit (all non-UI logic) is a standalone Swift package:

```sh
cd SyntheholKit && swift test
```

## License

TBD.
