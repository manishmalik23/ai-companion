#!/usr/bin/env python3
"""Verify shipped archives and Finder layout without installing Pip."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from ds_store import DSStore


def verify_app(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    helper = app / "Contents/Helpers/PipRuntime.app/Contents/MacOS/PipHelper"
    output = subprocess.check_output([str(helper), "--version"], text=True, env={"PATH": "/usr/bin:/bin"})
    assert json.loads(output)["bundled"] is True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    release = parser.parse_args().release.resolve()
    manifest = json.loads((release / "release.json").read_text())
    for name, expected in manifest["sha256"].items():
        assert Path(name).name == name
        assert hashlib.sha256((release / name).read_bytes()).hexdigest() == expected
    zip_file = next(release / n for n in manifest["sha256"] if n.endswith(".zip"))
    dmg = next(release / n for n in manifest["sha256"] if n.endswith(".dmg"))
    with tempfile.TemporaryDirectory(prefix="pip-download-check-") as directory:
        root = Path(directory).resolve()
        extracted = root / "extracted"
        extracted.mkdir()
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(zip_file), str(extracted)], check=True)
        verify_app(extracted / "Pip.app")
        mount = root / "mounted"
        mount.mkdir()
        subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg)],
                       check=True, stdout=subprocess.PIPE)
        try:
            assert (mount / "Applications").is_symlink()
            assert (mount / "Applications").readlink() == Path("/Applications")
            with DSStore.open(str(mount / ".DS_Store"), "r") as store:
                assert store["Pip.app"]["Iloc"] == (140, 140)
                assert store["Applications"]["Iloc"] == (500, 140)
                assert store["."]["icvp"]["iconSize"] == 96
                assert store["."]["icvp"]["backgroundType"] == 2
                assert store["."]["bwsp"]["ShowToolbar"] is False
            verify_app(mount / "Pip.app")
        finally:
            subprocess.run(["/usr/bin/hdiutil", "detach", str(mount)], check=True, stdout=subprocess.PIPE)
    print(json.dumps({"release_hashes": "passed", "extracted_zip_signature_and_runtime": "passed",
                      "mounted_dmg_signature_runtime_and_applications_shortcut": "passed", "finder_installer_layout": "passed"}))


if __name__ == "__main__":
    main()
