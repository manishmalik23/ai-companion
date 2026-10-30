import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { validLease, destination, SessionLease, normalizeLocalWorkspace, sessionLinksDirectory, readSessionLeasesFrom, BackgroundLeaseCache } from '../src/navigation';
const key = '11111111-1111-4111-8111-111111111111', sessionId = '22222222-2222-4222-8222-222222222222';
const lease: SessionLease = { schemaVersion: 1, windowKey: key, processId: 42, updatedAt: 100,
  workspaces: ['/workspace'], claudeSessionURL: 'vscode://anthropic.claude-code/open?windowId=4',
  terminalURL: 'vscode://pip-local.pip-session-links/terminal?windowId=4',
  codexSessionURL: 'vscode://pip-local.pip-session-links/codex?windowId=4', codexExtensionVersion: '26.1021.22027' };
test('only fresh, owned-window, allowlisted routes are usable', () => {
  assert.equal(validLease(lease, key + '.json', 100, () => true, 'darwin'), true);
  for (const candidate of [{ ...lease, updatedAt: 0 }, { ...lease, terminalURL: 'vscode://pip-local.pip-session-links/terminal?windowId=5' },
    { ...lease, claudeSessionURL: 'https://example.com/?windowId=4' }, { ...lease, codexExtensionVersion: 'unknown' }]) {
    assert.equal(validLease(candidate, key + '.json', 100, () => true, 'darwin'), false);
  }
  assert.equal(validLease(lease, key + '.json', 100, () => false, 'darwin'), false);
});
test('exact session IDs only and ambiguous workspaces stay unavailable', () => {
  const request = { source: 'claude', sessionId, cwd: '/workspace', sessionHost: 'claude-vscode' };
  assert.equal(destination(request, [lease], 'darwin'), `vscode://anthropic.claude-code/open?windowId=4&session=${sessionId}`);
  assert.equal(destination(request, [lease, { ...lease, windowKey: sessionId }], 'darwin'), undefined);
  assert.equal(destination({ ...request, sessionId: 'run a command' }, [lease], 'darwin'), undefined);
  assert.equal(destination(request, [lease], 'win32'), undefined);
  const codex = destination({ ...request, source: 'codex', sessionHost: 'codex-vscode', sessionWindowKey: key }, [lease], 'darwin');
  assert.match(codex!, /windowKey=11111111/); assert.match(codex!, /sessionId=22222222/);
  assert.equal(destination({ ...request, sessionWindowKey: 'wrong' }, [lease], 'darwin'), undefined);
});

test('Windows local drive paths normalize separators and drive case without guessing folder identity', () => {
  assert.equal(normalizeLocalWorkspace('c:/Work/Project/', 'win32'), 'C:\\Work\\Project');
  assert.equal(normalizeLocalWorkspace('D:\\Work\\space and ! & text', 'win32'), 'D:\\Work\\space and ! & text');
  for (const candidate of ['relative', 'C:relative', 'C:\\', '/workspace', '\\\\server\\share\\repo',
    '\\\\?\\C:\\repo', 'C:\\work\\..\\repo', 'C:\\work\\.\\repo', 'C:\\repo:stream',
    'C:\\Work\\NUL.txt', 'C:\\Work\\com1', 'C:\\Work\\lpt9.log', 'C:\\Work\\COM¹.txt', 'C:\\Work\\bad?name',
    'C:\\Work\\trailing.', 'C:\\Work\\trailing ', 'C:\\Work\\bad\nname']) {
    assert.equal(normalizeLocalWorkspace(candidate, 'win32'), undefined, candidate);
  }
  assert.equal(sessionLinksDirectory('win32', { LOCALAPPDATA: 'c:/Users/Dev/AppData/Local' }), 'C:\\Users\\Dev\\AppData\\Local\\Pip\\SessionLinks');
  assert.equal(sessionLinksDirectory('win32', {}), undefined);
  assert.equal(sessionLinksDirectory('win32', { LOCALAPPDATA: '\\\\server\\profile' }), undefined);
});

