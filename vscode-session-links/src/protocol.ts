import path from 'node:path';

export const EXTENSION_ID = 'pip-local.pip-session-links';
export const WINDOW_ENV = 'PIP_VSCODE_WINDOW_KEY';
export const MAX_LEASE_BYTES = 65_536;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const INTEGER = /^[1-9][0-9]{0,9}$/;
const SCHEMES = new Set(['vscode:', 'vscode-insiders:']);

export interface TerminalIdentity { processId: number; name: string }
export interface SessionLinkLease {
  schemaVersion: 1;
  windowKey: string;
  processId: number;
  updatedAt: number;
  workspaces: string[];
  claudeSessionURL: string;
  terminalURL: string;
  codexSessionURL?: string;
  codexExtensionVersion?: string;
  terminals: TerminalIdentity[];
}
export interface ResolvedRoutes {
  claudeSessionURL: string;
  terminalURL: string;
  windowId: string;
}
export interface SessionURILike {
  readonly scheme: string;
  readonly authority: string;
  readonly path: string;
  readonly query: string;
  readonly fragment: string;
  toString(skipEncoding?: boolean): string;
}

export function isWindowKey(value: string): boolean { return UUID.test(value); }
export function isProcessId(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0 && value <= 2_147_483_647;
}

export function parsedRoute(value: string, authority: string, pathname: string): URL {
  const url = new URL(value);
  if (!SCHEMES.has(url.protocol) || url.hostname !== authority || url.pathname !== pathname ||
      url.username || url.password || url.port || url.hash) throw new Error('unavailable_window_route');
  return url;
}

/** VS Code's default URI serializer encodes query '=' and '&'; preserve them explicitly. */
export function serializeSessionURI(uri: SessionURILike): string {
  const expectedPath = uri.authority === 'anthropic.claude-code' ? '/open' :
    uri.authority === EXTENSION_ID && ['/terminal', '/codex'].includes(uri.path) ? uri.path :
    uri.authority === 'openai.chatgpt' && /^\/local\/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(uri.path) ? uri.path : undefined;
  if (!SCHEMES.has(`${uri.scheme}:`) || expectedPath === undefined || uri.path !== expectedPath ||
      uri.fragment || /[\u0000-\u0020\u007f-\u009f]/.test(uri.query)) {
    throw new Error('unavailable_window_route');
  }
  const value = uri.toString(true);
  const parsed = parsedRoute(value, uri.authority, expectedPath);
  if (parsed.protocol !== `${uri.scheme}:` || parsed.search !== (uri.query ? `?${uri.query}` : '')) {
    throw new Error('unavailable_window_route');
  }
  return value;
}

export function windowId(url: URL): string {
  const keys = [...url.searchParams.keys()];
  const values = url.searchParams.getAll('windowId');
  if (keys.length !== 1 || values.length !== 1 || !INTEGER.test(values[0]) ||
      !isProcessId(Number(values[0]))) throw new Error('unavailable_window_route');
  return values[0];
}

/** Reject a generic URI: only asExternalUri's explicit, matching window IDs route safely. */
export function validateResolvedRoutes(claudeSessionURL: string, terminalURL: string): ResolvedRoutes {
  const claude = parsedRoute(claudeSessionURL, 'anthropic.claude-code', '/open');
  const terminal = parsedRoute(terminalURL, EXTENSION_ID, '/terminal');
  const id = windowId(claude);
  if (windowId(terminal) !== id || terminal.protocol !== claude.protocol) throw new Error('unavailable_window_route');
  return { claudeSessionURL, terminalURL, windowId: id };
}

