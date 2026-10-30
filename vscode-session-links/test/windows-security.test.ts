import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { ensureWindowsDirectory, ensureWindowsDirectoryAsync, inspectWindowsPath,
  inspectWindowsPaths, inspectWindowsPathsAsync, MAX_WINDOWS_SECURITY_PATHS,
  validateWindowsSecurityReport, WindowsPathCheck, WindowsSecurityInvocation,
  WINDOWS_SECURITY_SCRIPT, WINDOWS_SECURITY_TIMEOUT_MS, windowsSecurityPath } from '../src/windows-security';

const user = 'S-1-5-21-1-2-3-1001';
const checks: WindowsPathCheck[] = [{ path: 'C:\\Users\\Demo\\AppData\\Local\\Pip\\SessionLinks', kind: 'directory' },
  { path: 'C:\\Users\\Demo\\AppData\\Local\\Pip\\SessionLinks\\lease.json', kind: 'file' }];
const env = { SystemRoot: 'C:\\Windows', PATH: 'C:\\untrusted-bin', SOME_KEEP: 'kept' };
function report(paths: readonly WindowsPathCheck[] = checks, nonce = 'nonce'): any {
  return { schemaVersion: 1, nonce, currentUserSid: user, entries: paths.map((item, index) => ({
    index, kind: item.kind, ownerSid: user, driveType: 'Fixed', protected: item.kind === 'directory', componentsSafe: true,
    rules: [user, 'S-1-5-18', 'S-1-5-32-544'].map(sid => ({ sid, access: 'Allow', rights: 2_032_127,
      inheritance: item.kind === 'directory' ? 3 : 0, propagation: 0, inherited: item.kind === 'file' }))
  })) };
}
function request(invocation: WindowsSecurityInvocation): { operation: string; nonce: string; paths: WindowsPathCheck[] } {
  return JSON.parse(Buffer.from(invocation.env.PIP_SESSION_LINK_SECURITY_REQUEST!, 'base64').toString('utf8'));
}
function success(invocation: WindowsSecurityInvocation): string {
  const value = request(invocation);
  return JSON.stringify(report(value.paths, value.nonce));
}
const options = { platform: 'win32' as const, env, runSync: success };

test('Windows path validation accepts literal data but rejects alternate Win32 path interpretations', () => {
  assert.equal(windowsSecurityPath('c:/Users/Demo/Pip/SessionLinks/'), 'c:\\Users\\Demo\\Pip\\SessionLinks');
  assert.equal(windowsSecurityPath("C:\\Users\\Demo\\$(do-not-execute)'quote\\file.json"),
    "C:\\Users\\Demo\\$(do-not-execute)'quote\\file.json");
  for (const invalid of ['C:\\', 'C:relative', '\\\\server\\share\\file', '\\\\?\\C:\\file', '\\\\.\\pipe\\file',
    '/Users/Demo', 'C:\\folder\\..\\outside', 'C:\\folder\\.\\file', 'C:\\folder\\file:stream',
    'C:\\folder\\file.', 'C:\\folder\\file ', 'C:\\folder\\NUL.txt', 'C:\\folder\\COM1',
    'C:\\folder\\LPT2.log', 'C:\\folder\\COM¹.txt', 'C:\\folder\\LPT³', 'C:\\folder\\wild*card', 'C:\\folder\\a?b', 'C:\\folder\\double\\\\separator',
    'C:\\folder\\\u0000file', 'C:\\folder\\' + 'x'.repeat(256)]) {
    assert.equal(windowsSecurityPath(invalid), undefined, invalid);
  }
});

test('private protected directory and inherited private file ACLs pass the same policy', () => {
  assert.doesNotThrow(() => validateWindowsSecurityReport(report(), checks, 'nonce'));
  inspectWindowsPaths(checks, options);
  inspectWindowsPath(checks[1].path, 'file', options);
});

