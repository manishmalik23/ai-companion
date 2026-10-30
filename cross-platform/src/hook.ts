import path from 'node:path';
import * as fs from 'node:fs/promises';
import { createHash, randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { alive, defaultRuntime, locked, prepare, read, write } from './mailbox';
import { quoteHookCommand } from './platform-config';
import { displaySessionTitle, lookupClaudeSessionTitle, lookupCodexSessionTitle } from './session-titles';
import {
  Request, Source, Correlation, Retirement, ActiveTool, Session, SessionMetadata, Response,
  seconds, object, identifier, boundedText, validSource, validCorrelation, validRequest, validResponse,
  validQuestions, validWindowKey, sessionHosts
} from './protocol';

export interface HookEvent {
  hook_event_name: string; session_id: string; tool_name?: string; tool_input?: unknown;
  cwd?: string; turn_id?: string; prompt_id?: string; agent_id?: string; agent_type?: string; tool_use_id?: string;
  session_title?: string; session_name?: string; custom_title?: string; sessionName?: string;
  session_host?: string; sessionHost?: string; notification_type?: string; title?: string; message?: string;
  transcript_path?: string;
  background_tasks?: unknown; session_crons?: unknown; tool_calls?: unknown;
}
export interface TelemetryDecision {
  session_id: string; tool_use_id: string; decision: 'accept' | 'reject'; source: string; decided_at: number; prompt_id?: string;
}
const labels = { claude: 'Claude Code', codex: 'Codex' };
const toolEvents = new Set(['PostToolUse', 'PostToolUseFailure']);
const turnEvents = new Set(['Stop', 'StopFailure', 'Interrupt', 'SessionEnd']);
const retirementEvents = new Set([...toolEvents, ...turnEvents, 'ToolDecision']);
const MAX_ACTIVE = 128, MAX_RECORDS = 32, MAX_SESSION = 300_000;
const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const sessionFile = (source: Source, id: string) => `sessions/${digest(`${source}:${id}`)}.json`;
const pause = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
const optionalFields = ['turn_id', 'prompt_id', 'agent_id', 'agent_type', 'tool_use_id'] as const;
function validateStructure(value: unknown): void {
  const pending: [unknown, number][] = [[value, 0]];
  let count = 0;
  while (pending.length) {
    const [node, depth] = pending.pop()!;
    if (++count > 50_000 || depth > 32) throw new Error('Hook input is too complex.');
    if (typeof node === 'number' && !Number.isFinite(node)) throw new Error('Hook input contains a nonfinite number.');
    if (object(node)) pending.push(...Object.values(node).map(child => [child, depth + 1] as [unknown, number]));
    else if (Array.isArray(node)) pending.push(...node.map(child => [child, depth + 1] as [unknown, number]));
    else if (node !== null && node !== undefined && !['string', 'number', 'boolean'].includes(typeof node)) throw new Error('Invalid hook input.');
  }
  const serialized = JSON.stringify(value);
  if (!serialized || Buffer.byteLength(serialized) > 512 * 1024) throw new Error('Hook input is too large.');
}
function canonical(value: unknown): string {
  const sorted = (item: unknown): unknown => Array.isArray(item) ? item.map(sorted) : object(item) ?
    Object.fromEntries(Object.keys(item).sort().map(key => [key, sorted(item[key])])) : item;
  return JSON.stringify(sorted(value));
}
export function correlation(event: HookEvent): Correlation {
  const result: Correlation = { sessionId: event.session_id };
  for (const [input, output] of [
    ['turn_id', 'turnId'], ['prompt_id', 'promptId'], ['agent_id', 'agentId'], ['agent_type', 'agentType'],
    ['tool_use_id', 'toolUseId'], ['tool_name', 'toolName']
  ] as const) if (identifier(event[input])) result[output] = event[input];
  if (event.tool_input !== undefined) result.toolInputHash = digest(canonical(event.tool_input));
  return result;
}
async function metadata(source: Source, event: HookEvent, previous?: Session): Promise<SessionMetadata> {
  const result: SessionMetadata = {};
  for (const name of [event.session_title, event.session_name, event.custom_title, event.sessionName]) {
    const value = displaySessionTitle(name, event);
    if (value) { result.sessionName = value; break; }
  }
  const tool = event.tool_name?.split('.').at(-1);
  const refresh = ['SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'Notification'].includes(event.hook_event_name) ||
    event.hook_event_name === 'PreToolUse' && ['AskUserQuestion', 'request_user_input', 'request_user_input_async'].includes(tool || '');
  if (!result.sessionName && refresh) {
    const saved = source === 'claude' ? await lookupClaudeSessionTitle(event) : await lookupCodexSessionTitle(event);
    result.sessionName = displaySessionTitle(saved?.title, event);
  }
  if (!result.sessionName) result.sessionName = displaySessionTitle(previous?.sessionName, event);
  const explicit = event.session_host ?? event.sessionHost;
  const origin = source === 'claude' ? process.env.CLAUDE_CODE_ENTRYPOINT : process.env.CODEX_INTERNAL_ORIGINATOR_OVERRIDE;
  const implicit = source === 'claude' ? (['claude-vscode', 'vscode'].includes(origin || '') ? 'claude-vscode' : undefined) :
    origin === 'Codex Desktop' ? 'codex-desktop' : origin === 'codex_vscode' ? 'codex-vscode' : undefined;
  const terminal = origin === 'codex_work_desktop' ? undefined : process.env.TERM_PROGRAM === 'vscode' ? 'vscode-terminal' :
    process.env.TERM_PROGRAM === 'Apple_Terminal' ? 'apple-terminal' : process.env.WT_SESSION ? 'windows-terminal' : undefined;
  const host = explicit ?? implicit ?? terminal;
  if (typeof host === 'string' && sessionHosts.has(host) &&
      (source === 'claude' ? !host.startsWith('codex-') : host !== 'claude-vscode')) {
    result.sessionHost = host;
    if (host.endsWith('-vscode') || host === 'vscode-terminal') {
      const key = process.env.PIP_VSCODE_WINDOW_KEY;
      if (validWindowKey(key)) result.sessionWindowKey = key.toLowerCase();
    }
  }
  return result;
}
async function session(root: string, source: Source, id: string): Promise<Session | undefined> {
  try {
    const value = await read(root, sessionFile(source, id), MAX_SESSION);
    return object(value) && value.source === source && value.sessionId === id ? value as unknown as Session : undefined;
  } catch { return undefined; }
}
function records(document?: Session): Retirement[] {
  return Array.isArray(document?.retirements) ? document.retirements.filter(record =>
    object(record) && retirementEvents.has(record.eventName) && validCorrelation(record.correlation) &&
    Number.isFinite(record.observedAt) && record.observedAt > 0).slice(-MAX_RECORDS) : [];
}
function calls(document?: Session): ActiveTool[] {
  return Array.isArray(document?.activeToolCalls) ? document.activeToolCalls.filter(call =>
    object(call) && validCorrelation(call.correlation) && identifier(call.correlation.toolUseId) &&
    Number.isFinite(call.observedAt) && call.observedAt > 0 && typeof call.background === 'boolean').slice(-MAX_ACTIVE) : [];
}
function ambiguous(document?: Session): boolean {
  return !!document?.activeToolOverflow || (document?.activeToolCalls !== undefined &&
    (!Array.isArray(document.activeToolCalls) || document.activeToolCalls.length !== calls(document).length));
}
async function saveSession(root: string, source: Source, event: HookEvent, status: Session['status'],
  additions: Retirement[] = [], active?: ActiveTool[], overflow?: boolean, message = ''): Promise<number> {
  const previous = await session(root, source, event.session_id);
  const activeCalls = active ?? calls(previous);
  const retirements = [...records(previous), ...additions].slice(-MAX_RECORDS);
  // Only bounded identities and tool-input hashes persist here, never a second copy of tool text.
  const state: Session = {
    source, sessionId: event.session_id, ...await metadata(source, event, previous),
    cwd: boundedText(event.cwd, 4096) ? event.cwd : previous?.cwd || '',
    status: status === 'idle' && activeCalls.length ? 'working' : status, updatedAt: seconds(), message,
    retirements, activeToolCalls: activeCalls.slice(-MAX_ACTIVE),
    activeToolOverflow: (overflow ?? ambiguous(previous)) || activeCalls.length > MAX_ACTIVE
  };
  while (Buffer.byteLength(JSON.stringify(state)) > MAX_SESSION) {
    if (state.activeToolCalls!.length) { state.activeToolCalls!.shift(); state.activeToolOverflow = true; }
    else if (state.retirements!.length) state.retirements!.shift();
    else throw new Error('Session metadata is too large.');
  }
  await write(root, sessionFile(source, event.session_id), state);
  return state.updatedAt;
}
export function completionMatch(request: Pick<Request, 'source' | 'createdAt' | 'correlation'> & Partial<Pick<Request, 'kind' | 'canRespond'>>,
  record: Retirement, publication = false): 'session' | 'turn' | 'tool' | 'fingerprint' | undefined {
  const a = request.correlation, b = record.correlation, name = record.eventName;
  if (!validCorrelation(a) || !validCorrelation(b) || a.sessionId !== b.sessionId || !Number.isFinite(request.createdAt)) return undefined;
  if (request.source === 'codex' && request.kind === 'notice' && request.canRespond === false && name === 'PostToolUse' &&
      a.toolName?.split('.').at(-1) === 'request_user_input_async') return undefined;
  if (name === 'ToolDecision' && request.canRespond === false && request.createdAt > record.observedAt) return undefined;
  if (request.createdAt > record.observedAt) {
    const interruptedTurn = name === 'Interrupt' && request.source === 'codex' &&
      (!!a.turnId && a.turnId === b.turnId || !!a.promptId && a.promptId === b.promptId);
    const completedTool = (toolEvents.has(name) || name === 'ToolDecision') && !!a.toolUseId && a.toolUseId === b.toolUseId;
    if (!publication || !interruptedTurn && !completedTool) return undefined;
  }
  if (name === 'SessionEnd') return 'session';
  const exactTool = (toolEvents.has(name) || name === 'ToolDecision') && !!a.toolUseId && a.toolUseId === b.toolUseId;
  for (const key of ['agentId', 'turnId', 'promptId'] as const) if (a[key] !== b[key] && (!exactTool || a[key] !== undefined && b[key] !== undefined)) return undefined;
  if (!(a.agentId && a.agentId === b.agentId) && a.agentType !== b.agentType &&
      (!exactTool || a.agentType !== undefined && b.agentType !== undefined)) return undefined;
  if (turnEvents.has(name)) return record.backgroundWork ? undefined : 'turn';
  if (a.toolUseId && b.toolUseId) return a.toolUseId === b.toolUseId ? 'tool' : undefined;
  if (name === 'ToolDecision') return undefined;
  if (a.toolName && a.toolInputHash && a.toolName === b.toolName && a.toolInputHash === b.toolInputHash) return 'fingerprint';
  return undefined;
}
async function pendingRequests(root: string): Promise<{ file: string; request: Request }[]> {
  const result: { file: string; request: Request }[] = [];
  for (const file of (await fs.readdir(path.join(root, 'requests'))).filter(name => /^[a-f0-9]{32}\.json$/.test(name)).slice(0, 256)) {
    try {
      const request = await read(root, `requests/${file}`);
      if (validRequest(request) && `${request.id}.json` === file) result.push({ file, request });
    } catch { /* A malformed local file never becomes a controllable request. */ }
  }
  return result;
}
async function remove(root: string, id: string): Promise<void> {
  await fs.unlink(path.join(root, 'requests', `${id}.json`)).catch(() => undefined);
  await fs.unlink(path.join(root, 'decisions', `${id}.json`)).catch(() => undefined);
}
async function retire(root: string, source: Source, record: Retirement): Promise<void> {
  const previous = await session(root, source, record.correlation.sessionId);
  const matching = (await pendingRequests(root)).filter(({ request }) => request.source === source).map(item =>
    ({ ...item, match: completionMatch(item.request, record) })).filter(item => !!item.match);
  const ambiguousRequests = matching.filter(item => item.match === 'fingerprint').length > 1;
  for (const { request, match } of matching) {
    if (match === 'fingerprint') {
      if (ambiguousRequests || ambiguous(previous)) continue;
      const owners = calls(previous).filter(call => {
        const { toolUseId: _toolUseId, ...scope } = call.correlation;
        return completionMatch({ source, createdAt: call.observedAt, correlation: scope }, record) === 'fingerprint';
      });
      if (owners.length > 1) continue;
    }
    await remove(root, request.id);
  }
}
function remaining(source: Source, previous: Session | undefined, record: Retirement): ActiveTool[] {
  if (record.eventName === 'SessionEnd') return [];
  return calls(previous).filter(call => call.background && (turnEvents.has(record.eventName) || record.eventName === 'PostToolUse') ||
    !completionMatch({ source, createdAt: call.observedAt, correlation: call.correlation }, record));
}
async function bindIdentity(root: string, source: Source, request: Request): Promise<void> {
  if (request.correlation.toolUseId) return;
  const previous = await session(root, source, request.sessionId);
  if (ambiguous(previous)) return;
  const active = calls(previous);
  let candidates: ActiveTool[];
  if (!request.canRespond) {
    if (active.length !== 1 || active[0]!.background) return;
    candidates = active;
    const owner = active[0]!.correlation;
    if (request.correlation.promptId && owner.promptId && request.correlation.promptId !== owner.promptId) return;
    const other = (await pendingRequests(root)).some(({ request: r }) => r.source === source && r.sessionId === request.sessionId &&
      r.correlation.toolUseId !== owner.toolUseId);
    if (other) return;
  } else candidates = active.filter(call => {
    const a = call.correlation, b = request.correlation;
    return ['sessionId', 'promptId', 'turnId', 'agentId', 'toolName', 'toolInputHash'].every(key =>
      a[key as keyof Correlation] === b[key as keyof Correlation]) && (b.agentId || a.agentType === b.agentType);
  });
  if (candidates.length === 1 && candidates[0]!.observedAt <= request.createdAt) request.correlation = { ...candidates[0]!.correlation };
}
async function track(root: string, source: Source, event: HookEvent): Promise<void> {
  const scope = correlation(event), previous = await session(root, source, event.session_id);
  if (!scope.toolUseId || !scope.toolName || !scope.toolInputHash) {
    await saveSession(root, source, event, previous?.status || 'working', [], undefined, true); return;
  }
  const active = calls(previous);
  const same = active.find(call => call.correlation.toolUseId === scope.toolUseId);
  if (same && canonical(same.correlation) !== canonical(scope)) {
    await saveSession(root, source, event, 'working', [], active, true); return;
  }
  if (!same) active.push({
    correlation: scope, observedAt: seconds(), background: object(event.tool_input) && event.tool_input.run_in_background === true
  });
  await saveSession(root, source, event, 'working', [], active);
}
async function publish(root: string, source: Source, event: HookEvent, request: Request): Promise<number | undefined> {
  return locked(root, async () => {
    const previous = await session(root, source, request.sessionId);
    Object.assign(request, await metadata(source, event, previous));
    await bindIdentity(root, source, request);
    if (records(previous).some(record => !!completionMatch(request, record, true))) return undefined;
    if (!validRequest(request)) throw new Error('Request cannot be displayed safely.');
    await write(root, `requests/${request.id}.json`, request);
    return saveSession(root, source, event, request.canRespond ? 'attention' : 'working');
  });
}
async function waitForResponse(root: string, source: Source, event: HookEvent, request: Request, wait: number, signal?: AbortSignal): Promise<Response | undefined> {
  const deadline = performance.now() + wait * 1000;
  if (signal?.aborted) return undefined;
  const attentionAt = await publish(root, source, event, request);
  if (attentionAt === undefined) return undefined;
  let result: Response | undefined, cancelled = false;
  try {
    while (!signal?.aborted && performance.now() < deadline && seconds() < request.expiresAt && await alive(root)) {
      const response = await locked(root, async () => {
        let current: unknown;
        try { current = await read(root, `requests/${request.id}.json`); } catch { return { cancelled: true } as const; }
        if (canonical(current) !== canonical(request)) return { cancelled: true } as const;
        try {
          const decision = await read(root, `decisions/${request.id}.json`, 4096);
          return validResponse(request, decision) ? decision : undefined;
        } catch { return undefined; }
      });
      if (response && 'cancelled' in response) { cancelled = true; return undefined; }
      if (response) { result = signal?.aborted ? undefined : response; return result; }
      await pause(100);
    }
    return undefined;
  } finally {
    await locked(root, async () => {
      await remove(root, request.id);
      const previous = await session(root, source, event.session_id);
      if (!cancelled && previous?.status === 'attention' && previous.updatedAt === attentionAt) {
        const answered = result !== undefined && result.decision !== 'defer';
        await saveSession(root, source, event, answered ? 'working' : 'attention', [], undefined, undefined,
          answered ? '' : 'Continue in the original app');
      }
    });
  }
}
function baseRequest(source: Source, event: HookEvent, wait: number, demo: boolean): Request {
  const now = seconds();
  const input = object(event.tool_input) ? event.tool_input : {};
  const reason = [input.description, input.justification, input.reason, input.message].find(value => boundedText(value, 4000) && !!value.trim());
  return { schemaVersion: 1, id: randomUUID().replaceAll('-', ''), source, sourceLabel: labels[source],
    sessionId: event.session_id, toolName: event.tool_name || 'Permission alert',
    cwd: boundedText(event.cwd, 4096) ? event.cwd : '', reason: demo ? 'Demo only. No command will run.' :
      typeof reason === 'string' ? reason : 'Review the complete tool input before deciding.',
    detailText: JSON.stringify(event.tool_input ?? {}, null, 2), createdAt: now, expiresAt: now + wait,
    canRespond: true, isDemo: demo, kind: 'permission', correlation: correlation(event) };
}
export async function handle(root: string, source: Source, event: HookEvent, wait = 120, demo = false, trackOnly = false, signal?: AbortSignal): Promise<unknown> {
  if (!validSource(source) || !object(event) || !identifier(event.session_id) || !boundedText(event.hook_event_name, 100) ||
      !event.hook_event_name || optionalFields.some(key => event[key] !== undefined && !identifier(event[key])) ||
      (event.tool_name !== undefined && !boundedText(event.tool_name, 200)) || !Number.isFinite(wait) || wait <= 0 || wait > 300) throw new Error('Invalid hook event.');
  validateStructure(event);
  await prepare(root);
  if (signal?.aborted || !await alive(root)) return undefined;
  const name = event.hook_event_name;
  if (name === 'PreToolUse') {
    await locked(root, () => track(root, source, event));
    if (trackOnly) return undefined;
    if (source === 'claude' && event.tool_name === 'AskUserQuestion') {
      if (!object(event.tool_input) || !validQuestions(event.tool_input.questions)) throw new Error('Invalid questions. Continue in the original agent.');
      const request = { ...baseRequest(source, event, wait, demo), kind: 'question' as const,
        reason: 'Choose an answer to continue.', questions: event.tool_input.questions };
      const answer = await waitForResponse(root, source, event, request, wait, signal);
      if (!answer || answer.decision !== 'answer') return undefined;
      return { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow',
        updatedInput: { ...event.tool_input, answers: answer.answers } } };
    }
    if (source === 'codex' && ['request_user_input', 'request_user_input_async'].includes(event.tool_name?.split('.').at(-1) || '')) {
      const request: Request = { ...baseRequest(source, event, wait, demo), kind: 'notice', canRespond: false,
        toolName: 'Question', reason: 'A question is waiting. Answer it in the original app.',
        instructions: 'Open the original Codex session to answer. Dismissing this alert does not answer the question.' };
      await publish(root, source, event, request);
    }
    return undefined;
  }
  if (name === 'Notification' && source === 'claude' && event.notification_type === 'permission_prompt') {
    if ((event.title !== undefined && !boundedText(event.title, 4000)) || (event.message !== undefined && !boundedText(event.message, 4000))) throw new Error('Invalid permission notice.');
    const request: Request = { ...baseRequest(source, event, wait, demo), kind: 'notice', canRespond: false,
      toolName: 'Permission alert', reason: event.title || 'Permission needed',
      detailText: JSON.stringify({ message: event.message || '', notification_type: event.notification_type }, null, 2),
      instructions: 'This host provides an alert only. Continue in the original agent.' };
    await publish(root, source, event, request); return undefined;
  }
  if (name === 'PermissionRequest') {
    if (!event.tool_name || event.tool_input === undefined) throw new Error('Permission request requires tool details.');
    const request = { ...baseRequest(source, event, wait, demo), canDefer: true };
    const answer = await waitForResponse(root, source, event, request, wait, signal);
    if (!answer || answer.decision !== 'allow' && answer.decision !== 'deny') return undefined;
    return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: {
      behavior: answer.decision, ...(answer.decision === 'deny' ? { message: 'Denied by the user in Pip.' } : {})
    } } };
  }
  if (name === 'PostToolBatch' && source === 'claude') {
    if (!Array.isArray(event.tool_calls) || event.tool_calls.length > MAX_ACTIVE) throw new Error('Invalid completed tool batch.');
    for (const call of event.tool_calls) if (object(call)) {
      const completed: HookEvent = { ...event, hook_event_name: 'PostToolUse' };
      for (const key of ['tool_name', 'tool_input', 'tool_use_id'] as const) if (call[key] !== undefined) (completed as unknown as Record<string, unknown>)[key] = call[key];
      await handle(root, source, completed, wait, false, false, signal);
    }
    return undefined;
  }
  if (toolEvents.has(name) || turnEvents.has(name) || ['SessionStart', 'UserPromptSubmit'].includes(name)) {
    await locked(root, async () => {
      const previous = await session(root, source, event.session_id);
      const record: Retirement | undefined = retirementEvents.has(name) ? {
        eventName: name, correlation: correlation(event), observedAt: seconds(), backgroundWork: !!event.background_tasks || !!event.session_crons
      } : undefined;
      if (record) await retire(root, source, record);
      await saveSession(root, source, event, name === 'SessionEnd' ? 'offline' :
        turnEvents.has(name) || name === 'SessionStart' ? 'idle' : 'working', record ? [record] : [],
        record ? remaining(source, previous, record) : undefined, name === 'SessionEnd' ? false : undefined);
    });
  }
  return undefined;
}
export async function handleTelemetryDecision(root: string, event: TelemetryDecision): Promise<void> {
  const allowed: Record<string, string[]> = { accept: ['config', 'hook', 'user_temporary', 'user_permanent'], reject: ['config', 'hook', 'user_abort', 'user_reject'] };
  if (!object(event) || !identifier(event.session_id) || !identifier(event.tool_use_id) ||
      !allowed[event.decision]?.includes(event.source) || !Number.isFinite(event.decided_at) || event.decided_at <= 0 ||
      event.decided_at > seconds() + 2 || event.prompt_id !== undefined && !identifier(event.prompt_id)) return;
  await prepare(root);
  await locked(root, async () => {
    const previous = await session(root, 'claude', event.session_id);
    if (ambiguous(previous)) return;
    const active = calls(previous).filter(call => call.correlation.toolUseId === event.tool_use_id);
    if (active.some(call => event.decided_at < call.observedAt - 2)) return;
    const owners = active.length ? active.map(call => call.correlation) : records(previous).filter(record =>
      toolEvents.has(record.eventName) && record.correlation.toolUseId === event.tool_use_id).map(record => record.correlation);
    const unique = [...new Map(owners.map(owner => [canonical(owner), owner])).values()];
    if (unique.length !== 1) return;
    const owner = unique[0]!;
    if (event.prompt_id && owner.promptId && event.prompt_id !== owner.promptId) return;
    const record: Retirement = { eventName: 'ToolDecision', correlation: owner, observedAt: event.decided_at };
    await retire(root, 'claude', record);
    const stillWaiting = (await pendingRequests(root)).some(({ request }) => request.source === 'claude' && request.sessionId === event.session_id);
    const eventContext: HookEvent = { hook_event_name: 'ToolDecision', session_id: event.session_id, cwd: previous?.cwd };
    await saveSession(root, 'claude', eventContext, previous?.status === 'attention' && !stillWaiting ? 'working' : previous?.status || 'working', [record]);
  });
}
export function config(source: Source, root: string, options: { nodePath?: string; platform?: NodeJS.Platform } = {}): unknown {
  if (!validSource(source)) throw new Error('Unknown assistant.');
  const platform = options.platform ?? process.platform;
  const prefix = [options.nodePath ?? process.execPath, __filename, 'hook', '--source', source, '--runtime',
    platform === 'win32' ? path.win32.resolve(root) : path.resolve(root)];
  const command = (flags: string[] = []) => quoteHookCommand([...prefix, ...flags], platform);
  const entry = (timeout: number, flags: string[] = []) => source === 'claude' ?
    { type: 'command', command: prefix[0], args: [...prefix.slice(1), ...flags], timeout } :
    { type: 'command', command: command(flags), ...(platform === 'win32' ? { commandWindows: command(flags) } : {}), timeout };
  const hooks: Record<string, unknown> = {};
  for (const event of ['SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Stop', 'SessionEnd',
    ...(source === 'codex' ? ['Interrupt'] : ['PostToolUseFailure', 'PostToolBatch', 'StopFailure'])]) hooks[event] = [{ hooks: [entry(2)] }];
  hooks.PermissionRequest = [{ matcher: '*', hooks: [entry(130)] }];
  if (source === 'claude') {
    hooks.Notification = [{ matcher: 'permission_prompt', hooks: [entry(2)] }];
    hooks.PreToolUse = [
      { matcher: '^AskUserQuestion$', hooks: [entry(130)] },
      { matcher: '*', hooks: [entry(2, ['--track-tools'])] }
    ];
  } else hooks.PreToolUse = [
    { matcher: '(^|[.])(request_user_input|request_user_input_async)$', hooks: [entry(2)] },
    { matcher: '*', hooks: [entry(2, ['--track-activity'])] }
  ];
  return { hooks };
}
async function main(): Promise<void> {
  const args = process.argv.slice(2), command = args[0];
  const flag = (key: string) => { const index = args.indexOf(key); if (index < 0 || !args[index + 1] || args[index + 1]!.startsWith('--')) throw new Error(`Missing ${key} value.`); return args[index + 1]!; };
  const root = args.includes('--runtime') ? flag('--runtime') : defaultRuntime();
  const source = args.includes('--source') ? flag('--source') : 'codex';
  if (!validSource(source)) throw new Error('Unknown assistant.');
  if (command === 'config') { console.log(JSON.stringify(config(source, root), null, 2)); return; }
  if (command === 'demo') {
    if (!await alive(root)) throw new Error('Start the TypeScript companion first.');
    const scenario = args.includes('--scenario') ? flag('--scenario') : args.includes('--question') ? 'question' : 'permission';
    if (!['permission', 'question', 'notice'].includes(scenario)) throw new Error('Use demo scenario permission, question or notice.');
    const question = scenario === 'question', notice = scenario === 'notice';
    const event: HookEvent = { hook_event_name: question || notice ? 'PreToolUse' : 'PermissionRequest', session_id: `demo-${randomUUID()}`,
      turn_id: 'demo-turn', tool_use_id: 'demo-tool', session_name: 'Companion demonstration',
      tool_name: question ? 'AskUserQuestion' : notice ? 'functions.request_user_input_async' : 'exec_command', tool_input: question || notice ? {
        questions: [{ question: 'Which language should the demo use?', header: 'Language', options: [{ label: 'TypeScript' }, { label: 'Python' }], multiSelect: false }]
      } : { cmd: 'yarn test', description: 'Displayed only. Never executed.' } };
    const demoSource = question ? 'claude' : notice ? 'codex' : source;
    const result = await handle(root, demoSource, event, 120, true);
    if (notice) {
      const deadline = performance.now() + 120_000;
      while (performance.now() < deadline && await alive(root) &&
        await locked(root, async () => (await pendingRequests(root)).some(({ request }) => request.sessionId === event.session_id))) await pause(100);
    }
    await handle(root, demoSource, { ...event, hook_event_name: 'Stop' });
    console.log(JSON.stringify(result || { status: 'no decision' })); return;
  }
  if (command !== 'hook') throw new Error('Use hook, config or demo.');
  const cancellation = new AbortController();
  const cancel = () => cancellation.abort();
  process.once('SIGTERM', cancel); process.once('SIGINT', cancel);
  try {
    const chunks: Buffer[] = []; let size = 0;
    for await (const chunk of process.stdin) { const bytes = Buffer.from(chunk); size += bytes.length; if (size > 512 * 1024) throw new Error('Hook input too large.'); chunks.push(bytes); }
    const event = JSON.parse(Buffer.concat(chunks).toString()) as HookEvent;
    const result = await handle(root, source, event, 120, false, args.includes('--track-tools') || args.includes('--track-activity'), cancellation.signal);
    if (result && !cancellation.signal.aborted) console.log(JSON.stringify(result));
  } finally { process.removeListener('SIGTERM', cancel); process.removeListener('SIGINT', cancel); }
}
if (require.main === module) main().catch(error => {
  console.error(`Pip: ${(error as Error).message} Continue in the original assistant.`);
  process.exitCode = process.argv[2] === 'hook' ? 0 : 1;
});
