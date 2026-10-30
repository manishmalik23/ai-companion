import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import { animatedCharacterChoices, atlasCell, atlasFrameIndex, characterChoices, descriptors, Drawing, drawCharacter, frameIndex, isBlinking, loadCharacter, mainBody, Mood, parseAtlasLayouts, Raster, registerEye } from '../src/characters';

function layoutFixture(){
  return {version:1,width:1254,height:1254,columns:4,rows:3,characters:Object.fromEntries(animatedCharacterChoices.map(choice=>[choice.id,{
    file:`${choice.asset}.png`,frames:(['idle','working','waiting'] as const).flatMap(mood=>[0,1,2,3].map(column=>{const r=atlasCell(1254,1254,column,mood);return[r.x,r.y,r.width,r.height];})),canvas:[314,418]
  }]))};
}

test('six animated companions append to the unchanged released choices',()=>{
  assert.deepEqual(characterChoices.map(choice=>choice.id),['default','sunny','mochi','boba','lumi','mallow','sprout','peach-puff','lavender-mochi','mint-bean','nimbo','chai','plumo']);
  assert.deepEqual(characterChoices.map(choice=>choice.name),['Default Pip','Sunny','Mochi','Boba','Lumi','Mallow','Sprout','Peach Puff','Lavender Mochi','Mint Bean','Nimbo','Chai','Plumo']);
  assert.equal(new Set(characterChoices.map(choice=>choice.id)).size,13);
  assert.deepEqual(Object.keys(descriptors),['sunny','mochi','boba','lumi','mallow','sprout']);
  for(const descriptor of Object.values(descriptors)){
    assert.equal(descriptor.idle.length,2);assert.equal(descriptor.working.length,2);
    assert.ok(descriptor.split>500&&descriptor.split<800);
  }
});
test('animated atlases follow the specified idle, typing, blink and waiting boundaries',()=>{
  const timelines: { mood: Mood; boundaries: number[]; columns: number[] }[] = [
    { mood:'idle',boundaries:[0,4.25,4.41,4.54,4.74],columns:[0,1,2,3] },
    { mood:'working',boundaries:[0,.3,.6,.9,1.2,1.5,1.8,2.1,2.4,2.7,3,3.3,3.6,3.9,4.2,4.5,4.8,4.93,5.23],columns:[0,1,3,1,0,1,3,1,0,1,3,1,0,1,3,1,2,3] },
    { mood:'waiting',boundaries:[0,2.8,3.5,3.63,4.33],columns:[0,1,2,3] }
  ];
  for(const {mood,boundaries,columns} of timelines){
    const cycle=boundaries.at(-1)!;
    for(let index=0;index<columns.length;index++){
      const start=boundaries[index]!,end=boundaries[index+1]!;
      assert.equal(atlasFrameIndex(mood,start),columns[index],`${mood} at ${start}`);
      assert.equal(atlasFrameIndex(mood,end-.000001),columns[index],`${mood} before ${end}`);
      assert.equal(atlasFrameIndex(mood,(start+end)/2+cycle*3),columns[index],`${mood} repeating`);
    }
    assert.equal(atlasFrameIndex(mood,cycle),0,`${mood} wraps`);
    assert.equal(atlasFrameIndex(mood,-.001),3,`${mood} negative phase`);
    for(const invalid of [NaN,Infinity,-Infinity,Number.MAX_VALUE])assert.equal(atlasFrameIndex(mood,invalid),0);
  }
});
test('atlas crops partition all twelve cells without overlap, fractional pixels or missing edges',()=>{
  for(const [row,mood] of (['idle','working','waiting'] as const).entries()){
    const cells=[0,1,2,3].map(column=>atlasCell(1254,1254,column,mood));
    assert.deepEqual(cells.map(cell=>cell.x),[0,313,627,940]);
    assert.deepEqual(cells.map(cell=>cell.width),[313,314,313,314]);
    assert.equal(cells.reduce((sum,cell)=>sum+cell.width,0),1254);
    for(const cell of cells){assert.equal(cell.y,row*418);assert.equal(cell.height,418);}
  }
});
test('registered layouts reject malformed, nonfinite, out-of-cell and mismatched asset metadata',()=>{
  const valid=layoutFixture();assert.equal(Object.keys(parseAtlasLayouts(valid)).length,6);
  const corruptions=[
    (value:ReturnType<typeof layoutFixture>)=>{value.version=2;},
    (value:ReturnType<typeof layoutFixture>)=>{value.width=1255;},
    (value:ReturnType<typeof layoutFixture>)=>{value.columns=3;},
    (value:ReturnType<typeof layoutFixture>)=>{delete value.characters.chai;},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.file='../Chai.png';},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.frames.pop();},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.frames[0]![0]=Infinity;},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.frames[0]![2]=NaN;},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.frames[0]![0]=.5;},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.frames[1]![0]=0;},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.frames[4]![1]=0;},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.frames[0]![2]=314;},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.frames[0]![3]=0;},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.canvas=[Infinity,418];},
    (value:ReturnType<typeof layoutFixture>)=>{value.characters.chai!.canvas=[300,418];}
  ];
  for(const mutate of corruptions){const value=structuredClone(valid);mutate(value);assert.throws(()=>parseAtlasLayouts(value),/Invalid/);}
  for(const value of [null,[],{},'invalid'])assert.throws(()=>parseAtlasLayouts(value),/Invalid/);
});
test('animated registered crops share a fixed center, baseline and scale without synthetic overlays',()=>{
  const draws:unknown[][]=[];
  const context={save(){},restore(){},drawImage(...args:unknown[]){draws.push(args);},imageSmoothingEnabled:false} as unknown as CanvasRenderingContext2D;
  const image={} as HTMLImageElement,layout=parseAtlasLayouts(layoutFixture()).chai;
  layout.frames=layout.frames.map((r,index)=>({x:r.x+10,y:r.y+10,width:r.width-20-(index%4)*3,height:r.height-20-Math.floor(index/4)*7}));
  layout.canvas={width:Math.max(...layout.frames.map(r=>r.width)),height:Math.max(...layout.frames.map(r=>r.height))};
  const drawing:Drawing={kind:'atlas',image,layout,width:layout.canvas.width,height:layout.canvas.height};
  const scale=Math.min(192/drawing.width,208/drawing.height);
  for(const mood of ['idle','working','waiting'] as const)for(const phase of [0,.3,2.8,3.5,4.25,4.5,4.8,4.93,NaN]){
    draws.length=0;
    drawCharacter(context,drawing,{x:10,y:20,width:192,height:208},mood,phase);
    assert.equal(draws.length,1);
    const [actualImage,x,y,width,height,...target]=draws[0]!;
    assert.equal(actualImage,image);
    const row=mood==='idle'?0:mood==='working'?1:2;
    assert.deepEqual({x,y,width,height},layout.frames[row*4+atlasFrameIndex(mood,phase)]);
    const [left,top,targetWidth,targetHeight]=target as number[];
    assert.ok(Math.abs(left!+targetWidth!/2-106)<1e-8,'same horizontal center');
    assert.ok(Math.abs(top!+targetHeight!-228)<1e-8,'same bottom baseline');
    assert.ok(Math.abs(targetWidth!/(width as number)-scale)<1e-8,'same horizontal scale');
    assert.ok(Math.abs(targetHeight!/(height as number)-scale)<1e-8,'same vertical scale');
  }
});
test('released characters keep their standing/laptop pose selection and registered blink patches',()=>{
  const draws:unknown[][]=[];
  const context={save(){},restore(){},drawImage(...args:unknown[]){draws.push(args);},imageSmoothingEnabled:false} as unknown as CanvasRenderingContext2D;
  const standing={width:100,height:180} as HTMLCanvasElement,laptop={width:160,height:140} as HTMLCanvasElement;
  const patch={image:{} as HTMLCanvasElement,rectangle:{x:20,y:30,width:10,height:12}};
  const drawing:Drawing={kind:'builtin',width:160,height:180,
    idle:{image:standing,bounds:{x:0,y:0,width:100,height:180},patches:[patch]},
    working:{image:laptop,bounds:{x:0,y:0,width:160,height:140},patches:[patch]}};
  for(const mood of ['idle','working'] as const){
    draws.length=0;drawCharacter(context,drawing,{x:0,y:0,width:160,height:180},mood,0);
    assert.equal(draws.length,1);assert.equal(draws[0]![0],mood==='working'?laptop:standing);
    const original=draws[0];
    draws.length=0;drawCharacter(context,drawing,{x:0,y:0,width:160,height:180},mood,4.7);
    assert.deepEqual(draws[0],original);assert.equal(draws.length,2);assert.equal(draws[1]![0],patch.image);
    assert.deepEqual(draws[1]!.slice(1),[mood==='working'?20:50,mood==='working'?70:30,10,12]);
  }
});
test('built-in atlas loading uses one original asset and preserves default and custom drawing kinds',async()=>{
  const previous=globalThis.Image,sources:string[]=[],globals=globalThis as unknown as Record<string,unknown>,previousLayouts=globals.__PIP_FLUFFY_LAYOUTS__;
  class ImageStub{
    naturalWidth=1254;naturalHeight=1254;onload=()=>{};
    set src(value:string){sources.push(value);queueMicrotask(()=>this.onload());}
  }
  globalThis.Image=ImageStub as unknown as typeof Image;
  globals.__PIP_FLUFFY_LAYOUTS__=layoutFixture();
  try{
    for(const choice of animatedCharacterChoices){
      const before=sources.length,drawing=await loadCharacter({selection:choice.id});
      assert.equal(drawing.kind,'atlas');assert.equal(drawing.width,314);assert.equal(drawing.height,418);assert.equal(drawing.layout?.frames.length,12);
      assert.deepEqual(sources.slice(before),[`characters/${choice.asset}.png`]);
      assert.equal(await loadCharacter({selection:choice.id}),drawing,'built-in decoding is cached');
    }
    assert.equal((await loadCharacter({selection:'default'})).kind,'sprite');
    assert.equal((await loadCharacter({selection:'unknown'})).kind,'sprite');
    for(const kind of ['still','sprite'] as const)assert.equal((await loadCharacter({selection:'custom',custom:{kind,dataUrl:'data:image/png;base64,AA==',name:'My import'}})).kind,kind);
  }finally{globalThis.Image=previous;if(previousLayouts===undefined)delete globals.__PIP_FLUFFY_LAYOUTS__;else globals.__PIP_FLUFFY_LAYOUTS__=previousLayouts;}
});
test('the UI build packages every atlas byte-for-byte from the authoritative native resources',async()=>{
  for(const choice of animatedCharacterChoices){
    const source=await fs.readFile(path.join(__dirname,'../../../desktop/Resources/Characters',`${choice.asset}.png`));
    const bundled=await fs.readFile(path.join(__dirname,'../ui/characters',`${choice.asset}.png`));
    assert.deepEqual(bundled,source,choice.asset);
    assert.equal(source.toString('ascii',12,16),'IHDR');
    assert.equal(source.readUInt32BE(16),1254);assert.equal(source.readUInt32BE(20),1254);
  }
  const source=await fs.readFile(path.join(__dirname,'../../../desktop/Resources/Characters/FluffyLayouts.json'));
  assert.deepEqual(await fs.readFile(path.join(__dirname,'../ui/characters/FluffyLayouts.json')),source);
  const renderer=await fs.readFile(path.join(__dirname,'../ui/renderer.js'),'utf8');
  const embedded=/^const __PIP_FLUFFY_LAYOUTS__ = (.+);\r?\n/.exec(renderer);
  assert.ok(embedded,'authoritative registrations are embedded in the external bundle');
  assert.deepEqual(JSON.parse(embedded[1]!),JSON.parse(source.toString()));
  assert.equal(Object.keys(parseAtlasLayouts(JSON.parse(embedded[1]!))).length,6);
});
test('blink occupies only 160ms of a 5.2-second cycle, with finite boundary handling',()=>{
  for(const phase of [0,4.599,4.76,5.2,NaN,Infinity,-Infinity])assert.equal(isBlinking(phase),false,`${phase}`);
  for(const phase of [4.6,4.7,4.759,9.9,-.5])assert.equal(isBlinking(phase),true,`${phase}`);
});
test('compact idle playback rests four seconds and then traverses its four exact frames',()=>{
  const durations=[250,160,130,200];
  assert.equal(frameIndex(durations,4,0),0);assert.equal(frameIndex(durations,4,3.99),0);
  assert.equal(frameIndex(durations,4,4.3),1);assert.equal(frameIndex(durations,4,4.45),2);
  assert.equal(frameIndex(durations,4,4.6),3);assert.equal(frameIndex(durations,4,4.75),0);
  assert.equal(frameIndex(durations,4,Infinity),0);assert.equal(frameIndex(durations,4,-.1),3);
});
function image():Raster{return{width:80,height:70,data:new Uint8ClampedArray(80*70*4)};}
function pixel(raster:Raster,x:number,y:number,alpha=255):void{const i=(y*raster.width+x)*4;raster.data.set([100,120,140,alpha],i);}
test('body extraction keeps its connected pose and fringe but removes neighboring fragments',()=>{
  const raster=image();
  for(let y=10;y<40;y++)for(let x=12;x<36;x++)pixel(raster,x,y);
  pixel(raster,11,20,32);pixel(raster,65,20);pixel(raster,66,20);
  const original=raster.data.slice();
  const body=mainBody(raster,{x:0,y:0,width:80,height:70});
  assert.deepEqual(body.bounds,{x:10,y:8,width:28,height:34});
  assert.equal(body.data[((20-body.bounds.y)*body.width+11-body.bounds.x)*4+3],32);
  assert.equal(body.width*body.height*4,body.data.length);assert.deepEqual(raster.data,original);
  assert.ok(!Array.from(body.data).includes(65));
});
test('pose search never follows an opaque component outside its side of the sheet',()=>{
  const raster=image();for(let y=5;y<30;y++)for(let x=8;x<25;x++)pixel(raster,x,y);
  for(let y=3;y<60;y++)for(let x=40;x<78;x++)pixel(raster,x,y);
  const body=mainBody(raster,{x:0,y:0,width:35,height:70});
  assert.ok(body.bounds.x+body.width<=35);assert.deepEqual(body.bounds,{x:6,y:3,width:21,height:29});
});
test('empty or malformed character pixels fail without constructing a pose',()=>{
  assert.throws(()=>mainBody(image(),{x:0,y:0,width:80,height:70}),/empty/);
  assert.throws(()=>mainBody({width:80,height:70,data:new Uint8ClampedArray(1)},{x:0,y:0,width:80,height:70}),/Invalid/);
});
test('closed-eye crops register to the fixed original pose rather than moving the body',()=>{
  const original={x:100,y:200,width:400,height:800},closed={x:103,y:195,width:420,height:780};
  const result=registerEye({x:180,y:350,width:100,height:80},original,closed);
  assert.deepEqual(result.target,{x:69,y:141.2,width:122,height:97.6});
  assert.equal(result.source.x,69*420/400);assert.equal(result.source.y,141.2*780/800);
  assert.equal(result.source.width,122*420/400);assert.equal(result.source.height,97.6*780/800);
  assert.deepEqual(original,{x:100,y:200,width:400,height:800});
});