const windowsLease: SessionLease = { ...lease, workspaces: ['C:\\Work\\Project'] };
test('native Windows exact Claude and allowlisted Codex links retain window binding', () => {
  const request = { source: 'claude', sessionId, cwd: 'c:/Work/Project/', sessionHost: 'claude-vscode' };
  assert.equal(validLease(windowsLease, key + '.json', 100, () => true, 'win32'), true);
  assert.equal(validLease(windowsLease, key + '.json', 100, () => true, 'darwin'), false);
  assert.equal(validLease(lease, key + '.json', 100, () => true, 'win32'), false);
  assert.equal(destination(request, [windowsLease], 'win32'), `vscode://anthropic.claude-code/open?windowId=4&session=${sessionId}`);
  assert.equal(destination(request, [windowsLease, { ...windowsLease, windowKey: sessionId }], 'win32'), undefined);
  assert.equal(destination({ ...request, sessionWindowKey: key }, [windowsLease, { ...windowsLease, windowKey: sessionId }], 'win32'),
    `vscode://anthropic.claude-code/open?windowId=4&session=${sessionId}`);
  assert.equal(destination({ ...request, cwd: 'C:\\Work\\Project\\src', sessionWindowKey: key }, [windowsLease], 'win32'),
    `vscode://anthropic.claude-code/open?windowId=4&session=${sessionId}`);
  for (const cwd of ['C:\\Work\\Project-other', 'C:\\Work\\project', 'C:\\Work\\Project\\..\\Other']) {
    assert.equal(destination({ ...request, cwd, sessionWindowKey: key }, [windowsLease], 'win32'), undefined);
  }
  assert.equal(destination({ ...request, sessionWindowKey: sessionId }, [windowsLease], 'win32'), undefined);
  const codex = { ...request, source: 'codex', sessionHost: 'codex-vscode', sessionWindowKey: key };
  assert.match(destination(codex, [windowsLease], 'win32')!, /windowKey=11111111.*sessionId=22222222/);
  assert.equal(destination(codex, [{ ...windowsLease, codexExtensionVersion: 'unknown' }], 'win32'), undefined);
  assert.equal(destination({ ...codex, sessionHost: 'codex-desktop' }, [], 'win32'), undefined);
  assert.equal(destination({ ...request, sessionId: 'command' }, [windowsLease], 'win32'), undefined);
});

test('Windows lease reader batches ACL inspection before trusting bounded unchanged files', async t => {
  const folder = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'pip-windows-lease-')));
  t.after(() => fs.rm(folder, { recursive: true, force: true }));
  const file = path.join(folder, key + '.json'), content = JSON.stringify(windowsLease);
  await fs.writeFile(file, content, { mode: 0o600 });
  let inspections = 0;
  const result = await readSessionLeasesFrom(folder, { platform: 'win32', now: () => 100, alive: () => true,
    inspectWindows: async entries => {
      inspections++;
      assert.deepEqual(entries, [{ path: folder, kind: 'directory' }, { path: file, kind: 'file' }]);
    } });
  assert.equal(inspections, 1); assert.deepEqual(result, [windowsLease]);
  assert.equal(await fs.readFile(file, 'utf8'), content);
  assert.deepEqual(await readSessionLeasesFrom(folder, { platform: 'win32', inspectWindows: async () => { throw new Error('Unsafe ACL'); } }), []);
  await fs.writeFile(file, 'x'.repeat(65_537));
  assert.deepEqual(await readSessionLeasesFrom(folder, { platform: 'win32', inspectWindows: async entries => assert.equal(entries.length, 1) }), []);
});

test('a replaced Windows registry or symlinked lease never supplies navigation', async t => {
  const parent = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'pip-windows-replaced-')));
  t.after(() => fs.rm(parent, { recursive: true, force: true }));
  const folder = path.join(parent, 'links'), retired = path.join(parent, 'retired');
  await fs.mkdir(folder); await fs.writeFile(path.join(folder, key + '.json'), JSON.stringify(windowsLease));
  assert.deepEqual(await readSessionLeasesFrom(folder, { platform: 'win32', now: () => 100, alive: () => true,
    inspectWindows: async () => { await fs.rename(folder, retired); await fs.mkdir(folder);
      await fs.writeFile(path.join(folder, key + '.json'), JSON.stringify(windowsLease)); } }), []);
  if (process.platform !== 'win32') {
    await fs.unlink(path.join(folder, key + '.json'));
    await fs.symlink(path.join(retired, key + '.json'), path.join(folder, key + '.json'));
    assert.deepEqual(await readSessionLeasesFrom(folder, { platform: 'win32', inspectWindows: async entries => assert.equal(entries.length, 1) }), []);
  }
});

test('Windows UI polling never awaits ACL inspection and a click never reuses the background snapshot', async () => {
  let clock = 0, reads = 0;
  const finish: ((value: SessionLease[]) => void)[] = [];
  const cache = new BackgroundLeaseCache(() => { reads++; return new Promise(resolve => finish.push(resolve)); }, () => clock);
  assert.deepEqual(await cache.get(), []);
  assert.deepEqual(await cache.get(), []); assert.equal(reads, 1);
  finish[0]!([windowsLease]);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(await cache.get(), [windowsLease]); assert.equal(reads, 1);
  clock = 6_000;
  assert.deepEqual(await cache.get(), [windowsLease]); assert.equal(reads, 2);
  const click = cache.get(true); assert.equal(reads, 3);
  finish[2]!([]);
  assert.deepEqual(await click, []);
  finish[1]!([]); await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(await cache.get(), []);
});
