import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { lookupClaudeSessionTitle, lookupCodexSessionTitle, displaySessionTitle, cleanSessionTitle, TITLE_WINDOW_BYTES, CODEX_INDEX_BYTES } from '../src/session-titles';
import { requestTitle } from '../src/view-model';
import { Mailbox, write } from '../src/mailbox';
import { handle } from '../src/hook';

const ID = '12345678-1234-4234-8234-123456789abc', OTHER = '12345678-1234-4234-8234-123456789def';
const event = { session_id: ID, cwd: '/work/project' };
const ai = (title: unknown, session = ID) => ({ type: 'ai-title', aiTitle: title, sessionId: session });
const custom = (title: unknown, session = ID) => ({ type: 'custom-title', customTitle: title, sessionId: session });
const line = (value: unknown) => JSON.stringify(value) + '\n';
const filler = line({ type: 'user', message: { content: 'Private fixture text '.repeat(TITLE_WINDOW_BYTES / 4) } });
async function fixture(run: (f: { home: string; root: string; project: string; file: string; sidecar: string; lookup: (next?: Record<string, unknown>, environment?: NodeJS.ProcessEnv) => ReturnType<typeof lookupClaudeSessionTitle> }) => Promise<void>): Promise<void> {
  const home = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'pip-title-metadata-')));
  const root = path.join(home, '.claude'), project = path.join(root, 'projects', '-work-project'), file = path.join(project, ID + '.jsonl');
  await fs.mkdir(path.join(project, ID), { recursive: true, mode: 0o700 });
  const sidecar = path.join(project, ID, 'custom-title.json');
  try { await run({ home, root, project, file, sidecar, lookup: (next = {}, environment = {}) => lookupClaudeSessionTitle({ ...event, ...next }, { home, environment }) }); }
  finally { await fs.rm(home, { recursive: true, force: true }); }
}

