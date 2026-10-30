#!/usr/bin/env python3
"""Install the real built app into a temporary home, without launching it."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(project))
import install_local as installer

with tempfile.TemporaryDirectory(prefix='pip-clean-install-') as directory:
    home = Path(directory).resolve() / 'home'
    home.mkdir()
    source_project = project
    project = Path(directory).resolve() / 'project'
    project.mkdir()
    for name in installer.SCRIPT_NAMES:
        shutil.copy2(source_project / name, project / name)
    shutil.copytree(source_project / 'dist', project / 'dist')
    paths = installer.locations(home, project)
    # Both home and project are disposable: never overwrite a developer's plan.
    plan = installer.create_plan(home, project)
    installer.atomic_bytes(paths['plan'], installer.encoded_json(plan))
    try:
        installer.apply(home, project)
        installer.managed_state(paths)
        app = paths['app']
        plist = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        source_info = plistlib.loads((source_project / 'dist/Agent Companion.app/Contents/Info.plist').read_bytes())
        assert plist['CFBundleShortVersionString'] == source_info['CFBundleShortVersionString']
        assert Path(plist['CompanionRuntimePath']).is_relative_to(home)
        assert (app / 'Contents/Resources/PipSpriteSheet.png').is_file()
        for character in ('Sunny', 'Mochi', 'Boba', 'Lumi', 'Mallow', 'Sprout'):
            for suffix in ('', 'Blink'):
                relative = Path('Contents/Resources/Characters') / (character + suffix + '.png')
                assert (app / relative).read_bytes() == (source_project / 'dist/Agent Companion.app' / relative).read_bytes()
        for filename in ('PeachPuff.png', 'LavenderMochi.png', 'MintBean.png', 'Nimbo.png',
                         'Chai.png', 'Plumo.png', 'FluffyLayouts.json'):
            relative = Path('Contents/Resources/Characters') / filename
            assert (app / relative).read_bytes() == (source_project / 'dist/Agent Companion.app' / relative).read_bytes()
        assert not (app / 'Contents/Resources/CodexSpriteSheet.webp').exists()
        assert (paths['support'] / 'session_titles.py').read_bytes() == (source_project / 'session_titles.py').read_bytes()
        # Run the installed source bridge away from the checkout with Python
        # environment/user imports disabled. --help never invokes an agent or
        # reads conversations, and catches missing copied sibling dependencies.
        bridge_check = subprocess.run([
            sys.executable, '-E', '-s', '-B', str(paths['support'] / 'bridge.py'), '--help'
        ], cwd=home, capture_output=True, text=True, timeout=5, check=True)
        assert '{hook,demo,telemetry}' in bridge_check.stdout
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        for _, settings in paths['settings']:
            document = json.loads(settings.read_text())
            assert 'PermissionRequest' in document['hooks']
        runtime = paths['support'] / '.runtime'
        appearance = runtime / 'appearance'
        appearance.mkdir(mode=0o700)
        profile = appearance / 'character.json'
        original = b'{"fixture":"preserve custom character"}\n'
        installer.atomic_bytes(profile, original)
        settings_before = {str(p): p.read_bytes() for _, p in paths['settings']}
        plan = installer.create_plan(home, project)
        installer.atomic_bytes(paths['plan'], installer.encoded_json(plan))
        installer.apply(home, project)
        installer.managed_state(paths)
        assert profile.read_bytes() == original
        assert all(p.read_bytes() == settings_before[str(p)] for _, p in paths['settings'])
        print('Passed real-bundle fresh installation, installed source bridge imports, signature, hooks, idempotent update, and custom-profile preservation checks in a temporary home. No app launched or real user settings changed.')
    finally:
        paths['plan'].unlink(missing_ok=True)