test('trusted elevated file ownership is allowed without relaxing directory or access rules', () => {
  for (const owner of ['S-1-5-18', 'S-1-5-32-544']) {
    const candidate = report(); candidate.entries[1].ownerSid = owner;
    assert.doesNotThrow(() => validateWindowsSecurityReport(candidate, checks, 'nonce'));
    candidate.entries[0].ownerSid = owner;
    assert.throws(() => validateWindowsSecurityReport(candidate, checks, 'nonce'), /storage is unavailable/);
  }
});

test('foreign owners, broad grants, deny entries and reparse/unknown reports fail closed', () => {
  const mutations: ((value: any) => void)[] = [
    value => { value.entries[0].ownerSid = 'S-1-5-21-9-9-9-999'; },
    value => { value.entries[1].ownerSid = 'S-1-5-21-9-9-9-999'; },
    value => { value.entries[0].driveType = 'Network'; },
    value => { value.entries[1].driveType = 'Removable'; },
    value => { value.entries[0].protected = false; },
    value => { value.entries[0].componentsSafe = false; },
    value => { value.entries[0].rules[0].sid = 'S-1-1-0'; },
    value => { value.entries[1].rules[0].sid = 'S-1-5-32-545'; },
    value => { value.entries[0].rules[0].access = 'Deny'; },
    value => { value.entries[0].rules[0].rights = 1; },
    value => { value.entries[0].rules[0].propagation = 2; },
    value => { value.entries[0].rules[0].inheritance = 0; },
    value => { value.entries[0].rules = []; },
    value => { value.entries[0].rules = Array.from({ length: 33 }, () => value.entries[0].rules[0]); },
    value => { value.entries[0].rules[0].rights = -1; },
    value => { value.entries[0].rules[0].inherited = 'yes'; },
    value => { value.entries[0].rules[0].inheritance = 4; },
    value => { value.entries[0].index = 1; },
    value => { value.entries[0].kind = 'file'; },
    value => { value.entries.pop(); },
    value => { value.currentUserSid = 'S-1-5-18'; },
    value => { value.currentUserSid = 'not-a-sid'; },
    value => { value.nonce = 'stale'; },
    value => { value.schemaVersion = 2; }
  ];
  for (const mutate of mutations) {
    const candidate = report(); mutate(candidate);
    assert.throws(() => validateWindowsSecurityReport(candidate, checks, 'nonce'), /storage is unavailable/);
  }
});

