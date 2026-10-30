import test from 'node:test';
import assert from 'node:assert/strict';
import { cleanTerminalName, EXTENSION_ID, focusExistingTerminal, isProcessId, localWorkspaces,
  localPlatformUnavailableReason, normalizeLocalWorkspace, parseTerminalRequest, readTerminalProcessId, serializeSessionURI, SessionURILike,
  validateResolvedRoutes } from '../src/protocol';

const KEY = '11f16f2b-98b5-416c-8f15-700df828a81b';
const CLAUDE = 'vscode://anthropic.claude-code/open?windowId=7';
const TERMINAL = `vscode://${EXTENSION_ID}/terminal?windowId=7`;

/** Match VS Code's default query encoding, rather than testing only hand-authored URLs. */
function vscodeURI(value: string): SessionURILike {
  const url = new URL(value);
  return {
    scheme: url.protocol.slice(0, -1), authority: url.host, path: url.pathname,
    query: url.search.slice(1), fragment: url.hash.slice(1),
    toString(skipEncoding = false): string {
      return `${this.scheme}://${this.authority}${this.path}?${skipEncoding ? this.query : encodeURIComponent(this.query)}`;
    }
  };
}

test('resolved VS Code URI boundary preserves windowId instead of encoding its delimiter', () => {
  const claude = vscodeURI(CLAUDE), terminal = vscodeURI(TERMINAL);
  assert.equal(claude.toString(), CLAUDE.replace('=', '%3D'));
  assert.equal(new URL(claude.toString()).searchParams.get('windowId'), null);
  assert.throws(() => validateResolvedRoutes(claude.toString(), terminal.toString()));
  const routes = validateResolvedRoutes(serializeSessionURI(claude), serializeSessionURI(terminal));
  assert.deepEqual(routes, { claudeSessionURL: CLAUDE, terminalURL: TERMINAL, windowId: '7' });
});

test('incoming VS Code terminal URI boundary preserves all validated request parameters', () => {
  const uri = vscodeURI(`${TERMINAL}&windowKey=${KEY}&pid=1234`);
  assert.equal(uri.toString().includes('%26windowKey%3D'), true);
  assert.equal(parseTerminalRequest(uri.toString(), KEY, '7'), undefined);
  const value = serializeSessionURI(uri);
  assert.deepEqual([...new URL(value).searchParams.keys()], ['windowId', 'windowKey', 'pid']);
  assert.equal(parseTerminalRequest(value, KEY, '7'), 1234);
  assert.equal(parseTerminalRequest(value, KEY, '8'), undefined);
});

test('URI boundary rejects unrelated components and serializers that alter the query', () => {
  const uri = vscodeURI(TERMINAL);
  for (const change of [{ scheme: 'https' }, { authority: 'attacker.example' }, { path: '/new' },
      { fragment: 'fragment' }, { query: 'windowId=7\n' }, { query: 'windowId=7#fragment' },
      { toString: () => uri.toString() }, { toString: () => TERMINAL.replace('=7', '=8') }]) {
    assert.throws(() => serializeSessionURI({ ...uri, ...change }));
  }
});

test('resolved links keep the originating VS Code window ID', () => {
  assert.deepEqual(validateResolvedRoutes(CLAUDE, TERMINAL), {
    claudeSessionURL: CLAUDE, terminalURL: TERMINAL, windowId: '7'
  });
  assert.equal(validateResolvedRoutes(CLAUDE.replace('vscode:', 'vscode-insiders:'),
    TERMINAL.replace('vscode:', 'vscode-insiders:')).windowId, '7');
});

test('generic, ambiguous, or unrelated app links are unavailable', () => {
  for (const claude of [CLAUDE.split('?')[0], `${CLAUDE}&windowId=8`, `${CLAUDE}&prompt=hello`,
      CLAUDE.replace('=7', '=0'), CLAUDE.replace('=7', '=2147483648'),
      CLAUDE.replace('anthropic.claude-code', 'attacker.example'), CLAUDE.replace('/open?', '/new?'),
      CLAUDE.replace('vscode:', 'https:'), `${CLAUDE}#secret`, CLAUDE.replace('//', '//user@')]) {
    assert.throws(() => validateResolvedRoutes(claude, TERMINAL));
  }
  assert.throws(() => validateResolvedRoutes(CLAUDE, TERMINAL.replace('=7', '=8')));
  assert.throws(() => validateResolvedRoutes(CLAUDE, TERMINAL.replace('vscode:', 'vscode-insiders:')));
});

