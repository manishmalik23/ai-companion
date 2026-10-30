import type { Question, Request } from './protocol';

/** Navigation availability is UI metadata, not part of the mailbox request snapshot. */
export function requestSnapshot(request: Request & { navigation?: unknown }): string {
  const { navigation, ...snapshot } = request;
  return JSON.stringify(snapshot);
}

/** Preserve the chosen request as new requests arrive, without losing form drafts. */
export class RequestSelection {
  private selected?: string;
  update(requests: readonly Request[]): Request | undefined {
    const current=requests.find(request=>request.id===this.selected)||requests[0];
    this.selected=current?.id; return current;
  }
  move(requests: readonly Request[], delta: number): Request | undefined {
    if (!requests.length) { this.selected=undefined; return undefined; }
    const index=Math.max(0,requests.findIndex(request=>request.id===this.selected));
    const next=requests[(index+delta%requests.length+requests.length)%requests.length]!;
    this.selected=next.id; return next;
  }
}
const normalize=(value:string)=>value.replace(/\s+/g,' ').trim();
/** Presentation-only filtering: commands, paths and nested tool arguments stay intact. */
export function displayedDetails(request: Pick<Request,'detailText'|'reason'>): string {
  try {
    const parsed: unknown=JSON.parse(request.detailText);
    if (!parsed||typeof parsed!=='object'||Array.isArray(parsed)) return request.detailText;
    const filtered={...parsed as Record<string,unknown>};
    for(const key of ['description','justification','reason','message']) {
      if(typeof filtered[key]==='string'&&normalize(filtered[key] as string)===normalize(request.reason)) delete filtered[key];
    }
    return JSON.stringify(filtered,null,2);
  } catch { return request.detailText; }
}
export function actionLabel(request: Pick<Request,'toolName'|'kind'>): string {
  if(request.kind==='question')return 'A question for you';
  if(request.kind==='notice')return 'Continue in the source app';
  const labels:Record<string,string>={Bash:'Run command',exec_command:'Run command',Read:'Read file',Write:'Write file',Edit:'Edit file',MultiEdit:'Edit files'};
  return labels[request.toolName]||request.toolName;
}
export function actionDetail(request:Pick<Request,'toolName'|'detailText'>):string{
  try{
    const input:unknown=JSON.parse(request.detailText);
    if(!input||typeof input!=='object'||Array.isArray(input))return request.toolName;
    const values=input as Record<string,unknown>,text=(key:string)=>typeof values[key]==='string'&&values[key]?values[key] as string:undefined;
    const integer=(key:string)=>typeof values[key]==='number'&&Number.isSafeInteger(values[key])&&(values[key] as number)>0?values[key] as number:undefined;
    const tool=request.toolName.toLowerCase(),file=text('file_path');
    if(tool==='read'&&file){
      const offset=integer('offset'),limit=integer('limit');
      if(offset&&limit&&Number.isSafeInteger(offset+limit-1))return `Read(${file} · lines ${offset}–${offset+limit-1})`;
      return offset?`Read(${file} · from line ${offset})`:`Read(${file})`;
    }
    if(['edit','write','multiedit'].includes(tool)&&file)return `${request.toolName}(${file})`;
    const command=tool==='bash'?text('command'):tool==='exec_command'?text('cmd'):undefined;
    return command?`${request.toolName}(${command})`:request.toolName;
  }catch{return request.toolName;}
}
export function sessionText(value:string):string{
  return value.replace(/[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]/g,'').replace(/[\u0000-\u001f\u007f-\u009f]/g,' ').replace(/\s+/g,' ').trim();
}
export function requestTitle(request: Pick<Request,'sessionName'|'reason'|'toolName'|'kind'|'sessionId'|'cwd'>): string {
  const usable=(value:string):boolean=>{
    const label=value.toLocaleLowerCase(),directory=sessionText(request.cwd).replace(/[\\/]+$/,'').toLocaleLowerCase();
    const folder=directory.split(/[\\/]/).at(-1);
    const identifier=value.replace(/^(?:session(?:\s+(?:id|uuid))?|id|uuid)\s*[:#]?\s*/i,'').replace(/^[\s\[\]\{\}\(\)<>]+|[\s\[\]\{\}\(\)<>]+$/g,'');
    return !!value&&label!==sessionText(request.sessionId).toLocaleLowerCase()&&identifier.toLocaleLowerCase()!==sessionText(request.sessionId).toLocaleLowerCase()&&
      !/^(?:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{32})$/i.test(identifier)&&
      (!directory||label.replace(/[\\/]+$/,'')!==directory&&label.replace(/[\\/]+$/,'')!==folder);
  };
  const name=sessionText(request.sessionName||'');
  if(usable(name))return name;
  const first=sessionText(request.reason.trim().split(/\r?\n/,1)[0]||'');
  return `Task: ${(usable(first)?first:actionLabel(request)).slice(0,120)}`;
}
export function workspaceName(cwd:string):string {
  return sessionText(cwd.replace(/[\\/]+$/,'').split(/[\\/]/).filter(Boolean).at(-1)||'Local session');
}
export function hostLabel(host?:string):string {
  return ({'claude-vscode':'VS Code','codex-vscode':'VS Code','codex-desktop':'Codex desktop','vscode-terminal':'VS Code terminal','apple-terminal':'Terminal','windows-terminal':'Windows Terminal'} as Record<string,string>)[host||'']||'Local agent';
}
export interface QuestionDraft { labels:string[]; otherEnabled:boolean; other:string }
export function emptyDraft():QuestionDraft{return {labels:[],otherEnabled:false,other:''};}
export function answersFromDrafts(questions:readonly Question[],drafts:ReadonlyMap<string,QuestionDraft>):Record<string,string>|undefined {
  const answers:Record<string,string>={};
  for(const question of questions){
    const draft=drafts.get(question.question);
    if(!draft)return undefined;
    const valid=new Set(question.options.map(option=>option.label));
    if(draft.labels.some(label=>!valid.has(label))||new Set(draft.labels).size!==draft.labels.length)return undefined;
    if(!question.multiSelect&&draft.labels.length+(draft.otherEnabled?1:0)>1)return undefined;
    if(draft.otherEnabled&&!draft.other.trim())return undefined;
    const values=[...draft.labels,...(draft.otherEnabled?[draft.other]:[])];
    if(!values.length)return undefined;
    Object.defineProperty(answers,question.question,{value:values.join(', '),enumerable:true,writable:true,configurable:true});
  }
  if(new TextEncoder().encode(JSON.stringify(answers)).length>2000)return undefined;
  return answers;
}
