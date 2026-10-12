#!/usr/bin/env python3
"""Convert a verified Recall runtime into Synthehol's Libraries layout.

The input is Recall's runtime.tar.gz, not an installed application directory.
Every archived regular file is checked against runtime.json before packaging.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
from typing import Optional


ROOT = Path(__file__).resolve().parent
CAPABILITIES = ROOT / "performance-capabilities.example.json"
RECALL_LICENSE = ROOT / "Recall/LICENSE"
RECALL_NOTICE = ROOT / "Recall/NOTICE"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def safe_member(member: tarfile.TarInfo) -> bool:
    path = PurePosixPath(member.name)
    return not path.is_absolute() and ".." not in path.parts


def extract_verified(archive: Path, destination: Path) -> str:
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        if not all(safe_member(member) for member in members):
            raise ValueError("Recall runtime contains an unsafe archive path")
        manifest_member = bundle.getmember("runtime.json")
        manifest = json.load(bundle.extractfile(manifest_member))
        if manifest.get("schema") != 1:
            raise ValueError("Unsupported Recall runtime manifest schema")
        bundle.extractall(destination, members=members)

    expected_files = manifest.get("files", {})
    actual_files = {
        str(path.relative_to(destination))
        for path in destination.rglob("*")
        if path.is_file() and path.name != "runtime.json"
    }
    if actual_files != set(expected_files):
        missing = sorted(set(expected_files) - actual_files)
        extra = sorted(actual_files - set(expected_files))
        raise ValueError(f"Runtime contents differ from manifest; missing={missing}, extra={extra}")
    for relative, identity in expected_files.items():
        path = destination / relative
        if path.stat().st_size != identity["bytes"] or sha256(path) != identity["sha256"]:
            raise ValueError(f"Runtime file verification failed: {relative}")
    return manifest["version"]


DXMT_COMPONENTS = [
    "lib/wine/x86_64-windows/d3d10core.dll",
    "lib/wine/x86_64-windows/d3d11.dll",
    "lib/wine/x86_64-windows/dxgi.dll",
    "lib/wine/x86_64-windows/winemetal.dll",
    "lib/wine/x86_64-unix/winemetal.so",
]


def package(source_archive: Path, output: Path, base_libraries: Optional[Path]) -> dict:
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite {output}")
    with tempfile.TemporaryDirectory(prefix="synthehol-performance-") as temporary:
        staging = Path(temporary)
        recall_root = staging / "recall"
        recall_root.mkdir()
        upstream_version = extract_verified(source_archive, recall_root)

        wine = staging / "package/Libraries/Wine"
        wine.parent.mkdir(parents=True)
        if base_libraries:
            base_wine = base_libraries / "Wine"
            if not (base_wine / "bin/wine64").exists():
                raise ValueError("Base runtime is missing Libraries/Wine/bin/wine64")
            shutil.copytree(base_wine, wine, symlinks=True)
            for relative in DXMT_COMPONENTS:
                source = recall_root / relative
                destination = wine / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                if destination.exists() or destination.is_symlink():
                    destination.unlink()
                shutil.copy2(source, destination)
            shutil.copy2(recall_root / "config/dxmt.conf", wine / "share/synthehol-recall-dxmt.conf")
        else:
            recall_root.rename(wine)
            (wine / "runtime.json").unlink()
        wine64 = wine / "bin/wine64"
        if not wine64.exists():
            wine64.symlink_to("wine")

        synthehol = wine / "share/synthehol"
        licenses = synthehol / "licenses"
        licenses.mkdir(parents=True)
        shutil.copy2(CAPABILITIES, synthehol / "performance-capabilities.json")
        shutil.copy2(RECALL_LICENSE, licenses / "Recall-APACHE-2.0")
        shutil.copy2(RECALL_NOTICE, licenses / "Recall-NOTICE")
        shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", licenses / "Synthehol-THIRD-PARTY-NOTICES.md")
        recall_licenses = recall_root / "licenses"
        if recall_licenses.exists():
            shutil.copytree(recall_licenses, licenses / "Recall-runtime", dirs_exist_ok=True)

        with tarfile.open(output, "w:gz", format=tarfile.PAX_FORMAT) as result:
            result.add(staging / "package/Libraries", arcname="Libraries", recursive=True)

    identity = {
        "schemaVersion": 1,
        "version": f"performance-{upstream_version}" + ("-steam" if base_libraries else ""),
        "archive": output.name,
        "sha256": sha256(output),
        "upstream": {
            "project": "Recall",
            "runtimeVersion": upstream_version,
            "archiveSHA256": sha256(source_archive),
        },
    }
    manifest = output.with_suffix(output.suffix + ".json")
    manifest.write_text(json.dumps(identity, indent=2) + "\n")
    return identity


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recall_runtime", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument(
        "--base-libraries", type=Path,
        help="Keep this Synthehol runtime's Wine build and overlay only Recall's DXMT components",
    )
    arguments = parser.parse_args()

    actual = sha256(arguments.recall_runtime)
    if actual != arguments.expected_sha256.lower():
        raise ValueError(f"Recall archive checksum mismatch: expected {arguments.expected_sha256}, got {actual}")
    identity = package(
        arguments.recall_runtime.resolve(), arguments.output.resolve(),
        arguments.base_libraries.resolve() if arguments.base_libraries else None,
    )
    print(json.dumps(identity, indent=2))


if __name__ == "__main__":
    main()
