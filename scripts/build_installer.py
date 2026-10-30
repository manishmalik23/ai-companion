#!/usr/bin/env python3
"""Build a local Mac installer using an already installed Python and build tools."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PYTHON_PROBE = r'''
import ensurepip, json, sys, sysconfig, venv
from pathlib import Path
base = Path(sys.base_prefix)
candidates = [base / name for name in ("LICENSE", "LICENSE.txt")]
candidates.append(Path(sysconfig.get_path("stdlib")) / "LICENSE.txt")
candidates += [p / "LICENSE" for p in base.parents
               if p.name.startswith("python") or p.parent.name.startswith("python")]
import _ssl
print(json.dumps({"version": list(sys.version_info[:3]), "python": sys.executable,
    "license": next((str(p) for p in candidates if p.is_file()), None),
    "ssl": _ssl.__file__, "distribution_licenses":
    (base.parent / "licenses").is_dir() and (base.parent / "PYTHON.json").is_file()}))
'''


def output(*command, **kwargs):
    return subprocess.check_output(list(map(str, command)), text=True,
                                   stderr=subprocess.STDOUT, timeout=30, **kwargs).strip()


def preflight(args):
    issues = []
    macos = platform.mac_ver()[0]
    if sys.platform != "darwin" or not macos or tuple(map(int, macos.split("."))) < (13, 0):
        issues.append("Use a Mac running macOS 13 or newer.")
    tools_ready = False
    try:
        output("/usr/bin/xcode-select", "-p")
        output("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path")
        output("/usr/bin/swiftc", "--version")
        tools_ready = True
    except (OSError, subprocess.SubprocessError):
        issues.append("Complete Xcode Command Line Tools setup first: run xcode-select --install (or finish setup in Xcode), then retry.")
    python = shutil.which(args.python or sys.executable)
    if python is None:
        issues.append("Install an approved Python 3.11+ with venv/ensurepip, or pass --python /path/to/python3.")
    else:
        try:
            info = json.loads(output(python, "-I", "-B", "-c", PYTHON_PROBE))
            if tuple(info["version"]) < (3, 11):
                issues.append("Python 3.11+ is required; pass --python /path/to/an/installed/python3.11-or-newer.")
            if not info["license"]:
                issues.append("This Python lacks its redistributable LICENSE. Choose a complete Python installation with --python; Apple's CLT Python may be unsuitable.")
            linked = output("/usr/bin/otool", "-L", info["ssl"]) if tools_ready else ""
            if re.search(r"lib(?:ssl|crypto)", linked) and not info["distribution_licenses"] and not any(
                    (Path(prefix) / "opt/openssl@3/LICENSE.txt").is_file() for prefix in ("/opt/homebrew", "/usr/local")):
                issues.append("This Python links OpenSSL, but its LICENSE.txt is missing. Restore the license from your approved Python/OpenSSL installation.")
        except (OSError, ValueError, KeyError, subprocess.SubprocessError):
            issues.append("The selected Python must include working venv, ensurepip and ssl modules. Use --python with a complete Python 3.11+ installation.")
    for tool, requirement in [("node", "Node.js 20+"), ("yarn", "Yarn Classic 1.22.22")]:
        executable = shutil.which(tool)
        try:
            version = output(executable, "--version", env=dict(os.environ, COREPACK_ENABLE_NETWORK="0")) if executable else ""
            valid = bool(re.match(r"v?(\d+)\.", version)) and int(version.lstrip("v").split(".")[0]) >= 20 if tool == "node" else version == "1.22.22"
            if not valid:
                issues.append("Install or select " + requirement + " through your approved tooling, then put it on PATH.")
        except (OSError, subprocess.SubprocessError):
            issues.append("Make " + requirement + " available on PATH. Corepack tool downloads are disabled; install Yarn once through your approved tooling.")
    if args.output and os.path.lexists(args.output):
        issues.append("--output must name a new directory; existing paths and symlinks are never overwritten.")
    if issues:
        raise RuntimeError("Prerequisites need attention:\n" + "\n".join("  - " + issue for issue in issues))
    return python, macos


def run(*command, **kwargs):
    print("\n" + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), check=True, **kwargs)


@contextmanager
def build_lock(builds):
    descriptor = os.open(builds / "build.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another installer build is running in this checkout. Wait for it to finish, then retry.")
        yield
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", help="Existing Python 3.11+ executable (default: the Python running this script)")
    parser.add_argument("--output", type=lambda value: Path(value).expanduser().absolute(), help="New output directory; default: a fresh .build/installers/local-*/installer directory")
    parser.add_argument("--no-open", action="store_true", help="Build without opening the finished DMG")
    parser.add_argument("--check", action="store_true", help="Check prerequisites only, without downloads or creating build files")
    args = parser.parse_args()
    try:
        python, macos = preflight(args)
        if args.check:
            print("Prerequisites ready. No build files created.")
            return 0
        builds = ROOT / ".build/installers"
        builds.mkdir(parents=True, exist_ok=True)
        with build_lock(builds):
            work = Path(tempfile.mkdtemp(prefix="local-", dir=builds))
            destination = args.output or work / "installer"
            environment = dict(os.environ, COREPACK_ENABLE_NETWORK="0")
            helper = ROOT / "vscode-session-links"
            print("Building locally in " + str(work), flush=True)
            print("Registry access is needed for the locked Yarn and pip dependencies.", flush=True)
            run("yarn", "install", "--frozen-lockfile", "--non-interactive", cwd=helper, env=environment)
            run("yarn", "package", cwd=helper, env=environment)
            run(python, "-m", "venv", work / "venv")
            build_python = work / "venv/bin/python"
            run(build_python, "-m", "pip", "install", "--disable-pip-version-check", "-r", ROOT / "scripts/package-requirements.txt")
            run(build_python, ROOT / "scripts/package_macos.py", "--dmg", "--output", destination,
                "--max-minimum-macos", macos, cwd=ROOT)
            images = list(destination.glob("*.dmg"))
            if len(images) != 1:
                raise RuntimeError("Expected one completed DMG in " + str(destination))
            manifest = json.loads((destination / "release.json").read_text())
            print("\nInstaller: " + str(images[0]), flush=True)
            print("Minimum macOS: " + manifest["minimum_macos"] + " (measured from this local build)", flush=True)
            if not args.no_open:
                run("/usr/bin/open", images[0])
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("Build stopped: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
