import test from 'node:test';
import assert from 'node:assert/strict';
import { deflateRawSync } from 'node:zlib';

const installer = require('../../scripts/session-links.cjs');
const pkg = {
  name: 'pip-session-links', publisher: 'pip-local', version: '0.3.0', main: './dist/src/extension.js',
  packageManager: 'yarn@1.22.22', devDependencies: { '@types/node': '22.18.6', '@types/vscode': '1.95.0', typescript: '5.9.3' },
  scripts: { build: 'tsc -p tsconfig.json', test: 'yarn build && node --test dist/test/*.test.js', package: 'yarn build && node scripts/package.mjs' }
};

function archive(manifest: unknown, name = 'extension/package.json'): Buffer {
  const data = Buffer.from(JSON.stringify(manifest)), filename = Buffer.from(name), compressed = deflateRawSync(data);
  const header = Buffer.alloc(30);
  header.writeUInt32LE(0x04034b50); header.writeUInt16LE(0x800, 6); header.writeUInt16LE(8, 8);
  header.writeUInt32LE(compressed.length, 18); header.writeUInt32LE(data.length, 22); header.writeUInt16LE(filename.length, 26);
  return Buffer.concat([header, filename, compressed]);
}

test('the helper installer accepts only the reviewed private package and pinned toolchain', () => {
  assert.doesNotThrow(() => installer.validateHelperPackage(pkg));
  for (const changed of [{ ...pkg, publisher: 'other' }, { ...pkg, version: '0.2.0' }, { ...pkg, dependencies: { unknown: '*' } },
    { ...pkg, devDependencies: { ...pkg.devDependencies, typescript: '*' } },
    { ...pkg, scripts: { ...pkg.scripts, package: 'run-unreviewed-command' } },
    { ...pkg, scripts: { ...pkg.scripts, prepackage: 'unreviewed-lifecycle' } },
    { ...pkg, extensionDependencies: ['other.extension'] }]) {
    assert.throws(() => installer.validateHelperPackage(changed), /package changed/);
  }
  assert.equal(installer.yarnEntry({ npm_execpath: '/tools/yarn/bin/yarn.js' }, () => true), '/tools/yarn/bin/yarn.js');
  assert.throws(() => installer.yarnEntry({ npm_execpath: '/tools/npm.js' }, () => true), /through Yarn/);
  assert.throws(() => installer.yarnEntry({ npm_execpath: '/tools/yarn.js' }, () => false), /through Yarn/);
});

test('the built VSIX must identify the same extension instead of another archive or duplicate manifest', () => {
  assert.equal(installer.readVSIXManifest(archive(pkg)).version, '0.3.0');
  assert.throws(() => installer.readVSIXManifest(archive({ ...pkg, publisher: 'other' })), /package changed/);
  assert.throws(() => installer.readVSIXManifest(Buffer.concat([archive(pkg), archive(pkg)])), /Unsafe Pip VSIX/);
  assert.throws(() => installer.readVSIXManifest(archive(pkg, '../package.json')), /Unsafe Pip VSIX/);
  assert.throws(() => installer.readVSIXManifest(archive(pkg).subarray(0, 40)), /Unsupported Pip VSIX/);
});

test('Windows VS Code selection uses known native install locations and rejects remote/relative roots', () => {
  const candidates = installer.vscodeCandidates('win32', { LOCALAPPDATA: 'C:\\Users\\Dev & Team\\AppData\\Local', ProgramFiles: 'C:\\Program Files' }, '', false);
  assert.equal(candidates.length, 2);
  assert.equal(candidates[0].executable, 'C:\\Users\\Dev & Team\\AppData\\Local\\Programs\\Microsoft VS Code\\Code.exe');
  assert.equal(candidates[1].cli, 'C:\\Program Files\\Microsoft VS Code\\resources\\app\\out\\cli.js');
  const insiders = installer.vscodeCandidates('win32', { ProgramFiles: 'C:\\Program Files' }, '', true);
  assert.equal(insiders[0].executable, 'C:\\Program Files\\Microsoft VS Code Insiders\\Code - Insiders.exe');
  for (const root of ['\\\\server\\share', 'C:relative', 'C:\\Users\\..\\escape', 'C:\\Users\\bad:stream']) {
    assert.deepEqual(installer.vscodeCandidates('win32', { LOCALAPPDATA: root }, '', false), []);
  }
  assert.deepEqual(installer.vscodeCandidates('linux', {}, '', false), []);
});

test('installation keeps Windows paths and profile metacharacters as literal arguments without code.cmd or a shell', () => {
  const calls: Array<{ command: string; args: string[]; options: { shell: boolean; env: NodeJS.ProcessEnv } }> = [];
  const archivePath = 'C:\\repo & team\\Pip [demo]\\pip-session-links-0.3.0.vsix';
  const options = installer.parseArguments(['install', '--profile', 'Work & demo "profile"']);
  installer.installBuiltHelper(archivePath, options, {
    platform: 'win32', env: { ProgramFiles: 'C:\\Program Files', ELECTRON_RUN_AS_NODE: '0' }, home: '',
    fileExists: () => true, log: () => undefined,
    runner: (command: string, args: string[], settings: { shell: boolean; env: NodeJS.ProcessEnv }) => {
      calls.push({ command, args, options: settings }); return { status: 0 };
    }
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, 'C:\\Program Files\\Microsoft VS Code\\Code.exe');
  assert.deepEqual(calls[0]!.args, ['C:\\Program Files\\Microsoft VS Code\\resources\\app\\out\\cli.js',
    '--install-extension', archivePath, '--force', '--profile', 'Work & demo "profile"']);
  assert.equal(calls[0]!.options.shell, false);
  assert.equal(calls[0]!.options.env.ELECTRON_RUN_AS_NODE, '1');
});

test('missing VS Code and failed installation leave a manual VSIX path and never run a guessed command', () => {
  let launches = 0;
  const runtime = { platform: 'win32', env: { ProgramFiles: 'C:\\Program Files' }, home: '',
    fileExists: () => false, log: () => undefined, runner: () => { launches += 1; return { status: 0 }; } };
  assert.throws(() => installer.installBuiltHelper('C:\\Pip\\helper.vsix', { insiders: false }, runtime), /Extensions: Install from VSIX[\s\S]*C:\\Pip\\helper.vsix/);
  assert.equal(launches, 0);
  assert.throws(() => installer.installBuiltHelper('C:\\Pip\\helper.vsix', { insiders: false },
    { ...runtime, fileExists: () => true, runner: () => ({ status: 1 }) }), /exit status 1/);
  assert.throws(() => installer.runCommand('Code.exe', [], {}, () => ({ error: { code: 'EACCES' } })), /EACCES/);
});

test('channel and profile options are explicit and malformed or unsupported switches stop before installation', () => {
  assert.deepEqual(installer.parseArguments(['build']), { action: 'build', insiders: false, profile: undefined });
  assert.deepEqual(installer.parseArguments(['install', '--insiders', '--profile', 'Existing Work']),
    { action: 'install', insiders: true, profile: 'Existing Work' });
  for (const args of [[], ['install', '--profile'], ['install', '--profile', '--force'], ['install', '--profile', 'line\nbreak'],
    ['install', '--insiders', '--insiders'], ['install', '--remote', 'ssh-host']]) assert.throws(() => installer.parseArguments(args));
});
