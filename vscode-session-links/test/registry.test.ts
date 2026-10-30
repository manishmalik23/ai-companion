import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { assertPrivateStat, ensurePrivateDirectory, PrivateLeaseWriter, registryDirectory } from '../src/registry';
import { SessionLinkLease } from '../src/protocol';
import { SUPPORTED_CODEX_VERSION } from '../src/codex';

const posixOnly = { skip: process.platform !== 'darwin' };

test('registry path is shared, local and explicit on each supported platform', () => {
  assert.equal(registryDirectory('darwin', {}, '/Users/example'),
    '/Users/example/Library/Application Support/AgentCompanion/.runtime/session-links');
  assert.equal(registryDirectory('win32', { LOCALAPPDATA: 'c:/Users/example/AppData/Local' }),
    'C:\\Users\\example\\AppData\\Local\\Pip\\SessionLinks');
  for (const base of [undefined, '', '\\\\server\\profile', 'C:relative', 'C:\\Users\\..\\other']) {
    assert.equal(registryDirectory('win32', { LOCALAPPDATA: base }), undefined);
  }
  assert.equal(registryDirectory('linux', {}), undefined);
});

async function fixture() {
  const temporaryRoot = await fs.realpath(os.tmpdir());
  const root = await fs.mkdtemp(path.join(temporaryRoot, 'pip-session-links-test-'));
  await fs.chmod(root, 0o700);
  const directory = path.join(root, 'runtime', 'session-links');
  const windowKey = randomUUID();
  const writer = new PrivateLeaseWriter(directory, windowKey, process.pid);
  const lease: SessionLinkLease = { schemaVersion: 1, windowKey, processId: process.pid, updatedAt: Date.now() / 1000,
    workspaces: ['/Users/example/project'], claudeSessionURL: 'vscode://anthropic.claude-code/open?windowId=7',
    terminalURL: 'vscode://pip-local.pip-session-links/terminal?windowId=7', terminals: [{ processId: 123, name: 'zsh' }] };
  return { root, directory, writer, lease };
}

test('private leases are atomic 0600 files inside a 0700 directory', posixOnly, async t => {
  const { root, directory, writer, lease } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await writer.write(lease);
  assert.equal((await fs.lstat(directory)).mode & 0o777, 0o700);
  assert.equal((await fs.lstat(writer.file)).mode & 0o777, 0o600);
  assert.deepEqual(JSON.parse(await fs.readFile(writer.file, 'utf8')), lease);
  const first = await fs.lstat(writer.file);
  const updated = { ...lease, updatedAt: lease.updatedAt + 10, terminals: [] };
  await writer.write(updated);
  assert.deepEqual(JSON.parse(await fs.readFile(writer.file, 'utf8')), updated);
  assert.notEqual((await fs.lstat(writer.file)).ino, first.ino);
  assert.deepEqual(await fs.readdir(directory), [`${lease.windowKey}.json`]);
});

test('optional Codex capability persists atomically and cannot invalidate a prior Claude-only lease', posixOnly, async t => {
  const { root, writer, lease } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await writer.write(lease);
  for (const invalid of [{ ...lease, codexSessionURL: 'vscode://pip-local.pip-session-links/codex?windowId=7' },
      { ...lease, codexExtensionVersion: SUPPORTED_CODEX_VERSION },
      { ...lease, codexSessionURL: 'vscode://pip-local.pip-session-links/codex?windowId=8',
        codexExtensionVersion: SUPPORTED_CODEX_VERSION }]) {
    await assert.rejects(writer.write(invalid));
    assert.deepEqual(JSON.parse(await fs.readFile(writer.file, 'utf8')), lease);
  }
  const updated = { ...lease, codexSessionURL: 'vscode://pip-local.pip-session-links/codex?windowId=7',
    codexExtensionVersion: SUPPORTED_CODEX_VERSION };
  await writer.write(updated);
  assert.deepEqual(JSON.parse(await fs.readFile(writer.file, 'utf8')), updated);
  assert.equal((await fs.lstat(writer.file)).mode & 0o777, 0o600);
});

