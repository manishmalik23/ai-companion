import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { isProcessId, isWindowKey, MAX_LEASE_BYTES, normalizeLocalWorkspace, SessionLinkLease, validateResolvedRoutes } from './protocol';
import { validateCodexLease } from './codex';
import { ensureWindowsDirectoryAsync, inspectWindowsPaths, inspectWindowsPathsAsync } from './windows-security';

export class RegistryError extends Error {
  constructor(readonly code: 'unsafe_directory' | 'unsafe_file' | 'invalid_lease' | 'write_failed') { super(code); }
}

export function registryDirectory(platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env,
                                  home: string = os.homedir()): string | undefined {
  if (platform === 'darwin') return path.posix.join(home, 'Library', 'Application Support', 'AgentCompanion', '.runtime', 'session-links');
  if (platform !== 'win32') return;
  const base = normalizeLocalWorkspace(env.LOCALAPPDATA, 'win32');
  return base === undefined ? undefined : path.win32.join(base, 'Pip', 'SessionLinks');
}

function currentUserId(): number {
  if (typeof process.getuid !== 'function') throw new RegistryError('unsafe_directory');
  return process.getuid();
}

export function assertPrivateStat(stat: fs.Stats, kind: 'directory' | 'file', uid: number): void {
  const mode = kind === 'directory' ? 0o700 : 0o600;
  if (stat.isSymbolicLink() || stat.uid !== uid || (stat.mode & 0o777) !== mode ||
      (kind === 'directory' ? !stat.isDirectory() : !stat.isFile())) {
    throw new RegistryError(kind === 'directory' ? 'unsafe_directory' : 'unsafe_file');
  }
}

async function existsStat(value: string): Promise<fs.Stats | undefined> {
  try { return await fsp.lstat(value); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined; throw error; }
}

/** Reject symlink traversal. Existing ancestor permissions are not changed. */
export async function ensurePrivateDirectory(directory: string): Promise<fs.Stats> {
  if (process.platform === 'win32') {
    await ensureWindowsDirectoryAsync(directory);
    return fsp.lstat(directory);
  }
  if (!path.isAbsolute(directory) || typeof process.getuid !== 'function') throw new RegistryError('unsafe_directory');
  const normalized = path.normalize(directory);
  const root = path.parse(normalized).root;
  let current = root;
  for (const piece of normalized.slice(root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, piece);
    let stat = await existsStat(current);
    if (!stat) {
      try { await fsp.mkdir(current, { mode: 0o700 }); }
      catch (error) { if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error; }
      stat = await fsp.lstat(current);
    }
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new RegistryError('unsafe_directory');
  }
  const stat = await fsp.lstat(normalized);
  assertPrivateStat(stat, 'directory', currentUserId());
  return stat;
}

function inspectPrivateDirectory(directory: string): fs.Stats {
  if (!path.isAbsolute(directory)) throw new RegistryError('unsafe_directory');
  const root = path.parse(directory).root;
  let current = root;
  for (const piece of directory.slice(root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, piece);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink() || !stat.isDirectory()) throw new RegistryError('unsafe_directory');
  }
  const stat = fs.lstatSync(directory);
  assertPrivateStat(stat, 'directory', currentUserId());
  return stat;
}

export class PrivateLeaseWriter {
  readonly file: string;
  constructor(readonly directory: string, readonly windowKey: string, readonly processId: number,
              private readonly platform: NodeJS.Platform = process.platform) {
    if (!isWindowKey(windowKey) || !isProcessId(processId)) throw new RegistryError('invalid_lease');
    this.file = (platform === 'win32' ? path.win32 : path).join(directory, `${windowKey}.json`);
  }

  async write(lease: SessionLinkLease): Promise<void> {
    if (lease.schemaVersion !== 1 || lease.windowKey !== this.windowKey || lease.processId !== this.processId ||
        !Number.isFinite(lease.updatedAt) || !Array.isArray(lease.workspaces) || lease.workspaces.length > 32 ||
        lease.workspaces.some(folder => normalizeLocalWorkspace(folder, this.platform) === undefined) ||
        !Array.isArray(lease.terminals) || lease.terminals.length > 64 || lease.terminals.some(terminal =>
          !isProcessId(terminal.processId) || typeof terminal.name !== 'string' || terminal.name.length > 160)) throw new RegistryError('invalid_lease');
    const routes = validateResolvedRoutes(lease.claudeSessionURL, lease.terminalURL);
    validateCodexLease(lease, routes);
    const content = Buffer.from(`${JSON.stringify(lease)}\n`);
    if (content.length > MAX_LEASE_BYTES) throw new RegistryError('invalid_lease');
    if (this.platform === 'win32') {
      await this.writeWindows(content);
      return;
    }
    const directoryStat = await ensurePrivateDirectory(this.directory);
    const previous = await existsStat(this.file);
    if (previous) assertPrivateStat(previous, 'file', currentUserId());
    const temporary = path.join(this.directory, `.${this.windowKey}.${randomUUID()}.tmp`);
    let handle: fsp.FileHandle | undefined;
    try {
      handle = await fsp.open(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL |
        (fs.constants.O_NOFOLLOW ?? 0), 0o600);
      await handle.writeFile(content);
      await handle.sync();
      await handle.close(); handle = undefined;
      const currentDirectory = await ensurePrivateDirectory(this.directory);
      if (currentDirectory.dev !== directoryStat.dev || currentDirectory.ino !== directoryStat.ino) {
        throw new RegistryError('unsafe_directory');
      }
      const target = await existsStat(this.file);
      if (target) assertPrivateStat(target, 'file', currentUserId());
      await fsp.rename(temporary, this.file);
    } finally {
      await handle?.close().catch(() => undefined);
      try {
        const currentDirectory = inspectPrivateDirectory(this.directory);
        if (currentDirectory.dev === directoryStat.dev && currentDirectory.ino === directoryStat.ino) {
          const stat = await existsStat(temporary);
          if (stat) { assertPrivateStat(stat, 'file', currentUserId()); await fsp.unlink(temporary); }
        }
      } catch { /* Never clean up through a replaced/unsafe directory or target. */ }
    }
  }

