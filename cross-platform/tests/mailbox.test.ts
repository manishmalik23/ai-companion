import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import nativeFs from 'node:fs/promises';
import timers from 'node:timers/promises';
import { performance } from 'node:perf_hooks';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { Mailbox, alive, read, write } from '../src/mailbox';
import { handle, HookEvent, config, handleTelemetryDecision } from '../src/hook';
import { Request, seconds, Session, validRequest } from '../src/protocol';
import { hookArguments } from '../src/platform-config';

const event: HookEvent = { hook_event_name: 'PermissionRequest', session_id: 'test-session', turn_id: 'turn-1',
  tool_use_id: 'tool-1', tool_name: 'exec_command', tool_input: { cmd: 'never execute this' } };
async function atomicFixture(t: TestContext, platform: NodeJS.Platform, run: (root: string, delays: number[], rename: typeof fs.rename, clock: { now: number; onDelay?: () => void }) => Promise<void>): Promise<void> {
  const root = await fs.mkdtemp(path.join(os.tmpdir(),'pip-atomic-check-'));
  const descriptor = Object.getOwnPropertyDescriptor(process,'platform')!, rename = nativeFs.rename, delays: number[] = [], clock: { now: number; onDelay?: () => void } = { now: 0 };
  try {
    await fs.writeFile(path.join(root,'heartbeat.json'),'{"updatedAt":1}',{mode:0o600});
    Object.defineProperty(process,'platform',{...descriptor,value:platform});
    t.mock.method(performance,'now',()=>clock.now);
    t.mock.method(timers,'setTimeout',async <T = void>(milliseconds?: number,value?: T) => { const wait = milliseconds || 0; delays.push(wait); clock.now += wait; clock.onDelay?.(); return value as T; });
    await run(root,delays,rename,clock);
  } finally {
    Object.defineProperty(process,'platform',descriptor);t.mock.restoreAll();
    await fs.rm(root,{recursive:true,force:true});await fs.rm(root+'-original',{recursive:true,force:true});
  }
}
test('Windows atomic writes reuse the original temporary bytes through transient sharing failures',async t=>{
  await atomicFixture(t,'win32',async(root,delays,rename)=>{
    const sources:string[]=[],target=path.join(root,'heartbeat.json');let attempts=0;
    t.mock.method(nativeFs,'rename',async(source:Parameters<typeof fs.rename>[0],destination:Parameters<typeof fs.rename>[1])=>{
      sources.push(String(source));attempts++;
      assert.equal(await fs.readFile(target,'utf8'),'{"updatedAt":1}','readers retain the complete old value until replacement');
      assert.equal(await fs.readFile(source,'utf8'),'{"updatedAt":2}');
      if(attempts<4)throw Object.assign(new Error('sharing'),{code:['EPERM','EACCES','EBUSY'][attempts-1]});
      await rename(source,destination);
    });
    await write(root,'heartbeat.json',{updatedAt:2});
    assert.equal(new Set(sources).size,1);assert.equal(attempts,4);assert.deepEqual(delays,[10,20,40]);
    assert.equal(await fs.readFile(target,'utf8'),'{"updatedAt":2}');assert.deepEqual(await fs.readdir(root),['heartbeat.json']);
  });
});
test('Windows sharing retry exhaustion preserves the destination and removes only its own temporary file',async t=>{
  await atomicFixture(t,'win32',async(root,delays)=>{
    let attempts=0;const denied=Object.assign(new Error('denied'),{code:'EPERM'});
    t.mock.method(nativeFs,'rename',async()=>{attempts++;throw denied;});
    await assert.rejects(write(root,'heartbeat.json',{updatedAt:2}),error=>error===denied);
    assert.equal(attempts,6);assert.deepEqual(delays,[10,20,40,80,100]);assert.equal(delays.reduce((a,b)=>a+b),250);
    assert.equal(await fs.readFile(path.join(root,'heartbeat.json'),'utf8'),'{"updatedAt":1}');assert.deepEqual(await fs.readdir(root),['heartbeat.json']);
  });
});
test('POSIX failures and non-sharing Windows failures do not retry atomic replacement',async t=>{
  const cases:[NodeJS.Platform,string][]=[['win32','ENOENT'],['win32','ENOSPC']];
  // Exercise POSIX ownership rules on the POSIX runners, where getuid and Unix modes exist.
  if(process.platform!=='win32')cases.push(['darwin','EPERM'],['linux','EACCES']);
  for(const [platform,code] of cases){
    await atomicFixture(t,platform,async(root,delays)=>{
      let attempts=0;const failure=Object.assign(new Error(code),{code});
      t.mock.method(nativeFs,'rename',async()=>{attempts++;throw failure;});
      await assert.rejects(write(root,'heartbeat.json',{}),error=>error===failure);
      assert.equal(attempts,1);assert.deepEqual(delays,[]);assert.deepEqual(await fs.readdir(root),['heartbeat.json']);
    });
  }
});
test('an overdue Windows timer cannot schedule an atomic rename beyond its monotonic retry deadline',async t=>{
  await atomicFixture(t,'win32',async(root,delays,_rename,clock)=>{
    let attempts=0;const denied=Object.assign(new Error('busy'),{code:'EBUSY'});
    clock.onDelay=()=>{clock.now=301;};
    t.mock.method(nativeFs,'rename',async()=>{attempts++;throw denied;});
    await assert.rejects(write(root,'heartbeat.json',{}),error=>error===denied);
    assert.equal(attempts,1);assert.deepEqual(delays,[10]);assert.deepEqual(await fs.readdir(root),['heartbeat.json']);
  });
});
test('a non-sharing error during Windows recovery stops immediately and cleans the staged file',async t=>{
  await atomicFixture(t,'win32',async(root,delays)=>{
    let attempts=0;const failure=Object.assign(new Error('disk full'),{code:'ENOSPC'});
    t.mock.method(nativeFs,'rename',async()=>{if(++attempts===1)throw Object.assign(new Error('sharing'),{code:'EPERM'});throw failure;});
    await assert.rejects(write(root,'heartbeat.json',{}),error=>error===failure);
    assert.equal(attempts,2);assert.deepEqual(delays,[10]);assert.deepEqual(await fs.readdir(root),['heartbeat.json']);
    assert.equal(await fs.readFile(path.join(root,'heartbeat.json'),'utf8'),'{"updatedAt":1}');
  });
});
test('Windows recovery rejects replaced, mutated, newly appeared or removed destinations',async t=>{
  for(const change of ['replace','mutate','appear','remove'])await atomicFixture(t,'win32',async(root,_delays,rename)=>{
    const target=path.join(root,'heartbeat.json');if(change==='appear')await fs.unlink(target);
    let attempts=0;
    t.mock.method(nativeFs,'rename',async()=>{
      attempts++;
      if(change==='replace'){await rename(target,path.join(root,'old.json'));await fs.writeFile(target,'new owner');}
      else if(change==='remove')await fs.unlink(target);
      else await fs.writeFile(target,'new owner');
      throw Object.assign(new Error('sharing'),{code:'EPERM'});
    });
    await assert.rejects(write(root,'heartbeat.json',{}),/target changed/);assert.equal(attempts,1);
    if(change==='remove')await assert.rejects(fs.lstat(target),{code:'ENOENT'});else assert.equal(await fs.readFile(target,'utf8'),'new owner');
    assert.equal((await fs.readdir(root)).some(name=>name.startsWith('.write-')),false);
  });
});
test('Windows recovery rejects a symlink destination without following or replacing it',async t=>{
  await atomicFixture(t,'win32',async(root,_delays)=>{
    const target=path.join(root,'heartbeat.json'),lstat=nativeFs.lstat;let attempts=0;
    t.mock.method(nativeFs,'rename',async()=>{attempts++;throw Object.assign(new Error('sharing'),{code:'EPERM'});});
    t.mock.method(nativeFs,'lstat',async(...args:Parameters<typeof nativeFs.lstat>)=>{
      const stat=await lstat(...args);
      if(attempts && String(args[0])===target)return Object.assign(Object.create(stat),{isSymbolicLink:()=>true,isFile:()=>false});
      return stat;
    });
    await assert.rejects(write(root,'heartbeat.json',{}),/target changed/);assert.equal(attempts,1);
    assert.equal(await fs.readFile(target,'utf8'),'{"updatedAt":1}');
  });
});
test('Windows recovery leaves substituted or modified temporary paths untouched',async t=>{
  for(const change of ['replace','mutate'])await atomicFixture(t,'win32',async(root,_delays,rename)=>{
    let source='',attempts=0;
    t.mock.method(nativeFs,'rename',async(from:Parameters<typeof fs.rename>[0])=>{
      source=String(from);attempts++;
      if(change==='replace')await rename(from,path.join(root,'original-staged.json'));
      await fs.writeFile(from,'replacement temporary');
      throw Object.assign(new Error('sharing'),{code:'EACCES'});
    });
    await assert.rejects(write(root,'heartbeat.json',{}),/temporary file changed/);assert.equal(attempts,1);
    assert.equal(await fs.readFile(source,'utf8'),'replacement temporary');assert.equal(await fs.readFile(path.join(root,'heartbeat.json'),'utf8'),'{"updatedAt":1}');
  });
});
test('Windows recovery never unlinks through a substituted root or destination parent',async t=>{
  for(const nested of [false,true])await atomicFixture(t,'win32',async(root,_delays,rename)=>{
    if(nested)await fs.mkdir(path.join(root,'requests'));
    const parent=nested?path.join(root,'requests'):root,backup=nested?path.join(root,'original-parent'):root+'-original';let source='',attempts=0;
    t.mock.method(nativeFs,'rename',async(from:Parameters<typeof fs.rename>[0])=>{
      source=String(from);attempts++;
      await rename(parent,backup);await fs.mkdir(parent);
      await fs.writeFile(source,'replacement in new parent');
      throw Object.assign(new Error('sharing'),{code:'EPERM'});
    });
    await assert.rejects(write(root,nested?'requests/new.json':'heartbeat.json',{}),/directory changed/);assert.equal(attempts,1);
    assert.equal(await fs.readFile(source,'utf8'),'replacement in new parent');
    assert.equal(await fs.readFile(path.join(backup,path.basename(source)),'utf8'),'{}');
  });
});
async function fixture(run: (box: Mailbox) => Promise<void>): Promise<void> {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pip-ts-check-'));
  const box = new Mailbox(root);
  try { await box.start(); await box.poll(); await run(box); }
  finally { await box.close(); await fs.rm(root, { recursive: true, force: true }); }
}
async function pending(box: Mailbox, count = 1) {
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    const state = await box.poll();
    if (state.requests.length === count) return state.requests;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error('Request did not arrive.');
}
function handoffRequest():Request{
  const now=seconds();return{schemaVersion:1,id:'a'.repeat(32),source:'codex',sourceLabel:'Codex',sessionId:'handoff-session',
    toolName:'exec_command',cwd:'/fixture',reason:'Review command',detailText:'{}',createdAt:now,expiresAt:now+120,
    canRespond:true,canDefer:true,isDemo:true,kind:'permission',correlation:{sessionId:'handoff-session'}};
}
const sessionRecord=(source:string,id:string)=>`sessions/${createHash('sha256').update(`${source}:${id}`).digest('hex')}.json`;
for(const source of ['claude','codex'] as const)test(`${source} permission handoff unblocks the hook without an allow, deny or answer`,async()=>{
  await fixture(async box=>{
    const response=handle(box.root,source,event,3),request=(await pending(box))[0]!;
    assert.equal(request.kind,'permission');assert.equal(request.canDefer,true);
    await box.defer(request.id,JSON.stringify(request));assert.equal(await response,undefined);
    assert.deepEqual((await box.poll()).requests,[]);
    const state=await read(box.root,sessionRecord(source,request.sessionId)) as Session;
    assert.equal(state.status,'attention');assert.equal(state.message,'Continue in the original app');
    assert.deepEqual(await fs.readdir(path.join(box.root,'decisions')),[]);
  });
});
test('permission handoff preserves the exact newer attention publication and its queued approval',async()=>{
  await fixture(async box=>{
    const first=handle(box.root,'codex',event,3),request=(await pending(box))[0]!;
    const firstState=await read(box.root,sessionRecord('codex',event.session_id)) as Session;
    const second=handle(box.root,'codex',{...event,tool_use_id:'newer-tool',turn_id:'newer-turn'},3);
    const requests=await pending(box,2),other=requests.find(value=>value.id!==request.id)!;
    const newer=await read(box.root,sessionRecord('codex',event.session_id)) as Session;
    assert.ok(newer.updatedAt>firstState.updatedAt);assert.equal(newer.status,'attention');
    await box.defer(request.id,JSON.stringify(request));assert.equal(await first,undefined);
    assert.deepEqual(await read(box.root,sessionRecord('codex',event.session_id)),newer);
    assert.deepEqual((await box.poll()).requests,[other]);
    await box.decide(other.id,'deny');assert.equal((await second as any).hookSpecificOutput.decision.behavior,'deny');
  });
});
test('permission handoff preserves a newer source lifecycle status and timestamp',async()=>{
  await fixture(async box=>{
    const response=handle(box.root,'codex',event,3),request=(await pending(box))[0]!;
    await handle(box.root,'codex',{hook_event_name:'UserPromptSubmit',session_id:event.session_id,turn_id:'new-turn'});
    const newer=await read(box.root,sessionRecord('codex',event.session_id)) as Session;
    assert.equal(newer.status,'working');
    await box.defer(request.id,JSON.stringify(request));assert.equal(await response,undefined);
    assert.deepEqual(await read(box.root,sessionRecord('codex',event.session_id)),newer);
  });
});
test('older permissions cannot defer and remain answerable in Pip',async()=>{
  for(const canDefer of [undefined,false])await fixture(async box=>{
    const request={...handoffRequest(),canDefer};await write(box.root,`requests/${request.id}.json`,request);await box.poll();
    await assert.rejects(box.defer(request.id),/does not match/);assert.equal((await box.poll()).requests.length,1);
    await box.decide(request.id,'deny');assert.deepEqual((await box.poll()).requests,[]);
  });
});
test('explicit handoff snapshots cannot be refreshed away by concurrent polling',async()=>{
  await fixture(async box=>{
    const request=handoffRequest(),snapshot=JSON.stringify(request);await write(box.root,`requests/${request.id}.json`,request);await box.poll();
    const changed={...request,reason:'Changed while the chat opened'};await write(box.root,`requests/${request.id}.json`,changed);await box.poll();
    await assert.rejects(box.defer(request.id,snapshot),/changed/);
    assert.deepEqual((await box.poll()).requests,[changed]);assert.deepEqual(await fs.readdir(path.join(box.root,'decisions')),[]);
  });
});
test('notice handoff uses its exact snapshot and preserves every other queued approval',async()=>{
  await fixture(async box=>{
    const notice={...handoffRequest(),kind:'notice' as const,canRespond:false,canDefer:undefined},other={...handoffRequest(),id:'b'.repeat(32)};
    await write(box.root,`requests/${notice.id}.json`,notice);await write(box.root,`requests/${other.id}.json`,other);await box.poll();
    const snapshot=JSON.stringify(notice),changed={...notice,reason:'Updated notice'};await write(box.root,`requests/${notice.id}.json`,changed);await box.poll();
    await assert.rejects(box.dismiss(notice.id,snapshot),/changed/);
    await box.dismiss(notice.id,JSON.stringify(changed));assert.deepEqual((await box.poll()).requests,[other]);
    assert.deepEqual(await fs.readdir(path.join(box.root,'decisions')),[]);
  });
});
test('handoff never overwrites a decision made while the source chat was opening',async()=>{
  await fixture(async box=>{
    const request=handoffRequest(),snapshot=JSON.stringify(request);await write(box.root,`requests/${request.id}.json`,request);await box.poll();
    await box.decide(request.id,'deny');await assert.rejects(box.defer(request.id,snapshot),/Already decided/);
    assert.equal((await read(box.root,`decisions/${request.id}.json`) as {decision:string}).decision,'deny');
  });
});
for (const decision of ['allow', 'deny'] as const) test(`${decision} returns the matching hook decision and removes its card`, async () => {
  await fixture(async box => {
    const response = handle(box.root, 'codex', event, 3);
    const requests = await pending(box);
    await box.decide(requests[0]!.id, decision);
    assert.equal((await box.poll()).requests.length, 0);
    assert.equal((await response as any).hookSpecificOutput.decision.behavior, decision);
    assert.equal((await box.poll()).requests.length, 0);
  });
});
test('two concurrent requests cannot answer each other', async () => {
  await fixture(async box => {
    const a = handle(box.root, 'codex', event, 3);
    const b = handle(box.root, 'claude', { ...event, session_id: 'other-session' }, 3);
    const requests = await pending(box, 2);
    const codex = requests.find(r => r.source === 'codex')!, claude = requests.find(r => r.source === 'claude')!;
    await box.decide(codex.id, 'allow'); await box.decide(claude.id, 'deny');
    assert.equal((await a as any).hookSpecificOutput.decision.behavior, 'allow');
    assert.equal((await b as any).hookSpecificOutput.decision.behavior, 'deny');
  });
});
test('changed request snapshots cannot be approved', async () => {
  await fixture(async box => {
    const response = handle(box.root, 'codex', event, 1);
    const r = (await pending(box))[0]!;
    await write(box.root, `requests/${r.id}.json`, { ...r, detailText: 'different command' });
    await assert.rejects(box.decide(r.id, 'allow'), /changed/);
    assert.equal(await response, undefined);
  });
});
test('timeout and missing companion return no approval', async () => {
  await fixture(async box => {
    assert.equal(await handle(box.root, 'codex', event, .15), undefined);
    const state=await read(box.root,sessionRecord('codex',event.session_id)) as Session;
    assert.equal(state.status,'attention');assert.equal(state.message,'Continue in the original app');
    await box.close(); assert.equal(await alive(box.root), false);
    assert.equal(await handle(box.root, 'codex', event, 1), undefined);
  });
});
test('completion only clears the identified tool and updates working state', async () => {
  await fixture(async box => {
    const a = handle(box.root, 'codex', event, 3);
    const b = handle(box.root, 'codex', { ...event, tool_use_id: 'tool-2' }, 3);
    await pending(box, 2);
    await handle(box.root, 'codex', { ...event, hook_event_name: 'PostToolUse' });
    const r = (await pending(box))[0]!;
    assert.equal(r.correlation.toolUseId, 'tool-2'); assert.equal(await a, undefined);
    await box.decide(r.id, 'deny'); await b;
    assert.equal((await box.poll()).working, true);
    await handle(box.root, 'codex', { ...event, hook_event_name: 'Stop' });
    assert.equal((await box.poll()).working, false);
  });
});
test('a child-agent stop cannot clear the main-agent card', async () => {
  await fixture(async box => {
    const response = handle(box.root, 'codex', event, 3);
    const r = (await pending(box))[0]!;
    await handle(box.root, 'codex', { ...event, hook_event_name: 'Stop', agent_id: 'child' });
    assert.equal((await box.poll()).requests.length, 1);
    await box.decide(r.id, 'deny'); await response;
  });
});
test('invalid and expired requests are ignored', async () => {
  await fixture(async box => {
    const id = 'a'.repeat(32);
    await write(box.root, `requests/${id}.json`, { id, schemaVersion: 1, expiresAt: seconds() - 1 });
    assert.equal((await box.poll()).requests.length, 0);
    assert.equal(validRequest({}), false);
  });
});
test('an already completed tool cannot publish a stale approval card, but Stop can continue the same turn', async () => {
  await fixture(async box => {
    await handle(box.root, 'codex', { ...event, hook_event_name: 'PostToolUse' });
    assert.equal(await handle(box.root, 'codex', event, .2), undefined);
    await handle(box.root, 'codex', { ...event, hook_event_name: 'Stop' });
    const next = handle(box.root, 'codex', { ...event, tool_use_id: 'different-tool' }, 3);
    const request = (await pending(box))[0]!;
    await box.decide(request.id, 'deny');
    assert.equal((await next as any).hookSpecificOutput.decision.behavior, 'deny');
    assert.equal((await box.poll()).requests.length, 0);
    assert.equal((await box.poll()).working, true);
  });
});