test('exact automatic title events supply a session title without changing provider files', async () => fixture(async f => {
  await fs.writeFile(f.file, line(ai('Older name')) + line(ai('Other session', OTHER)) + line(ai('  Fix\ncheckout\u202e \u0000titles  ')), { mode: 0o644 });
  const before = await fs.readFile(f.file), stat = await fs.stat(f.file);
  assert.deepEqual(await f.lookup(), { title: 'Fix checkout titles', source: 'claude-ai-title-record' });
  assert.deepEqual(await fs.readFile(f.file), before); assert.equal((await fs.stat(f.file)).mtimeMs, stat.mtimeMs);
}));
test('latest tail custom title takes precedence over an older custom-title sidecar', async () => fixture(async f => {
  await fs.writeFile(f.sidecar, JSON.stringify({ customTitle: 'Stale sidecar' }), { mode: 0o600 });
  await fs.writeFile(f.file, line(custom('Old head title')) + filler + line(ai('Generated tail')) + line(custom('Renamed current session')), { mode: 0o600 });
  assert.deepEqual(await f.lookup(), { title: 'Renamed current session', source: 'claude-custom-title-record' });
}));
test('a checked sidecar precedes a head custom title, then head custom precedes automatic titles', async () => fixture(async f => {
  await fs.writeFile(f.file, line(custom('Head custom')) + filler + line(ai('Tail automatic')), { mode: 0o600 });
  await fs.writeFile(f.sidecar, JSON.stringify({ customTitle: 'Saved custom name' }), { mode: 0o600 });
  assert.equal((await f.lookup())?.title, 'Saved custom name');
  await fs.unlink(f.sidecar); assert.equal((await f.lookup())?.title, 'Head custom');
}));
test('small file custom metadata counts as tail and a missing transcript still allows a sidecar', async () => fixture(async f => {
  await fs.writeFile(f.sidecar, JSON.stringify({ customTitle: 'Sidecar' }), { mode: 0o600 });
  assert.deepEqual(await f.lookup(), { title: 'Sidecar', source: 'claude-custom-title' });
  await fs.writeFile(f.file, line(custom('Recent short-file rename')), { mode: 0o600 });
  assert.equal((await f.lookup())?.title, 'Recent short-file rename');
}));
test('invalid Claude workspace/identity metadata cannot mask an older valid saved subject', async () => fixture(async f => {
  for (const invalid of ['project', '/work/project/', `UUID: [${ID}]`, `Session UUID: (${ID})`]) {
    await fs.writeFile(f.sidecar, JSON.stringify({ customTitle: invalid }), { mode: 0o600 });
    await fs.writeFile(f.file, line(custom('Valid head custom title')) + line(ai('Valid AI title')) + filler + line(custom(invalid)) + line(ai(invalid)), { mode: 0o600 });
    assert.deepEqual(await f.lookup(), { title: 'Valid head custom title', source: 'claude-custom-title-record' });
    await fs.writeFile(f.file, line(ai('Valid automatic title')) + line(ai(invalid)), { mode: 0o600 });
    assert.deepEqual(await f.lookup(), { title: 'Valid automatic title', source: 'claude-ai-title-record' });
  }
}));
test('empty tail custom metadata clears stale custom titles and permits an automatic title', async () => fixture(async f => {
  await fs.writeFile(f.sidecar, JSON.stringify({ customTitle: 'Stale sidecar' }), { mode: 0o600 });
  await fs.writeFile(f.file, line(custom('Stale head')) + line(ai('Head AI')) + filler + line(custom('  ')) + line(ai('Current AI')), { mode: 0o600 });
  assert.deepEqual(await f.lookup(), { title: 'Current AI', source: 'claude-ai-title-record' });
  await fs.unlink(f.sidecar);
  await fs.writeFile(f.file, line(ai('Head AI')) + filler + line(ai('')), { mode: 0o600 });
  assert.equal(await f.lookup(), undefined);
}));
test('malformed, duplicate-key, mismatched and non-title records cannot supply a name', async () => fixture(async f => {
  const records = [
    line({ type: 'user', message: { content: line(ai('Nested fake title')) } }),
    line({ type: 'assistant', aiTitle: 'Message field', sessionId: ID }),
    line({ type: 'summary', summary: 'Private summary', sessionId: ID }),
    line({ type: 'last-prompt', lastPrompt: 'Private prompt', sessionId: ID }),
    line({ ...ai('Unknown schema'), message: 'Private text' }), line(ai('Wrong session', OTHER)),
    line(ai({ nested: 'Never parse this object' })), line(ai('x'.repeat(513))), line(ai('\ud800')),
    `{"type":"ai-title","aiTitle":"One","aiTitle":"Two","sessionId":"${ID}"}\n`,
    `{"type":"ai-title","aiTitle":"Other","sessionId":"${OTHER}","sessionId":"${ID}"}\n`
  ];
  await fs.writeFile(f.file, records.join(''), { mode: 0o600 });
  assert.equal(await f.lookup({ prompt: 'Never a title', summary: 'Never a fallback' }), undefined);
  await fs.writeFile(f.sidecar, '{"customTitle":"One","customTitle":"Two"}', { mode: 0o600 });
  assert.equal(await f.lookup(), undefined);
}));
test('incomplete head/tail boundaries and unfinished metadata appends are ignored', async () => fixture(async f => {
  await fs.writeFile(f.file, 'x'.repeat(TITLE_WINDOW_BYTES) + line(ai('Not a standalone line')), { mode: 0o600 });
  assert.equal(await f.lookup(), undefined);
  await fs.writeFile(f.file, line(ai('Complete title')) + JSON.stringify(ai('Unfinished append')), { mode: 0o600 });
  assert.equal((await f.lookup())?.title, 'Complete title');
  await fs.writeFile(f.file, JSON.stringify(ai('No newline yet')), { mode: 0o600 });
  assert.equal(await f.lookup(), undefined);
}));
test('lookup is confined to the exact provider project, session UUID and explicit config override', async () => fixture(async f => {
  await fs.writeFile(f.file, line(ai('Exact name')), { mode: 0o600 });
  assert.equal((await f.lookup({ transcript_path: f.file }))?.title, 'Exact name');
  for (const next of [{ transcript_path: path.join(f.home, ID + '.jsonl') }, { transcript_path: path.join(f.project, OTHER + '.jsonl') }, { session_id: '../' + ID }, { session_id: ID + '/other' }]) assert.equal(await f.lookup(next), undefined);
  for (const override of ['relative', path.join(f.root, '..', '.claude') + '/..', 'missing']) assert.equal(await f.lookup({}, { CLAUDE_CONFIG_DIR: override }), undefined);
  assert.equal((await f.lookup({}, { CLAUDE_CONFIG_DIR: f.root }))?.title, 'Exact name');
  assert.equal((await f.lookup({}, { CLAUDE_CODE_PROJECT_DIR_NAME: '-work-project' }))?.title, 'Exact name');
  assert.equal(await f.lookup({}, { CLAUDE_CODE_PROJECT_DIR_NAME: '../outside' }), undefined);
}));
test('symlinked files, provider roots and writable-by-others title metadata are ignored', async () => fixture(async f => {
  const outside = path.join(f.home, 'outside.jsonl'); await fs.writeFile(outside, line(ai('Outside')), { mode: 0o600 });
  await fs.symlink(outside, f.file); assert.equal(await f.lookup(), undefined); await fs.unlink(f.file);
  await fs.writeFile(f.file, line(ai('Owned title')), { mode: 0o600 });
  if (process.platform !== 'win32') {
    await fs.chmod(f.file, 0o666); assert.equal(await f.lookup(), undefined); await fs.chmod(f.file, 0o600);
    await fs.chmod(f.project, 0o777); assert.equal(await f.lookup(), undefined); await fs.chmod(f.project, 0o700);
  }
  const alias = path.join(f.home, 'alias'); await fs.symlink(f.root, alias, 'dir');
  assert.equal(await f.lookup({}, { CLAUDE_CONFIG_DIR: alias }), undefined);
}));
test('large exact-session files read only their two fixed windows', async () => fixture(async f => {
  await fs.writeFile(f.file, line(ai('Head AI')) + filler + line(ai('Tail AI')), { mode: 0o600 });
  const promises = require('node:fs/promises') as { open: typeof fs.open };
  const open = promises.open, reads: { length: number; position: number }[] = [];
  promises.open = (async (...args: Parameters<typeof fs.open>) => {
    const handle = await open(...args);
    if (args[0] !== f.file) return handle;
    const original = handle.read.bind(handle);
    handle.read = ((...values: any[]) => { reads.push({ length: values[2], position: values[3] }); return (original as any)(...values); }) as typeof handle.read;
    return handle;
  }) as typeof fs.open;
  try { assert.equal((await f.lookup())?.title, 'Tail AI'); }
  finally { promises.open = open; }
  assert.equal(reads.length, 2); assert.equal(reads.reduce((n, value) => n + value.length, 0), 2 * TITLE_WINDOW_BYTES);
  assert.equal(reads[0]?.position, 0); assert.ok(reads[1]!.position > TITLE_WINDOW_BYTES);
}));
test('head/tail overlap is deduplicated and classified by absolute record location', async () => fixture(async f => {
  const header = line({ type: 'user', message: 'x'.repeat(20_000) });
  await fs.writeFile(f.sidecar, JSON.stringify({ customTitle: 'Stale sidecar' }), { mode: 0o600 });
  await fs.writeFile(f.file, header + line(custom('Overlapping tail rename')) + line({ type: 'user', message: 'x'.repeat(50_000) }), { mode: 0o600 });
  assert.equal((await f.lookup())?.title, 'Overlapping tail rename');
}));
test('a concurrent append preserves the bounded initial snapshot, while same-size rewrites are rejected', async () => fixture(async f => {
  const promises = require('node:fs/promises') as { open: typeof fs.open }, open = promises.open;
  let mutate = async () => { await fs.appendFile(f.file, line(ai('Appended title'))); };
  promises.open = (async (...args: Parameters<typeof fs.open>) => {
    const handle = await open(...args); if (args[0] !== f.file) return handle;
    const original = handle.read.bind(handle); let changed = false;
    handle.read = (async (...values: any[]) => {
      const result = await (original as any)(...values);
      if (!changed) { changed = true; await mutate(); }
      return result;
    }) as typeof handle.read; return handle;
  }) as typeof fs.open;
  try {
    await fs.writeFile(f.file, line(ai('Snapshot title')), { mode: 0o600 });
    assert.equal((await f.lookup())?.title, 'Snapshot title');
    await fs.writeFile(f.file, line(ai('Snapshot title')), { mode: 0o600 });
    mutate = async () => { await fs.writeFile(f.file, line(ai('Replaced title')), { mode: 0o600 }); await fs.utimes(f.file, new Date(), new Date(Date.now() + 1000)); };
    assert.equal(await f.lookup(), undefined);
  } finally { promises.open = open; }
}));
test('replacing the session path while its original descriptor is open cannot supply a title', async () => fixture(async f => {
  await fs.writeFile(f.file, line(ai('Original title')), { mode: 0o600 });
  const replacement = path.join(f.home, 'replacement.jsonl'); await fs.writeFile(replacement, line(ai('Replaced title')), { mode: 0o600 });
  const promises = require('node:fs/promises') as { open: typeof fs.open }, open = promises.open;
  promises.open = (async (...args: Parameters<typeof fs.open>) => {
    const handle = await open(...args); if (args[0] !== f.file) return handle;
    const original = handle.read.bind(handle); let changed = false;
    handle.read = (async (...values: any[]) => { const result = await (original as any)(...values); if (!changed) { changed = true; await fs.rename(replacement, f.file); } return result; }) as typeof handle.read;
    return handle;
  }) as typeof fs.open;
  try { assert.equal(await f.lookup(), undefined); } finally { promises.open = open; }
}));
test('fresh Claude request metadata replaces the old cached session title', async () => fixture(async f => {
  const old = process.env.CLAUDE_CONFIG_DIR, runtime = path.join(f.home, 'runtime'), box = new Mailbox(runtime);
  process.env.CLAUDE_CONFIG_DIR = f.root;
  try {
    await fs.writeFile(f.file, line(ai('Fresh display title')), { mode: 0o600 });
    await box.start(); await box.poll();
    const key = createHash('sha256').update('claude:' + ID).digest('hex');
    await write(runtime, `sessions/${key}.json`, { source: 'claude', sessionId: ID, sessionName: 'Stale cached title', status: 'idle', updatedAt: Date.now() / 1000 });
    const response = handle(runtime, 'claude', { ...event, hook_event_name: 'PermissionRequest', tool_name: 'Read', tool_input: { file_path: '/demo.ts' } }, 3, true);
    let request;
    for (let i = 0; i < 100; i++) { request = (await box.poll()).requests[0]; if (request) break; await new Promise(resolve => setTimeout(resolve, 10)); }
    assert.equal(request?.sessionName, 'Fresh display title');
    await box.decide(request!.id, 'deny'); await response;
  } finally { if (old === undefined) delete process.env.CLAUDE_CONFIG_DIR; else process.env.CLAUDE_CONFIG_DIR = old; await box.close(); }
}));
test('title sanitation rejects invalid Unicode and applies the UTF-8 byte limit', () => {
  assert.equal(cleanSessionTitle('\ud800'), undefined); assert.equal(cleanSessionTitle('é'.repeat(257)), undefined);
  assert.equal(cleanSessionTitle(' Good\u202e\u0000 title '), 'Good title');
});