  private async writeWindows(content: Buffer): Promise<void> {
    await ensureWindowsDirectoryAsync(this.directory);
    const directoryStat = await fsp.lstat(this.directory);
    const temporary = path.win32.join(this.directory, `.${this.windowKey}.${randomUUID()}.tmp`);
    let handle: fsp.FileHandle | undefined;
    try {
      const previous = await existsStat(this.file);
      handle = await fsp.open(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL, 0o600);
      // New files inherit the protected registry ACL. Check that inheritance
      // and any previous target before writing any session metadata.
      await inspectWindowsPathsAsync([{ path: temporary, kind: 'file' },
        ...(previous ? [{ path: this.file, kind: 'file' as const }] : [])]);
      const opened = await handle.stat(), named = await fsp.lstat(temporary);
      if (!opened.isFile() || named.isSymbolicLink() || opened.dev !== named.dev || opened.ino !== named.ino) {
        throw new RegistryError('unsafe_file');
      }
      await handle.writeFile(content); await handle.sync();
      await handle.close(); handle = undefined;
      const target = await existsStat(this.file);
      await inspectWindowsPathsAsync([{ path: this.directory, kind: 'directory' },
        ...(target ? [{ path: this.file, kind: 'file' as const }] : []), { path: temporary, kind: 'file' }]);
      const currentDirectory = await fsp.lstat(this.directory), currentTemporary = await fsp.lstat(temporary);
      if (currentDirectory.dev !== directoryStat.dev || currentDirectory.ino !== directoryStat.ino ||
          currentTemporary.dev !== opened.dev || currentTemporary.ino !== opened.ino) throw new RegistryError('unsafe_directory');
      await fsp.rename(temporary, this.file);
    } finally {
      await handle?.close().catch(() => undefined);
      const remaining = await existsStat(temporary);
      if (remaining) {
        try {
          await inspectWindowsPathsAsync([{ path: this.directory, kind: 'directory' }, { path: temporary, kind: 'file' }]);
          const directory = await fsp.lstat(this.directory);
          if (directory.dev === directoryStat.dev && directory.ino === directoryStat.ino) await fsp.unlink(temporary);
        } catch { /* Do not clean up through a substituted path or unsafe ACL. */ }
      }
    }
  }

  /** Refresh/error paths must not block VS Code while Windows inspects ACLs. */
  async removeAsync(): Promise<void> {
    if (this.platform !== 'win32') { this.remove(); return; }
    let handle: fsp.FileHandle | undefined;
    try {
      if (!await existsStat(this.file)) return;
      await inspectWindowsPathsAsync([{ path: this.directory, kind: 'directory' }, { path: this.file, kind: 'file' }]);
      const named = await fsp.lstat(this.file);
      if (!named.isFile() || named.isSymbolicLink() || named.size > MAX_LEASE_BYTES) return;
      handle = await fsp.open(this.file, fs.constants.O_RDONLY);
      const opened = await handle.stat();
      if (!opened.isFile() || opened.dev !== named.dev || opened.ino !== named.ino || opened.size > MAX_LEASE_BYTES) return;
      const content = Buffer.alloc(MAX_LEASE_BYTES + 1);
      const { bytesRead } = await handle.read(content, 0, content.length, 0);
      if (bytesRead > MAX_LEASE_BYTES) return;
      const lease = JSON.parse(content.subarray(0, bytesRead).toString('utf8')) as Partial<SessionLinkLease>;
      await handle.close(); handle = undefined;
      const current = await fsp.lstat(this.file);
      if (current.isFile() && !current.isSymbolicLink() && current.dev === named.dev && current.ino === named.ino &&
          lease.windowKey === this.windowKey && lease.processId === this.processId) await fsp.unlink(this.file);
    } catch { /* An unavailable/unsafe record never causes broad cleanup. */ }
    finally { await handle?.close().catch(() => undefined); }
  }

  /** Synchronous disposal is used because VS Code does not await Disposable.dispose(). */
  remove(): void {
    try {
      if (this.platform === 'win32') inspectWindowsPaths([{ path: this.directory, kind: 'directory' }, { path: this.file, kind: 'file' }]);
      else inspectPrivateDirectory(this.directory);
      const file = fs.lstatSync(this.file);
      if (this.platform !== 'win32') assertPrivateStat(file, 'file', currentUserId());
      else if (!file.isFile() || file.isSymbolicLink()) return;
      if (file.size > MAX_LEASE_BYTES) return;
      const lease = JSON.parse(fs.readFileSync(this.file, 'utf8')) as Partial<SessionLinkLease>;
      if (lease.windowKey === this.windowKey && lease.processId === this.processId) fs.unlinkSync(this.file);
    } catch { /* No cleanup through unsafe, replaced, or already removed paths. */ }
  }
}
