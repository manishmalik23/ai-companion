import * as fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { config } from './hook';
import { defaultRuntime, prepare, read, write } from './mailbox';
import { ensureTelemetryConfig, telemetryEnvironment, validTelemetryConfig } from './telemetry';
import { hookArguments } from './platform-config';
import type { Source } from './protocol';

type Hook = { type: string; command?: string; args?: string[]; [key: string]: unknown };
type Group = { hooks: Hook[]; [key: string]: unknown };
type Config = { hooks?: Record<string, Group[]>; env?: Record<string, unknown>; [key: string]: unknown };
interface Target { source: Source; file: string; before: string | null; next: string; removed: number; added: number }
interface Plan { version: 2; home: string; runtime: string; nodePath: string; files: Record<string, string>; telemetryHash: string; targets: Target[] }
interface Receipt { version: 2; targets: { file: string; backup?: string; after: string; backupHash?: string }[] }
export interface ConnectionOptions { nodePath?: string; environment?: NodeJS.ProcessEnv }
const hash = (bytes: Buffer | string) => createHash('sha256').update(bytes).digest('hex');
const clone = <T>(value: T): T => JSON.parse(JSON.stringify(value));
const parse = (value: Buffer): unknown => JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(value));
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value);
function validated(value: unknown): Config {
  if (!object(value)) throw new Error('Settings must be a JSON object.');
  const document = value as Config;
  if (document.hooks !== undefined && !object(document.hooks)) throw new Error('Hooks must be an object.');
  for (const groups of Object.values(document.hooks || {})) {
    if (!Array.isArray(groups) || !groups.every(g => object(g) && Array.isArray(g.hooks) &&
      g.hooks.every(h => object(h) && typeof h.type === 'string' && (h.type !== 'command' || typeof h.command === 'string') &&
        (h.args === undefined || Array.isArray(h.args) && h.args.every(a => typeof a === 'string' && !/[\0\r\n]/.test(a)))))) throw new Error('Invalid existing hooks; nothing changed.');
  }
  return document;
}
function argumentsOf(hook: Hook): string[] | undefined {
  if (hook.type !== 'command' || typeof hook.command !== 'string') return;
  return hook.args === undefined ? hookArguments(hook.command) : [hook.command, ...hook.args];
}
function owned(hook: Hook, runners: Set<string>): boolean {
  const args = argumentsOf(hook); if (!args) return false;
  for (let index = 0; index <= 1; index++) {
    if (index === 1 && !/^(?:python(?:\d+(?:\.\d+)*)?|node)(?:\.exe)?$/i.test(path.basename(args[0] || ''))) continue;
    if (!args[index] || !runners.has(args[index]!)) continue;
    if (args[index + 1] === 'hook') return true;
    if (path.basename(args[index]!) === 'PipHelper' && args[index + 1] === 'bridge' && args[index + 2] === 'hook') return true;
  }
  return false;
}
/** Match exact registered entrypoints, not a shell fragment mentioning Pip. */
export function merge(existing: unknown, addition: unknown, oldRunner: string | readonly string[], runner: string): { document: Config; removed: number; added: number } {
  const document = validated(clone(existing)), incoming = validated(addition).hooks || {};
  const runners = new Set([...(typeof oldRunner === 'string' ? [oldRunner] : oldRunner), runner]);
  let removed = 0, added = 0; document.hooks ||= {};
  for (const event of new Set([...Object.keys(document.hooks), ...Object.keys(incoming)])) {
    const groups = (document.hooks[event] || []).map(group => ({ ...group, hooks: group.hooks.filter(hook => { if (!owned(hook, runners)) return true; removed++; return false; }) })).filter(group => group.hooks.length);
    for (const group of incoming[event] || []) { groups.push(clone(group)); added += group.hooks.length; }
    if (groups.length) document.hooks[event] = groups; else delete document.hooks[event];
  }
  return { document, removed, added };
}
function telemetryName(name: string): boolean {
  return name.startsWith('OTEL_') || name.startsWith('CLAUDE_CODE_ENABLE_TELEMETRY') ||
    ['BETA_TRACING_ENDPOINT', 'CLAUDE_CODE_ENHANCED_TELEMETRY_BETA', 'ENABLE_ENHANCED_TELEMETRY_BETA', 'ENABLE_BETA_TRACING_DETAILED'].includes(name);
}
export function mergeTelemetry(document: Config, environment: Record<string, string>, prior?: Record<string, string>): Config {
  if (document.env !== undefined && !object(document.env)) throw new Error('Claude environment settings must be an object.');
  if (document.otelHeadersHelper) throw new Error('Existing Claude telemetry headers are preserved; a separate collector setup is required.');
  const current = document.env || {};
  for (const [name, value] of Object.entries(current)) if (telemetryName(name) && environment[name] !== value && prior?.[name] !== value) throw new Error('Existing Claude telemetry settings are preserved; a separate collector setup is required.');
  return { ...document, env: { ...current, ...environment } };
}
async function bytes(file: string, limit = 8 * 1024 * 1024, privateOnly = false): Promise<Buffer | undefined> {
  let before;
  try { before = await fs.lstat(file); } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined; throw error; }
  if (!before.isFile() || before.isSymbolicLink()) throw new Error('Configuration and runner files must be regular files, not links.');
  const handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0));
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > limit || stat.ino !== before.ino || stat.dev !== before.dev ||
        (process.platform !== 'win32' && (stat.uid !== process.getuid!() || privateOnly && (stat.mode & 0o077) !== 0))) throw new Error('Unsafe configuration or runner file.');
    const content = Buffer.alloc(limit + 1); let offset = 0;
    while (offset < content.length) { const result = await handle.read(content, offset, content.length - offset, offset); if (result.bytesRead === 0) break; offset += result.bytesRead; }
    if (offset > limit) throw new Error('Configuration file too large.'); return content.subarray(0, offset);
  } finally { await handle.close(); }
}
async function publish(file: string, data: Buffer | string): Promise<void> {
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const parent = await fs.lstat(path.dirname(file));
  if (!parent.isDirectory() || parent.isSymbolicLink() || (process.platform !== 'win32' && parent.uid !== process.getuid!())) throw new Error('Unsafe settings directory.');
  const temp = path.join(path.dirname(file), `.pip-preview-${randomUUID()}`);
  try {
    await fs.writeFile(temp, data, { flag: 'wx', mode: 0o600 });
    const current = await fs.lstat(path.dirname(file));
    if (current.isSymbolicLink() || current.ino !== parent.ino || current.dev !== parent.dev) throw new Error('Settings directory changed during connection.');
    await fs.rename(temp, file);
  } finally { await fs.unlink(temp).catch(() => undefined); }
}
export function connectionLocations(home: string, environment: NodeJS.ProcessEnv = process.env): Record<Source, string> {
  if (!path.isAbsolute(home) || /[\0\r\n]/.test(home)) throw new Error('Use an absolute local home directory.');
  const folder = (name: string, fallback: string) => {
    const value = environment[name] || fallback;
    if (!path.isAbsolute(value) || /[\0\r\n]/.test(value) || (process.platform === 'win32' && /^(?:\\\\|\/\/)/.test(value))) throw new Error('Agent configuration overrides must be absolute local paths. WSL and network homes are unsupported.');
    return path.resolve(value);
  };
  return { claude: path.join(folder('CLAUDE_CONFIG_DIR', path.join(home, '.claude')), 'settings.json'), codex: path.join(folder('CODEX_HOME', path.join(home, '.codex')), 'hooks.json') };
}
async function runnerState(nodePath: string): Promise<Record<string, string>> {
  if (!path.isAbsolute(nodePath) || /[\0\r\n]/.test(nodePath) || !/^node(?:\.exe)?$/i.test(path.basename(nodePath))) throw new Error('Hook connections require the absolute Node.js executable used to launch Pip.');
  const node = await fs.stat(nodePath); if (!node.isFile()) throw new Error('Node.js executable is unavailable.');
  if (process.platform !== 'win32') await fs.access(nodePath, constants.X_OK);
  const files: Record<string, string> = {};
  for (const name of (await fs.readdir(__dirname)).filter(name => name.endsWith('.js')).sort()) {
    const file = path.join(__dirname, name), data = await bytes(file); if (!data) throw new Error('Build Pip before connecting hooks.'); files[file] = hash(data);
  }
  for (const name of ['package.json', 'yarn.lock']) {
    const file = path.resolve(__dirname, '../..', name), data = await bytes(file); if (!data) throw new Error('Source dependencies or lockfile are unavailable.'); files[file] = hash(data);
  }
  files[nodePath] = hash(JSON.stringify([node.dev, node.ino, node.size, node.mtimeMs]));
  if (!files[path.join(__dirname, 'hook.js')]) throw new Error('Build Pip before connecting hooks.'); return files;
}
async function previousEnvironment(home: string): Promise<Record<string, string> | undefined> {
  if (process.platform !== 'darwin') return;
  const old = await bytes(path.join(home, 'Library', 'Application Support', 'AgentCompanion', '.telemetry.json'), 4096, true);
  if (!old) return;
  const value = parse(old); if (!validTelemetryConfig(value)) throw new Error('Existing Pip telemetry configuration cannot be verified.'); return telemetryEnvironment(value);
}
async function priorRunners(home: string, root: string, current: Config): Promise<string[]> {
  const runners = [path.join(home, 'Library', 'Application Support', 'AgentCompanion', 'bridge.py'),
    path.join(home, 'Applications', 'Pip.app', 'Contents', 'Resources', 'PipHelper'), '/Applications/Pip.app/Contents/Resources/PipHelper',
    path.join(home, 'Applications', 'Pip.app', 'Contents', 'Helpers', 'PipRuntime.app', 'Contents', 'MacOS', 'PipHelper'),
    '/Applications/Pip.app/Contents/Helpers/PipRuntime.app/Contents/MacOS/PipHelper'];
  for (const groups of Object.values(current.hooks || {})) for (const group of groups) for (const hook of group.hooks) {
    const args = argumentsOf(hook); if (!args || !/^node(?:\.exe)?$/i.test(path.basename(args[0] || '')) || args[2] !== 'hook' || args[args.indexOf('--runtime') + 1] !== root || !args[1] || path.basename(args[1]) !== 'hook.js' || !path.isAbsolute(args[1])) continue;
    try {
      const data = await bytes(path.resolve(path.dirname(args[1]), '../..', 'package.json'), 32_000), metadata = data && JSON.parse(data.toString());
      if (metadata && ['pip-companion-preview', 'pip-companion-source'].includes(metadata.name)) runners.push(args[1]);
    } catch { /* Unverified source entrypoints stay untouched. */ }
  }
  return runners;
}
async function nextSettings(home: string, root: string, source: Source, current: unknown, nodePath: string): Promise<{ document: Config; removed: number; added: number }> {
  const document = validated(current), addition = config(source, root, { nodePath });
  const result = merge(document, addition, await priorRunners(home, root, document), path.join(__dirname, 'hook.js'));
  if (source === 'claude') result.document = mergeTelemetry(result.document, telemetryEnvironment(await ensureTelemetryConfig(root)), await previousEnvironment(home)); return result;
}
export async function prepareConnection(home = os.homedir(), root = defaultRuntime(), options: ConnectionOptions = {}): Promise<Plan> {
  await prepare(root);
  const nodePath = options.nodePath || (process.versions.electron ? '' : process.execPath), files = await runnerState(nodePath), locations = connectionLocations(home, options.environment);
  const telemetry = await ensureTelemetryConfig(root), targets: Target[] = [];
  for (const source of ['claude', 'codex'] as const) {
    const file = locations[source], original = await bytes(file), result = await nextSettings(home, root, source, original ? parse(original) : {}, nodePath);
    targets.push({ source, file, before: original ? hash(original) : null, next: hash(JSON.stringify(result.document, null, 2) + '\n'), removed: result.removed, added: result.added });
  }
  const plan: Plan = { version: 2, home, runtime: root, nodePath, files, telemetryHash: hash(JSON.stringify(telemetry)), targets };
  await write(root, 'connection-plan.json', plan); return plan;
}
export async function applyConnection(home = os.homedir(), root = defaultRuntime(), options: ConnectionOptions = {}): Promise<void> {
  const plan = await read(root, 'connection-plan.json', 128_000) as Plan;
  const nodePath = options.nodePath || (process.versions.electron ? '' : process.execPath), locations = connectionLocations(home, options.environment);
  if (plan.version !== 2 || plan.home !== home || plan.runtime !== root || plan.nodePath !== nodePath || !object(plan.files) ||
      JSON.stringify(await runnerState(nodePath)) !== JSON.stringify(plan.files) || hash(JSON.stringify(await ensureTelemetryConfig(root))) !== plan.telemetryHash ||
      !Array.isArray(plan.targets) || plan.targets.length !== 2 || new Set(plan.targets.map(t => t.source)).size !== 2) throw new Error('Runner, configuration or plan changed; prepare again.');
  const originals = new Map<string, Buffer | undefined>(), next = new Map<string, string>();
  for (const target of plan.targets) {
    if (!['claude', 'codex'].includes(target.source) || target.file !== locations[target.source]) throw new Error('Agent configuration override changed; prepare again.');
    const original = await bytes(target.file); if ((original ? hash(original) : null) !== target.before) throw new Error('Assistant settings changed; prepare again.');
    const result = await nextSettings(home, root, target.source, original ? parse(original) : {}, nodePath), data = JSON.stringify(result.document, null, 2) + '\n';
    if (hash(data) !== target.next) throw new Error('Connection plan changed; prepare again.'); originals.set(target.file, original); next.set(target.file, data);
  }
  let previous: Receipt | undefined;
  try {
    const value = await read(root, 'connection-receipt.json', 32_000) as Receipt;
    if (!value || value.version !== 2 || !Array.isArray(value.targets) || value.targets.length !== 2 || new Set(value.targets.map(t => t.file)).size !== 2) throw new Error('Invalid existing connection receipt; review the saved connection state.');
    const allowed = new Set(Object.values(locations));
    for (const target of value.targets) {
      if (!allowed.has(target.file) || !/^[a-f0-9]{64}$/.test(target.after) || (target.backup &&
          (!target.backup.startsWith(target.file + '.pip-preview-') || !/\.pip-preview-[a-f0-9-]{36}\.backup$/.test(target.backup) || !target.backupHash || !/^[a-f0-9]{64}$/.test(target.backupHash)))) throw new Error('Invalid existing connection receipt; review the saved connection state.');
      if (target.backup) {
        const backup = await bytes(target.backup, 8 * 1024 * 1024, true);
        if (!backup || hash(backup) !== target.backupHash) throw new Error('Existing connection backup is unavailable or changed; nothing was replaced.');
      }
    }
    previous = value;
  } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
  const receipt: Receipt = { version: 2, targets: [] }, stamp = randomUUID();
  for (const target of plan.targets) {
    const original = originals.get(target.file), old = previous?.targets.find(t => t.file === target.file && t.after === target.before);
    if (old) { receipt.targets.push({ ...old, after: target.next }); continue; }
    const backup = original ? `${target.file}.pip-preview-${stamp}.backup` : undefined;
    if (backup) await fs.writeFile(backup, original!, { flag: 'wx', mode: 0o600 });
    receipt.targets.push({ file: target.file, backup, after: target.next, ...(original ? { backupHash: hash(original) } : {}) });
  }
  const written: string[] = [];
  try {
    for (const target of plan.targets) {
      const current = await bytes(target.file); if ((current ? hash(current) : null) !== target.before) throw new Error('Settings changed during apply.');
      if (target.before !== target.next) { await publish(target.file, next.get(target.file)!); written.push(target.file); }
    }
    await write(root, 'connection-receipt.json', receipt);
  } catch (error) {
    for (const file of written) { const current = await bytes(file); if (current && hash(current) === hash(next.get(file)!)) { const original = originals.get(file); if (original) await publish(file, original); else await fs.unlink(file); } } throw error;
  }
}
export async function restoreConnection(home = os.homedir(), root = defaultRuntime(), options: ConnectionOptions = {}): Promise<void> {
  const receipt = await read(root, 'connection-receipt.json', 32_000) as Receipt;
  if (receipt.version !== 2 || !Array.isArray(receipt.targets) || receipt.targets.length !== 2 || new Set(receipt.targets.map(t => t.file)).size !== 2) throw new Error('Invalid restore receipt.');
  const allowed = new Set(Object.values(connectionLocations(home, options.environment))), originals = new Map<string, Buffer | undefined>();
  const matchesOriginal = (current: Buffer | undefined, original: Buffer | undefined) => original === undefined ? current === undefined : current !== undefined && hash(current) === hash(original);
  for (const target of receipt.targets) {
    if (!allowed.has(target.file) || (target.backup && (!target.backup.startsWith(target.file + '.pip-preview-') || !/\.pip-preview-[a-f0-9-]{36}\.backup$/.test(target.backup)))) throw new Error('Invalid restore target.');
    const original = target.backup ? await bytes(target.backup, 8 * 1024 * 1024, true) : undefined;
    if (target.backup && (!original || !target.backupHash || hash(original) !== target.backupHash)) throw new Error('Restore backup unavailable or changed.'); originals.set(target.file, original);
    const current = await bytes(target.file);
    if ((!current || hash(current) !== target.after) && !matchesOriginal(current, original)) throw new Error('Settings changed since connecting; restore requires review.');
  }
  // A process can stop after restoring the first settings file. Keep the receipt
  // until all targets finish, and recognize only byte-identical verified originals
  // on retry. Transient Windows file locks cannot strand an unusable receipt.
  for (const target of receipt.targets) {
    const current = await bytes(target.file), original = originals.get(target.file);
    if (matchesOriginal(current, original)) continue;
    if (!current || hash(current) !== target.after) throw new Error('Settings changed during restore.');
    if (original) await publish(target.file, original); else await fs.unlink(target.file);
  }
  await fs.unlink(path.join(root, 'connection-receipt.json'));
}
if (require.main === module) (async () => {
  const action = process.argv[2];
  if (action === 'prepare') {
    const plan = await prepareConnection(); console.log(JSON.stringify({ action, targets: plan.targets.map(t => ({ source: t.source, removed: t.removed, added: t.added })),
      note: 'Review these changes before apply. Only confirmed Pip hooks are replaced. Claude decision metadata goes to an authenticated local receiver. Review Codex /hooks after applying.' }, null, 2));
  } else if (action === 'apply') { await applyConnection(); console.log('Connected local hooks to Pip TypeScript. Review/trust Codex hooks and reload Claude after active work finishes.'); }
  else if (action === 'restore') { await restoreConnection(); console.log('Restored the previous hook settings.'); }
  else throw new Error('Use prepare, apply or restore.');
})().catch(error => { console.error((error as Error).message); process.exitCode = 1; });
