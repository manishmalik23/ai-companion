import type { Request, State } from './protocol';
import { Appearance, characterChoices, CharacterChoice, Drawing, drawCharacter, loadCharacter, Mood } from './characters';
import { actionDetail, actionLabel, answersFromDrafts, displayedDetails, emptyDraft, hostLabel, QuestionDraft, RequestSelection, requestSnapshot, requestTitle, workspaceName } from './view-model';

type DisplayRequest=Request&{navigation?:{available:boolean;label?:string}};
interface DesktopAPI {
  onState(callback:(state:State&{requests:DisplayRequest[];dark:boolean;appearance:Appearance})=>void):()=>void;
  onAppearance(callback:()=>void):()=>void;
  decision(id:string,decision:'allow'|'deny'):Promise<{error?:string}>;
  answer(id:string,answers:Record<string,string>):Promise<{error?:string}>;
  defer(id:string):Promise<{error?:string}>;
  dismiss(id:string):Promise<{error?:string}>;
  openSession(id:string,snapshot:string):Promise<{error?:string}>;
  openChat(provider:'claude'|'chatgpt'):Promise<{error?:string}>;
  selectCharacter(choice:CharacterChoice|'import-still'|'import-sprite'):Promise<{error?:string}>;
  regions(value:{x:number;y:number;width:number;height:number}[]):void;
  beginDrag():void;endDrag():void;quit():void;
}
const pip=(window as unknown as {pip:DesktopAPI}).pip;
const element=(id:string)=>document.getElementById(id)!;
const button=(id:string)=>element(id) as HTMLButtonElement;
const canvas=element('robot') as HTMLCanvasElement,context=canvas.getContext('2d')!;
const reducedMotion=matchMedia('(prefers-reduced-motion: reduce)');
const selection=new RequestSelection(),pending=new Set<string>(),drafts=new Map<string,Map<string,QuestionDraft>>();
let state:State&{requests:DisplayRequest[]}={requests:[],working:false},current:DisplayRequest|undefined;
let appearance:Appearance={selection:'default'},drawing:Drawing|undefined,drawingKey='',loadToken=0;
let formSignature='',renderedId='',appearanceOpen=false,staged='default',previewMood:Mood='idle';
let previewDrawing:Drawing|undefined,previewToken=0,characterBusy=false;
const thumbnails=new Map<string,{canvas:HTMLCanvasElement;drawing?:Drawing;loading?:boolean}>();
function error(message:string):void{element('error').textContent=message;}
function setText(id:string,value:string):void{if(element(id).textContent!==value)element(id).textContent=value;}
function regions():void{
  const ids=['pet','handle',...(appearanceOpen?['appearance-panel']:current?['card']:[])];
  pip.regions(ids.map(id=>{const r=element(id).getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height};}));
}
function setAppearance(next:Appearance):void{
  appearance=next;
  const key=next.selection+'\n'+(next.custom?.dataUrl||'');
  if(key===drawingKey)return;
  drawingKey=key;const token=++loadToken;
  void loadCharacter(next).then(value=>{if(token===loadToken){drawing=value;canvas.dataset.character=next.selection;}}).catch(()=>{
    if(token!==loadToken)return;
    element('launch-status').textContent='Could not load the selected character. Showing Default Pip.';
    void loadCharacter({selection:'default'}).then(value=>{if(token===loadToken)drawing=value;});
  });
  if(appearanceOpen){staged=appearance.selection;updateAppearance();}
}
function formDrafts(request:Request):Map<string,QuestionDraft>{
  let stored=drafts.get(request.id);if(!stored){stored=new Map();drafts.set(request.id,stored);}return stored;
}
function updateAnswerButton():void{
  const canAnswer=current?.kind==='question'&&current.canRespond&&!!answersFromDrafts(current.questions||[],formDrafts(current));
  button('submit-answer').disabled=!canAnswer||!!current&&pending.has(current.id);
}
function renderQuestions(request:Request):void{
  const signature=request.id+'\n'+JSON.stringify(request.questions||[]);
  if(signature===formSignature)return;
  if(formSignature.startsWith(request.id+'\n'))drafts.delete(request.id);
  formSignature=signature;
  const form=element('question-form');form.replaceChildren();
  const stored=formDrafts(request);
  for(const [index,question]of(request.questions||[]).entries()){
    let draft=stored.get(question.question);if(!draft){draft=emptyDraft();stored.set(question.question,draft);}
    const fieldset=document.createElement('fieldset');
    const legend=document.createElement('legend');legend.textContent=question.question;fieldset.append(legend);
    if(question.header){const header=document.createElement('p');header.className='question-header';header.textContent=question.header;fieldset.append(header);}
    const inputs:HTMLInputElement[]=[];
    const otherText=document.createElement('textarea');otherText.id=`other-${index}`;otherText.className='other-answer';otherText.placeholder='Type your answer';otherText.setAttribute('aria-label',`Other answer for ${question.question}`);otherText.maxLength=2000;otherText.value=draft.other;otherText.hidden=!draft.otherEnabled;
    for(const option of question.options){
      const label=document.createElement('label');label.className='question-option';
      const input=document.createElement('input');input.type=question.multiSelect?'checkbox':'radio';input.name=`question-${index}`;input.value=option.label;input.checked=draft.labels.includes(option.label);inputs.push(input);
      const copy=document.createElement('span');copy.className='option-copy';const title=document.createElement('span');title.className='option-label';title.textContent=option.label;copy.append(title);
      if(option.description){const description=document.createElement('span');description.className='option-description';description.textContent=option.description;copy.append(description);}
      label.append(input,copy);fieldset.append(label);
      input.addEventListener('change',()=>{
        if(!question.multiSelect){draft!.labels=input.checked?[option.label]:[];draft!.otherEnabled=false;otherInput.checked=false;otherText.hidden=true;}
        else draft!.labels=inputs.filter(candidate=>candidate.checked).map(candidate=>candidate.value);
        updateAnswerButton();regions();
      });
    }
    const other=document.createElement('label');other.className='question-option';
    const otherInput=document.createElement('input');otherInput.type=question.multiSelect?'checkbox':'radio';otherInput.name=`question-${index}`;otherInput.value='';otherInput.checked=draft.otherEnabled;
    const otherLabel=document.createElement('span');otherLabel.className='option-label';otherLabel.textContent='Other';other.append(otherInput,otherLabel);fieldset.append(other,otherText);
    otherInput.addEventListener('change',()=>{
      draft!.otherEnabled=otherInput.checked;otherText.hidden=!otherInput.checked;
      if(!question.multiSelect&&otherInput.checked){draft!.labels=[];for(const input of inputs)input.checked=false;}
      if(otherInput.checked)requestAnimationFrame(()=>{otherText.focus({preventScroll:true});otherText.scrollIntoView({block:'nearest'});});
      updateAnswerButton();regions();
    });
    otherText.addEventListener('input',()=>{draft!.other=otherText.value;updateAnswerButton();});
    if(question.multiSelect){const note=document.createElement('p');note.className='question-note';note.textContent='Choose all that apply.';fieldset.append(note);}
    form.append(fieldset);
  }
  const note=document.createElement('p');note.className='question-note';note.textContent='Answer every question. Answers together must fit within 2,000 bytes.';form.append(note);
}
function update():void{
  current=selection.update(state.requests) as DisplayRequest|undefined;
  const live=new Set(state.requests.map(request=>request.id));for(const id of drafts.keys())if(!live.has(id))drafts.delete(id);
  element('card').hidden=!current||appearanceOpen;element('appearance-panel').hidden=!appearanceOpen;
  element('status').textContent=state.error||(current?current.kind==='question'?'Waiting for your answer':current.kind==='notice'?'Continue in the source app':'Waiting for your approval':state.working?'Pip Source · Working':'Pip Source · Idle');
  if(current){
    if(renderedId!==current.id){error('');renderedId=current.id;}
    const header=button('session-title');header.textContent=requestTitle(current);header.disabled=!current.navigation?.available||pending.has(current.id);header.title=current.navigation?.label||`Session ${current.sessionId}`;
    element('session-context').textContent=`${current.sourceLabel} · ${hostLabel(current.sessionHost)} · ${workspaceName(current.cwd)}`;
    element('session-context').title=`${current.cwd}\nSession ${current.sessionId}`;
    element('provider').textContent=`${current.sourceLabel}${current.isDemo?' · Demo':''}`;
    element('count').textContent=`${state.requests.length} pending`;element('tool').textContent=actionLabel(current);
    setText('reason',current.reason);element('reason-section').hidden=!current.reason.trim();
    setText('action-summary',actionDetail(current));element('action-summary').hidden=current.kind!=='permission';
    setText('details',displayedDetails(current));element('details').hidden=current.kind==='question';
    element('workspace').textContent=current.cwd;element('instructions').textContent=current.instructions||'';
    element('permission-actions').hidden=current.kind!=='permission';element('question-actions').hidden=current.kind!=='question';element('notice-actions').hidden=current.kind!=='notice';
    element('question-form').hidden=current.kind!=='question';
    if(current.kind==='question')renderQuestions(current);else formSignature='';
    const disabled=pending.has(current.id)||!current.canRespond;
    for(const fieldset of element('question-form').querySelectorAll('fieldset'))fieldset.disabled=disabled;
    for(const id of ['allow','deny','defer'])button(id).disabled=disabled;
    button('dismiss').disabled=pending.has(current.id);updateAnswerButton();
    const index=state.requests.findIndex(request=>request.id===current!.id);
    element('position').textContent=`${index+1} of ${state.requests.length} · ${current.kind==='notice'?'Alert only':'Waiting for you'}`;
  }else{renderedId='';formSignature='';}
  button('previous').disabled=state.requests.length<2;button('next').disabled=state.requests.length<2;
  regions();
}
async function perform(id:string,operation:()=>Promise<{error?:string}>,fallback='Could not send this response. Continue in the original agent.'):Promise<void>{
  if(pending.has(id))return;
  pending.add(id);error('');update();
  try{const result=await operation();if(current?.id===id)error(result.error||'');}
  catch{if(current?.id===id)error(fallback);}
  finally{pending.delete(id);update();}
}
pip.onState(next=>{
  const previousError=state.error;state=next;
  if(next.error)element('launch-status').textContent=next.error;
  else if(previousError&&element('launch-status').textContent===previousError)element('launch-status').textContent='';
  document.documentElement.classList.toggle('dark',next.dark);setAppearance(next.appearance||{selection:'default'});update();
});
for(const[id,value]of[['allow','allow'],['deny','deny']]as const)button(id).addEventListener('click',()=>{const request=current;if(request)void perform(request.id,()=>pip.decision(request.id,value));});
element('question-form').addEventListener('submit',event=>{
  event.preventDefault();const request=current;
  if(!request||request.kind!=='question')return;
  const answers=answersFromDrafts(request.questions||[],formDrafts(request));
  if(!answers){error('Answer every question and keep all answers together under 2,000 bytes.');return;}
  void perform(request.id,()=>pip.answer(request.id,answers));
});
button('defer').addEventListener('click',()=>{const request=current;if(request)void perform(request.id,()=>pip.defer(request.id));});
button('dismiss').addEventListener('click',()=>{const request=current;if(request)void perform(request.id,()=>pip.dismiss(request.id));});
button('session-title').addEventListener('click',()=>{
  const request=current;if(!request?.navigation?.available)return;
  void perform(request.id,()=>pip.openSession(request.id,requestSnapshot(request)),'The source session could not be opened. Continue in Pip.');
});
for(const[id,delta]of[['previous',-1],['next',1]]as const)button(id).addEventListener('click',()=>{selection.move(state.requests,delta);update();});
for(const provider of ['claude','chatgpt']as const)button(provider).addEventListener('click',async()=>{
  button(provider).disabled=true;try{const result=await pip.openChat(provider);element('launch-status').textContent=result.error||'';}
  catch{element('launch-status').textContent='Could not open the chat app.';}finally{button(provider).disabled=false;}
});
function updateAppearance():void{
  for(const choice of characterChoices)button(`character-${choice.id}`).setAttribute('aria-checked',String(staged===choice.id));
  button('apply-character').disabled=characterBusy||staged===appearance.selection||staged==='custom';button('reset-character').disabled=characterBusy||appearance.selection==='default';
  for(const id of ['import-still','import-sprite'])button(id).disabled=characterBusy;
  element('appearance-current').textContent=characterChoices.find(choice=>choice.id===staged)?.name||appearance.custom?.name||'Imported character';
  for(const[id,mood]of[['preview-idle','idle'],['preview-working','working'],['preview-waiting','waiting']]as const)button(id).setAttribute('aria-pressed',String(previewMood===mood));
  const token=++previewToken,choice=staged;void loadCharacter(staged==='custom'?appearance:{selection:staged}).then(value=>{if(token===previewToken){previewDrawing=value;element('appearance-preview').dataset.character=choice;}}).catch(()=>{element('appearance-error').textContent='This character could not be loaded.';});
  requestAnimationFrame(regions);
}
function showAppearance():void{
  appearanceOpen=true;staged=appearance.selection;previewMood='idle';element('appearance-error').textContent='';
  for(const[id,thumb]of thumbnails){
    if(thumb.loading||thumb.drawing)continue;
    thumb.loading=true;
    void loadCharacter({selection:id}).then(value=>{thumb.drawing=value;thumb.canvas.dataset.loaded='true';}).catch(()=>{button(`character-${id}`).disabled=true;button(`character-${id}`).title='Character image unavailable.';});
  }
  updateAppearance();update();
}
button('appearance-open').addEventListener('click',showAppearance);pip.onAppearance(showAppearance);
button('appearance-close').addEventListener('click',()=>{appearanceOpen=false;update();});
for(const choice of characterChoices){
  const tile=document.createElement('button');tile.id=`character-${choice.id}`;tile.className='character-choice';tile.setAttribute('role','radio');tile.setAttribute('aria-checked','false');
  const preview=document.createElement('canvas');preview.width=104;preview.height=116;preview.setAttribute('aria-hidden','true');const label=document.createElement('span');label.textContent=choice.name;tile.append(preview,label);element('appearance-grid').append(tile);
  const thumb:{canvas:HTMLCanvasElement;drawing?:Drawing}={canvas:preview};thumbnails.set(choice.id,thumb);
  tile.addEventListener('click',()=>{staged=choice.id;updateAppearance();});
}
for(const[id,mood]of[['preview-idle','idle'],['preview-working','working'],['preview-waiting','waiting']]as const)button(id).addEventListener('click',()=>{previewMood=mood;updateAppearance();});
async function chooseCharacter(choice:CharacterChoice|'import-still'|'import-sprite'):Promise<void>{
  if(characterBusy)return;characterBusy=true;element('appearance-error').textContent='';updateAppearance();
  try{const result=await pip.selectCharacter(choice);element('appearance-error').textContent=result.error||'';}
  catch{element('appearance-error').textContent='The character could not be applied.';}
  finally{characterBusy=false;updateAppearance();update();}
}
button('apply-character').addEventListener('click',()=>{if(characterChoices.some(choice=>choice.id===staged))void chooseCharacter(staged as CharacterChoice);});
button('reset-character').addEventListener('click',()=>void chooseCharacter('default'));
for(const id of ['import-still','import-sprite']as const)button(id).addEventListener('click',()=>void chooseCharacter(id));
button('quit').addEventListener('click',()=>pip.quit());
const pet=element('pet');
pet.addEventListener('pointerdown',event=>{if(event.button!==0)return;event.preventDefault();try{pet.setPointerCapture(event.pointerId);}catch{/* Synthetic verification has no active pointer. */}pip.beginDrag();});
for(const name of ['pointerup','pointercancel','lostpointercapture'])pet.addEventListener(name,()=>pip.endDrag());
new ResizeObserver(regions).observe(element('card'));new ResizeObserver(regions).observe(element('appearance-panel'));
function draw(time:number):void{
  const phase=reducedMotion.matches?0:time/1000,mood:Mood=state.requests.length?'waiting':state.working?'working':'idle';
  context.clearRect(0,0,canvas.width,canvas.height);if(drawing)drawCharacter(context,drawing,{x:0,y:0,width:canvas.width,height:canvas.height},mood,phase);
  if(appearanceOpen){
    for(const thumb of thumbnails.values()){const ctx=thumb.canvas.getContext('2d')!;ctx.clearRect(0,0,thumb.canvas.width,thumb.canvas.height);if(thumb.drawing)drawCharacter(ctx,thumb.drawing,{x:0,y:0,width:thumb.canvas.width,height:thumb.canvas.height},'idle',0);}
    const preview=element('appearance-preview')as HTMLCanvasElement,ctx=preview.getContext('2d')!;ctx.clearRect(0,0,preview.width,preview.height);if(previewDrawing)drawCharacter(ctx,previewDrawing,{x:0,y:0,width:preview.width,height:preview.height},previewMood,phase);
  }
  setTimeout(()=>requestAnimationFrame(draw),50);
}
setAppearance(appearance);update();requestAnimationFrame(draw);