/** Parse only a focus request for this window; no command or message is accepted. */
export function parseTerminalRequest(value: string, ownWindowKey: string, expectedWindowId?: string): number | undefined {
  try {
    const url = parsedRoute(value, EXTENSION_ID, '/terminal');
    const allowed = new Set(['windowId', 'windowKey', 'pid']);
    if ([...url.searchParams.keys()].some(key => !allowed.has(key))) return undefined;
    if (!isWindowKey(ownWindowKey) || url.searchParams.getAll('windowKey').length !== 1 ||
        url.searchParams.get('windowKey') !== ownWindowKey || url.searchParams.getAll('pid').length !== 1) return undefined;
    const pid = url.searchParams.get('pid') ?? '';
    if (!INTEGER.test(pid) || !isProcessId(Number(pid))) return undefined;
    const ids = url.searchParams.getAll('windowId');
    if (ids.length > 1 || (ids.length === 1 &&
        (!INTEGER.test(ids[0]) || !isProcessId(Number(ids[0])) ||
         (expectedWindowId !== undefined && ids[0] !== expectedWindowId)))) return undefined;
    return Number(pid);
  } catch { return undefined; }
}

export interface FocusableTerminal {
  processId: Thenable<number | undefined>;
  show(preserveFocus?: boolean): void;
}

export async function readTerminalProcessId(terminal: Pick<FocusableTerminal, 'processId'>,
                                            timeoutMs = 1_000): Promise<number | undefined> {
  let timer: NodeJS.Timeout | undefined;
  try {
    const value = await Promise.race([
      Promise.resolve(terminal.processId).catch(() => undefined),
      new Promise<undefined>(resolve => { timer = setTimeout(() => resolve(undefined), timeoutMs); })
    ]);
    return value !== undefined && isProcessId(value) ? value : undefined;
  } finally { if (timer) clearTimeout(timer); }
}

export async function focusExistingTerminal(terminals: readonly FocusableTerminal[], pid: number): Promise<boolean> {
  if (!isProcessId(pid)) return false;
  const matches = (await Promise.all(terminals.map(async terminal => {
    try { return await readTerminalProcessId(terminal) === pid ? terminal : undefined; }
    catch { return undefined; }
  }))).filter((terminal): terminal is FocusableTerminal => terminal !== undefined);
  if (matches.length !== 1) return false;
  try { matches[0].show(false); return true; }
  catch { return false; }
}

export function normalizeLocalWorkspace(value: unknown, platform: NodeJS.Platform = process.platform): string | undefined {
  if (typeof value !== 'string' || value.length > 4096 || /[\u0000-\u001f\u007f-\u009f]/.test(value)) return;
  if (platform === 'win32') {
    if (!/^[a-z]:[\\/]/i.test(value)) return;
    const parts = value.slice(3).split(/[\\/]/).filter(Boolean);
    if (parts.length > 64 || parts.some(part => part.length > 255 || part === '.' || part === '..' || /[<>:"|?*]/.test(part) || /[. ]$/.test(part) ||
        /^(?:con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(?:\.|$)/i.test(part))) return;
    const normalized = path.win32.normalize(value);
    if (normalized === path.win32.parse(normalized).root) return;
    return normalized[0].toUpperCase() + normalized.slice(1).replace(/\\+$/, '');
  }
  if (platform !== 'darwin' || !path.posix.isAbsolute(value)) return;
  const normalized = path.posix.normalize(value);
  return normalized === '/' ? undefined : normalized;
}

export function localPlatformUnavailableReason(platform: NodeJS.Platform, remoteName?: string): 'unsupported_platform' | 'remote_window' | undefined {
  if (remoteName !== undefined) return 'remote_window';
  return platform === 'darwin' || platform === 'win32' ? undefined : 'unsupported_platform';
}

export function localWorkspaces(folders: readonly { uri: { scheme: string; fsPath: string } }[],
                                platform: NodeJS.Platform = process.platform): string[] {
  return [...new Set(folders.flatMap(folder => {
    const normalized = folder.uri.scheme === 'file' ? normalizeLocalWorkspace(folder.uri.fsPath, platform) : undefined;
    return normalized === undefined ? [] : [normalized];
  }))].slice(0, 32);
}

export function cleanTerminalName(name: string): string {
  return name.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]/g, ' ').trim().slice(0, 160);
}