test('insecure registry permissions and foreign ownership are rejected without chmod', posixOnly, async t => {
  const { root, directory, writer, lease } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await ensurePrivateDirectory(directory);
  await fs.chmod(directory, 0o755);
  await assert.rejects(writer.write(lease));
  assert.equal((await fs.lstat(directory)).mode & 0o777, 0o755);
  await fs.chmod(directory, 0o700);
  const stat = await fs.lstat(directory);
  assert.throws(() => assertPrivateStat(stat, 'directory', process.getuid!() + 1));
});

test('symlinks in the registry path are never traversed', posixOnly, async t => {
  const { root, directory, writer, lease } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const outside = path.join(root, 'outside');
  await fs.mkdir(outside, { mode: 0o700 });
  await fs.symlink(outside, path.join(root, 'runtime'));
  await assert.rejects(writer.write(lease));
  assert.deepEqual(await fs.readdir(outside), []);
  assert.equal(await fs.readlink(path.dirname(directory)), outside);
});

test('an unsafe target file or symlink is not replaced', posixOnly, async t => {
  const { root, directory, writer, lease } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await ensurePrivateDirectory(directory);
  await fs.writeFile(writer.file, 'private data', { mode: 0o644 });
  await fs.chmod(writer.file, 0o644);
  await assert.rejects(writer.write(lease));
  assert.equal(await fs.readFile(writer.file, 'utf8'), 'private data');
  await fs.unlink(writer.file);
  const outside = path.join(root, 'other.json');
  await fs.writeFile(outside, 'unchanged', { mode: 0o600 });
  await fs.symlink(outside, writer.file);
  await assert.rejects(writer.write(lease));
  writer.remove();
  assert.equal(await fs.readFile(outside, 'utf8'), 'unchanged');
  assert.equal((await fs.lstat(writer.file)).isSymbolicLink(), true);
});

test('disposal removes only this exact window/process lease', posixOnly, async t => {
  const { root, writer, lease } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await writer.write(lease);
  const second = new PrivateLeaseWriter(writer.directory, randomUUID(), process.pid);
  await second.write({ ...lease, windowKey: second.windowKey });
  writer.remove();
  await assert.rejects(fs.lstat(writer.file), { code: 'ENOENT' });
  assert.equal((await fs.lstat(second.file)).isFile(), true);
  await writer.write(lease);
  await fs.writeFile(writer.file, JSON.stringify({ ...lease, processId: process.pid + 1 }));
  writer.remove();
  assert.equal((await fs.lstat(writer.file)).isFile(), true);
});

test('disposal does not follow a replaced parent directory symlink', posixOnly, async t => {
  const { root, directory, writer, lease } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  await writer.write(lease);
  await fs.rename(directory, `${directory}-old`);
  await fs.symlink(`${directory}-old`, directory);
  writer.remove();
  assert.equal((await fs.lstat(path.join(`${directory}-old`, `${lease.windowKey}.json`))).isFile(), true);
});

test('mismatched identity, unsupported routes, and oversized records never publish', posixOnly, async t => {
  const { root, writer, lease } = await fixture();
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  for (const invalid of [{ ...lease, windowKey: randomUUID() }, { ...lease, processId: 0 },
      { ...lease, updatedAt: NaN }, { ...lease, workspaces: ['relative'] },
      { ...lease, claudeSessionURL: 'vscode://anthropic.claude-code/open' },
      { ...lease, terminals: [{ processId: -1, name: 'bad' }] },
      { ...lease, workspaces: Array.from({ length: 32 }, (_, n) => `/${n}${'x'.repeat(4095)}`) }]) {
    await assert.rejects(writer.write(invalid));
  }
  await assert.rejects(fs.lstat(writer.file), { code: 'ENOENT' });
});

