import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { ensureTelemetryConfig, parseToolDecisions, startTelemetry, telemetryEnvironment, ToolDecision } from '../src/telemetry';
import { Mailbox } from '../src/mailbox';
import { handle, HookEvent } from '../src/hook';

const now = 1_790_000_000, at = now - 0.25;
const attr = (key: string, value: string) => ({ key, value: { stringValue: value } });
function fixture(time = at) {
  return { resourceLogs: [{ resource: { attributes: [attr('service.name', 'claude-code')] }, scopeLogs: [{ scope: { name: 'com.anthropic.claude_code.events' }, logRecords: [{
    timeUnixNano: String(BigInt(Math.round(time * 1000)) * 1_000_000n), observedTimeUnixNano: String(BigInt(Math.round(now * 1000)) * 1_000_000n),
    body: { stringValue: 'claude_code.tool_decision' }, attributes: [attr('event.name', 'tool_decision'), attr('event.timestamp', new Date(time * 1000).toISOString()),
      attr('session.id', 'session-one'), attr('prompt.id', 'prompt-one'), attr('tool_use_id', 'toolu_owned_one'), attr('decision', 'accept'), attr('source', 'user_temporary'), attr('tool_name', 'Bash')]
  }] }] }] };
}
const record = (value: ReturnType<typeof fixture>) => value.resourceLogs[0]!.scopeLogs[0]!.logRecords[0]!;
function replace(value: ReturnType<typeof fixture>, name: string, next: string): void {
  const log = record(value); log.attributes = log.attributes.filter(a => a.key !== name); log.attributes.push(attr(name, next));
}
test('Claude OTLP parser emits only exact decision metadata and original time', () => {
  assert.deepEqual(parseToolDecisions(fixture(), now), [{ session_id: 'session-one', prompt_id: 'prompt-one', tool_use_id: 'toolu_owned_one', decision: 'accept', source: 'user_temporary', decided_at: at }]);
  const old = fixture(now - 86400); record(old).observedTimeUnixNano = '9999999999999999999';
  assert.equal(parseToolDecisions(old, now)[0]!.decided_at, now - 86400);
  const result = JSON.stringify(parseToolDecisions(fixture(), now)); assert.ok(!result.includes('Bash')); assert.ok(!result.includes('resource'));
});
test('telemetry validates source/decision combinations and exact Claude service/scope', () => {
  for (const [decision, source] of [['accept', 'config'], ['accept', 'hook'], ['accept', 'user_temporary'], ['accept', 'user_permanent'], ['reject', 'config'], ['reject', 'hook'], ['reject', 'user_abort'], ['reject', 'user_reject']]) {
    const value = fixture(); replace(value, 'decision', decision!); replace(value, 'source', source!); assert.equal(parseToolDecisions(value, now).length, 1);
  }
  for (const [decision, source] of [['allow', 'hook'], ['accept', 'user_abort'], ['reject', 'user_temporary'], ['accept', 'classifier']]) {
    const value = fixture(); replace(value, 'decision', decision!); replace(value, 'source', source!); assert.deepEqual(parseToolDecisions(value, now), []);
  }
  const wrongService = fixture(); wrongService.resourceLogs[0]!.resource.attributes[0]!.value.stringValue = 'unrelated'; assert.deepEqual(parseToolDecisions(wrongService, now), []);
  const wrongScope = fixture(); wrongScope.resourceLogs[0]!.scopeLogs[0]!.scope.name = 'unrelated'; assert.deepEqual(parseToolDecisions(wrongScope, now), []);
  const wrongBody = fixture(); record(wrongBody).body.stringValue = 'claude_code.tool_result'; assert.deepEqual(parseToolDecisions(wrongBody, now), []);
});
test('duplicate, oversized, control and non-string attributes cannot impersonate an identity', () => {
  for (const value of ['', 'has space', 'bad\nidentity', '\ud800', 'é'.repeat(257)]) {
    const document = fixture(); replace(document, 'tool_use_id', value); assert.deepEqual(parseToolDecisions(document, now), []);
  }
  const duplicate = fixture(); record(duplicate).attributes.push(attr('tool_name', 'Bash')); assert.deepEqual(parseToolDecisions(duplicate, now), []);
  const typed = fixture(); (record(typed).attributes[0]!.value as unknown as Record<string, unknown>).intValue = '7'; assert.deepEqual(parseToolDecisions(typed, now), []);
  const over = fixture(); record(over).attributes = Array.from({ length: 129 }, (_, i) => attr(`key${i}`, 'value')); assert.deepEqual(parseToolDecisions(over, now), []);
});
test('event timestamps must agree and cannot substitute arrival time', () => {
  assert.deepEqual(parseToolDecisions(fixture(now + 6), now), []);
  const disagree = fixture(); replace(disagree, 'event.timestamp', new Date((at - 10) * 1000).toISOString()); assert.deepEqual(parseToolDecisions(disagree, now), []);
  const missing = fixture(); delete (record(missing) as Partial<ReturnType<typeof record>>).timeUnixNano; record(missing).attributes = record(missing).attributes.filter(a => a.key !== 'event.timestamp'); assert.deepEqual(parseToolDecisions(missing, now), []);
  for (const invalid of ['-1', '1e18', '9'.repeat(21), '18446744073709551616']) { const value = fixture(); record(value).timeUnixNano = invalid; assert.deepEqual(parseToolDecisions(value, now), []); }
  for (const invalid of ['2026-02-30T00:00:00Z', '2026-01-01T24:00:00Z', '2026-01-01T00:00:60Z']) { const value = fixture(); replace(value, 'event.timestamp', invalid); assert.deepEqual(parseToolDecisions(value, now), []); }
});
test('telemetry traversal limits fail closed as an envelope', () => {
  const value = fixture(); value.resourceLogs = Array.from({ length: 33 }, () => fixture().resourceLogs[0]!); assert.deepEqual(parseToolDecisions(value, now), []);
  const scopes = fixture(); scopes.resourceLogs[0]!.scopeLogs = Array.from({ length: 129 }, () => fixture().resourceLogs[0]!.scopeLogs[0]!); assert.deepEqual(parseToolDecisions(scopes, now), []);
  const records = fixture(); records.resourceLogs[0]!.scopeLogs[0]!.logRecords = Array.from({ length: 2049 }, () => record(fixture())); assert.deepEqual(parseToolDecisions(records, now), []);
});
test('receiver configuration is private, stable, loopback-only and disables content exporters', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-telemetry-config-'));
  try {
    const config = await ensureTelemetryConfig(root); assert.deepEqual(await ensureTelemetryConfig(root), config);
    assert.match(config.token, /^[a-f0-9]{64}$/); assert.equal(config.host, '127.0.0.1'); assert.ok(config.port >= 49152 && config.port <= 65535);
    if (process.platform !== 'win32') assert.equal((await fs.stat(path.join(root, 'telemetry.json'))).mode & 0o077, 0);
    const env = telemetryEnvironment(config); for (const key of ['OTEL_LOG_USER_PROMPTS', 'OTEL_LOG_ASSISTANT_RESPONSES', 'OTEL_LOG_TOOL_DETAILS', 'OTEL_LOG_RAW_API_BODIES']) assert.equal(env[key], '0');
    assert.equal(env.OTEL_METRICS_EXPORTER, 'none'); assert.equal(env.OTEL_TRACES_EXPORTER, 'none');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
test('authenticated local HTTP receiver accepts only bounded OTLP JSON, never persists raw logs', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-telemetry-http-')), received: ToolDecision[] = [];
  let receiver: Awaited<ReturnType<typeof startTelemetry>> | undefined;
  try {
    const config = await ensureTelemetryConfig(root); receiver = await startTelemetry(root, async (_root, event) => { received.push(event); });
    const request = (label: string, token: string, body: string, override: Record<string, string> = {}, headersOnly = false) => new Promise<number>((resolve, reject) => {
      const fail = (error: NodeJS.ErrnoException) => reject(new Error(`${label}: ${error.code || error.message}`, { cause: error }));
      const req = http.request(receiver!.endpoint, { method: 'POST', agent: false,
        headers: { 'Content-Type': 'application/json', 'Content-Length': String(Buffer.byteLength(body)), 'X-Pip-Token': token, ...override } }, res => {
        if (headersOnly) req.end();
        res.on('error', fail); res.resume(); res.on('end', () => resolve(res.statusCode!));
      });
      req.on('error', fail);
      // Over-limit headers must be rejected before the client uploads a body.
      // Sending the full rejected body races TCP close/reset on Windows.
      if (headersOnly) req.flushHeaders(); else req.end(body);
    });
    const body = JSON.stringify(fixture(Date.now() / 1000 - 0.1));
    assert.equal(await request('invalid token', 'invalid', body), 401); assert.equal(received.length, 0);
    assert.equal(await request('wrong content type', config.token, body, { 'Content-Type': 'text/plain' }), 400);
    assert.equal(await request('invalid JSON', config.token, '{invalid'), 400);
    assert.equal(await request('wrong host', config.token, body, { Host: 'other.example' }), 400);
    assert.equal(await request('oversized advertised body', config.token, '', { 'Content-Length': String(512 * 1024 + 1) }, true), 413);
    assert.equal(await request('valid decision', config.token, body), 200); assert.equal(received.length, 1); assert.equal(received[0]!.tool_use_id, 'toolu_owned_one');
    const files = (await fs.readdir(root)).filter(name => name.endsWith('.json') && name !== 'telemetry.json');
    for (const name of files) assert.ok(!(await fs.readFile(path.join(root, name), 'utf8')).includes('toolu_owned_one'));
  } finally { await receiver?.stop(); await fs.rm(root, { recursive: true, force: true }); }
});
test('a real local decision event clears only its bound card while the other tool keeps working', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-telemetry-integration-')), box = new Mailbox(root);
  let receiver: Awaited<ReturnType<typeof startTelemetry>> | undefined; const pending: Promise<unknown>[] = [];
  const first: HookEvent = { hook_event_name: 'PreToolUse', session_id: 'session-one', prompt_id: 'prompt-one', tool_use_id: 'toolu_owned_one', tool_name: 'Bash', tool_input: { command: 'show first demo only' }, cwd: root };
  const second: HookEvent = { ...first, tool_use_id: 'toolu_owned_two', tool_input: { command: 'show second demo only' } };
  try {
    await box.start(); await box.poll(); receiver = await startTelemetry(root);
    const config = await ensureTelemetryConfig(root);
    await handle(root, 'claude', first, 3, false, true); await handle(root, 'claude', second, 3, false, true);
    pending.push(handle(root, 'claude', { ...first, hook_event_name: 'PermissionRequest', tool_use_id: undefined }, 3));
    pending.push(handle(root, 'claude', { ...second, hook_event_name: 'PermissionRequest', tool_use_id: undefined }, 3));
    const deadline = Date.now() + 1500;
    while ((await box.poll()).requests.length !== 2 && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal((await box.poll()).requests.length, 2);
    const body = JSON.stringify(fixture(Date.now() / 1000));
    await new Promise<void>((resolve, reject) => {
      const req = http.request(receiver!.endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': String(Buffer.byteLength(body)), 'X-Pip-Token': config.token } }, res => {
        res.resume(); res.on('end', () => { try { assert.equal(res.statusCode, 200); resolve(); } catch (error) { reject(error); } });
      }); req.on('error', reject); req.end(body);
    });
    const remaining = await box.poll(); assert.equal(remaining.requests.length, 1); assert.equal(remaining.requests[0]!.correlation.toolUseId, second.tool_use_id); assert.equal(remaining.working, true);
    assert.equal(await pending[0], undefined);
    await handle(root, 'claude', { ...second, hook_event_name: 'PostToolUse' }, 3); assert.equal(await pending[1], undefined);
  } finally {
    await handle(root, 'claude', { ...first, hook_event_name: 'SessionEnd' }, 3).catch(() => undefined);
    await Promise.allSettled(pending); await receiver?.stop(); await box.close(); await fs.rm(root, { recursive: true, force: true });
  }
});
