#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/dxmt-source" >&2
  exit 64
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source_dir=$1
expected=c5dc3a0dfe9108e667da43de871324bd298c9c02
actual=$(git -C "$source_dir" rev-parse HEAD)
if [ "$actual" != "$expected" ]; then
  echo "DXMT must be checked out at $expected (found $actual)" >&2
  exit 65
fi

"$root/verify.sh"
for patch in \
  dxmt-v1-private.patch \
  dxmt-v1-performance.patch \
  dxmt-portable-metal.patch
do
  patch_path="$root/Recall/patches/$patch"
  if git -C "$source_dir" apply --check "$patch_path"; then
    git -C "$source_dir" apply "$patch_path"
  elif git -C "$source_dir" apply --reverse --check "$patch_path"; then
    echo "$patch is already applied"
  else
    echo "$patch does not apply cleanly" >&2
    exit 66
  fi
done

echo "Synthehol's Recall-derived DXMT patches are applied."