test('fixed PowerShell invocation transports paths as environment data without shell or policy bypass', () => {
  const literal = "C:\\Users\\Demo\\$(not-a-command)'quote\\SessionLinks";
  let calls = 0;
  inspectWindowsPath(literal, 'directory', { ...options, runSync: invocation => {
    calls++;
    assert.equal(invocation.executable, 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
    assert.deepEqual(invocation.args, ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', WINDOWS_SECURITY_SCRIPT]);
    assert.equal(invocation.timeout, WINDOWS_SECURITY_TIMEOUT_MS);
    assert.equal(invocation.windowsHide, true);
    assert.ok(invocation.maxBuffer <= 524_288);
    assert.equal(invocation.env.PSModulePath, 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\Modules');
    assert.equal(invocation.env.SOME_KEEP, 'kept');
    assert.equal(invocation.env.PATH, 'C:\\untrusted-bin');
    assert.ok(!invocation.args.some(argument => argument.includes(literal) || /ExecutionPolicy|Bypass/i.test(argument)));
    assert.deepEqual(request(invocation).paths, [{ path: literal, kind: 'directory' }]);
    assert.equal(request(invocation).operation, 'inspect');
    return success(invocation);
  } });
  assert.equal(calls, 1);
});

test('creation requests use the atomic DirectorySecurity overload and never repair existing ACLs', () => {
  ensureWindowsDirectory(checks[0].path, { ...options, runSync: invocation => {
    assert.equal(request(invocation).operation, 'ensure');
    assert.deepEqual(request(invocation).paths, [checks[0]]);
    return success(invocation);
  } });
  assert.match(WINDOWS_SECURITY_SCRIPT, /if \(\$null -eq \$attributes -and \$create\)/);
  assert.match(WINDOWS_SECURITY_SCRIPT, /Directory\]::CreateDirectory\(\$current, \$script:privateAcl\)/);
  assert.doesNotMatch(WINDOWS_SECURITY_SCRIPT, /Set-Acl|SetAccessControl|icacls|takeown/i);
  assert.match(WINDOWS_SECURITY_SCRIPT, /\$attributes -band 1024/);
  assert.match(WINDOWS_SECURITY_SCRIPT, /DriveInfo\]::new\(\$root\)\.DriveType -ne \[System\.IO\.DriveType\]::Fixed/);
});

test('async inspection and creation use the async runner with one bounded batch', async () => {
  let calls = 0;
  const asyncOptions = { platform: 'win32' as const, env, runAsync: async (invocation: WindowsSecurityInvocation) => {
    calls++; return success(invocation);
  }, runSync: () => { throw new Error('Synchronous process must not be used'); } };
  await inspectWindowsPathsAsync(checks, asyncOptions);
  assert.equal(calls, 1);
  await ensureWindowsDirectoryAsync(checks[0].path, asyncOptions);
  assert.equal(calls, 2);
});

test('unsupported platforms and invalid/bulk requests never invoke a child process', async () => {
  let calls = 0;
  const forbidden = () => { calls++; return ''; };
  const cases = [
    () => inspectWindowsPaths(checks, { platform: 'darwin', env, runSync: forbidden }),
    () => inspectWindowsPaths([], { ...options, runSync: forbidden }),
    () => inspectWindowsPaths([checks[0], checks[0]], { ...options, runSync: forbidden }),
    () => inspectWindowsPaths(Array.from({ length: MAX_WINDOWS_SECURITY_PATHS + 1 }, (_, n) =>
      ({ path: `C:\\Users\\Demo\\file-${n}.json`, kind: 'file' as const })), { ...options, runSync: forbidden }),
    () => inspectWindowsPath('C:\\Users\\Demo\\safe.json', 'file', { ...options, env: {}, runSync: forbidden }),
    () => inspectWindowsPath('C:\\Users\\Demo\\safe.json', 'file', { ...options, env: { SystemRoot: 'powershell-from-path' }, runSync: forbidden }),
    () => inspectWindowsPaths(Array.from({ length: 65 }, (_, n) =>
      ({ path: 'C:\\' + Array.from({ length: 10 }, () => 'x'.repeat(200)).join('\\') + `\\${n}`, kind: 'file' as const })),
      { ...options, runSync: forbidden })
  ];
  for (const operation of cases) assert.throws(operation, /^Error: Windows session-link storage is unavailable\.$/);
  await assert.rejects(inspectWindowsPathsAsync(checks, { platform: 'linux', env,
    runAsync: async () => { calls++; return ''; } }), /storage is unavailable/);
  assert.equal(calls, 0);
});

test('process errors, corrupt output and stale responses expose only the static failure message', async () => {
  for (const output of ['', 'not-json', JSON.stringify(report(checks, 'stale')), 'x'.repeat(524_289)]) {
    assert.throws(() => inspectWindowsPaths(checks, { ...options, runSync: () => output }),
      /^Error: Windows session-link storage is unavailable\.$/);
  }
  assert.throws(() => inspectWindowsPaths(checks, { ...options, runSync: () => { throw new Error('Private path or command content'); } }),
    /^Error: Windows session-link storage is unavailable\.$/);
  await assert.rejects(inspectWindowsPathsAsync(checks, { platform: 'win32', env,
    runAsync: async () => { throw new Error('Private path or command content'); } }),
    /^Error: Windows session-link storage is unavailable\.$/);
});

test('the helper and TypeScript app ship byte-identical Windows security policy', () => {
  const helper = path.resolve(__dirname, '../../src/windows-security.ts');
  const companion = path.resolve(__dirname, '../../../cross-platform/src/windows-security.ts');
  assert.equal(fs.readFileSync(helper, 'utf8'), fs.readFileSync(companion, 'utf8'));
});
