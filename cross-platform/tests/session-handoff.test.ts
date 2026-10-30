import test from 'node:test';
import assert from 'node:assert/strict';
import { Request, seconds, validRequest, validResponse } from '../src/protocol';
import { SessionHandoff, SessionHandoffActions } from '../src/session-handoff';
import { requestSnapshot, RequestSelection } from '../src/view-model';

function permission(): Request {
  const now=seconds();
  return {schemaVersion:1,id:'a'.repeat(32),source:'codex',sourceLabel:'Codex',sessionId:'test-session',
    toolName:'exec_command',cwd:'/fixture',reason:'Review this command',detailText:'{}',createdAt:now,expiresAt:now+120,
    canRespond:true,canDefer:true,isDemo:true,kind:'permission',correlation:{sessionId:'test-session'}};
}
function fixture(request=permission()) {
  const state={requests:[request],events:[] as string[]};
  const retire=async(id:string,snapshot:string)=>{
    assert.equal(JSON.stringify(state.requests.find(request=>request.id===id)),snapshot);
    state.requests=state.requests.filter(request=>request.id!==id);
  };
  const actions:SessionHandoffActions={
    pending:async()=>state.requests,
    destination:async()=>{state.events.push('route');return 'codex://threads/fixture';},
    navigate:async()=>{state.events.push('navigate');},
    defer:async(id,snapshot)=>{state.events.push('defer');await retire(id,snapshot);},
    dismiss:async(id,snapshot)=>{state.events.push('dismiss');await retire(id,snapshot);}
  };
  return {state,actions,handoff:new SessionHandoff(actions),request,snapshot:JSON.stringify(request)};
}
test('successful navigation defers only the clicked permission and normal queue selection preserves other approvals',async()=>{
  for(const withOther of [false,true]){
    const f=fixture(),selection=new RequestSelection(),other={...permission(),id:'b'.repeat(32)};
    if(withOther)f.state.requests.push(other);
    selection.update(f.state.requests);
    await f.handoff.open(f.request.id,f.snapshot);
    assert.deepEqual(f.state.events,['route','navigate','defer']);
    assert.deepEqual(f.state.requests,withOther?[other]:[]);
    assert.equal(selection.update(f.state.requests)?.id,withOther?other.id:undefined);
  }
});
test('structured Claude questions defer and Codex notices dismiss only after their source opens',async()=>{
  const question:Request={...permission(),source:'claude',kind:'question',canDefer:undefined,
    questions:[{question:'Choose?',options:[{label:'One'},{label:'Two'}]}]};
  const notice:Request={...permission(),kind:'notice',canRespond:false,canDefer:undefined};
  for(const request of [question,notice]){
    const f=fixture(request);await f.handoff.open(request.id,f.snapshot);
    assert.deepEqual(f.state.events,['route','navigate',request.kind==='notice'?'dismiss':'defer']);
    assert.deepEqual(f.state.requests,[]);
  }
});
test('failed navigation keeps the original card and never defers or dismisses',async()=>{
  const f=fixture();f.actions.navigate=async()=>{f.state.events.push('navigate');throw new Error('navigation failed');};
  await assert.rejects(f.handoff.open(f.request.id,f.snapshot),/navigation failed/);
  assert.deepEqual(f.state.requests,[f.request]);assert.deepEqual(f.state.events,['route','navigate']);
});
test('an unavailable exact source route keeps the card without attempting navigation',async()=>{
  const f=fixture();f.actions.destination=async()=>undefined;
  await assert.rejects(f.handoff.open(f.request.id,f.snapshot),/exact link/);
  assert.deepEqual(f.state.requests,[f.request]);assert.deepEqual(f.state.events,[]);
});
test('older permission hooks open their chat but keep an answerable Pip card with an explanation',async()=>{
  for(const canDefer of [undefined,false]){
    const f=fixture({...permission(),canDefer});
    await assert.rejects(f.handoff.open(f.request.id,f.snapshot),/chat opened\. Answer this request in Pip/);
    assert.equal(f.request.canRespond,true);assert.deepEqual(f.state.requests,[f.request]);assert.deepEqual(f.state.events,['route','navigate']);
  }
});
test('stale displayed snapshots and already finished requests cannot navigate or hand off',async()=>{
  for(const finished of [false,true]){
    const f=fixture();f.state.requests=finished?[]:[{...f.request,reason:'Changed approval'}];
    await assert.rejects(f.handoff.open(f.request.id,f.snapshot),/changed|finished/);
    assert.deepEqual(f.state.events,[]);
  }
});
test('a changed or resolved request during route lookup is rejected before navigation',async()=>{
  for(const finished of [false,true]){
    const f=fixture();f.actions.destination=async()=>{f.state.requests=finished?[]:[{...f.request,reason:'Changed'}];return 'codex://threads/fixture';};
    await assert.rejects(f.handoff.open(f.request.id,f.snapshot),/changed|finished/);
    assert.deepEqual(f.state.events,[]);
  }
});
test('changed, expired or resolved requests during navigation never retire a newer card',async()=>{
  for(const change of ['changed','expired','resolved']){
    const f=fixture(),other={...permission(),id:'b'.repeat(32)};
    f.actions.navigate=async()=>{f.state.requests=change==='resolved'?[other]:[{...f.request,...(change==='changed'?{reason:'Changed'}:{expiresAt:seconds()-1})},other];};
    await assert.rejects(f.handoff.open(f.request.id,f.snapshot),/changed|finished/);
    assert.ok(f.state.requests.includes(other));assert.deepEqual(f.state.events,['route']);
  }
});
test('failed defer or dismissal keeps the card and releases the navigation guard for retry',async()=>{
  for(const notice of [false,true]){
    const f=fixture(notice?{...permission(),kind:'notice',canRespond:false}:permission()),key=notice?'dismiss':'defer';
    const original=f.actions[key];f.actions[key]=async()=>{throw new Error('handoff failed');};
    await assert.rejects(f.handoff.open(f.request.id,f.snapshot),/handoff failed/);assert.deepEqual(f.state.requests,[f.request]);
    f.actions[key]=original;await f.handoff.open(f.request.id,f.snapshot);assert.deepEqual(f.state.requests,[]);
  }
});
test('concurrent clicks open and retire a request only once',async()=>{
  const f=fixture();let opened!:()=>void,release!:()=>void;
  const started=new Promise<void>(resolve=>{opened=resolve;}),gate=new Promise<void>(resolve=>{release=resolve;});
  f.actions.navigate=async()=>{f.state.events.push('navigate');opened();await gate;};
  const first=f.handoff.open(f.request.id,f.snapshot);await started;
  await assert.rejects(f.handoff.open(f.request.id,f.snapshot),/already opening/);
  release();await first;assert.deepEqual(f.state.events,['route','navigate','defer']);
});
test('IPC snapshots omit only display navigation metadata and malformed inputs have no effects',async()=>{
  const f=fixture();assert.equal(requestSnapshot({...f.request,navigation:{available:true}}),f.snapshot);
  for(const [id,snapshot] of [['invalid',f.snapshot],[f.request.id,undefined],[f.request.id,''],[f.request.id,'x'.repeat(1_000_001)]])await assert.rejects(f.handoff.open(id,snapshot),/Invalid/);
  assert.deepEqual(f.state.events,[]);
});
test('permission defer capability is optional, boolean, and permits only a bare defer response',()=>{
  const request=permission(),defer={id:request.id,decision:'defer',decidedAt:seconds()};
  assert.equal(validRequest(request),true);assert.equal(validResponse(request,defer),true);
  for(const canDefer of [undefined,false]){
    const old={...request,canDefer};assert.equal(validRequest(old),true);assert.equal(validResponse(old,defer),false);
    for(const decision of ['allow','deny'])assert.equal(validResponse(old,{...defer,decision}),true);
  }
  assert.equal(validRequest({...request,canDefer:'true'}),false);
  for(const decision of ['allow','deny','defer'])for(const extra of [{answers:null},{answers:{}},{unexpected:true}])assert.equal(validResponse(request,{...defer,decision,...extra}),false);
});
