# Console bootloader preserves hook stdin/stdout; BUNDLE supplies Apple's standard
# Frameworks/Resources layout for a correctly sealed nested helper application.
import os
from pathlib import Path
import platform

root = Path(SPECPATH).parent
identity = os.environ.get('PIP_SIGNING_IDENTITY')
analysis = Analysis([str(root / 'pip_helper.py')], pathex=[str(root)],
                    binaries=[], datas=[], hiddenimports=[], hookspath=[],
                    runtime_hooks=[], excludes=[], noarchive=False)
archive = PYZ(analysis.pure)
executable = EXE(archive, analysis.scripts, [], exclude_binaries=True,
                 name='PipHelper', debug=False, strip=False, upx=False,
                 console=True, target_arch=platform.machine(),
                 codesign_identity=identity, entitlements_file=None)
collection = COLLECT(executable, analysis.binaries, analysis.datas,
                     strip=False, upx=False, name='PipHelper')
app = BUNDLE(collection, name='PipRuntime.app', icon=None,
             bundle_identifier='dev.local.agent-companion.runtime',
             info_plist={'LSUIElement': True}, version='0.7.2')
