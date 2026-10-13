#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

(
  cd "$root/Recall"
  shasum -a 256 -c patches.sha256
)

capabilities="$root/performance-capabilities.example.json"
grep -q '"schemaVersion"[[:space:]]*:[[:space:]]*1' "$capabilities"
for feature in \
  dxmt.default-metal-cache \
  dxmt.eager-shader-preparation \
  dxmt.parallel-shader-compilation \
  dxmt.release-shader-ir \
  dxmt.triple-buffering
do
  grep -q "\"$feature\"" "$capabilities"
done

echo "Performance runtime inputs and v1 capability contract verified."

(
  cd "$root/Compatibility"
  printf '%s\n' '7257939ce4d2968ab801da15b6775ea5beaeb3873c8f4745f6076ece30316dd5  dxmt-skyrim-destroyed-object-release.patch' | shasum -a 256 -c -
)
