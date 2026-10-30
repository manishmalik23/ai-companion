#!/usr/bin/env python3
"""Build a self-contained Mac download. Run on the architecture being shipped."""
import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import sysconfig

ROOT = Path(__file__).resolve().parent.parent
MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
         b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def run(*arguments, **kwargs):
    return subprocess.run(list(map(str, arguments)), check=True, **kwargs)


def machos(root):
    for path in root.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MAGIC:
                    yield path


def minimum_version(app):
    versions = [(13, 0)]
    for path in machos(app):
        output = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
        for block in output.split("Load command"):
            pattern = r"\bminos\s+([\d.]+)" if "LC_BUILD_VERSION" in block else (
                r"\bversion\s+([\d.]+)" if "LC_VERSION_MIN_MACOSX" in block else None)
            match = re.search(pattern, block) if pattern else None
            if match:
                versions.append(tuple(map(int, match[1].split("."))))
    return ".".join(map(str, max(versions)))


def add_licenses(resources, helper):
    destination = resources / "Licenses"
    destination.mkdir()
    distribution_licenses = Path(sys.base_prefix).parent / "licenses"
    if distribution_licenses.is_dir() and (Path(sys.base_prefix).parent / "PYTHON.json").is_file():
        shutil.copytree(distribution_licenses, destination / "Python distribution")
    python_candidates = [Path(sys.base_prefix) / name for name in ("LICENSE", "LICENSE.txt")]
    python_candidates.append(Path(sysconfig.get_path("stdlib")) / "LICENSE.txt")
    python_candidates += [parent / "LICENSE" for parent in Path(sys.base_prefix).parents
                          if parent.name.startswith("python") or parent.parent.name.startswith("python")]
    license_file = next((p for p in python_candidates if p.is_file()), None)
    if license_file is None:
        raise RuntimeError("The build Python's LICENSE file must be available before distributing it")
    shutil.copy2(license_file, destination / "Python.txt")
    package = importlib.metadata.distribution("PyInstaller")
    copying = next((package.locate_file(p) for p in package.files or [] if p.name == "COPYING.txt"), None)
    if copying is None:
        raise RuntimeError("PyInstaller's COPYING.txt is missing")
    shutil.copy2(copying, destination / "PyInstaller.txt")
    # The DMG uses dmgbuild's bundled arrow artwork; include its MIT notice.
    try:
        installer = importlib.metadata.distribution("dmgbuild")
        notice = next((installer.locate_file(p) for p in installer.files or [] if p.name == "LICENSE"), None)
        if notice is not None:
            shutil.copy2(notice, destination / "Installer artwork.txt")
    except importlib.metadata.PackageNotFoundError:
        pass  # ZIP-only builders do not need the optional DMG artwork.
    if not distribution_licenses.is_dir() and any("libcrypto" in p.name or "libssl" in p.name for p in helper.rglob("*")):
        openssl = next((Path(prefix) / "opt/openssl@3/LICENSE.txt" for prefix in ("/opt/homebrew", "/usr/local")
                        if (Path(prefix) / "opt/openssl@3/LICENSE.txt").is_file()), None)
        if openssl is None:
            raise RuntimeError("This Python includes OpenSSL; its LICENSE.txt must be available")
        shutil.copy2(openssl, destination / "OpenSSL.txt")
    shutil.copy2(ROOT / "ASSETS.md", resources / "Asset provenance.txt")