const questionEvent: HookEvent = { ...event, hook_event_name: 'PreToolUse', tool_name: 'AskUserQuestion', tool_use_id: 'question-tool',
  tool_input: { questions: [
    { question: 'Which language?', header: 'Language', options: [{ label: 'TypeScript', description: 'Use the current workspace.' }, { label: 'Python' }], multiSelect: false },
    { question: 'Which features?', header: 'Features', options: [{ label: 'Approvals' }, { label: 'Questions' }], multiSelect: true }
  ], metadata: { preserve: 'original argument' } } };

test('Claude answers include typed Other text and preserve every original tool argument', async () => {
  await fixture(async box => {
    const response = handle(box.root, 'claude', questionEvent, 3);
    const request = (await pending(box))[0]!;
    assert.equal(request.kind, 'question');
    assert.deepEqual(request.questions, (questionEvent.tool_input as any).questions);
    const answers = { 'Which language?': 'Rust with a small TypeScript UI', 'Which features?': 'Approvals, Questions' };
    await box.answer(request.id, answers);
    assert.equal((await box.poll()).requests.length, 0);
    const result = (await response as any).hookSpecificOutput;
    assert.equal(result.hookEventName, 'PreToolUse'); assert.equal(result.permissionDecision, 'allow');
    assert.deepEqual(result.updatedInput, { ...(questionEvent.tool_input as object), answers });
  });
});
test('question responses must answer every exact question, and permission decisions cannot answer them', async () => {
  await fixture(async box => {
    const response = handle(box.root, 'claude', questionEvent, 3);
    const request = (await pending(box))[0]!;
    await assert.rejects(box.decide(request.id, 'allow'), /does not match/);
    await assert.rejects(box.answer(request.id, { 'Which language?': 'TypeScript' }), /does not match/);
    await assert.rejects(box.answer(request.id, { 'Which language?': '', 'Which features?': 'Approvals' }), /does not match/);
    await assert.rejects(box.answer(request.id, { 'Which language?': 'x'.repeat(2500), 'Which features?': 'Approvals' }), /does not match/);
    assert.equal((await box.poll()).requests.length, 1);
    await box.defer(request.id); assert.equal(await response, undefined);
    assert.equal((await box.poll()).requests.length, 0);
  });
});
test('deferring a question returns no allow, deny, answer or modified input', async () => {
  await fixture(async box => {
    const response = handle(box.root, 'claude', questionEvent, 3);
    const request = (await pending(box))[0]!;
    await box.defer(request.id);
    assert.equal(await response, undefined);
    await assert.rejects(read(box.root, `decisions/${request.id}.json`));
  });
});
test('a cancelled host question removes its card and returns no tool control', async () => {
  await fixture(async box => {
    const cancellation = new AbortController();
    const response = handle(box.root, 'claude', questionEvent, 3, false, false, cancellation.signal);
    await pending(box);
    cancellation.abort();
    assert.equal(await response, undefined);
    assert.equal((await box.poll()).requests.length, 0);
  });
});
test('changed question snapshots cannot accept a stale typed answer', async () => {
  await fixture(async box => {
    const response = handle(box.root, 'claude', questionEvent, 3);
    const request = (await pending(box))[0]!;
    await write(box.root, `requests/${request.id}.json`, { ...request, reason: 'Changed question context' });
    await assert.rejects(box.answer(request.id, { 'Which language?': 'TypeScript', 'Which features?': 'Approvals' }), /changed/);
    assert.equal(await response, undefined);
  });
});
test('malformed questions and excessive nesting never publish answerable cards', async () => {
  await fixture(async box => {
    for (const questions of [[], [{ question: 'One option?', options: [{ label: 'Only one' }] }],
      [{ question: 'Duplicate options?', options: [{ label: 'Same' }, { label: 'Same' }] }]]) {
      await assert.rejects(handle(box.root, 'claude', { ...questionEvent, tool_input: { questions } }, 1), /Invalid questions/);
    }
    let deep: unknown = {};
    for (let i = 0; i < 34; i++) deep = { child: deep };
    await assert.rejects(handle(box.root, 'claude', { ...event, tool_input: deep }), /complex/);
    assert.equal((await box.poll()).requests.length, 0);
  });
});
test('Codex async question acknowledgement keeps its notice until lifecycle completion', async () => {
  await fixture(async box => {
    const question: HookEvent = { ...questionEvent, tool_name: 'functions.request_user_input_async' };
    assert.equal(await handle(box.root, 'codex', question), undefined);
    const request = (await pending(box))[0]!;
    assert.equal(request.kind, 'notice'); assert.equal(request.canRespond, false);
    assert.equal(request.canDefer,undefined);assert.equal(request.questions,undefined);
    await assert.rejects(box.answer(request.id, { 'Which language?': 'TypeScript', 'Which features?': 'Questions' }), /changed/);
    await assert.rejects(box.decide(request.id, 'allow'), /changed/);
    await handle(box.root, 'codex', { ...question, hook_event_name: 'PostToolUse', tool_input: { accepted: true } });
    assert.equal((await box.poll()).requests.length, 1);
    await handle(box.root, 'codex', { ...question, hook_event_name: 'Stop' });
    assert.equal((await box.poll()).requests.length, 0);
  });
});
test('Codex async acknowledgement before the notice cannot suppress publication', async () => {
  await fixture(async box => {
    const question: HookEvent = { ...questionEvent, tool_name: 'request_user_input_async' };
    await handle(box.root, 'codex', { ...question, hook_event_name: 'PostToolUse' });
    await handle(box.root, 'codex', question);
    const request = (await pending(box))[0]!;
    await box.dismiss(request.id);
    assert.equal((await box.poll()).requests.length, 0);
    await assert.rejects(read(box.root, `decisions/${request.id}.json`));
  });
});
test('a synchronous Codex question clears by exact tool id despite changed output input', async () => {
  await fixture(async box => {
    const question: HookEvent = { ...questionEvent, tool_name: 'functions.request_user_input' };
    await handle(box.root, 'codex', question); await pending(box);
    await handle(box.root, 'codex', { ...question, hook_event_name: 'PostToolUse', tool_input: { answers: 'source-only answer' } });
    assert.equal((await box.poll()).requests.length, 0);
  });
});
test('permission notifications are notice-only and dismissal never creates a source decision', async () => {
  await fixture(async box => {
    await handle(box.root, 'claude', { hook_event_name: 'Notification', session_id: 'notify', notification_type: 'permission_prompt',
      title: 'Network access required', message: 'Continue in the original agent.' });
    const request = (await pending(box))[0]!;
    assert.equal(request.kind, 'notice'); assert.equal(request.reason, 'Network access required');
    await assert.rejects(box.defer(request.id), /changed/);
    await box.dismiss(request.id);
    assert.equal((await box.poll()).requests.length, 0);
    await assert.rejects(read(box.root, `decisions/${request.id}.json`));
  });
});
test('exact completion tolerates omitted optional scope but rejects explicitly conflicting agents or prompts', async () => {
  await fixture(async box => {
    const scoped = { ...event, prompt_id: 'prompt-one', agent_id: 'agent-one', agent_type: 'main' };
    const response = handle(box.root, 'claude', scoped, 3); await pending(box);
    await handle(box.root, 'claude', { ...scoped, hook_event_name: 'PostToolUse', agent_id: 'agent-two' });
    assert.equal((await box.poll()).requests.length, 1);
    await handle(box.root, 'claude', { ...scoped, hook_event_name: 'PostToolUse', prompt_id: 'another-prompt' });
    assert.equal((await box.poll()).requests.length, 1);
    await handle(box.root, 'claude', { ...event, hook_event_name: 'PostToolUse' });
    assert.equal((await box.poll()).requests.length, 0); assert.equal(await response, undefined);
  });
});
test('a batch completion retires only the completed call while another approval remains', async () => {
  await fixture(async box => {
    const a = handle(box.root, 'claude', event, 3);
    const b = handle(box.root, 'claude', { ...event, tool_use_id: 'second-tool' }, 3);
    await pending(box, 2);
    await handle(box.root, 'claude', { hook_event_name: 'PostToolBatch', session_id: event.session_id, turn_id: event.turn_id,
      tool_calls: [{ tool_use_id: event.tool_use_id, tool_name: event.tool_name, tool_input: event.tool_input }] });
    const request = (await pending(box))[0]!;
    assert.equal(request.correlation.toolUseId, 'second-tool'); assert.equal(await a, undefined);
    await box.decide(request.id, 'deny'); await b;
  });
});
test('source approval telemetry clears exactly its bound card while the action remains running', async () => {
  await fixture(async box => {
    const first = { ...event, tool_name: 'Bash', tool_use_id: 'first-tool', prompt_id: 'prompt-one', tool_input: { command: 'yarn first' } };
    const second = { ...first, tool_use_id: 'second-tool', tool_input: { command: 'yarn second' } };
    await handle(box.root, 'claude', { ...first, hook_event_name: 'PreToolUse' }, 3, false, true);
    await handle(box.root, 'claude', { ...second, hook_event_name: 'PreToolUse' }, 3, false, true);
    const a = handle(box.root, 'claude', { ...first, tool_use_id: undefined }, 3);
    const b = handle(box.root, 'claude', { ...second, tool_use_id: undefined }, 3);
    const requests = await pending(box, 2);
    assert.deepEqual(new Set(requests.map(r => r.correlation.toolUseId)), new Set(['first-tool', 'second-tool']));
    await handleTelemetryDecision(box.root, { session_id: first.session_id, tool_use_id: 'first-tool', prompt_id: 'prompt-one',
      decision: 'accept', source: 'user_temporary', decided_at: seconds() });
    const pendingSecond = (await pending(box))[0]!;
    assert.equal(pendingSecond.correlation.toolUseId, 'second-tool');
    assert.equal(await a, undefined); assert.equal((await box.poll()).working, true);
    await box.decide(pendingSecond.id, 'deny'); await b;
  });
});
test('unbound, stale, wrong-prompt, malformed and future telemetry cannot resolve a request', async () => {
  await fixture(async box => {
    const tool = { ...event, tool_name: 'Bash', prompt_id: 'prompt-one' };
    await handle(box.root, 'claude', { ...tool, hook_event_name: 'PreToolUse' }, 3, false, true);
    const response = handle(box.root, 'claude', tool, 3);
    const request = (await pending(box))[0]!;
    const decision = { session_id: tool.session_id, tool_use_id: tool.tool_use_id!, decision: 'accept' as const, source: 'user_temporary', decided_at: seconds() };
    for (const invalid of [{ ...decision, tool_use_id: 'unknown' }, { ...decision, prompt_id: 'other-prompt' },
      { ...decision, decided_at: seconds() - 60 }, { ...decision, decided_at: seconds() + 10 }, { ...decision, source: 'not-a-user-decision' }]) {
      await handleTelemetryDecision(box.root, invalid);
      assert.equal((await box.poll()).requests.length, 1);
    }
    await box.decide(request.id, 'deny'); await response;
  });
});
test('identical concurrent calls without shared tool identities cannot bind a notification to one guessed owner', async () => {
  await fixture(async box => {
    for (const id of ['call-one', 'call-two']) await handle(box.root, 'claude', { ...event, hook_event_name: 'PreToolUse', tool_use_id: id }, 3, false, true);
    await handle(box.root, 'claude', { hook_event_name: 'Notification', session_id: event.session_id,
      notification_type: 'permission_prompt', title: 'Permission required' });
    const request = (await pending(box))[0]!;
    assert.equal(request.correlation.toolUseId, undefined);
    await handleTelemetryDecision(box.root, { session_id: event.session_id, tool_use_id: 'call-one', decision: 'accept', source: 'user_temporary', decided_at: seconds() });
    assert.equal((await box.poll()).requests.length, 1);
    await box.dismiss(request.id);
  });
});
test('request reasons and explicit session labels stay bounded and no arbitrary navigation URL is accepted', async () => {
  await fixture(async box => {
    const response = handle(box.root, 'claude', { ...event, session_name: '  Demo\n session  ', session_host: 'https://example.invalid/evil',
      tool_input: { command: 'yarn test', description: 'Run the workspace tests' } }, 3);
    const request = (await pending(box))[0]!;
    assert.equal(request.reason, 'Run the workspace tests'); assert.equal(request.sessionName, 'Demo session');
    assert.equal(request.sessionHost, undefined);
    await box.decide(request.id, 'deny'); await response;
  });
});
test('mailbox relative paths cannot escape the private runtime', async () => {
  await fixture(async box => {
    await assert.rejects(read(box.root, '../outside.json'), /path/);
    await assert.rejects(write(box.root, '../outside.json', {}), /path/);
    await assert.rejects(read(box.root, '/absolute.json'), /path/);
  });
});

