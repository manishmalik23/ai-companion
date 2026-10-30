import { EXTENSION_ID, isWindowKey, parsedRoute, ResolvedRoutes, serializeSessionURI,
  SessionLinkLease, SessionURILike, windowId } from './protocol';

/** This installed implementation was inspected; the IDE route has no public compatibility contract. */
export const SUPPORTED_CODEX_VERSION = '26.1021.22027';
const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface CodexCapability { codexSessionURL: string; codexExtensionVersion: string }

export function supportsCodexVersion(version: unknown): version is string {
  return version === SUPPORTED_CODEX_VERSION;
}

/** Unknown versions do not advertise a capability; existing Claude/terminal links still work. */
export function codexCapability(version: unknown, value: string | undefined,
                                routes: ResolvedRoutes): CodexCapability | undefined {
  if (!supportsCodexVersion(version)) return undefined;
  if (value === undefined) throw new Error('unavailable_codex_route');
  const route = parsedRoute(value, EXTENSION_ID, '/codex');
  if (windowId(route) !== routes.windowId || route.protocol !== new URL(routes.terminalURL).protocol) {
    throw new Error('unavailable_codex_route');
  }
  return { codexSessionURL: value, codexExtensionVersion: version };
}

export function validateCodexLease(lease: Pick<SessionLinkLease, 'codexSessionURL' | 'codexExtensionVersion'>,
                                  routes: ResolvedRoutes): void {
  if (lease.codexSessionURL === undefined && lease.codexExtensionVersion === undefined) return;
  if (!supportsCodexVersion(lease.codexExtensionVersion) || typeof lease.codexSessionURL !== 'string' ||
      !codexCapability(lease.codexExtensionVersion, lease.codexSessionURL, routes)) {
    throw new Error('invalid_codex_capability');
  }
}

/** This endpoint accepts a thread identity only, never a prompt, command, new chat, or remote host. */
export function parseCodexRequest(value: string, ownWindowKey: string, routes: ResolvedRoutes): string | undefined {
  try {
    const route = parsedRoute(value, EXTENSION_ID, '/codex');
    const allowed = new Set(['windowId', 'windowKey', 'sessionId']);
    if ([...route.searchParams.keys()].length !== 3 ||
        [...route.searchParams.keys()].some(key => !allowed.has(key)) ||
        ![...allowed].every(key => route.searchParams.getAll(key).length === 1) ||
        !isWindowKey(ownWindowKey) || route.searchParams.get('windowKey') !== ownWindowKey ||
        route.searchParams.get('windowId') !== routes.windowId ||
        route.protocol !== new URL(routes.terminalURL).protocol) return undefined;
    const session = route.searchParams.get('sessionId')?.toLowerCase();
    return session !== undefined && SESSION_ID.test(session) ? session : undefined;
  } catch { return undefined; }
}

export type CodexNavigationResult = 'opened' | 'invalid_request' | 'unsupported_version' |
  'unavailable_window_route' | 'open_failed' | 'cancelled';

export interface CodexNavigationHost {
  extensionVersion(): unknown;
  resolveURI(value: string): Promise<SessionURILike>;
  openURI(value: string): Promise<boolean>;
  isCurrent(): boolean;
}

/** Resolve the full exact-thread route inside its owning window, then validate before opening. */
export async function openCodexSession(value: string, ownWindowKey: string, routes: ResolvedRoutes,
                                       host: CodexNavigationHost): Promise<CodexNavigationResult> {
  const session = parseCodexRequest(value, ownWindowKey, routes);
  if (session === undefined) return 'invalid_request';
  if (!host.isCurrent()) return 'cancelled';
  if (!supportsCodexVersion(host.extensionVersion())) return 'unsupported_version';
  const scheme = new URL(routes.terminalURL).protocol;
  const pathname = `/local/${session}`;
  let target: string;
  try {
    target = serializeSessionURI(await host.resolveURI(`${scheme}//openai.chatgpt${pathname}`));
    const route = parsedRoute(target, 'openai.chatgpt', pathname);
    if (route.protocol !== scheme || windowId(route) !== routes.windowId) return 'unavailable_window_route';
  } catch { return 'unavailable_window_route'; }
  if (!host.isCurrent()) return 'cancelled';
  // VS Code can update an extension while URI resolution is pending; stale leases cannot bypass this gate.
  if (!supportsCodexVersion(host.extensionVersion())) return 'unsupported_version';
  try { return await host.openURI(target) ? 'opened' : 'open_failed'; }
  catch { return 'open_failed'; }
}
