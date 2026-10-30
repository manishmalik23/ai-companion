#!/usr/bin/env python3
"""Maintainer-only portable build Python, verified against a pinned upstream hash."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import urllib.parse

ROOT = Path(__file__).resolve().parent.parent
RELEASE = "20261013"
VERSION = "3.12.15"
ARCHIVES = {
    "arm64": ("aarch64", "8c7ac5f091c64111247e595c9fc8fecc38453e94a60323a3b66dbfca3c01414a"),
    "x86_64": ("x86_64", "7b24fd8362742c471989a4491770beb377f0127c8671778a223d6c6b6c10a578"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wheelhouse", type=Path, help="Optional predownloaded packaging wheels")
    args = parser.parse_args()
    if sys.platform != "darwin" or platform.machine() not in ARCHIVES:
        parser.error("Run on an Apple silicon or Intel Mac")
    target, checksum = ARCHIVES[platform.machine()]
    filename = f"cpython-{VERSION}+{RELEASE}-{target}-apple-darwin-pgo+lto-full.tar.zst"
    url = "https://github.com/astral-sh/python-build-standalone/releases/download/" + RELEASE + "/" + urllib.parse.quote(filename)
    destination = ROOT / ".build/release-python"
    destination.mkdir(parents=True, exist_ok=True)
    archive = destination / filename
    if not archive.exists():
        temporary = destination / (filename + ".download")
        print("Downloading portable build Python from Astral's GitHub release…", flush=True)
        # macOS curl uses the system trust store; keep TLS verification enabled.
        subprocess.run(["/usr/bin/curl", "--fail", "--location", "--retry", "2",
                        "--connect-timeout", "20", "--output", str(temporary), "--url", url], check=True)
        temporary.rename(archive)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
            raise RuntimeError("Portable Python archive checksum mismatch; do not use this download")
    python = destination / "python/install/bin/python3"
    if not python.exists():
        subprocess.run(["/usr/bin/tar", "-xf", str(archive), "-C", str(destination)], check=True)
    venv = destination / "venv"
    if not venv.exists():
        subprocess.run([str(python), "-m", "venv", str(venv)], check=True)
    command = [str(venv / "bin/python"), "-m", "pip", "install", "--disable-pip-version-check"]
    if args.wheelhouse:
        command += ["--no-index", "--find-links", str(args.wheelhouse.resolve())]
    command += ["-r", str(ROOT / "scripts/package-requirements.txt")]
    subprocess.run(command, check=True)
    (destination / "provenance.json").write_text(json.dumps({"python": VERSION, "release": RELEASE,
        "url": url, "sha256": checksum, "architecture": platform.machine()}, indent=2) + "\n")
    print("Build environment ready: " + str(venv / "bin/python"))


if __name__ == "__main__":
    main()