test('a confirmed Codex interruption suppresses a delayed request for that exact turn', async () => {
  await fixture(async box => {
    await handle(box.root, 'codex', { ...event, hook_event_name: 'Interrupt' });
    assert.equal(await handle(box.root, 'codex', { ...event, tool_use_id: 'late-tool' }, .2), undefined);
    assert.equal((await box.poll()).requests.length, 0);
    const next = handle(box.root, 'codex', { ...event, turn_id: 'new-turn', tool_use_id: 'new-tool' }, 3);
    const request = (await pending(box))[0]!;
    await box.decide(request.id, 'deny'); await next;
  });
});
test('an earlier tool decision cannot retire a later permission notification for that tool', async () => {
  await fixture(async box => {
    await handle(box.root, 'claude', { ...event, hook_event_name: 'PreToolUse' }, 3, false, true);
    const earlier = seconds();
    await new Promise(resolve => setTimeout(resolve, 5));
    await handle(box.root, 'claude', { hook_event_name: 'Notification', session_id: event.session_id, notification_type: 'permission_prompt' });
    const request = (await pending(box))[0]!;
    assert.equal(request.correlation.toolUseId, event.tool_use_id);
    await handleTelemetryDecision(box.root, { session_id: event.session_id, tool_use_id: event.tool_use_id!, decision: 'accept', source: 'user_temporary', decided_at: earlier });
    assert.equal((await box.poll()).requests.length, 1);
    await box.dismiss(request.id);
  });
});