test('terminal requests bind both the window key and exact positive PID', () => {
  const uri = `${TERMINAL}&windowKey=${KEY}&pid=1234`;
  assert.equal(parseTerminalRequest(uri, KEY, '7'), 1234);
  assert.equal(parseTerminalRequest(uri.replace('windowId=7&', ''), KEY, '7'), 1234);
  for (const value of [uri.replace(KEY, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
      uri.replace('pid=1234', 'pid=-1'), uri.replace('pid=1234', 'pid=0'),
      uri.replace('pid=1234', 'pid=1.2'), uri.replace('pid=1234', 'pid=2147483648'),
      `${uri}&pid=44`, `${uri}&windowKey=${KEY}`, `${uri}&command=sendText`,
      uri.replace('windowId=7', 'windowId=8'), uri.replace('/terminal?', '/open?')]) {
    assert.equal(parseTerminalRequest(value, KEY, '7'), undefined);
  }
});

test('focus uses an existing exact terminal and never another terminal', async () => {
  const shown: string[] = [];
  const terminals = [
    { processId: Promise.resolve(111), show: (preserve?: boolean) => { assert.equal(preserve, false); shown.push('first'); } },
    { processId: Promise.resolve(222), show: (preserve?: boolean) => { assert.equal(preserve, false); shown.push('second'); } }
  ];
  assert.equal(await focusExistingTerminal(terminals, 222), true);
  assert.deepEqual(shown, ['second']);
  assert.equal(await focusExistingTerminal(terminals, 333), false);
  assert.equal(await focusExistingTerminal([terminals[0], terminals[0]], 111), false);
  assert.deepEqual(shown, ['second']);
});

test('closed, failed, and unresolved terminal PID lookups do not create or focus a terminal', async () => {
  assert.equal(await readTerminalProcessId({ processId: new Promise(() => undefined) }, 5), undefined);
  assert.equal(await readTerminalProcessId({ processId: Promise.reject(new Error('closed')) }), undefined);
  assert.equal(await focusExistingTerminal([{ processId: Promise.resolve(77), show: () => { throw new Error('closed'); } }], 77), false);
  for (const value of [0, -1, 1.5, Infinity, NaN, 2_147_483_648]) assert.equal(isProcessId(value), false);
});

test('only local, absolute workspace folder paths enter the lease', () => {
  assert.deepEqual(localWorkspaces([
    { uri: { scheme: 'file', fsPath: '/Users/example/work/../work/project' } },
    { uri: { scheme: 'file', fsPath: '/Users/example/work/project' } },
    { uri: { scheme: 'vscode-remote', fsPath: '/remote/project' } },
    { uri: { scheme: 'file', fsPath: 'relative/project' } },
    { uri: { scheme: 'file', fsPath: '/bad\npath' } }
  ], 'darwin'), ['/Users/example/work/project']);
  assert.equal(cleanTerminalName('  shell\nname\u202e  '), 'shell name');
  assert.equal(cleanTerminalName('x'.repeat(500)).length, 160);
});

test('Windows local workspace paths are drive-absolute and cannot use device, network or alias paths', () => {
  assert.equal(normalizeLocalWorkspace('c:/Work/project/', 'win32'), 'C:\\Work\\project');
  assert.deepEqual(localWorkspaces([
    { uri: { scheme: 'file', fsPath: 'c:/Work/project/' } },
    { uri: { scheme: 'file', fsPath: 'C:\\Work\\project' } },
    { uri: { scheme: 'vscode-remote', fsPath: 'C:\\remote\\project' } },
    { uri: { scheme: 'file', fsPath: '\\\\server\\project' } }
  ], 'win32'), ['C:\\Work\\project']);
  for (const value of ['C:', 'C:relative', 'C:\\', '/work/project', '\\\\server\\project', '\\\\?\\C:\\project',
      '\\\\.\\C:\\project', 'C:\\Work\\..\\project', 'C:\\Work\\.\\project', 'C:\\Work\\project:stream',
      'C:\\Work\\project.', 'C:\\Work\\project ', 'C:\\Work\\NUL.txt', 'C:\\Work\\LPT1', 'C:\\Work\\COM0', 'C:\\Work\\COM¹.txt',
      'C:\\' + 'x'.repeat(256), 'C:\\' + Array.from({ length: 65 }, () => 'x').join('\\'), 'C:\\bad\npath']) {
    assert.equal(normalizeLocalWorkspace(value, 'win32'), undefined, value);
  }
  assert.equal(normalizeLocalWorkspace('/', 'darwin'), undefined);
});

test('local Windows and macOS windows are enabled while remote and unsupported platforms retain a diagnostic', () => {
  assert.equal(localPlatformUnavailableReason('win32'), undefined);
  assert.equal(localPlatformUnavailableReason('darwin'), undefined);
  for (const remote of ['wsl', 'ssh-remote', 'dev-container']) {
    assert.equal(localPlatformUnavailableReason('win32', remote), 'remote_window');
  }
  assert.equal(localPlatformUnavailableReason('linux'), 'unsupported_platform');
});
