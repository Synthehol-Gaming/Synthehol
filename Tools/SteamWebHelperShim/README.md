# Steam WebHelper shim

This tiny Windows launcher adds `--disable-gpu --single-process` directly to
Steam's Chromium helper, then delegates to `steamwebhelper_real.exe`. It is
cross-compiled with MinGW and bundled as a SyntheholKit resource.

Build from the repository root:

```sh
mkdir -p SyntheholKit/Sources/SyntheholKit/Resources
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Wpedantic -municode \
  -DUNICODE -D_UNICODE -static -mwindows \
  -o SyntheholKit/Sources/SyntheholKit/Resources/steamwebhelper-shim.exe \
  Tools/SteamWebHelperShim/steamwebhelper-shim.c
```

The implementation is based on the MIT-licensed wrapper from
`notpop/steam-on-m1-wine`.
