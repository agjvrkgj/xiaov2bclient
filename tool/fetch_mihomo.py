#!/usr/bin/env python3
"""Download a pinned official Mihomo desktop binary and verify its digest."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import platform as host_platform
from pathlib import Path
import shutil
import subprocess
import tempfile
from typing import Optional
import urllib.request
import zipfile


VERSION = "v1.19.30"
RELEASE_BASE = f"https://github.com/MetaCubeX/mihomo/releases/download/{VERSION}"
PROJECT_DIRECTORY = Path(__file__).resolve().parent.parent

ASSETS = {
    ("windows", "amd64"): (
        f"mihomo-windows-amd64-compatible-{VERSION}.zip",
        "289fde5e29d37a5b3326480590d8b3551c5bf7f8737290355c19bce74d57a563",
    ),
    ("windows", "arm64"): (
        f"mihomo-windows-arm64-{VERSION}.zip",
        "b37c4b0259e85b020edc4215aa4c86052e21071cf520d4800364b21b4e2fc162",
    ),
    ("macos", "amd64"): (
        f"mihomo-darwin-amd64-compatible-{VERSION}.gz",
        "6e75de0732e8afabe413ff7c235e8f16226ce136672371c60787cbf9607402c5",
    ),
    ("macos", "arm64"): (
        f"mihomo-darwin-arm64-{VERSION}.gz",
        "2c7f3a7904fa1cee291e124123e630e7b1ebd13765dd9bf26c0a28432004d9f4",
    ),
    ("linux", "amd64"): (
        f"mihomo-linux-amd64-compatible-{VERSION}.gz",
        "db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9",
    ),
    ("linux", "arm64"): (
        f"mihomo-linux-arm64-{VERSION}.gz",
        "58896873736d28628f66de3677c8654fa0f180662523148e136cff4f6e890069",
    ),
}


def normalize_platform(value: str) -> str:
    value = value.lower()
    return {"darwin": "macos", "win32": "windows"}.get(value, value)


def normalize_arch(value: str) -> str:
    value = value.lower()
    return {
        "x86_64": "amd64",
        "amd64": "amd64",
        "aarch64": "arm64",
        "arm64": "arm64",
    }.get(value, value)


def download(
    target_platform: str,
    target_arch: str,
    destination: Optional[Path] = None,
) -> Path:
    key = (target_platform, target_arch)
    if key not in ASSETS:
        supported = ", ".join(f"{os_name}/{arch}" for os_name, arch in ASSETS)
        raise SystemExit(f"Unsupported target {target_platform}/{target_arch}; use {supported}")

    asset_name, expected_digest = ASSETS[key]
    if destination is None:
        destination_directory = PROJECT_DIRECTORY / "assets" / "core" / target_platform
        destination = destination_directory / (
            "mihomo.exe" if target_platform == "windows" else "mihomo"
        )
    destination.parent.mkdir(parents=True, exist_ok=True)

    request = urllib.request.Request(
        f"{RELEASE_BASE}/{asset_name}",
        headers={"User-Agent": "xiaov2bclient-core-fetcher/1.0"},
    )
    print(f"Downloading {asset_name}")
    with urllib.request.urlopen(request, timeout=120) as response:
        compressed = response.read()

    actual_digest = hashlib.sha256(compressed).hexdigest()
    if actual_digest != expected_digest:
        raise SystemExit(
            f"SHA-256 mismatch for {asset_name}: expected {expected_digest}, "
            f"received {actual_digest}"
        )

    if asset_name.endswith(".gz"):
        destination.write_bytes(gzip.decompress(compressed))
    else:
        with tempfile.TemporaryDirectory(prefix="mihomo-") as temporary_directory:
            archive_path = Path(temporary_directory) / asset_name
            archive_path.write_bytes(compressed)
            with zipfile.ZipFile(archive_path) as archive:
                executable = next(
                    name for name in archive.namelist() if name.lower().endswith(".exe")
                )
                with archive.open(executable) as source, destination.open("wb") as output:
                    shutil.copyfileobj(source, output)

    destination.chmod(0o755)
    print(f"Verified {actual_digest} and wrote {destination}")
    return destination


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--platform",
        dest="target_platform",
        default=normalize_platform(host_platform.system()),
        choices=("windows", "macos", "linux"),
    )
    parser.add_argument(
        "--arch",
        dest="target_arch",
        default=normalize_arch(host_platform.machine()),
        choices=("amd64", "arm64", "universal"),
    )
    arguments = parser.parse_args()
    if arguments.target_arch == "universal":
        if arguments.target_platform != "macos":
            raise SystemExit("The universal target is only available for macOS")
        destination = PROJECT_DIRECTORY / "assets" / "core" / "macos" / "mihomo"
        with tempfile.TemporaryDirectory(prefix="mihomo-universal-") as directory:
            temporary = Path(directory)
            amd64 = download("macos", "amd64", temporary / "mihomo-amd64")
            arm64 = download("macos", "arm64", temporary / "mihomo-arm64")
            destination.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["lipo", "-create", str(amd64), str(arm64), "-output", str(destination)],
                check=True,
            )
            destination.chmod(0o755)
            print(f"Wrote universal macOS core to {destination}")
    else:
        download(arguments.target_platform, arguments.target_arch)


if __name__ == "__main__":
    main()