test('a real Claude question hook subprocess returns typed answers and unchanged original arguments', async () => {
  await fixture(async box => {
    const child = spawn(process.execPath, [path.join(__dirname, '../src/hook.js'), 'hook', '--source', 'claude', '--runtime', box.root], { stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '', errors = '';
    child.stdout.on('data', data => output += data); child.stderr.on('data', data => errors += data);
    const done = new Promise<number | null>((resolve, reject) => { child.on('exit', resolve); child.on('error', reject); });
    child.stdin.end(JSON.stringify(questionEvent));
    const request = (await pending(box))[0]!;
    const answers = { 'Which language?': 'Other: Rust', 'Which features?': 'Approvals, Questions' };
    await box.answer(request.id, answers);
    assert.equal(await done, 0, errors);
    assert.deepEqual(JSON.parse(output).hookSpecificOutput.updatedInput, { ...(questionEvent.tool_input as object), answers });
  });
});

test('Claude configuration uses literal executable args for questions and permission hooks', () => {
  const result = config('claude', '/example/private-runtime') as any;
  const permission = result.hooks.PermissionRequest[0].hooks[0];
  assert.equal(permission.command, process.execPath); assert.equal(permission.timeout, 130);
  assert.equal(permission.args[1], 'hook');
  assert.equal(result.hooks.PreToolUse[0].matcher, '^AskUserQuestion$');
  assert.equal(result.hooks.PreToolUse[1].hooks[0].args.at(-1), '--track-tools');
  assert.ok(result.hooks.Notification); assert.ok(result.hooks.PostToolBatch);
});
test('future, wrong-ID and malformed decisions do not hide or approve a request', async () => {
  await fixture(async box => {
    const response = handle(box.root, 'codex', event, .5);
    const r = (await pending(box))[0]!;
    for (const decision of [
      { id: r.id, decision: 'allow', decidedAt: seconds() + 10 },
      { id: 'c'.repeat(32), decision: 'allow', decidedAt: seconds() },
      { id: r.id, decision: 'always-allow', decidedAt: seconds() }
    ]) {
      await write(box.root, `decisions/${r.id}.json`, decision);
      assert.equal((await box.poll()).requests.length, 1);
    }
    assert.equal(await response, undefined);
  });
});
test('symlink substitution is rejected', { skip: process.platform === 'win32' }, async () => {
  await fixture(async box => {
    const target = path.join(box.root, 'outside.json'); await fs.writeFile(target, '{}', { mode: 0o600 });
    await fs.symlink(target, path.join(box.root, 'requests', `${'b'.repeat(32)}.json`));
    await assert.rejects(read(box.root, `requests/${'b'.repeat(32)}.json`), /Invalid/);
    assert.equal((await box.poll()).requests.length, 0);
  });
});
test('another desktop cannot own the same runtime', async () => {
  await fixture(async box => { await assert.rejects(new Mailbox(box.root).start()); });
});
test('configuration uses absolute hook paths and does not edit settings', () => {
  const result = config('codex', '/example/private-runtime') as any;
  assert.equal(result.hooks.PermissionRequest[0].hooks[0].timeout, 130);
  const args = hookArguments(result.hooks.PermissionRequest[0].hooks[0].command);
  assert.deepEqual(args, [process.execPath, path.resolve(__dirname, '../src/hook.js'), 'hook', '--source', 'codex',
    '--runtime', path.resolve('/example/private-runtime')]);
  assert.ok(path.isAbsolute(args![0]!) && path.isAbsolute(args![1]!));
});
test('real hook subprocess accepts stdin and returns stdout without executing tool text', async () => {
  await fixture(async box => {
    const sentinel = path.join(box.root, 'must-not-exist');
    const child = spawn(process.execPath, [path.join(__dirname, '../src/hook.js'), 'hook', '--source', 'codex', '--runtime', box.root], { stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '', errors = ''; child.stdout.on('data', data => output += data); child.stderr.on('data', data => errors += data);
    const done = new Promise<number | null>((resolve, reject) => { child.on('exit', resolve); child.on('error', reject); });
    child.stdin.end(JSON.stringify({ ...event, tool_input: { cmd: `touch ${sentinel}` } }));
    const r = (await pending(box))[0]!; await box.decide(r.id, 'allow');
    assert.equal(await done, 0, errors); assert.equal(JSON.parse(output).hookSpecificOutput.decision.behavior, 'allow');
    await assert.rejects(fs.stat(sentinel));
  });
});
