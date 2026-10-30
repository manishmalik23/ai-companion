import test from 'node:test';
import assert from 'node:assert/strict';
import type { Question, Request } from '../src/protocol';
import { actionDetail, answersFromDrafts, displayedDetails, emptyDraft, QuestionDraft, RequestSelection, requestTitle, sessionText, workspaceName } from '../src/view-model';

const request=(id:string):Request=>({schemaVersion:1,id,source:'claude',sourceLabel:'Claude Code',sessionId:'session',toolName:'Bash',cwd:'/app',reason:'Run the tests',detailText:'{}',createdAt:1,expiresAt:100,canRespond:true,isDemo:true,kind:'permission',correlation:{sessionId:'session'}});
test('queue navigation preserves the selected request when another request arrives',()=>{
  const selection=new RequestSelection(),a=request('a'),b=request('b'),c=request('c');
  assert.equal(selection.update([a,b])?.id,'a');assert.equal(selection.move([a,b],1)?.id,'b');
  assert.equal(selection.update([c,a,b])?.id,'b');assert.equal(selection.move([c,a,b],1)?.id,'c');
  assert.equal(selection.move([c,a,b],-1)?.id,'b');assert.equal(selection.update([a])?.id,'a');
  assert.equal(selection.update([]),undefined);assert.equal(selection.move([],1),undefined);
});
test('only duplicate top-level reason metadata disappears from the displayed copy',()=>{
  const original={command:'Run the tests',description:'Run   the tests',justification:'Different explanation',reason:'Run the tests',message:'Run the tests',nested:{description:'Run the tests'},file_path:'Run the tests'};
  const detailText=JSON.stringify(original),displayed=JSON.parse(displayedDetails({detailText,reason:'Run the tests'}));
  assert.deepEqual(displayed,{command:'Run the tests',justification:'Different explanation',nested:{description:'Run the tests'},file_path:'Run the tests'});
  assert.equal(detailText,JSON.stringify(original));assert.equal(displayedDetails({detailText:'unparsed text',reason:'text'}),'unparsed text');
});
test('session names take precedence and fallback task titles do not reveal session IDs',()=>{
  const r=request('a');assert.equal(requestTitle({...r,sessionName:'  Payment validation  '}),'Payment validation');
  assert.equal(requestTitle(r),'Task: Run the tests');assert.equal(workspaceName('C:\\Work\\checkout\\'),'checkout');assert.equal(workspaceName('/Users/example/app/'),'app');
});
test('headers remove control/bidirectional text and never use the session ID as a subject',()=>{
  const r=request('a');assert.equal(requestTitle({...r,sessionName:r.sessionId}),'Task: Run the tests');
  assert.equal(sessionText('  Fix\u202e payment\ncheck  '),'Fix payment check');
});
test('Codex workspace and ID-shaped labels stay out of the primary title',()=>{
  const r={...request('a'),source:'codex' as const,cwd:'C:\\Work\\shared-workspace',sessionId:'12345678-1234-4234-8234-123456789abc'};
  for(const sessionName of ['shared-workspace','SHARED-WORKSPACE','shared-workspace/',r.cwd,r.sessionId,'ID: '+r.sessionId,'Session ID: '+r.sessionId,'Session UUID: {'+r.sessionId+'}','11111111-1111-4111-8111-111111111111','UUID: ['+r.sessionId+']','a'.repeat(32)]){
    assert.equal(requestTitle({...r,sessionName}),'Task: Run the tests');
  }
  assert.equal(requestTitle({...r,reason:'ID: '+r.sessionId}),'Task: Run command');
  assert.equal(requestTitle({...r,sessionName:'Review checkout session '+r.sessionId}),'Review checkout session '+r.sessionId);
});
test('action details reproduce supplied commands and exact read line ranges',()=>{
  assert.equal(actionDetail({toolName:'Read',detailText:JSON.stringify({file_path:'C:\\Work\\app.ts',offset:810,limit:32})}),'Read(C:\\Work\\app.ts · lines 810–841)');
  assert.equal(actionDetail({toolName:'Read',detailText:JSON.stringify({file_path:'/tmp/file',offset:10,limit:true})}),'Read(/tmp/file · from line 10)');
  assert.equal(actionDetail({toolName:'Read',detailText:JSON.stringify({file_path:'/tmp/file',offset:0})}),'Read(/tmp/file)');
  assert.equal(actionDetail({toolName:'Bash',detailText:JSON.stringify({command:'echo "$HOME"; $(never-execute)'})}),'Bash(echo "$HOME"; $(never-execute))');
});
const question:Question={question:'Which language?',options:[{label:'TypeScript'},{label:'Python'}]};
test('Other preserves typed text and combines explicitly selected multi-choice options',()=>{
  const drafts=new Map<string,QuestionDraft>([[question.question,{labels:[],otherEnabled:true,other:'  Rust and WebAssembly  '}]]);
  assert.deepEqual(answersFromDrafts([question],drafts),{'Which language?':'  Rust and WebAssembly  '});
  drafts.set(question.question,{labels:['TypeScript'],otherEnabled:true,other:'Rust'});
  assert.equal(answersFromDrafts([question],drafts),undefined);
  assert.deepEqual(answersFromDrafts([{...question,multiSelect:true}],drafts),{'Which language?':'TypeScript, Rust'});
});
test('every question needs an answer and empty Other text cannot submit',()=>{
  const drafts=new Map([[question.question,emptyDraft()]]);assert.equal(answersFromDrafts([question],drafts),undefined);
  drafts.set(question.question,{labels:[],otherEnabled:true,other:'   '});assert.equal(answersFromDrafts([question],drafts),undefined);
  drafts.set(question.question,{labels:['unknown'],otherEnabled:false,other:''});assert.equal(answersFromDrafts([question],drafts),undefined);
  drafts.set(question.question,{labels:['Python'],otherEnabled:false,other:''});assert.equal(answersFromDrafts([question,{...question,question:'Another question?'}],drafts),undefined);
});
test('UTF-8 answer budget includes the complete answer map',()=>{
  const drafts=new Map([[question.question,{labels:[],otherEnabled:true,other:'🙂'.repeat(510)}]]);assert.equal(answersFromDrafts([question],drafts),undefined);
  drafts.set(question.question,{labels:[],otherEnabled:true,other:'🙂'.repeat(100)});assert.ok(answersFromDrafts([question],drafts));
});
test('question text used as a map key cannot mutate the answer object prototype',()=>{
  const q={...question,question:'__proto__'},drafts=new Map([[q.question,{labels:['Python'],otherEnabled:false,other:''}]]);
  const answers=answersFromDrafts([q],drafts)!;
  assert.equal(Object.hasOwn(answers,'__proto__'),true);assert.equal(JSON.stringify(answers),'{"__proto__":"Python"}');assert.equal(Object.getPrototypeOf(answers),Object.prototype);
});
