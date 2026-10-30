import * as fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { inspectWindowsPathsAsync } from './windows-security';

const UUID = /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i;
const CODEX_VERSION = '26.1021.22027';
export interface NavigationRequest { source: string; sessionId: string; cwd: string; sessionHost?: string; sessionWindowKey?: string }
export interface SessionLease {
  schemaVersion: 1; windowKey: string; processId: number; updatedAt: number; workspaces: string[];
  claudeSessionURL: string; terminalURL: string; codexSessionURL?: string; codexExtensionVersion?: string;
}
/** Keep drive paths local and unambiguous; never guess around a different path spelling. */
export function normalizeLocalWorkspace(value: unknown, platform: NodeJS.Platform = process.platform): string | undefined {
  if (typeof value !== 'string' || !value || value.length > 4096 || /[\u0000-\u001f\u007f-\u009f]/.test(value)) return undefined;
  if (platform === 'win32') {
    if (!/^[a-z]:[\\/]/i.test(value) || value.slice(2).includes(':')) return undefined;
    const pieces = value.slice(3).split(/[\\/]/).filter(Boolean);
    if (!pieces.length || pieces.length > 64 || pieces.some(piece => piece.length > 255 || piece === '.' || piece === '..' || /[<>:"|?*]/.test(piece) || /[. ]$/.test(piece) ||
      /^(?:con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\.|$)/i.test(piece))) return undefined;
    const normalized = path.win32.normalize(value).replace(/[\\/]+$/, '');
    return normalized[0]!.toUpperCase() + normalized.slice(1);
  }
  if (platform !== 'darwin' || !path.posix.isAbsolute(value) || value === '/') return undefined;
  return path.posix.normalize(value).replace(/\/+$/, '') || undefined;
}

export function sessionLinksDirectory(platform: NodeJS.Platform = process.platform,
                                      env: NodeJS.ProcessEnv = process.env, home = os.homedir()): string | undefined {
  if (platform === 'darwin') return path.join(home, 'Library', 'Application Support', 'AgentCompanion', '.runtime', 'session-links');
  const local = platform === 'win32' ? normalizeLocalWorkspace(env.LOCALAPPDATA, platform) : undefined;
  return local ? path.win32.join(local, 'Pip', 'SessionLinks') : undefined;
}
function route(value: unknown, authority: string, pathname: string): URL | undefined {
  if (typeof value !== 'string' || value.length > 2048) return undefined;
  try {
    const u = new URL(value), keys = [...u.searchParams.keys()], id = u.searchParams.get('windowId');
    if (!['vscode:', 'vscode-insiders:'].includes(u.protocol) || u.hostname !== authority || u.pathname !== pathname ||
        u.username || u.password || u.port || u.hash || keys.length !== 1 || keys[0] !== 'windowId' || !id ||
        !/^[1-9][0-9]{0,9}$/.test(id) || Number(id) > 2_147_483_647) return undefined;
    return u;
  } catch { return undefined; }
}
export function validLease(value: unknown, filename: string, now: number, alive: (pid: number) => boolean,
                           platform: NodeJS.Platform = process.platform): value is SessionLease {
  if (!value || typeof value !== 'object') return false;
  const l = value as SessionLease;
  if (l.schemaVersion !== 1 || typeof l.windowKey !== 'string' || !UUID.test(l.windowKey) ||
      filename !== l.windowKey.toLowerCase() + '.json' || !Number.isSafeInteger(l.processId) || l.processId < 2 || l.processId > 2_147_483_647 ||
      !Number.isFinite(l.updatedAt) || l.updatedAt < now - 35 || l.updatedAt > now + 5 || !alive(l.processId) ||
      !Array.isArray(l.workspaces) || l.workspaces.length > 32 || l.workspaces.some(w => !normalizeLocalWorkspace(w, platform))) return false;
  const c = route(l.claudeSessionURL, 'anthropic.claude-code', '/open'), t = route(l.terminalURL, 'pip-local.pip-session-links', '/terminal');
  if (!c || !t || c.protocol !== t.protocol || c.search !== t.search) return false;
  if (l.codexSessionURL !== undefined || l.codexExtensionVersion !== undefined) {
    const x = route(l.codexSessionURL, 'pip-local.pip-session-links', '/codex');
    if (l.codexExtensionVersion !== CODEX_VERSION || !x || x.protocol !== t.protocol || x.search !== t.search) return false;
  }
  return true;
}
export function destination(request: NavigationRequest, leases: readonly SessionLease[], platform = process.platform): string | undefined {
  if (!['darwin', 'win32'].includes(platform) || !UUID.test(request.sessionId)) return undefined;
  if (platform === 'darwin' && request.source === 'codex' && request.sessionHost === 'codex-desktop') return `codex://threads/${request.sessionId.toLowerCase()}`;
  if (!((request.source === 'claude' && request.sessionHost === 'claude-vscode') || (request.source === 'codex' && request.sessionHost === 'codex-vscode'))) return undefined;
  const cwd = normalizeLocalWorkspace(request.cwd, platform);
  if (!cwd) return undefined;
  const sameWorkspace = (folder: string, nested: boolean): boolean => {
    const normalized = normalizeLocalWorkspace(folder, platform);
    return !!normalized && (cwd === normalized || nested && cwd.startsWith(normalized + (platform === 'win32' ? '\\' : '/')));
  };
  let matches: readonly SessionLease[];
  if (request.sessionWindowKey !== undefined) {
    if (!UUID.test(request.sessionWindowKey)) return undefined;
    matches = leases.filter(l => l.windowKey.toLowerCase() === request.sessionWindowKey!.toLowerCase() &&
      l.workspaces.some(w => sameWorkspace(w, true)));
  } else matches = leases.filter(l => l.workspaces.some(w => sameWorkspace(w, false)));
  if (matches.length !== 1) return undefined;
  const lease = matches[0]!;
  if (request.source === 'claude') {
    const u = route(lease.claudeSessionURL, 'anthropic.claude-code', '/open');
    if (!u) return undefined;
    u.searchParams.append('session', request.sessionId); return u.toString();
  }
  const u = route(lease.codexSessionURL, 'pip-local.pip-session-links', '/codex');
  if (!u || lease.codexExtensionVersion !== CODEX_VERSION) return undefined;
  u.searchParams.append('windowKey', lease.windowKey); u.searchParams.append('sessionId', request.sessionId.toLowerCase());
  return u.toString();
}

interface LeaseReadOptions {
  platform: NodeJS.Platform;
  inspectWindows?: typeof inspectWindowsPathsAsync;
  now?: () => number;
  alive?: (pid: number) => boolean;
}

/** Read existing leases only. Injection supports fixtures; it never changes provider settings. */
export async function readSessionLeasesFrom(folder: string, options: LeaseReadOptions): Promise<SessionLease[]> {
  const platform = options.platform;
  if (!['darwin', 'win32'].includes(platform) || platform === 'darwin' && typeof process.getuid !== 'function') return [];
  try {
    let current = path.parse(folder).root;
    for (const part of folder.slice(current.length).split(path.sep).filter(Boolean)) {
      current = path.join(current, part);
      const stat = await fs.lstat(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) return [];
    }
    const directory = await fs.lstat(folder);
    if (platform === 'darwin' && (directory.uid !== process.getuid!() || (directory.mode & 0o077) !== 0)) return [];
    const files: { name: string; file: string; before: Awaited<ReturnType<typeof fs.lstat>> }[] = [];
    for (const name of (await fs.readdir(folder)).slice(0, 64)) {
      if (!UUID.test(name.replace(/\.json$/, '')) || !name.endsWith('.json')) continue;
      try {
        const file = path.join(folder, name), before = await fs.lstat(file);
        if (!before.isFile() || before.isSymbolicLink() || before.size > 65_536 ||
          platform === 'darwin' && (before.uid !== process.getuid!() || (before.mode & 0o077) !== 0)) continue;
        files.push({ name, file, before });
      } catch { /* A disappearing lease is unavailable. */ }
    }
    if (platform === 'win32') await (options.inspectWindows ?? inspectWindowsPathsAsync)([
      { path: folder, kind: 'directory' }, ...files.map(item => ({ path: item.file, kind: 'file' as const }))
    ]);
    const result: SessionLease[] = [];
    for (const { name, file, before } of files) {
      try {
        const handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0));
        try {
          const after = await handle.stat();
          if (!after.isFile() || after.ino !== before.ino || after.dev !== before.dev || after.size > 65_536) continue;
          const buffer = Buffer.alloc(65_537), { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
          const final = await handle.stat(), current = await fs.lstat(file);
          if (bytesRead > 65_536 || bytesRead !== before.size || final.size !== before.size ||
            final.mtimeMs !== before.mtimeMs || current.isSymbolicLink() || current.ino !== before.ino || current.dev !== before.dev) continue;
          const lease: unknown = JSON.parse(buffer.subarray(0, bytesRead).toString());
          const alive = options.alive ?? ((pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } });
          if (validLease(lease, name, (options.now ?? (() => Date.now() / 1000))(), alive, platform)) result.push(lease);
        } finally { await handle.close(); }
      } catch { /* Unavailable leases never become guessed destinations. */ }
    }
    const currentDirectory = await fs.lstat(folder);
    return !currentDirectory.isSymbolicLink() && currentDirectory.dev === directory.dev && currentDirectory.ino === directory.ino ? result : [];
  } catch { return []; }
}