def build_dmg(app, dmg, version):
    import dmgbuild
    background = dmg.parent / "installer-background.png"
    run("/usr/bin/swift", "-module-cache-path", ROOT / ".build/module-cache",
        ROOT / "scripts/InstallerBackground.swift", background)
    # Keep Finder presentation in .DS_Store; changing FinderInfo on a sealed app
    # (for example to hide its extension) breaks strict signature verification.
    dmgbuild.build_dmg(str(dmg), "Pip " + version, settings={
        "format": "UDZO", "filesystem": "HFS+",
        "files": [str(app)], "symlinks": {"Applications": "/Applications"},
        "icon_locations": {"Pip.app": (140, 140), "Applications": (500, 140)},
        "background": str(background), "window_rect": ((200, 200), (640, 360)),
        "default_view": "icon-view", "icon_size": 96, "text_size": 14,
        "label_pos": "bottom",
        "show_toolbar": False, "show_sidebar": False, "show_status_bar": False,
        "show_pathbar": False, "show_tab_view": False,
    })
    background.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New output directory; existing directories are never overwritten")
    parser.add_argument("--identity", help="Developer ID Application identity; otherwise create an ad-hoc beta")
    parser.add_argument("--notary-profile", help="Existing notarytool Keychain profile; requires --identity")
    parser.add_argument("--dmg", action="store_true", help="Also build a drag-and-drop disk image")
    parser.add_argument("--max-minimum-macos", default="13.0", help="Refuse dependencies requiring newer macOS (default: 13.0)")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Run this builder on macOS")
    if args.notary_profile and not args.identity:
        parser.error("Notarization requires a Developer ID signing identity")
    if importlib.metadata.version("PyInstaller") != "6.22.3":
        parser.error("Install scripts/package-requirements.txt in your build environment")
    if not (ROOT / "vscode-session-links/artifacts/pip-session-links-0.3.0.vsix").is_file():
        parser.error("Build the VS Code session helper first: cd vscode-session-links && yarn install --frozen-lockfile && yarn package")
    run("/bin/bash", ROOT / "build.sh", cwd=ROOT)
    source = ROOT / "dist/Agent Companion.app"
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    name = "Pip-" + info["CFBundleShortVersionString"] + "-macos-" + platform.machine()
    output = (args.output or ROOT / ".build/releases" / name).absolute()
    output.mkdir(parents=True, exist_ok=False)
    work = output / "build-work"
    work.mkdir()
    env = dict(os.environ, PYINSTALLER_CONFIG_DIR=str(work / "pyinstaller-cache"))
    command = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
               "--distpath", str(work / "dist"), "--workpath", str(work / "work")]
    if args.identity:
        env["PIP_SIGNING_IDENTITY"] = args.identity
    command.append(str(ROOT / "scripts/PipRuntime.spec"))
    run(*command, env=env, cwd=ROOT)
    app = output / "Pip.app"
    shutil.copytree(source, app, symlinks=True)
    helper = app / "Contents/Helpers/PipRuntime.app"
    helper.parent.mkdir()
    shutil.copytree(work / "dist/PipRuntime.app", helper, symlinks=True)
    add_licenses(app / "Contents/Resources", helper)
    info["LSMinimumSystemVersion"] = minimum_version(app)
    if tuple(map(int, info["LSMinimumSystemVersion"].split("."))) > tuple(map(int, args.max_minimum_macos.split("."))):
        raise RuntimeError("Build dependencies require macOS " + info["LSMinimumSystemVersion"] +
                           ". Use scripts/bootstrap_package.py for a portable build runtime.")
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    identity = args.identity or "-"
    signing = ["--options", "runtime", "--timestamp"] if args.identity else []
    # Sign nested native code from inside out. No customer-side signing is used.
    for binary in sorted(machos(app), key=lambda p: len(p.parts), reverse=True):
        if binary.parent.name == "MacOS":
            continue  # Seal each application at its bundle root, after its libraries.
        run("/usr/bin/codesign", "--force", "--sign", identity, *signing, binary,
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for framework in sorted(app.rglob("*.framework"), key=lambda p: len(p.parts), reverse=True):
        if not framework.is_symlink():
            run("/usr/bin/codesign", "--force", "--sign", identity, *signing, framework)
    run("/usr/bin/codesign", "--force", "--sign", identity, *signing, helper)
    run("/usr/bin/codesign", "--force", "--sign", identity, *signing,
        "--entitlements", ROOT / "scripts/PipApp.entitlements", app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    if args.notary_profile:
        submission = work / "notary.zip"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission)
        run("/usr/bin/xcrun", "notarytool", "submit", submission, "--keychain-profile", args.notary_profile, "--wait")
        run("/usr/bin/xcrun", "stapler", "staple", app)
        run("/usr/bin/xcrun", "stapler", "validate", app)
    archive = output / (name + ".zip")
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    readme = ("Pip " + info["CFBundleShortVersionString"] + "\n\n"
              "1. Drag Pip to Applications in the installer window.\n"
              "2. Open Applications, then double-click Pip to start it. Copying alone does not start Pip.\n"
              "Alternatively, open Pip in the disk image and choose Move to Applications to install and open it.\n"
              "The installed app opens Agent connections; it is also available from Pip's menu.\n"
              "Python, Xcode, Git, Node and Yarn are not required to run this download.\n"
              "Install/sign in to Claude Code or Codex separately. Host hook trust still applies.\n"
              "Minimum macOS: " + info["LSMinimumSystemVersion"] + "; architecture: " + platform.machine() + ".\n" +
              ("Developer ID signed" if args.identity else "Private beta: ad-hoc signed; Gatekeeper may require manual approval") +
              (", Apple notarized.\n" if args.notary_profile else "; not notarized.\n"))
    (output / "Read me.txt").write_text(readme)
    downloads = [archive]
    if args.dmg:
        dmg = output / (name + ".dmg")
        build_dmg(app, dmg, info["CFBundleShortVersionString"])
        if args.identity:
            run("/usr/bin/codesign", "--sign", args.identity, "--timestamp", dmg)
        if args.notary_profile:
            run("/usr/bin/xcrun", "notarytool", "submit", dmg, "--keychain-profile", args.notary_profile, "--wait")
            run("/usr/bin/xcrun", "stapler", "staple", dmg)
        downloads.append(dmg)
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in downloads}
    manifest = {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
                "installer_revision": 2, "architecture": platform.machine(),
                "minimum_macos": info["LSMinimumSystemVersion"], "self_contained": True,
                "python": platform.python_version(),
                "developer_id_signed": bool(args.identity), "notarized": bool(args.notary_profile), "sha256": hashes}
    (output / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # Build inputs stay out of customer archives. Keep work locally for diagnostics.
    print(json.dumps({"output": str(output), **manifest}, indent=2))


if __name__ == "__main__":
    main()
