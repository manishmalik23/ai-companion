export type Source = 'claude' | 'codex';
export type Decision = 'allow' | 'deny';
export type RequestKind = 'permission' | 'question' | 'notice';
export interface QuestionOption { label: string; description?: string }
export interface Question { question: string; header?: string; options: QuestionOption[]; multiSelect?: boolean }
export interface Correlation {
  sessionId: string; turnId?: string; promptId?: string; agentId?: string; agentType?: string;
  toolUseId?: string; toolName?: string; toolInputHash?: string;
}
export interface SessionMetadata { sessionName?: string; sessionHost?: string; sessionWindowKey?: string }
export interface Request extends SessionMetadata {
  schemaVersion: 1; id: string; source: Source; sourceLabel: string;
  sessionId: string; toolName: string; cwd: string; reason: string; detailText: string;
  createdAt: number; expiresAt: number; canRespond: boolean; canDefer?: boolean; isDemo: boolean;
  kind: RequestKind; correlation: Correlation; questions?: Question[]; instructions?: string;
}
export interface Retirement {
  eventName: string; correlation: Correlation; observedAt: number; backgroundWork?: boolean;
}
export interface ActiveTool { correlation: Correlation; observedAt: number; background: boolean }
export interface Session extends SessionMetadata {
  source: Source; sessionId: string; status: 'idle' | 'working' | 'attention' | 'offline';
  updatedAt: number; cwd?: string; message?: string; retirements?: Retirement[]; activeToolCalls?: ActiveTool[]; activeToolOverflow?: boolean;
}
export interface State { requests: Request[]; working: boolean; error?: string }
export interface Response {
  id: string; decision: Decision | 'answer' | 'defer'; decidedAt: number; answers?: Record<string, string>;
}
export const seconds = () => Date.now() / 1000;
export const object = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value);
export const boundedText = (value: unknown, max: number): value is string =>
  typeof value === 'string' && value.length <= max && new TextEncoder().encode(value).byteLength <= max;
export const identifier = (value: unknown): value is string =>
  boundedText(value, 1024) && !!value.trim() && value.trim().toLowerCase() !== 'unknown';
export const validId = (id: unknown): id is string => typeof id === 'string' && /^[a-f0-9]{32}$/.test(id);
export const validSource = (source: unknown): source is Source => source === 'claude' || source === 'codex';
export const validWindowKey = (value: unknown): value is string =>
  typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(value);
export const sessionHosts = new Set(['claude-vscode', 'codex-vscode', 'codex-desktop', 'vscode-terminal', 'apple-terminal', 'windows-terminal']);
const scopeKeys = new Set(['sessionId', 'turnId', 'promptId', 'agentId', 'agentType', 'toolUseId', 'toolName', 'toolInputHash']);
export function validCorrelation(value: unknown): value is Correlation {
  return object(value) && identifier(value.sessionId) && Object.entries(value).every(([key, field]) =>
    scopeKeys.has(key) && identifier(field) && (key !== 'toolInputHash' || /^[a-f0-9]{64}$/.test(field)));
}
export function validQuestions(value: unknown): value is Question[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > 4) return false;
  const texts = new Set<string>();
  for (const q of value) {
    if (!object(q) || !boundedText(q.question, 4000) || !q.question.trim() || texts.has(q.question) ||
        (q.header !== undefined && !boundedText(q.header, 200)) ||
        (q.multiSelect !== undefined && typeof q.multiSelect !== 'boolean') ||
        !Array.isArray(q.options) || q.options.length < 2 || q.options.length > 4) return false;
    texts.add(q.question);
    const labels = new Set<string>();
    for (const option of q.options) {
      if (!object(option) || !boundedText(option.label, 1000) || !option.label.trim() || labels.has(option.label) ||
          (option.description !== undefined && !boundedText(option.description, 4000))) return false;
      labels.add(option.label);
    }
  }
  return true;
}
export function validAnswers(request: Request, value: unknown): value is Record<string, string> {
  if (request.kind !== 'question' || !validQuestions(request.questions) || !object(value)) return false;
  const expected = new Set(request.questions.map(q => q.question));
  return new TextEncoder().encode(JSON.stringify(value)).byteLength <= 2000 &&
    Object.keys(value).length === expected.size && Object.entries(value).every(([key, answer]) =>
    expected.has(key) && boundedText(answer, 4000) && !!answer.trim());
}
export function validRequest(value: unknown, now = seconds()): value is Request {
  if (!object(value)) return false;
  const r = value;
  return r.schemaVersion === 1 && validId(r.id) && validSource(r.source) && identifier(r.sessionId) &&
    boundedText(r.sourceLabel, 80) && boundedText(r.toolName, 200) && !!r.toolName &&
    boundedText(r.reason, 4000) && boundedText(r.cwd, 4096) && boundedText(r.detailText, 500_000) &&
    typeof r.createdAt === 'number' && Number.isFinite(r.createdAt) && r.createdAt > 0 && r.createdAt <= now + 60 &&
    typeof r.expiresAt === 'number' && Number.isFinite(r.expiresAt) && r.expiresAt > now &&
    r.expiresAt > r.createdAt && r.expiresAt - r.createdAt <= 300 && typeof r.isDemo === 'boolean' &&
    validCorrelation(r.correlation) && r.correlation.sessionId === r.sessionId &&
    (r.sessionName === undefined || boundedText(r.sessionName, 512) && !!r.sessionName.trim()) &&
    (r.sessionHost === undefined || typeof r.sessionHost === 'string' && sessionHosts.has(r.sessionHost)) &&
    (r.sessionWindowKey === undefined || validWindowKey(r.sessionWindowKey)) &&
    (r.instructions === undefined || boundedText(r.instructions, 4000)) &&
    (r.canDefer === undefined || typeof r.canDefer === 'boolean') &&
    ((r.kind === 'permission' && r.canRespond === true && r.questions === undefined) ||
     (r.kind === 'question' && r.source === 'claude' && r.canRespond === true && validQuestions(r.questions)) ||
     (r.kind === 'notice' && r.canRespond === false && r.questions === undefined));
}
export function validResponse(request: Request, value: unknown, now = seconds()): value is Response {
  if (!object(value) || value.id !== request.id || typeof value.decidedAt !== 'number' || !Number.isFinite(value.decidedAt) ||
      value.decidedAt < request.createdAt || value.decidedAt > Math.min(now, request.expiresAt)) return false;
  return request.canRespond && (request.kind === 'permission' ?
    Object.keys(value).length === 3 && (value.decision === 'allow' || value.decision === 'deny' || request.canDefer === true && value.decision === 'defer') && value.answers === undefined :
    request.kind === 'question' && (value.decision === 'defer' && value.answers === undefined ||
      value.decision === 'answer' && validAnswers(request, value.answers)));
}