/** ACL inspection must never hold up incoming approvals or completion notices. */
export class BackgroundLeaseCache {
  private leases: SessionLease[] = [];
  private expires = 0;
  private pending: Promise<void> | undefined;
  constructor(private readonly read: () => Promise<SessionLease[]>, private readonly now = Date.now) {}
  async get(fresh = false): Promise<SessionLease[]> {
    if (fresh) return this.read().catch(() => []);
    if (this.now() >= this.expires && !this.pending) {
      this.pending = this.read().catch(() => []).then(leases => {
        this.leases = leases; this.expires = this.now() + 5_000;
      }).finally(() => { this.pending = undefined; });
    }
    return this.leases;
  }
}
let windowsCache: { folder: string; cache: BackgroundLeaseCache } | undefined;
/** UI refreshes in the background; every click awaits a separate fresh inspection. */
export async function readSessionLeases(options: { fresh?: boolean } = {}): Promise<SessionLease[]> {
  const folder = sessionLinksDirectory(); if (!folder) return [];
  if (process.platform !== 'win32') return readSessionLeasesFrom(folder, { platform: process.platform });
  if (windowsCache?.folder !== folder) windowsCache = { folder,
    cache: new BackgroundLeaseCache(() => readSessionLeasesFrom(folder, { platform: 'win32' })) };
  return windowsCache.cache.get(options.fresh);
}
