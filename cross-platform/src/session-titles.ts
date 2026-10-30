import * as fs from 'node:fs/promises';
import type { Stats } from 'node:fs';
import { constants } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';

export const TITLE_WINDOW_BYTES = 65_536;
export const TITLE_RECORD_BYTES = 8192;
export const CODEX_INDEX_BYTES = 256 * 1024;
const TITLE_BYTES = 512, SIDECAR_BYTES = 8192;
const UUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
const PROJECT = /^[A-Za-z0-9_-]{1,255}$/;
const decoder = new TextDecoder('utf-8', { fatal: true });
export interface TitleEvent { session_id?: unknown; cwd?: unknown; transcript_path?: unknown }
export interface TitleOptions { home?: string; environment?: NodeJS.ProcessEnv }
export interface SessionTitle { title: string; source: 'claude-custom-title' | 'claude-custom-title-record' | 'claude-ai-title-record' | 'codex-index' }
interface PathIdentity { file: string; dev: number; ino: number; directory: boolean; requireOwned: boolean }

export function cleanSessionTitle(value: unknown): string | undefined {
  if (typeof value !== 'string' || Buffer.byteLength(value, 'utf8') > TITLE_BYTES || Buffer.from(value, 'utf8').toString('utf8') !== value) return;
  return value.replace(/[\p{C}]/gu, ' ').replace(/\s+/g, ' ').trim() || undefined;
}
/** Session IDs and workspace context are labels, not conversation subjects. */
export function displaySessionTitle(value: unknown, event: TitleEvent): string | undefined {
  const title = cleanSessionTitle(value); if (!title) return;
  const identity = title.replace(/^(?:session(?:\s+(?:id|uuid))?|id|uuid)\s*[:#]?\s*/i, '').trim().replace(/^[<>()\[\]{} ]+|[<>()\[\]{} ]+$/g, '');
  const session = cleanSessionTitle(event.session_id);
  if (UUID.test(identity) || /^[a-f0-9]{32}$/i.test(identity) || session && identity.toLowerCase() === session.toLowerCase()) return;
  if (typeof event.cwd === 'string') {
    const folder = event.cwd.trim().replaceAll('\\', '/').replace(/\/+$/, ''), normalized = title.replaceAll('\\', '/').replace(/\/+$/, '').toLowerCase();
    if (normalized && (normalized === folder.toLowerCase() || normalized === folder.split('/').at(-1)?.toLowerCase())) return;
  }
  return title;
}
function absolute(value: unknown): string | undefined {
  if (typeof value !== 'string' || !path.isAbsolute(value) || Buffer.byteLength(value) > 4096 ||
      /[\u0000-\u001f\u007f]/.test(value) || value.split(/[\\/]/).includes('..') ||
      (process.platform === 'win32' && /^(?:\\\\|\/\/)/.test(value))) return;
  return path.normalize(value);
}
function owned(stat: Stats, directory: boolean): boolean {
  return !stat.isSymbolicLink() && (directory ? stat.isDirectory() : stat.isFile()) &&
    (process.platform === 'win32' || typeof process.getuid === 'function' && stat.uid === process.getuid() && (stat.mode & 0o022) === 0);
}
async function safePath(root: string, parts: readonly string[]): Promise<PathIdentity[]> {
  if (absolute(root) === undefined || parts.some(part => !part || part === '.' || part === '..' || /[\\/\u0000-\u001f]/.test(part))) throw new Error('Invalid title metadata path.');
  const identities: PathIdentity[] = [], parsed = path.parse(root);
  let current = parsed.root;
  for (const component of root.slice(parsed.root.length).split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    const stat = await fs.lstat(current);
    if (!stat.isDirectory() || stat.isSymbolicLink() || current === root && !owned(stat, true)) throw new Error('Untrusted title metadata root.');
    identities.push({ file: current, dev: stat.dev, ino: stat.ino, directory: true, requireOwned: current === root });
  }
  for (const [index, component] of parts.entries()) {
    current = path.join(current, component);
    const stat = await fs.lstat(current);
    if (!owned(stat, index !== parts.length - 1)) throw new Error('Untrusted title metadata.');
    identities.push({ file: current, dev: stat.dev, ino: stat.ino, directory: index !== parts.length - 1, requireOwned: true });
  }
  return identities;
}
async function withFile<T>(root: string, parts: readonly string[], operation: (handle: fs.FileHandle, before: Stats) => Promise<T>): Promise<T> {
  const identities = await safePath(root, parts), file = identities.at(-1)!;
  const handle = await fs.open(file.file, constants.O_RDONLY | (constants.O_NOFOLLOW || 0) | (constants.O_NONBLOCK || 0));
  try {
    const before = await handle.stat();
    if (!owned(before, false) || before.dev !== file.dev || before.ino !== file.ino || !Number.isSafeInteger(before.size) || before.size < 0) throw new Error('Title metadata file changed.');
    const result = await operation(handle, before), after = await handle.stat();
    if (!owned(after, false) || after.dev !== before.dev || after.ino !== before.ino || after.size < before.size ||
        after.size === before.size && (after.mtimeMs !== before.mtimeMs || after.ctimeMs !== before.ctimeMs)) throw new Error('Title metadata changed during lookup.');
    for (const identity of identities) {
      const stat = await fs.lstat(identity.file);
      if (stat.isSymbolicLink() || stat.dev !== identity.dev || stat.ino !== identity.ino ||
          identity.requireOwned && !owned(stat, identity.directory) || !identity.requireOwned && !stat.isDirectory()) throw new Error('Title metadata path changed during lookup.');
    }
    return result;
  } finally { await handle.close(); }
}

/** A deliberately flat parser: duplicates, unknown keys and nested values stop
 * before any message/prompt/summary object could be parsed. Only title strings
 * and their exact-session identity are permitted. */
function flatStrings(raw: Buffer, allowed: ReadonlySet<string>): Map<string, string> | undefined {
  try {
    const text = decoder.decode(raw); let offset = 0;
    const whitespace = () => { while (/[ \t\r\n]/.test(text[offset] || '\u0000')) offset++; };
    const string = (): string => {
      whitespace(); if (text[offset] !== '"') throw new Error('Expected string.');
      const start = offset++;
      while (offset < text.length) {
        const char = text[offset++]!;
        if (char === '"') return JSON.parse(text.slice(start, offset)) as string;
        if (char === '\\') { if (offset >= text.length) break; offset++; }
        else if (char.charCodeAt(0) < 32) throw new Error('Invalid string.');
      }
      throw new Error('Incomplete string.');
    };
    whitespace(); if (text[offset++] !== '{') return;
    const values = new Map<string, string>(); whitespace();
    if (text[offset] === '}') { offset++; whitespace(); return offset === text.length ? values : undefined; }
    for (;;) {
      const key = string(); if (!allowed.has(key) || values.has(key)) return;
      whitespace(); if (text[offset++] !== ':') return;
      values.set(key, string()); whitespace();
      const separator = text[offset++];
      if (separator === '}') { whitespace(); return offset === text.length ? values : undefined; }
      if (separator !== ',') return;
    }
  } catch { return; }
}
interface TitleRecord { kind: 'custom-title' | 'ai-title'; value: string | undefined }
interface WindowTitles { custom?: TitleRecord; ai?: TitleRecord }
interface TitleWindows { head: WindowTitles; tail: WindowTitles }
function titleRecord(line: Buffer, session: string, event: TitleEvent): TitleRecord | undefined {
  if (!line.length || line.length > TITLE_RECORD_BYTES ||
      !/^[ \t\r]*\{[ \t\r]*"type"[ \t\r]*:[ \t\r]*"(?:custom-title|ai-title)"[ \t\r]*[,}]/.test(line.toString('ascii', 0, Math.min(line.length, 128)))) return;
  const values = flatStrings(line, new Set(['type', 'sessionId', 'customTitle', 'aiTitle']));
  if (!values || values.size !== 3 || values.get('sessionId')?.toLowerCase() !== session || !UUID.test(values.get('sessionId') || '')) return;
  const type = values.get('type'), field = type === 'custom-title' ? 'customTitle' : type === 'ai-title' ? 'aiTitle' : undefined;
  if (!field || !values.has(field)) return;
  const raw = values.get(field)!;
  if (Buffer.byteLength(raw) > TITLE_BYTES || Buffer.from(raw).toString('utf8') !== raw) return;
  const cleaned = cleanSessionTitle(raw);
  if (cleaned === undefined) return { kind: type as TitleRecord['kind'], value: undefined };
  const value = displaySessionTitle(cleaned, event);
  return value ? { kind: type as TitleRecord['kind'], value } : undefined;
}
function project(root: string, event: TitleEvent, environment: NodeJS.ProcessEnv, session: string): string | undefined {
  if (event.transcript_path !== undefined) {
    const file = absolute(event.transcript_path);
    if (!file || path.basename(file) !== session + '.jsonl' || path.dirname(path.dirname(file)) !== path.join(root, 'projects')) return;
    const name = path.basename(path.dirname(file)); return PROJECT.test(name) ? name : undefined;
  }
  if (environment.CLAUDE_CODE_PROJECT_DIR_NAME !== undefined) {
    return PROJECT.test(environment.CLAUDE_CODE_PROJECT_DIR_NAME) ? environment.CLAUDE_CODE_PROJECT_DIR_NAME : undefined;
  }
  const cwd = absolute(event.cwd); if (!cwd) return;
  const encoded = cwd.replace(/[^A-Za-z0-9]/g, '-'); return PROJECT.test(encoded) ? encoded : undefined;
}
async function sidecar(root: string, name: string, session: string, event: TitleEvent): Promise<SessionTitle | undefined> {
  return withFile(root, ['projects', name, session, 'custom-title.json'], async (handle, stat) => {
    if (stat.size > SIDECAR_BYTES) return;
    const raw = Buffer.alloc(SIDECAR_BYTES + 1), { bytesRead } = await handle.read(raw, 0, raw.length, 0);
    if (bytesRead > SIDECAR_BYTES) return;
    const values = flatStrings(raw.subarray(0, bytesRead), new Set(['customTitle']));
    const title = values?.size === 1 ? displaySessionTitle(values.get('customTitle'), event) : undefined;
    return title ? { title, source: 'claude-custom-title' } : undefined;
  });
}
async function records(root: string, name: string, session: string, event: TitleEvent): Promise<TitleWindows | undefined> {
  return withFile(root, ['projects', name, session + '.jsonl'], async (handle, stat) => {
    const length = Math.min(TITLE_WINDOW_BYTES, stat.size), head = Buffer.alloc(length);
    if ((await handle.read(head, 0, length, 0)).bytesRead !== length) return;
    const start = Math.max(0, stat.size - TITLE_WINDOW_BYTES), windows = [{ bytes: head, offset: 0 }];
    if (start > 0) {
      const tail = Buffer.alloc(TITLE_WINDOW_BYTES);
      if ((await handle.read(tail, 0, tail.length, start)).bytesRead !== tail.length) return;
      const firstNewline = tail.indexOf(10);
      if (firstNewline >= 0) windows.push({ bytes: tail.subarray(firstNewline + 1), offset: start + firstNewline + 1 });
    }
    const found = new Map<number, TitleRecord>();
    const deadline = performance.now() + 30;
    for (const window of windows) {
      let from = 0;
      for (;;) {
        if (performance.now() > deadline) return;
        const to = window.bytes.indexOf(10, from); if (to < 0) break; // Never parse a partial record or unfinished append.
        const offset = window.offset + from, record = titleRecord(window.bytes.subarray(from, to), session, event); from = to + 1;
        if (record) found.set(offset, record);
      }
    }
    const result: TitleWindows = { head: {}, tail: {} };
    for (const [offset, record] of [...found].sort(([a], [b]) => a - b)) {
      const target = offset >= start ? result.tail : result.head;
      if (record.kind === 'custom-title') target.custom = record;
      else target.ai = record;
    }
    return result;
  });
}

/** Claude 2.1.312 stores display titles as exact metadata records in its JSONL
 * session file. Read bounded ends only; never parse or use conversation messages,
 * prompt previews, summaries or lastPrompt fallbacks. No provider files change. */
export async function lookupClaudeSessionTitle(event: TitleEvent, options: TitleOptions = {}): Promise<SessionTitle | undefined> {
  if (typeof event.session_id !== 'string' || !UUID.test(event.session_id)) return;
  const session = event.session_id.toLowerCase(), environment = options.environment ?? process.env;
  const root = absolute(environment.CLAUDE_CONFIG_DIR || path.join(options.home ?? os.homedir(), '.claude'));
  if (!root) return;
  const name = project(root, event, environment, session); if (!name) return;
  let custom: SessionTitle | undefined, windows: TitleWindows | undefined;
  try { custom = await sidecar(root, name, session, event); } catch { /* Missing/invalid sidecars do not supply a title. */ }
  try { windows = await records(root, name, session, event); } catch { /* The independently checked sidecar can still supply a title. */ }
  const tailCustom = windows?.tail.custom;
  if (tailCustom?.value) return { title: tailCustom.value, source: 'claude-custom-title-record' };
  // A valid empty tail custom-title explicitly clears older custom metadata.
  if (tailCustom === undefined) {
    if (custom) return custom;
    if (windows?.head.custom?.value) return { title: windows.head.custom.value, source: 'claude-custom-title-record' };
  }
  const ai = windows?.tail.ai ?? windows?.head.ai;
  return ai?.value ? { title: ai.value, source: 'claude-ai-title-record' } : undefined;
}

/** The Codex index contains title-only metadata. Read its bounded latest tail;
 * never open Codex transcripts or use database title/first-message columns. */
export async function lookupCodexSessionTitle(event: TitleEvent, options: TitleOptions = {}): Promise<SessionTitle | undefined> {
  if (typeof event.session_id !== 'string' || !UUID.test(event.session_id)) return;
  const session = event.session_id.toLowerCase(), environment = options.environment ?? process.env;
  const root = absolute(environment.CODEX_HOME || path.join(options.home ?? os.homedir(), '.codex')); if (!root) return;
  try {
    return await withFile(root, ['session_index.jsonl'], async (handle, stat) => {
      const length = Math.min(CODEX_INDEX_BYTES, stat.size), start = stat.size - length, raw = Buffer.alloc(length);
      if ((await handle.read(raw, 0, raw.length, start)).bytesRead !== length) return;
      const first = start > 0 ? raw.indexOf(10) + 1 : 0;
      if (start > 0 && first === 0) return;
      let end = raw.length;
      const deadline = performance.now() + 30;
      while (end > first) {
        if (performance.now() > deadline) return;
        const newline = raw.lastIndexOf(10, end - 1), begin = Math.max(first, newline + 1), line = raw.subarray(begin, end);
        end = begin - 1;
        if (!line.length || line.length > TITLE_RECORD_BYTES) continue;
        const values = flatStrings(line, new Set(['id', 'thread_name', 'updated_at']));
        if (values?.size !== 3 || !UUID.test(values.get('id') || '') || values.get('id')?.toLowerCase() !== session || !values.get('updated_at')) continue;
        const title = displaySessionTitle(values.get('thread_name'), event);
        if (title) return { title, source: 'codex-index' };
      }
      return;
    });
  } catch { return; }
}