const indexLine = (title: string, id = ID) => line({ id, thread_name: title, updated_at: '2026-10-29T00:00:00Z' });
test('Codex resolves the latest title-only index entry for the exact session', async () => fixture(async f => {
  const root = path.join(f.home, '.codex'); await fs.mkdir(root, { mode: 0o700 });
  const file = path.join(root, 'session_index.jsonl');
  await fs.writeFile(file, indexLine('Old title') + indexLine('Different chat', OTHER) + indexLine('Review checkout changes'), { mode: 0o644 });
  const before = await fs.readFile(file);
  assert.deepEqual(await lookupCodexSessionTitle(event, { home: f.home, environment: {} }), { title: 'Review checkout changes', source: 'codex-index' });
  assert.deepEqual(await fs.readFile(file), before);
}));
test('large Codex indexes use only their latest 256 KiB instead of failing the size check', async () => fixture(async f => {
  const root = path.join(f.home, '.codex'); await fs.mkdir(root, { mode: 0o700 });
  const file = path.join(root, 'session_index.jsonl');
  await fs.writeFile(file, indexLine('Older exact title') + indexLine('Other title', OTHER).repeat(3000) + indexLine('Fresh large-index title'), { mode: 0o600 });
  const promises = require('node:fs/promises') as { open: typeof fs.open }, open = promises.open, reads: { length: number; position: number }[] = [];
  promises.open = (async (...args: Parameters<typeof fs.open>) => {
    const handle = await open(...args); if (args[0] !== file) return handle;
    const original = handle.read.bind(handle);
    handle.read = ((...values: any[]) => { reads.push({ length: values[2], position: values[3] }); return (original as any)(...values); }) as typeof handle.read;
    return handle;
  }) as typeof fs.open;
  try { assert.equal((await lookupCodexSessionTitle(event, { home: f.home, environment: {} }))?.title, 'Fresh large-index title'); }
  finally { promises.open = open; }
  assert.equal(reads.length, 1); assert.equal(reads[0]?.length, CODEX_INDEX_BYTES); assert.ok(reads[0]!.position > 0);
}));
test('Codex duplicate keys, prompt fields and UUID/workspace labels never become display subjects', async () => fixture(async f => {
  const root = path.join(f.home, '.codex'); await fs.mkdir(root, { mode: 0o700 });
  const file = path.join(root, 'session_index.jsonl');
  const invalid = [
    `{"id":"${OTHER}","id":"${ID}","thread_name":"Duplicate identity","updated_at":"now"}\n`,
    line({ id: ID, thread_name: 'Unknown fields', updated_at: 'now', prompt: 'Never read this prompt' }),
    line({ id: ID, thread_name: { nested: 'Never parse' }, updated_at: 'now' }),
    indexLine('project'), indexLine('/work/project'), indexLine(`ID: ${ID}`), indexLine(ID.replaceAll('-', ''))
  ];
  await fs.writeFile(file, invalid.join(''), { mode: 0o600 });
  assert.equal(await lookupCodexSessionTitle(event, { home: f.home, environment: {} }), undefined);
  await fs.writeFile(file, indexLine('Earlier valid subject') + invalid.join(''), { mode: 0o600 });
  assert.equal((await lookupCodexSessionTitle(event, { home: f.home, environment: {} }))?.title, 'Earlier valid subject');
}));
test('Codex accepts a complete final metadata entry without newline and ignores partial tail boundaries', async () => fixture(async f => {
  const root = path.join(f.home, '.codex'); await fs.mkdir(root, { mode: 0o700 });
  const file = path.join(root, 'session_index.jsonl');
  await fs.writeFile(file, indexLine('Complete final title').trimEnd(), { mode: 0o600 });
  assert.equal((await lookupCodexSessionTitle(event, { home: f.home, environment: {} }))?.title, 'Complete final title');
  await fs.writeFile(file, 'x'.repeat(CODEX_INDEX_BYTES) + indexLine('Not a standalone record'), { mode: 0o600 });
  assert.equal(await lookupCodexSessionTitle(event, { home: f.home, environment: {} }), undefined);
}));
test('Codex config overrides are absolute and no symlinked or unsafe index is followed', async () => fixture(async f => {
  const root = path.join(f.home, 'codex-config'); await fs.mkdir(root, { mode: 0o700 });
  const file = path.join(root, 'session_index.jsonl'); await fs.writeFile(file, indexLine('Configured subject'), { mode: 0o600 });
  const lookup = () => lookupCodexSessionTitle(event, { home: f.home, environment: { CODEX_HOME: root } });
  assert.equal((await lookup())?.title, 'Configured subject');
  assert.equal(await lookupCodexSessionTitle(event, { home: f.home, environment: { CODEX_HOME: 'relative' } }), undefined);
  if (process.platform !== 'win32') { await fs.chmod(file, 0o666); assert.equal(await lookup(), undefined); await fs.chmod(file, 0o600); }
  const original = path.join(root, 'original'); await fs.rename(file, original); await fs.symlink(original, file);
  assert.equal(await lookup(), undefined);
}));
test('display subjects reject workspace and identity labels without rejecting real descriptive titles', () => {
  const context = { session_id: ID, cwd: '/work/Example_Workspace/' };
  for (const candidate of ['example_workspace', 'EXAMPLE_WORKSPACE', '/work/example_workspace/', '\\work\\Example_Workspace', ID, OTHER,
    'Session ' + ID, 'Session ID: [' + ID + ']', 'ID: <' + ID + '>', `UUID: [${ID}]`, `Session UUID: (${ID})`, `{${ID}}`, ID.replaceAll('-', '')]) assert.equal(displaySessionTitle(candidate, context), undefined, candidate);
  assert.equal(displaySessionTitle('ID: local-demo', { session_id: 'local-demo' }), undefined);
  assert.equal(displaySessionTitle(`Review ${ID} timestamps`, context), `Review ${ID} timestamps`);
  assert.equal(displaySessionTitle('Investigate Example_Workspace hooks', context), 'Investigate Example_Workspace hooks');
});
test('an invalid Codex explicit/cache label permits fresh lookup while a valid explicit title keeps priority', async () => fixture(async f => {
  const old = process.env.CODEX_HOME, root = path.join(f.home, '.codex'), runtime = path.join(f.home, 'runtime'), box = new Mailbox(runtime);
  await fs.mkdir(root, { mode: 0o700 }); process.env.CODEX_HOME = root;
  try {
    await fs.writeFile(path.join(root, 'session_index.jsonl'), indexLine('Fresh Codex subject'), { mode: 0o600 });
    await box.start(); await box.poll();
    const key = createHash('sha256').update('codex:' + ID).digest('hex');
    await write(runtime, `sessions/${key}.json`, { source: 'codex', sessionId: ID, sessionName: `ID: ${ID}`, status: 'idle', updatedAt: Date.now() / 1000 });
    for (const [explicit, expected] of [['project', 'Fresh Codex subject'], [`UUID: [${ID}]`, 'Fresh Codex subject'], ['Host supplied rename', 'Host supplied rename']] as const) {
      const response = handle(runtime, 'codex', { ...event, session_title: explicit, hook_event_name: 'PermissionRequest', tool_name: 'Read', tool_input: { file_path: '/demo.ts' } }, 3, true);
      let request;
      for (let i = 0; i < 100; i++) { request = (await box.poll()).requests[0]; if (request) break; await new Promise(resolve => setTimeout(resolve, 10)); }
      assert.equal(request?.sessionName, expected);
      await box.decide(request!.id, 'deny'); await response;
    }
    await fs.unlink(path.join(root, 'session_index.jsonl'));
    await write(runtime, `sessions/${key}.json`, { source: 'codex', sessionId: ID, sessionName: 'project', status: 'idle', updatedAt: Date.now() / 1000 });
    const response = handle(runtime, 'codex', { ...event, session_title: `Session ${ID}`, hook_event_name: 'PermissionRequest', tool_name: 'Read', tool_input: { file_path: '/demo.ts' } }, 3, true);
    let request;
    for (let i = 0; i < 100; i++) { request = (await box.poll()).requests[0]; if (request) break; await new Promise(resolve => setTimeout(resolve, 10)); }
    assert.equal(request?.sessionName, undefined); assert.equal(requestTitle(request!), 'Task: Demo only. No command will run.');
    await box.decide(request!.id, 'deny'); await response;
  } finally { if (old === undefined) delete process.env.CODEX_HOME; else process.env.CODEX_HOME = old; await box.close(); }
}));
