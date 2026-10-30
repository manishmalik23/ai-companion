#!/usr/bin/env python3
"""Package explicit source files; exclude personal state and third-party art."""
import hashlib
import argparse
import json
from pathlib import Path
import re
import zipfile

root = Path(__file__).resolve().parent.parent
version = re.search(r'CFBundleShortVersionString</key><string>([^<]+)',
                    (root / 'build.sh').read_text()).group(1)
files = [root / name for name in (
    '.gitignore', 'README.md', 'ASSETS.md', 'GITHUB_SETUP.md', 'RELEASE_CHECKS.md',
    'CONTRIBUTING.md', '.github/pull_request_template.md',
    'build.sh', 'build-installer.sh', 'run.sh', 'demo.sh', 'install_local.py', 'setup_hooks.py',
    'bridge.py', 'session_titles.py', 'chat_bridge.py', 'telemetry.py', 'pip_helper.py', 'connections.py',
    'scripts/package-requirements.txt', 'scripts/PipRuntime.spec', 'DISTRIBUTION.md')]
for directory in ('desktop', 'tests', 'examples', 'scripts'):
    files.extend(p for p in (root / directory).rglob('*') if p.is_file()
                 and p.suffix in ('.swift', '.py', '.sh', '.json', '.entitlements'))
helper = root / 'vscode-session-links'
for name in ('.gitignore', '.yarnrc', 'README.md', 'NOTICE.txt', 'package.json', 'tsconfig.json', 'yarn.lock'):
    files.append(helper / name)
for directory in ('src', 'test', 'scripts'):
    files.extend(p for p in (helper / directory).rglob('*') if p.is_file()
                 and p.suffix in ('.ts', '.mjs', '.json'))
files.append(root / 'desktop/Resources/PipSpriteSheet.png')
files.extend(root / 'desktop/Resources/Characters' / (name + suffix + '.png')
             for name in ('Sunny', 'Mochi', 'Boba', 'Lumi', 'Mallow', 'Sprout') for suffix in ('', 'Blink'))
files.extend(root / 'desktop/Resources/Characters' / (name + '.png')
             for name in ('PeachPuff', 'LavenderMochi', 'MintBean', 'Nimbo', 'Chai', 'Plumo'))
files.extend(root / name for name in ('design/characters/README.txt', 'design/characters/generation-prompts.json',
    'design/characters/fluffy-generation-prompts.json', 'design/characters/fluffy-margin-correction-prompts.json',
    'design/characters/measure_fluffy_layouts.swift'))
shared = root / 'cross-platform'
for name in ('.gitignore', '.yarnrc', 'README.md', 'package.json', 'tsconfig.json', 'yarn.lock'):
    files.append(shared / name)
for directory in ('src', 'tests', 'scripts', 'ui'):
    files.extend(p for p in (shared / directory).rglob('*') if p.is_file()
                 and p.suffix in ('.ts', '.cjs', '.html', '.css'))
assert len(files) == len(set(files))
assert all(p.is_file() and not p.is_symlink() for p in files)
manifest = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(files)}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, help='Optional new ZIP path; existing files are never overwritten.')
arguments = parser.parse_args()
output = arguments.output or root / '.build/releases' / ('Pip-' + version + '-source.zip')
if not output.is_absolute(): output = root / output
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
    for p in sorted(files):
        archive.write(p, 'Pip/' + p.relative_to(root).as_posix())
    archive.writestr('Pip/SOURCE_MANIFEST.json', json.dumps(manifest, indent=2) + '\n')
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert len(archive.namelist()) == len(files) + 1
    for name, expected in manifest.items():
        assert hashlib.sha256(archive.read('Pip/' + name)).hexdigest() == expected
print(json.dumps({'archive': str(output), 'version': version, 'source_files': len(files),
                  'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                  'integrity': 'passed', 'distribution': 'private source beta'}))
