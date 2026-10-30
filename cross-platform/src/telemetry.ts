import http from 'node:http';
import { randomBytes, randomInt, timingSafeEqual } from 'node:crypto';
import { locked, prepare, read, write } from './mailbox';
import { handleTelemetryDecision } from './hook';

export interface TelemetryConfig { version: 1; host: '127.0.0.1'; port: number; token: string }
export interface ToolDecision { session_id: string; tool_use_id: string; decision: 'accept' | 'reject'; source: string; decided_at: number; prompt_id?: string }
const anyTypes = new Set(['stringValue', 'boolValue', 'intValue', 'doubleValue', 'arrayValue', 'kvlistValue', 'bytesValue']);
const fields = new Set(['session.id', 'prompt.id', 'tool_use_id', 'decision', 'source', 'event.name', 'event.timestamp']);
const sources: Record<string, Set<string>> = { accept: new Set(['config', 'hook', 'user_temporary', 'user_permanent']), reject: new Set(['config', 'hook', 'user_abort', 'user_reject']) };
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value);
const bounded = (value: unknown, size: number): value is string => typeof value === 'string' && value.length <= size && Buffer.byteLength(value, 'utf8') <= size && !/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/u.test(value);
const identifier = (value: unknown): value is string => bounded(value, 512) && value.length > 0 && !/[\s\u0000-\u001f\u007f]/u.test(value);
export function validTelemetryConfig(value: unknown): value is TelemetryConfig {
  return object(value) && value.version === 1 && value.host === '127.0.0.1' && Number.isInteger(value.port) &&
    (value.port as number) >= 49152 && (value.port as number) <= 65535 && typeof value.token === 'string' && /^[a-f0-9]{64}$/.test(value.token);
}
export async function ensureTelemetryConfig(root: string): Promise<TelemetryConfig> {
  await prepare(root);
  return locked(root, async () => {
    try {
      const value = await read(root, 'telemetry.json', 4096);
      if (!validTelemetryConfig(value)) throw new Error('Invalid local decision receiver configuration.');
      return value;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
      const value: TelemetryConfig = { version: 1, host: '127.0.0.1', port: randomInt(49152, 65536), token: randomBytes(32).toString('hex') };
      await write(root, 'telemetry.json', value); return value;
    }
  });
}
export function telemetryEnvironment(config: TelemetryConfig): Record<string, string> {
  if (!validTelemetryConfig(config)) throw new Error('Invalid local decision receiver configuration.');
  return {
    CLAUDE_CODE_ENABLE_TELEMETRY: '1', OTEL_LOGS_EXPORTER: 'otlp', OTEL_EXPORTER_OTLP_LOGS_PROTOCOL: 'http/json',
    OTEL_EXPORTER_OTLP_LOGS_ENDPOINT: `http://127.0.0.1:${config.port}/v1/logs`, OTEL_EXPORTER_OTLP_LOGS_HEADERS: `X-Pip-Token=${config.token}`,
    OTEL_LOGS_EXPORT_INTERVAL: '1000', OTEL_METRICS_EXPORTER: 'none', OTEL_TRACES_EXPORTER: 'none', OTEL_LOG_USER_PROMPTS: '0',
    OTEL_LOG_ASSISTANT_RESPONSES: '0', OTEL_LOG_TOOL_DETAILS: '0', OTEL_LOG_TOOL_CONTENT: '0', OTEL_LOG_MANAGED_SETTINGS: '0', OTEL_LOG_RAW_API_BODIES: '0'
  };
}
function strings(attributes: unknown, wanted: Set<string>): Record<string, string> | undefined {
  if (!Array.isArray(attributes) || attributes.length > 128) return;
  const result: Record<string, string> = {}, seen = new Set<string>();
  for (const entry of attributes) {
    if (!object(entry) || !bounded(entry.key, 128) || !entry.key || seen.has(entry.key) || !object(entry.value)) return;
    seen.add(entry.key);
    const types = Object.keys(entry.value).filter(key => anyTypes.has(key));
    if (types.length !== 1) return;
    if ('stringValue' in entry.value && !bounded(entry.value.stringValue, 4096)) return;
    if (wanted.has(entry.key)) {
      if (!('stringValue' in entry.value)) return;
      result[entry.key] = entry.value.stringValue as string;
    }
  }
  return result;
}
function originalTime(record: Record<string, unknown>, attrs: Record<string, string>, now: number): number | undefined {
  let nanos: number | undefined, iso: number | undefined;
  if ('timeUnixNano' in record) {
    const raw = record.timeUnixNano;
    if ((typeof raw !== 'string' || !/^[0-9]{1,20}$/.test(raw)) && (typeof raw !== 'number' || !Number.isInteger(raw) || raw < 0)) return;
    try { const value = BigInt(raw as string | number); if (value < 0n || value > 18446744073709551615n) return; if (value) nanos = Number(value / 1_000_000_000n) + Number(value % 1_000_000_000n) / 1e9; } catch { return; }
  }
  if ('event.timestamp' in attrs) {
    const match = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/.exec(attrs['event.timestamp']!);
    if (!match || (match[3] !== 'Z' && (Number(match[3]!.slice(1, 3)) > 23 || Number(match[3]!.slice(4)) > 59))) return;
    const parts = match[1]!.split(/[-T:]/).map(Number), date = new Date(0);
    date.setUTCFullYear(parts[0]!, parts[1]! - 1, parts[2]!); date.setUTCHours(parts[3]!, parts[4]!, parts[5]!, 0);
    if ([date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate(), date.getUTCHours(), date.getUTCMinutes(), date.getUTCSeconds()].some((value, index) => value !== parts[index])) return;
    iso = Date.parse(match[1]! + match[3]!) / 1000 + Number((match[2] || '').padEnd(9, '0')) / 1e9;
    if (!Number.isFinite(iso)) return;
  }
  if (nanos !== undefined && iso !== undefined && Math.abs(nanos - iso) > 1) return;
  const value = nanos ?? iso;
  return value !== undefined && Number.isFinite(value) && value > 0 && value <= now + 5 ? value : undefined;
}
function decision(record: unknown, now: number): ToolDecision | undefined {
  if (!object(record) || !object(record.body) || record.body.stringValue !== 'claude_code.tool_decision' ||
      Object.keys(record.body).filter(key => anyTypes.has(key)).join() !== 'stringValue') return;
  const attrs = strings(record.attributes, fields);
  if (!attrs || (attrs['event.name'] !== undefined && attrs['event.name'] !== 'tool_decision') || !identifier(attrs['session.id']) ||
      !identifier(attrs.tool_use_id) || (attrs['prompt.id'] !== undefined && !identifier(attrs['prompt.id'])) || !sources[attrs.decision || '']?.has(attrs.source || '')) return;
  const at = originalTime(record, attrs, now);
  if (at === undefined) return;
  return { session_id: attrs['session.id'], tool_use_id: attrs.tool_use_id, decision: attrs.decision as 'accept' | 'reject', source: attrs.source!, decided_at: at,
    ...(attrs['prompt.id'] === undefined ? {} : { prompt_id: attrs['prompt.id'] }) };
}
/** Only correlation, decision and original event time leave this parser. */
export function parseToolDecisions(document: unknown, now = Date.now() / 1000): ToolDecision[] {
  if (!Number.isFinite(now) || now <= 0 || !object(document) || !Array.isArray(document.resourceLogs) || document.resourceLogs.length > 32) return [];
  const result: ToolDecision[] = []; let scopeCount = 0, recordCount = 0;
  for (const resource of document.resourceLogs) {
    if (!object(resource) || !object(resource.resource) || strings(resource.resource.attributes, new Set(['service.name']))?.['service.name'] !== 'claude-code' || !Array.isArray(resource.scopeLogs)) continue;
    scopeCount += resource.scopeLogs.length; if (scopeCount > 128) return [];
    for (const scope of resource.scopeLogs) {
      if (!object(scope) || !object(scope.scope) || scope.scope.name !== 'com.anthropic.claude_code.events' || !Array.isArray(scope.logRecords)) continue;
      recordCount += scope.logRecords.length; if (recordCount > 2048) return [];
      for (const record of scope.logRecords) { const value = decision(record, now); if (value) result.push(value); }
    }
  }
  return result;
}
export interface TelemetryReceiver { endpoint: string; stop(): Promise<void> }
export async function startTelemetry(root: string, consume: (root: string, event: ToolDecision) => Promise<unknown> = handleTelemetryDecision): Promise<TelemetryReceiver> {
  const config = await ensureTelemetryConfig(root);
  const expected = Buffer.from(config.token, 'ascii');
  const server = http.createServer({ maxHeaderSize: 16 * 1024, requestTimeout: 3000, headersTimeout: 3000, connectionsCheckingInterval: 1000 }, async (req, res) => {
    const reject = (code: number) => { res.writeHead(code, { Connection: 'close', 'Content-Length': '0' }); res.end(); req.resume(); };
    const names = new Set<string>();
    for (let i = 0; i < req.rawHeaders.length; i += 2) { const name = req.rawHeaders[i]!.toLowerCase(); if (names.has(name)) { reject(400); return; } names.add(name); }
    if (req.socket.remoteAddress !== '127.0.0.1' || req.method !== 'POST' || req.url !== '/v1/logs' || req.httpVersion !== '1.1' ||
        req.headers.host !== `127.0.0.1:${config.port}` || req.headers['transfer-encoding'] !== undefined || req.headers['content-encoding'] !== undefined || req.headers.expect !== undefined ||
        !['application/json', 'application/json; charset=utf-8'].includes(String(req.headers['content-type']).toLowerCase()) || !/^[0-9]+$/.test(String(req.headers['content-length']))) { reject(400); return; }
    const length = Number(req.headers['content-length']);
    if (!Number.isSafeInteger(length) || length > 512 * 1024) { reject(413); return; }
    const supplied = Buffer.from(String(req.headers['x-pip-token'] || ''), 'ascii');
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) { reject(401); return; }
    try {
      let size = 0; const chunks: Buffer[] = [];
      for await (const chunk of req) { const value = Buffer.from(chunk); size += value.length; if (size > length || size > 512 * 1024) { reject(413); return; } chunks.push(value); }
      if (size !== length) { reject(400); return; }
      const document: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
      for (const event of parseToolDecisions(document)) await consume(root, event);
      res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': '2', Connection: 'close' }); res.end('{}');
    } catch { if (!res.headersSent) reject(400); else res.destroy(); }
  });
  server.maxConnections = 16; server.maxRequestsPerSocket = 1; server.setTimeout(3000, socket => socket.destroy());
  server.on('clientError', (_error, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'); });
  try {
    await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(config.port, config.host, () => { server.removeListener('error', reject); resolve(); }); });
  } catch { await write(root, 'telemetry-health.json', { status: 'unavailable', port: config.port }); throw new Error('Local Claude decision receiver is unavailable.'); }
  server.on('error', () => { void write(root, 'telemetry-health.json', { status: 'unavailable', port: config.port }).catch(() => undefined); });
  await write(root, 'telemetry-health.json', { status: 'listening', port: config.port });
  let stopped = false;
  return { endpoint: `http://127.0.0.1:${config.port}/v1/logs`, async stop() {
    if (stopped) return; stopped = true;
    server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
    await write(root, 'telemetry-health.json', { status: 'stopped', port: config.port });
  } };
}
