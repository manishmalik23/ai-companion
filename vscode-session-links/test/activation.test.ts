import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import * as protocol from '../src/protocol';
import { SharedRefresh } from '../src/refresh';
import * as codex from '../src/codex';

function fixture(platform: NodeJS.Platform, remoteName?: string, failWrite = false) {
  const commands = new Map<string, () => Promise<void>>(), writes: unknown[] = [], warnings: string[] = [], messages: string[] = [];
  const subscriptions: { dispose(): void }[] = [];
  const removals = { sync: 0, async: 0 };
  const disposable = () => ({ dispose() {} });
  const output = { appendLine: (line: string) => messages.push(line), ...disposable() };
  const uri = (value: string): protocol.SessionURILike => {
    const parsed = new URL(value);
    return { scheme: parsed.protocol.slice(0, -1), authority: parsed.hostname, path: parsed.pathname,
      query: parsed.search.slice(1), fragment: parsed.hash.slice(1),
      toString: () => parsed.toString() };
  };
  const vscode = {
    env: { remoteName, uriScheme: 'vscode', asExternalUri: async (value: protocol.SessionURILike) => uri(value.toString() + '?windowId=7') },
    Uri: { parse: uri },
    window: { createOutputChannel: () => output, showWarningMessage: (message: string) => warnings.push(message),
      showInformationMessage: (message: string) => messages.push(message), registerUriHandler: disposable,
      terminals: [], onDidOpenTerminal: disposable, onDidCloseTerminal: disposable },
    workspace: { workspaceFolders: [], onDidChangeWorkspaceFolders: disposable },
    extensions: { getExtension: () => undefined, onDidChange: disposable },
    commands: { registerCommand: (name: string, action: () => Promise<void>) => { commands.set(name, action); return disposable(); } }
  };
  const exports: { activate?: (context: unknown) => void } = {};
  const imports: Record<string, unknown> = {
    vscode, 'node:crypto': require('node:crypto'), './refresh': { SharedRefresh }, './codex': codex,
    './protocol': { ...protocol, localWorkspaces: (folders: Parameters<typeof protocol.localWorkspaces>[0]) => protocol.localWorkspaces(folders, platform) },
    './registry': { registryDirectory: () => platform === 'win32' ? 'C:\\Users\\example\\AppData\\Local\\Pip\\SessionLinks' : '/private/test/registry',
      RegistryError: class extends Error {}, PrivateLeaseWriter: class {
        async write(value: unknown) { if (failWrite) throw new Error('Synthetic write failure'); writes.push(value); }
        remove() { removals.sync += 1; }
        async removeAsync() { removals.async += 1; }
      } }
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../src/extension.js'), 'utf8'), {
    exports, module: { exports }, require: (name: string) => { if (!(name in imports)) throw new Error('Unexpected import: ' + name); return imports[name]; },
    process: { platform, pid: 123, env: {} }, setInterval: () => ({ unref() {} }), clearInterval() {}
  });
  assert.ok(exports.activate);
  exports.activate({ subscriptions, environmentVariableCollection: { persistent: false, replace() {}, delete() {} } });
  return { commands, writes, warnings, messages, removals, dispose: () => subscriptions.forEach(value => value.dispose()) };
}

test('Windows activation registers Refresh Session Links and publishes the existing window route', async () => {
  const f = fixture('win32');
  try {
    assert.ok(f.commands.has('pipSessionLinks.refresh'));
    await f.commands.get('pipSessionLinks.refresh')!();
    assert.ok(f.writes.length > 0);
    const lease = f.writes[0] as { claudeSessionURL: string; terminalURL: string };
    assert.equal(lease.claudeSessionURL, 'vscode://anthropic.claude-code/open?windowId=7');
    assert.equal(lease.terminalURL, 'vscode://pip-local.pip-session-links/terminal?windowId=7');
    assert.deepEqual(f.warnings, []);
    assert.ok(f.messages.includes('Pip session links refreshed for this VS Code window.'));
  } finally { f.dispose(); }
});

test('remote Windows command remains registered and explains why no links are published', async () => {
  const f = fixture('win32', 'wsl');
  try {
    await f.commands.get('pipSessionLinks.refresh')!();
    assert.equal(f.writes.length, 0);
    assert.match(f.warnings[0], /local VS Code windows only/);
    assert.ok(f.messages.some(value => value.includes('remote_window')));
  } finally { f.dispose(); }
});

test('unsupported platforms retain a registered command and static output diagnostic', async () => {
  const f = fixture('linux');
  try {
    await f.commands.get('pipSessionLinks.refresh')!();
    assert.equal(f.writes.length, 0);
    assert.match(f.warnings[0], /Pip Session Links output/);
    assert.ok(f.messages.some(value => value.includes('unsupported_platform')));
  } finally { f.dispose(); }
});

test('a failed Windows refresh cleans up asynchronously; synchronous removal is reserved for disposal', async () => {
  const f = fixture('win32', undefined, true);
  await f.commands.get('pipSessionLinks.refresh')!();
  assert.ok(f.removals.async > 0);
  assert.equal(f.removals.sync, 0);
  assert.match(f.warnings[0], /Pip Session Links output/);
  f.dispose();
  assert.equal(f.removals.sync, 1);
});
