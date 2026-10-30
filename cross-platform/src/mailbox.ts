import { constants, type BigIntStats } from 'node:fs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import lockfile from 'proper-lockfile';
import { performance } from 'node:perf_hooks';
import { setTimeout as delay } from 'node:timers/promises';
import { Request, Decision, State, Session, Response, validId, validRequest, validResponse, validSource, identifier, seconds } from './protocol';

export function defaultRuntime(): string {
  const base = process.platform === 'darwin' ? path.join(os.homedir(), 'Library', 'Application Support') :
    process.platform === 'win32' ? process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming') :
      process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
  return path.join(base, 'PipSource', 'runtime');
}
export async function directory(folder: string): Promise<void> {
  await fs.mkdir(folder, { recursive: true, mode: 0o700 });
  const stat = await fs.lstat(folder);
  if (!stat.isDirectory() || stat.isSymbolicLink() ||
      (process.platform !== 'win32' && (stat.uid !== process.getuid!() || (stat.mode & 0o077) !== 0))) {
    throw new Error('Pip Source runtime must be a private directory owned by you.');
  }
}
export async function prepare(root: string): Promise<void> {
  // Never share locks or heartbeat ownership with the installed Swift app.
  if (path.resolve(root).split(path.sep).some(part => part.toLowerCase() === 'agentcompanion')) throw new Error('Use a separate Pip Source runtime.');
  await directory(root);
  for (const name of ['requests', 'decisions', 'sessions']) await directory(path.join(root, name));
}
function localPath(root: string, relative: string): string {
  if (!relative || path.isAbsolute(relative) || relative.split(/[\\/]/).some(part => !part || part === '.' || part === '..') || /[\x00-\x1f]/.test(relative)) throw new Error('Invalid mailbox path.');
  const target = path.resolve(root, relative);
  if (!target.startsWith(path.resolve(root) + path.sep)) throw new Error('Invalid mailbox path.');
  return target;
}
export async function read(root: string, relative: string, limit = 1_000_000): Promise<unknown> {
  const file = localPath(root, relative);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1_000_000) throw new Error('Invalid mailbox limit.');
  await directory(root);
  const folder = path.dirname(relative);
  if (folder !== '.') await directory(path.join(root, folder));
  const before = await fs.lstat(file);
  if (before.isSymbolicLink() || !before.isFile()) throw new Error('Invalid mailbox file.');
  const handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0));
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size > limit || stat.ino !== before.ino || stat.dev !== before.dev ||
        (process.platform !== 'win32' && (stat.uid !== process.getuid!() || (stat.mode & 0o077) !== 0))) throw new Error('Invalid mailbox file.');
    const bytes = Buffer.alloc(limit + 1);
    const result = await handle.read(bytes, 0, bytes.length, 0);
    if (result.bytesRead > limit) throw new Error('Mailbox file too large.');
    return JSON.parse(bytes.subarray(0, result.bytesRead).toString());
  } finally { await handle.close(); }
}
interface WriteSnapshot { directories: [string, BigIntStats][]; temporary: BigIntStats; target?: BigIntStats }
async function writeStat(file: string): Promise<BigIntStats | undefined> {
  try { return await fs.lstat(file, { bigint: true }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined; throw error; }
}
const sameIdentity = (a: BigIntStats, b: BigIntStats) => a.dev === b.dev && a.ino === b.ino;
const sameFile = (a: BigIntStats, b: BigIntStats) => a.isFile() && !a.isSymbolicLink() && b.isFile() && !b.isSymbolicLink() &&
  sameIdentity(a,b) && a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs && a.mode === b.mode;
async function snapshotWrite(root: string, temporary: string, target: string): Promise<WriteSnapshot> {
  const names = [...new Set([path.resolve(root), path.dirname(target)])];
  const [directories, source, destination] = await Promise.all([
    Promise.all(names.map(async name => [name, await fs.lstat(name, { bigint: true })] as [string, BigIntStats])),
    fs.lstat(temporary, { bigint: true }), writeStat(target)
  ]);
  return { directories, temporary: source, target: destination };
}
async function unchangedWrite(snapshot: WriteSnapshot, temporary: string): Promise<void> {
  for (const [name, before] of snapshot.directories) {
    const after = await fs.lstat(name, { bigint: true });
    if (!before.isDirectory() || before.isSymbolicLink() || !after.isDirectory() || after.isSymbolicLink() || !sameIdentity(before,after)) throw new Error('Mailbox directory changed during atomic write.');
  }
  if (!sameFile(snapshot.temporary, await fs.lstat(temporary, { bigint: true }))) throw new Error('Mailbox temporary file changed during atomic write.');
}
const transientRename = (error: unknown) => ['EPERM','EACCES','EBUSY'].includes((error as NodeJS.ErrnoException).code || '');
export async function write(root: string, relative: string, value: unknown): Promise<void> {
  const target = localPath(root, relative);
  const serialized = JSON.stringify(value);
  if (!serialized || Buffer.byteLength(serialized) > 1_000_000) throw new Error('Mailbox value is too large.');
  await directory(root);
  const folder = path.dirname(relative);
  if (folder !== '.') await directory(path.join(root, folder));
  const temporary = path.join(path.dirname(target), `.write-${randomUUID()}`);
  let snapshot: WriteSnapshot | undefined, retrying = false;
  try {
    await fs.writeFile(temporary, serialized, { flag: 'wx', mode: 0o600 });
    // Snapshot only for Windows recovery; the first atomic rename keeps its existing behavior.
    if (process.platform === 'win32') snapshot = await snapshotWrite(root,temporary,target).catch(() => undefined);
    try { await fs.rename(temporary, target); return; }
    catch (error) {
      if (process.platform !== 'win32' || !snapshot || !transientRename(error)) throw error;
      retrying = true;
      const deadline = performance.now() + 300;
      let last = error;
      // Windows readers/scanners may briefly deny replacement. Keep the same staged bytes;
      // never remove the destination or relax permissions to make replacement succeed.
      for (const milliseconds of [10,20,40,80,100]) {
        if (performance.now() + milliseconds >= deadline) throw last;
        await delay(milliseconds);
        if (performance.now() >= deadline) throw last;
        await unchangedWrite(snapshot,temporary);
        const destination = await writeStat(target);
        if (snapshot.target ? !destination || !sameFile(snapshot.target,destination) : destination !== undefined) throw new Error('Mailbox target changed during atomic write.');
        if (performance.now() >= deadline) throw last;
        try { await fs.rename(temporary,target); return; }
        catch (next) { if (!transientRename(next)) throw next; last = next; }
      }
      throw last;
    }
  } finally {
    if (retrying) {
      // A substituted parent or source belongs to somebody else; do not unlink through it.
      try { await unchangedWrite(snapshot!,temporary); await fs.unlink(temporary); } catch { /* Unknown paths are left alone. */ }
    } else await fs.unlink(temporary).catch(() => undefined);
  }
}
async function lockTarget(root: string, name: 'mailbox' | 'desktop'): Promise<string> {
  await directory(root);
  const target = path.join(root, `${name}-ts-target`);
  try { await fs.writeFile(target, '', { flag: 'wx', mode: 0o600 }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; }
  const stat = await fs.lstat(target);
  if (!stat.isFile() || stat.isSymbolicLink() ||
      (process.platform !== 'win32' && (stat.uid !== process.getuid!() || (stat.mode & 0o077) !== 0))) throw new Error('Unsafe lock target.');
  return target;
}
export async function locked<T>(root: string, operation: () => Promise<T>): Promise<T> {
  const target = await lockTarget(root, 'mailbox');
  const release = await lockfile.lock(target, {
    retries: { retries: 30, minTimeout: 20, maxTimeout: 80 }, stale: 10_000, update: 2000 });
  try { return await operation(); } finally { await release(); }
}
export async function alive(root: string): Promise<boolean> {
  try { const h = await read(root, 'heartbeat.json', 1024) as { updatedAt: number };
    return Number.isFinite(h.updatedAt) && h.updatedAt > seconds() - 5 && h.updatedAt <= seconds() + 1;
  } catch { return false; }
}
export class Mailbox {
  private snapshots = new Map<string, string>();
  private release?: () => Promise<void>;
  private readonly owner = randomUUID().replaceAll('-', '');
  constructor(readonly root: string) {}
  async start(): Promise<void> {
    if (this.release) throw new Error('The companion is already running.');
    await prepare(this.root);
    this.release = await lockfile.lock(await lockTarget(this.root, 'desktop'), { stale: 10_000, update: 2000 });
  }
  async poll(): Promise<State> {
    return locked(this.root, async () => {
      const now = seconds(), requests: Request[] = [];
      this.snapshots.clear();
      for (const file of (await fs.readdir(path.join(this.root, 'requests'))).filter(name => /^[a-f0-9]{32}\.json$/.test(name)).slice(0, 256)) {
        const id = file.replace(/\.json$/, '');
        if (!file.endsWith('.json') || !validId(id)) continue;
        try {
          const request = await read(this.root, `requests/${file}`);
          if (!validRequest(request, now) || request.id !== id) continue;
          let decided = false;
          try { const d = await read(this.root, `decisions/${id}.json`, 4096);
            decided = validResponse(request, d, now);
          } catch { /* No decision yet. */ }
          if (!decided) { requests.push(request); this.snapshots.set(id, JSON.stringify(request)); }
        } catch { /* Invalid files never become approval cards. */ }
      }
      let working = requests.length > 0;
      for (const file of (await fs.readdir(path.join(this.root, 'sessions'))).filter(name => /^[a-f0-9]{64}\.json$/.test(name)).slice(0, 256)) {
        if (!/^[a-f0-9]{64}\.json$/.test(file)) continue;
        try { const s = await read(this.root, `sessions/${file}`, 300_000) as Session;
          if (validSource(s.source) && identifier(s.sessionId) && `${createHash('sha256').update(`${s.source}:${s.sessionId}`).digest('hex')}.json` === file &&
            (s.status === 'working' || s.status === 'attention') && Number.isFinite(s.updatedAt) && s.updatedAt > now - 300 && s.updatedAt <= now + 60) working = true;
        } catch { /* Ignore incomplete sessions. */ }
      }
      await write(this.root, 'heartbeat.json', { updatedAt: now, owner: this.owner, codexActivity: false });
      requests.sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id));
      return { requests, working };
    });
  }
  async decide(id: string, decision: Decision): Promise<void> {
    if (!validId(id) || !['allow', 'deny'].includes(decision)) throw new Error('Invalid decision.');
    await this.respond(id, { id, decision, decidedAt: seconds() });
  }
  async answer(id: string, answers: Record<string, string>): Promise<void> {
    await this.respond(id, { id, decision: 'answer', answers, decidedAt: seconds() });
  }
  async defer(id: string, snapshot?: string): Promise<void> {
    await this.respond(id, { id, decision: 'defer', decidedAt: seconds() }, snapshot);
  }
  private async respond(id: string, response: Response, snapshot?: string): Promise<void> {
    if (!validId(id) || Buffer.byteLength(JSON.stringify(response)) > 4096) throw new Error('Invalid or oversized answer.');
    await locked(this.root, async () => {
      const current = await read(this.root, `requests/${id}.json`);
      if (!validRequest(current) || !current.canRespond || JSON.stringify(current) !== (snapshot ?? this.snapshots.get(id))) throw new Error('Request changed or expired; refresh before deciding.');
      if (!validResponse(current, response)) throw new Error('This response does not match the waiting request.');
      try { await fs.lstat(path.join(this.root, `decisions/${id}.json`)); throw new Error('Already decided.'); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
      await write(this.root, `decisions/${id}.json`, response);
    });
  }
  async dismiss(id: string, snapshot?: string): Promise<void> {
    if (!validId(id)) throw new Error('Invalid notice.');
    await locked(this.root, async () => {
      const current = await read(this.root, `requests/${id}.json`);
      if (!validRequest(current) || current.kind !== 'notice' || current.canRespond || JSON.stringify(current) !== (snapshot ?? this.snapshots.get(id))) throw new Error('Notice changed or expired; refresh first.');
      await fs.unlink(path.join(this.root, 'requests', `${id}.json`));
      this.snapshots.delete(id);
    });
  }
  async close(): Promise<void> {
    if (!this.release) return;
    await locked(this.root, async () => {
      try {
        const heartbeat = await read(this.root, 'heartbeat.json', 1024) as { owner?: string };
        if (heartbeat.owner === this.owner) await fs.unlink(path.join(this.root, 'heartbeat.json'));
      } catch { /* A newer desktop owns its own heartbeat. */ }
    });
    await this.release(); this.release = undefined;
  }
}