test('Windows private ACL leases publish atomically and reject unprotected or junction registries',
  { skip: process.platform !== 'win32' }, async t => {
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-windows-session-links-test-'));
    t.after(() => fs.rm(root, { recursive: true, force: true }));
    const directory = path.join(root, 'SessionLinks'), key = randomUUID();
    const writer = new PrivateLeaseWriter(directory, key, process.pid);
    const lease: SessionLinkLease = { schemaVersion: 1, windowKey: key, processId: process.pid, updatedAt: Date.now() / 1000,
      workspaces: ['C:\\Work\\project'], claudeSessionURL: 'vscode://anthropic.claude-code/open?windowId=7',
      terminalURL: 'vscode://pip-local.pip-session-links/terminal?windowId=7', terminals: [] };
    await writer.write(lease);
    assert.deepEqual(JSON.parse(await fs.readFile(writer.file, 'utf8')), lease);
    const updated = { ...lease, updatedAt: lease.updatedAt + 1 };
    await writer.write(updated);
    assert.deepEqual(JSON.parse(await fs.readFile(writer.file, 'utf8')), updated);
    assert.deepEqual(await fs.readdir(directory), [key + '.json']);
    await writer.removeAsync();
    await assert.rejects(fs.lstat(writer.file), { code: 'ENOENT' });
    assert.deepEqual(await fs.readdir(directory), []);

    // Plain Node mkdir inherits its parent ACL rather than making a protected
    // registry. Existing directories must fail closed instead of being repaired.
    const unprotected = path.join(root, 'UnprotectedSessionLinks');
    await fs.mkdir(unprotected);
    const aclFingerprint = async (value: string) => {
      assert.ok(process.env.SystemRoot);
      const { stdout } = await promisify(execFile)(path.join(process.env.SystemRoot!, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
          "$ErrorActionPreference='Stop'; $acl=[System.IO.Directory]::GetAccessControl($env:PIP_SESSION_LINK_TEST_DIRECTORY); " +
          '[Console]::Out.Write((@{ protected=[bool]$acl.AreAccessRulesProtected; descriptor=[Convert]::ToBase64String($acl.GetSecurityDescriptorBinaryForm()) } | ConvertTo-Json -Compress))'],
        { env: { ...process.env, PIP_SESSION_LINK_TEST_DIRECTORY: value }, encoding: 'utf8', timeout: 5_000,
          maxBuffer: 16_384, windowsHide: true });
      const result = JSON.parse(stdout);
      return { protected: result.protected, fingerprint: createHash('sha256').update(Buffer.from(result.descriptor, 'base64')).digest('hex') };
    };
    const unprotectedAclBefore = await aclFingerprint(unprotected);
    assert.equal(unprotectedAclBefore.protected, false);
    const unprotectedBefore = await fs.lstat(unprotected);
    const unprotectedWriter = new PrivateLeaseWriter(unprotected, key, process.pid);
    await assert.rejects(unprotectedWriter.write(lease));
    const unprotectedAfter = await fs.lstat(unprotected);
    assert.equal(unprotectedAfter.dev, unprotectedBefore.dev);
    assert.equal(unprotectedAfter.ino, unprotectedBefore.ino);
    assert.deepEqual(await aclFingerprint(unprotected), unprotectedAclBefore);
    assert.deepEqual(await fs.readdir(unprotected), []);
    assert.deepEqual(await fs.readdir(directory), []);

    // Junction creation does not need Developer Mode or symlink privileges.
    // Reject the alias before any lease bytes reach the valid target directory.
    const junction = path.join(root, 'SessionLinksJunction');
    await fs.symlink(directory, junction, 'junction');
    assert.equal((await fs.lstat(junction)).isSymbolicLink(), true);
    const junctionWriter = new PrivateLeaseWriter(junction, key, process.pid);
    await assert.rejects(junctionWriter.write(lease));
    assert.equal((await fs.lstat(junction)).isSymbolicLink(), true);
    assert.deepEqual(await fs.readdir(directory), []);
    assert.deepEqual(await fs.readdir(unprotected), []);
  });
