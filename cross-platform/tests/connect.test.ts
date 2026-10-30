import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { merge, mergeTelemetry, connectionLocations, prepareConnection, applyConnection, restoreConnection } from '../src/connect';
import { ensureTelemetryConfig, telemetryEnvironment } from '../src/telemetry';
import { hookArguments, quoteHookCommand } from '../src/platform-config';
test('connection replaces owned hooks across events while preserving unrelated hooks and settings', () => {
  const old = '/example/AgentCompanion/bridge.py', runner = '/example/PipPreview/hook.js';
  const current = { env: { private: 'sentinel' }, permissions: { defaultMode: 'plan' }, hooks: {
    PermissionRequest: [{ matcher: '*', hooks: [{ type: 'command', command: `python '${old}' hook --source claude` }, { type: 'command', command: 'other-hook' }] }],
    PreToolUse: [{ matcher: 'AskUserQuestion', hooks: [{ type: 'command', command: `python '${old}' hook` }] }]
  } };
  const addition = { hooks: { PermissionRequest: [{ matcher: '*', hooks: [{ type: 'command', command: `node '${runner}' hook` }] }] } };
  const result = merge(current, addition, old, runner);
  assert.deepEqual(result.document.env, current.env); assert.deepEqual(result.document.permissions, current.permissions);
  assert.equal(result.document.hooks!.PreToolUse, undefined);
  assert.equal(result.removed, 2); assert.equal(result.added, 1);
  assert.equal(result.document.hooks!.PermissionRequest!.flatMap(g => g.hooks).some(h => h.command === 'other-hook'), true);
});
test('native PipHelper and source exec-form hooks are replaced without matching unrelated fragments', () => {
  const old = '/Applications/Pip.app/Contents/Resources/PipHelper', runner = '/example/source/hook.js';
  const current = { hooks: { Notification: [{ hooks: [
    { type: 'command', command: `'${old}' bridge hook --source claude` },
    { type: 'command', command: '/opt/node', args: [runner, 'hook', '--source', 'claude'] },
    { type: 'command', command: `'${old}' bridge hook; echo unrelated` },
    { type: 'command', command: 'echo', args: [old, 'bridge', 'hook'] },
    { type: 'command', command: '/unrelated/bridge.py hook' }
  ] }] } };
  const result = merge(current, { hooks: {} }, old, runner);
  assert.equal(result.removed, 2);
  assert.equal(result.document.hooks!.Notification![0]!.hooks.length, 3);
  assert.ok(result.document.hooks!.Notification![0]!.hooks.some(h => h.command?.includes('; echo unrelated')));
});
test('Windows encoded launcher transports literal paths and rejects modified command fragments', () => {
  const args = ['C:\\Program Files\\nodejs\\node.exe', "C:\\Users\\O'Brien $()\\Pip\\hook.js", 'hook', '--runtime', 'C:\\Users\\Name & Co\\AppData\\Roaming\\PipSource\\runtime'];
  const command = quoteHookCommand(args, 'win32');
  assert.ok(command.startsWith('powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand '));
  assert.deepEqual(hookArguments(command), args);
  assert.equal(hookArguments(command + ' & do-something'), undefined);
  assert.deepEqual(hookArguments(quoteHookCommand(["/Users/O'Brien/node", '/repo/hook.js', 'hook'], 'darwin')), ["/Users/O'Brien/node", '/repo/hook.js', 'hook']);
  assert.throws(() => quoteHookCommand(['/node', '/bad\npath']), /launcher/);
});
test('agent configuration directory overrides remain explicit and must be absolute', () => {
  const home = path.resolve('/example/home');
  const result = connectionLocations(home, { CLAUDE_CONFIG_DIR: path.resolve('/custom/claude'), CODEX_HOME: path.resolve('/custom/codex') });
  assert.equal(result.claude, path.join(path.resolve('/custom/claude'), 'settings.json'));
  assert.equal(result.codex, path.join(path.resolve('/custom/codex'), 'hooks.json'));
  assert.throws(() => connectionLocations(home, { CODEX_HOME: 'relative-home' }), /absolute/);
});
test('telemetry merge preserves unrelated settings and refuses another collector', () => {
  const environment = telemetryEnvironment({ version: 1, host: '127.0.0.1', port: 49152, token: 'a'.repeat(64) });
  const prior = telemetryEnvironment({ version: 1, host: '127.0.0.1', port: 49153, token: 'b'.repeat(64) });
  assert.equal(mergeTelemetry({ env: { sentinel: 'keep' } }, environment).env!.sentinel, 'keep');
  assert.equal(mergeTelemetry({ env: prior }, environment, prior).env!.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT, environment.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT);
  for (const current of [{ env: { OTEL_EXPORTER_OTLP_ENDPOINT: 'https://existing.example' } }, { otelHeadersHelper: 'approved-helper' }, { env: { OTEL_LOG_USER_PROMPTS: '1' } }]) assert.throws(() => mergeTelemetry(current, environment), /preserved/);
});
test('prepare/apply/restore preserve original settings with private backups and reject stale plans', async () => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-connect-test-'));
  const home = path.join(base, 'home'), root = path.join(base, 'runtime');
  await fs.mkdir(path.join(home, '.claude'), { recursive: true });
  const file = path.join(home, '.claude', 'settings.json');
  const original = JSON.stringify({ env: { token: 'secret sentinel' }, hooks: {} });
  await fs.writeFile(file, original, { mode: 0o600 });
  try {
    await prepareConnection(home, root);
    assert.equal((await fs.readFile(path.join(root, 'connection-plan.json'), 'utf8')).includes('secret sentinel'), false);
    assert.equal(await fs.readFile(file, 'utf8'), original);
    await applyConnection(home, root);
    assert.equal(JSON.parse(await fs.readFile(file, 'utf8')).env.token, 'secret sentinel');
    const receipt = JSON.parse(await fs.readFile(path.join(root, 'connection-receipt.json'), 'utf8'));
    if (process.platform !== 'win32') assert.equal((await fs.stat(receipt.targets[0].backup)).mode & 0o077, 0);
    await prepareConnection(home, root);
    await applyConnection(home, root);
    await restoreConnection(home, root);
    assert.equal(await fs.readFile(file, 'utf8'), original);
    await assert.rejects(fs.stat(path.join(home, '.codex', 'hooks.json')));
    await prepareConnection(home, root);
    await fs.writeFile(file, '{"changed":true}', { mode: 0o600 });
    await assert.rejects(applyConnection(home, root), /settings changed/);
    assert.equal(await fs.readFile(file, 'utf8'), '{"changed":true}');
  } finally { await fs.rm(base, { recursive: true, force: true }); }
});
test('changed receiver configuration and source paths cannot reuse an earlier plan', async () => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-connect-stale-'));
  const home = path.join(base, 'home'), root = path.join(base, 'runtime');
  try {
    await prepareConnection(home, root, { environment: {} });
    const config = await ensureTelemetryConfig(root);
    await fs.writeFile(path.join(root, 'telemetry.json'), JSON.stringify({ ...config, token: 'c'.repeat(64) }), { mode: 0o600 });
    await assert.rejects(applyConnection(home, root, { environment: {} }), /configuration or plan changed/);
    await assert.rejects(fs.stat(path.join(home, '.claude', 'settings.json')));
    await prepareConnection(home, root, { environment: {} });
    await assert.rejects(applyConnection(home, root, { environment: { CODEX_HOME: path.join(home, 'other-codex') } }), /override changed/);
    await assert.rejects(prepareConnection(home, root, { nodePath: '/Applications/Pip.app/Contents/MacOS/Electron' }), /Node.js executable/);
  } finally { await fs.rm(base, { recursive: true, force: true }); }
});
test('restore refuses changed backups and changed post-connection settings', async () => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-connect-restore-'));
  const home = path.join(base, 'home'), root = path.join(base, 'runtime'), file = path.join(home, '.claude', 'settings.json');
  await fs.mkdir(path.dirname(file), { recursive: true }); await fs.writeFile(file, '{"env":{"sentinel":"keep"}}', { mode: 0o600 });
  try {
    await prepareConnection(home, root, { environment: {} }); await applyConnection(home, root, { environment: {} });
    const after = await fs.readFile(file, 'utf8'), receipt = JSON.parse(await fs.readFile(path.join(root, 'connection-receipt.json'), 'utf8'));
    const originalBackup = await fs.readFile(receipt.targets[0].backup);
    await fs.writeFile(receipt.targets[0].backup, '{"tampered":true}', { mode: 0o600 });
    await assert.rejects(restoreConnection(home, root, { environment: {} }), /backup unavailable or changed/);
    assert.equal(await fs.readFile(file, 'utf8'), after);
    await fs.writeFile(receipt.targets[0].backup, originalBackup, { mode: 0o600 });
    await fs.writeFile(file, '{"userChanged":true}', { mode: 0o600 });
    await assert.rejects(restoreConnection(home, root, { environment: {} }), /Settings changed/);
    assert.equal(await fs.readFile(file, 'utf8'), '{"userChanged":true}');
  } finally { await fs.rm(base, { recursive: true, force: true }); }
});
test('release 0.7.0 nested PipHelper hooks migrate without leaving duplicate approval or question hooks', async () => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-connect-release-'));
  const home = path.join(base, 'home'), root = path.join(base, 'runtime'), file = path.join(home, '.claude', 'settings.json');
  await fs.mkdir(path.dirname(file), { recursive: true });
  const helper = '/Applications/Pip.app/Contents/Helpers/PipRuntime.app/Contents/MacOS/PipHelper';
  const perUser = path.join(home, 'Applications', 'Pip.app', 'Contents', 'Helpers', 'PipRuntime.app', 'Contents', 'MacOS', 'PipHelper');
  const original = { permissions: { defaultMode: 'default' }, hooks: {
    PermissionRequest: [{ matcher: '*', hooks: [{ type: 'command', command: `'${helper}' hook --source claude --runtime '/old/runtime' --wait 120` }, { type: 'command', command: 'unrelated-approval-hook' }] }],
    PreToolUse: [{ matcher: '^AskUserQuestion$', hooks: [{ type: 'command', command: `'${perUser}' hook --source claude --runtime '/old/runtime' --wait 120` }] }, { matcher: '*', hooks: [{ type: 'command', command: `'${helper}' hook --source claude --runtime '/old/runtime' --track-tools` }] }],
    Notification: [{ matcher: 'permission_prompt', hooks: [{ type: 'command', command: `'${helper}' hook --source claude --runtime '/old/runtime'` }] }]
  } };
  await fs.writeFile(file, JSON.stringify(original), { mode: 0o600 });
  try {
    const plan = await prepareConnection(home, root, { environment: {} }); assert.equal(plan.targets[0]!.removed, 4);
    await applyConnection(home, root, { environment: {} });
    const next = JSON.parse(await fs.readFile(file, 'utf8'));
    assert.equal(JSON.stringify(next.hooks).includes('PipRuntime.app'), false);
    assert.equal(next.hooks.PermissionRequest.flatMap((g: any) => g.hooks).length, 2);
    assert.equal(next.hooks.PreToolUse.flatMap((g: any) => g.hooks).length, 2);
    assert.equal(next.hooks.Notification.flatMap((g: any) => g.hooks).length, 1);
    assert.ok(JSON.stringify(next.hooks).includes('unrelated-approval-hook'));
    await restoreConnection(home, root, { environment: {} }); assert.deepEqual(JSON.parse(await fs.readFile(file, 'utf8')), original);
  } finally { await fs.rm(base, { recursive: true, force: true }); }
});
test('an invalid existing connection receipt cannot silently discard the restore baseline', async () => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-connect-receipt-'));
  const home = path.join(base, 'home'), root = path.join(base, 'runtime');
  try {
    await prepareConnection(home, root, { environment: {} }); await applyConnection(home, root, { environment: {} });
    const before = await fs.readFile(path.join(home, '.claude', 'settings.json'), 'utf8');
    await fs.writeFile(path.join(root, 'connection-receipt.json'), '{invalid', { mode: 0o600 });
    await prepareConnection(home, root, { environment: {} }); await assert.rejects(applyConnection(home, root, { environment: {} }));
    assert.equal(await fs.readFile(path.join(home, '.claude', 'settings.json'), 'utf8'), before);
  } finally { await fs.rm(base, { recursive: true, force: true }); }
});
test('restore resumes after one target was already restored without overwriting later edits', async () => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-connect-partial-'));
  const home = path.join(base, 'home'), root = path.join(base, 'runtime'), claude = path.join(home, '.claude', 'settings.json'), codex = path.join(home, '.codex', 'hooks.json');
  await fs.mkdir(path.dirname(claude), { recursive: true });
  const original = '{"env":{"sentinel":"original value"}}'; await fs.writeFile(claude, original, { mode: 0o600 });
  try {
    await prepareConnection(home, root, { environment: {} }); await applyConnection(home, root, { environment: {} });
    // Simulate a process interrupted after its first successful restore write.
    await fs.writeFile(claude, original, { mode: 0o600 });
    await restoreConnection(home, root, { environment: {} });
    assert.equal(await fs.readFile(claude, 'utf8'), original); await assert.rejects(fs.stat(codex));
    await prepareConnection(home, root, { environment: {} }); await applyConnection(home, root, { environment: {} });
    await fs.writeFile(claude, original, { mode: 0o600 }); await fs.writeFile(codex, '{"userEdited":true}', { mode: 0o600 });
    await assert.rejects(restoreConnection(home, root, { environment: {} }), /Settings changed/);
    assert.equal(await fs.readFile(codex, 'utf8'), '{"userEdited":true}'); assert.equal(await fs.readFile(claude, 'utf8'), original);
  } finally { await fs.rm(base, { recursive: true, force: true }); }
});
