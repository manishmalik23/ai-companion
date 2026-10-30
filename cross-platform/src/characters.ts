/** Original 4 × 3 atlases shared, without modification, with the native app. */
export const animatedCharacterChoices = [
  { id: 'peach-puff', name: 'Peach Puff', asset: 'PeachPuff' },
  { id: 'lavender-mochi', name: 'Lavender Mochi', asset: 'LavenderMochi' },
  { id: 'mint-bean', name: 'Mint Bean', asset: 'MintBean' },
  { id: 'nimbo', name: 'Nimbo', asset: 'Nimbo' },
  { id: 'chai', name: 'Chai', asset: 'Chai' },
  { id: 'plumo', name: 'Plumo', asset: 'Plumo' }
] as const;
/** Keep the released choices and their ordering stable. */
export const characterChoices = [
  { id: 'default', name: 'Default Pip' },
  { id: 'sunny', name: 'Sunny' }, { id: 'mochi', name: 'Mochi' },
  { id: 'boba', name: 'Boba' }, { id: 'lumi', name: 'Lumi' },
  { id: 'mallow', name: 'Mallow' }, { id: 'sprout', name: 'Sprout' },
  ...animatedCharacterChoices
] as const;
export type CharacterChoice = typeof characterChoices[number]['id'];
type AnimatedCharacterChoice = typeof animatedCharacterChoices[number]['id'];
type LegacyCharacterChoice = Exclude<CharacterChoice, 'default' | AnimatedCharacterChoice>;
// build-ui embeds the authoritative resource in the external renderer bundle.
declare const __PIP_FLUFFY_LAYOUTS__: unknown;
export type Mood = 'idle' | 'working' | 'waiting';
export interface Appearance { selection: string; custom?: { kind: 'still' | 'sprite'; dataUrl: string; name: string } }
export interface Rectangle { x: number; y: number; width: number; height: number }
export interface Raster { width: number; height: number; data: Uint8ClampedArray }
export interface Body extends Raster { bounds: Rectangle }
interface Descriptor { split: number; idle: Rectangle[]; working: Rectangle[]; matchColors?: boolean }
const eye = (x: number, y: number, width: number, height: number): Rectangle => ({ x, y, width, height });
export const descriptors: Record<LegacyCharacterChoice, Descriptor> = {
  sunny: { split: 652, idle: [eye(177,433,148,158),eye(429,485,143,161)], working: [eye(798,579,146,146),eye(1038,558,108,156)] },
  mochi: { split: 639, idle: [eye(178,427,130,134),eye(387,502,115,128)], working: [eye(780,570,127,126),eye(995,570,117,126)] },
  boba: { split: 644, idle: [eye(187,430,186,193),eye(432,409,154,185)], working: [eye(795,628,168,155),eye(1006,663,151,145)], matchColors: true },
  lumi: { split: 630, idle: [eye(170,354,182,166),eye(405,409,170,165)], working: [eye(735,538,190,157),eye(982,493,142,169)] },
  mallow: { split: 667, idle: [eye(170,319,150,146),eye(414,392,148,137)], working: [eye(730,501,145,144),eye(968,524,140,143)] },
  sprout: { split: 590, idle: [eye(118,318,160,169),eye(327,373,151,159)], working: [eye(762,515,138,139),eye(977,551,117,137)] }
};
const atlasSequences: Record<Mood, readonly { column: number; milliseconds: number }[]> = {
  idle: [
    { column: 0, milliseconds: 4250 }, { column: 1, milliseconds: 160 },
    { column: 2, milliseconds: 130 }, { column: 3, milliseconds: 200 }
  ],
  working: [
    ...Array.from({ length: 4 }, () => [0, 1, 3, 1].map(column => ({ column, milliseconds: 300 }))).flat(),
    { column: 2, milliseconds: 130 }, { column: 3, milliseconds: 300 }
  ],
  waiting: [
    { column: 0, milliseconds: 2800 }, { column: 1, milliseconds: 700 },
    { column: 2, milliseconds: 130 }, { column: 3, milliseconds: 700 }
  ]
};
/** Millisecond boundaries avoid accumulated fractional-second drift within a cycle. */
export function atlasFrameIndex(mood: Mood, phase: number): number {
  if (!Number.isFinite(phase)) return 0;
  const sequence = atlasSequences[mood], cycle = sequence.reduce((sum, frame) => sum + frame.milliseconds, 0);
  let milliseconds = (phase * 1000) % cycle;
  if (!Number.isFinite(milliseconds)) return 0;
  if (milliseconds < 0) milliseconds += cycle;
  for (const frame of sequence) {
    if (milliseconds < frame.milliseconds) return frame.column;
    milliseconds -= frame.milliseconds;
  }
  return 0;
}
/** Partition the entire image exactly; 1254-pixel columns alternate 313/314 pixels. */
export function atlasCell(width: number, height: number, column: number, mood: Mood): Rectangle {
  const row = mood === 'working' ? 1 : mood === 'waiting' ? 2 : 0;
  const x = Math.floor(column * width / 4), y = Math.floor(row * height / 3);
  return { x, y, width: Math.floor((column + 1) * width / 4) - x, height: Math.floor((row + 1) * height / 3) - y };
}
export interface RegisteredAtlas { frames: Rectangle[]; canvas: { width: number; height: number } }
export type AtlasLayouts = Record<AnimatedCharacterChoice, RegisteredAtlas>;
function record(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value !== null && !Array.isArray(value); }
/** Validate packaged registrations before using any source rectangle or canvas size. */
export function parseAtlasLayouts(value: unknown): AtlasLayouts {
  const invalid = () => { throw new Error('Invalid built-in character layout.'); };
  if (!record(value) || value.version !== 1 || value.width !== 1254 || value.height !== 1254 || value.columns !== 4 || value.rows !== 3 || !record(value.characters)) return invalid();
  const characters = value.characters;
  if (Object.keys(characters).length !== animatedCharacterChoices.length) return invalid();
  const output = {} as AtlasLayouts;
  for (const choice of animatedCharacterChoices) {
    const entry = characters[choice.id];
    if (!Object.hasOwn(characters, choice.id) || !record(entry) || entry.file !== `${choice.asset}.png` || !Array.isArray(entry.frames) || entry.frames.length !== 12 || !Array.isArray(entry.canvas) || entry.canvas.length !== 2) return invalid();
    const frames: Rectangle[] = [];
    for (const [index, frame] of entry.frames.entries()) {
      if (!Array.isArray(frame) || frame.length !== 4 || !frame.every(coordinate => Number.isInteger(coordinate))) return invalid();
      const [x, y, width, height] = frame as number[];
      const cell = atlasCell(1254, 1254, index % 4, index < 4 ? 'idle' : index < 8 ? 'working' : 'waiting');
      if (x! < cell.x || y! < cell.y || width! < 1 || height! < 1 || x! + width! > cell.x + cell.width || y! + height! > cell.y + cell.height) return invalid();
      frames.push({ x: x!, y: y!, width: width!, height: height! });
    }
    const [width, height] = entry.canvas as unknown[];
    if (!Number.isInteger(width) || !Number.isInteger(height) || width !== Math.max(...frames.map(frame => frame.width)) || height !== Math.max(...frames.map(frame => frame.height))) return invalid();
    output[choice.id] = { frames, canvas: { width: width as number, height: height as number } };
  }
  return output;
}
let registeredLayouts: AtlasLayouts | undefined;
function layouts(): AtlasLayouts {
  return registeredLayouts ??= parseAtlasLayouts(typeof __PIP_FLUFFY_LAYOUTS__ === 'undefined' ? undefined : __PIP_FLUFFY_LAYOUTS__);
}
export function isBlinking(phase: number): boolean {
  if (!Number.isFinite(phase)) return false;
  let seconds = phase % 5.2;
  if(seconds<0)seconds+=5.2;
  return seconds >= 4.6 && seconds < 4.76;
}
export function frameIndex(durations: number[], hold: number, phase: number, rate = 1): number {
  if (!Number.isFinite(phase)) return 0;
  const cycle = durations.reduce((a,b) => a+b, 0) / (1000 * rate) + hold;
  let seconds = phase % cycle;
  if(seconds<0)seconds+=cycle;
  if (seconds < hold) return 0;
  seconds = (seconds - hold) * 1000 * rate;
  for (let i = 0; i < durations.length; i++) { if (seconds < durations[i]!) return i; seconds -= durations[i]!; }
  return 0;
}
/** Keep only the largest connected opaque component, with its anti-aliased fringe. */
export function mainBody(image: Raster, region: Rectangle): Body {
  const { width, height, data } = image;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 || width > 4096 || height > 4096 || data.length !== width * height * 4) throw new Error('Invalid character pixels.');
  const minX = Math.max(0, Math.floor(region.x)), minY = Math.max(0, Math.floor(region.y));
  const maxX = Math.min(width, Math.ceil(region.x + region.width)), maxY = Math.min(height, Math.ceil(region.y + region.height));
  const visited = new Uint8Array(width * height), queue = new Int32Array(Math.max(0, maxX-minX) * Math.max(0, maxY-minY));
  let best = new Int32Array(0), bounds: Rectangle | undefined;
  for (let y = minY; y < maxY; y++) for (let x = minX; x < maxX; x++) {
    const start = y * width + x;
    if (visited[start] || data[start * 4 + 3]! < 64) continue;
    visited[start] = 1; queue[0] = start;
    let count = 1, cursor = 0, left = x, right = x, top = y, bottom = y;
    while (cursor < count) {
      const value = queue[cursor++]!, px = value % width, py = Math.floor(value / width);
      left = Math.min(left,px); right = Math.max(right,px); top = Math.min(top,py); bottom = Math.max(bottom,py);
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        if (dx === 0 && dy === 0) continue;
        const nx = px + dx, ny = py + dy;
        if (nx < minX || nx >= maxX || ny < minY || ny >= maxY) continue;
        const next = ny * width + nx;
        if (!visited[next] && data[next * 4 + 3]! >= 64) { visited[next] = 1; queue[count++] = next; }
      }
    }
    if (count > best.length) {
      best = queue.slice(0,count);
      const bx = Math.max(minX,left-2), by = Math.max(minY,top-2);
      bounds = { x: bx, y: by, width: Math.min(maxX,right+3)-bx, height: Math.min(maxY,bottom+3)-by };
    }
  }
  if (!bounds || best.length <= 100) throw new Error('The character pose is empty.');
  const output = new Uint8ClampedArray(bounds.width * bounds.height * 4);
  for (const index of best) {
    const px = index % width, py = Math.floor(index / width);
    for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
      const x = px+dx, y = py+dy;
      if (x < bounds.x || x >= bounds.x+bounds.width || y < bounds.y || y >= bounds.y+bounds.height) continue;
      const source = (y*width+x)*4, target = ((y-bounds.y)*bounds.width+x-bounds.x)*4;
      output.set(data.subarray(source,source+4),target);
    }
  }
  return { width: bounds.width, height: bounds.height, data: output, bounds };
}
export function registerEye(target: Rectangle, open: Rectangle, closed: Rectangle): { target: Rectangle; source: Rectangle } {
  const expanded = { x: target.x-target.width*.11, y: target.y-target.height*.11, width: target.width*1.22, height: target.height*1.22 };
  return {
    target: { ...expanded, x: expanded.x-open.x, y: expanded.y-open.y },
    source: { x: (expanded.x-open.x)*closed.width/open.width, y: (expanded.y-open.y)*closed.height/open.height,
      width: expanded.width*closed.width/open.width, height: expanded.height*closed.height/open.height }
  };
}
function canvas(width: number, height: number): HTMLCanvasElement {
  const result = document.createElement('canvas'); result.width = width; result.height = height; return result;
}
function pixels(image: HTMLImageElement): Raster {
  const result = canvas(image.naturalWidth,image.naturalHeight), context = result.getContext('2d',{willReadFrequently:true})!;
  context.drawImage(image,0,0); return { width: result.width, height: result.height, data: context.getImageData(0,0,result.width,result.height).data };
}
function imageCanvas(image: Raster): HTMLCanvasElement {
  const result = canvas(image.width,image.height);
  const data = new ImageData(image.width,image.height); data.data.set(image.data);
  result.getContext('2d')!.putImageData(data,0,0); return result;
}
function loadImage(source: string): Promise<HTMLImageElement> {
  return new Promise((resolve,reject) => { const result = new Image(); result.onload = () => resolve(result); result.onerror = () => reject(new Error('The character image could not be loaded.')); result.src = source; });
}
interface Patch { image: HTMLCanvasElement; rectangle: Rectangle }
interface Pose { image: HTMLCanvasElement; bounds: Rectangle; patches: Patch[] }
export interface Drawing { kind: 'still' | 'sprite' | 'builtin' | 'atlas'; image?: HTMLImageElement; idle?: Pose; working?: Pose; layout?: RegisteredAtlas; width: number; height: number }
function patchImage(closed: HTMLCanvasElement, base: HTMLCanvasElement, registration: {target: Rectangle; source: Rectangle}, matchColors: boolean): HTMLCanvasElement {
  const { target, source } = registration, result = canvas(Math.round(target.width),Math.round(target.height));
  const context = result.getContext('2d',{willReadFrequently:true})!;
  context.drawImage(closed,source.x,source.y,source.width,source.height,0,0,result.width,result.height);
  const patch = context.getImageData(0,0,result.width,result.height);
  if (matchColors && result.width > 12 && result.height > 12) {
    const comparison = canvas(result.width,result.height), comparisonContext = comparison.getContext('2d',{willReadFrequently:true})!;
    comparisonContext.drawImage(base,target.x,target.y,target.width,target.height,0,0,result.width,result.height);
    const original = comparisonContext.getImageData(0,0,result.width,result.height).data;
    const corners = [[2,2],[result.width-8,2],[2,result.height-8],[result.width-8,result.height-8]];
    const offsets = corners.map(([left,top]) => {
      const sums = [0,0,0]; let count = 0;
      for (let y = top!; y < top!+6; y++) for (let x = left!; x < left!+6; x++) {
        const i = (y*result.width+x)*4;
        if (original[i+3]! < 200 || patch.data[i+3]! < 200) continue;
        for (let channel=0;channel<3;channel++) sums[channel] = sums[channel]!+original[i+channel]!-patch.data[i+channel]!;
        count++;
      }
      return sums.map(sum => count ? sum/count : 0);
    });
    for (let y=0;y<result.height;y++) for (let x=0;x<result.width;x++) {
      const fx=x/(result.width-1), fy=y/(result.height-1), i=(y*result.width+x)*4;
      for (let c=0;c<3;c++) {
        const upper=offsets[0]![c]!*(1-fx)+offsets[1]![c]!*fx, lower=offsets[2]![c]!*(1-fx)+offsets[3]![c]!*fx;
        patch.data[i+c] = Math.round(Math.min(255,Math.max(0,patch.data[i+c]!+upper*(1-fy)+lower*fy)));
      }
    }
  }
  // A soft rectangular mask covers the iris without moving body/laptop pixels.
  for (let y=0;y<result.height;y++) for (let x=0;x<result.width;x++) {
    const px=(x+.5)/result.width*2-1, py=(y+.5)/result.height*2-1;
    const radius=Math.pow(Math.pow(Math.abs(px),4)+Math.pow(Math.abs(py),4),.25);
    const edge=Math.min(1,Math.max(0,(radius-.84)/.16));
    patch.data[(y*result.width+x)*4+3] = Math.round(patch.data[(y*result.width+x)*4+3]!*(1-edge*edge*(3-2*edge)));
  }
  context.putImageData(patch,0,0); return result;
}
function pose(open: Raster, closed: Raster | undefined, region: Rectangle, eyes: Rectangle[], matchColors: boolean): Pose {
  const body=mainBody(open,region), base=imageCanvas(body), closedBody=closed ? mainBody(closed,region) : undefined;
  const patches: Patch[]=[];
  if (closedBody) {
    const closedImage=imageCanvas(closedBody);
    for (const target of eyes) {
      const registered=registerEye(target,body.bounds,closedBody.bounds), r=registered.target;
      if (r.x < 0 || r.y < 0 || r.x+r.width > body.width || r.y+r.height > body.height) continue;
      patches.push({ image: patchImage(closedImage,base,registered,matchColors), rectangle:r });
    }
  }
  return { image:base,bounds:body.bounds,patches };
}
const builtins=new Map<string,Promise<Drawing>>();
export function loadCharacter(appearance: Appearance): Promise<Drawing> {
  const id=appearance.selection;
  if (id==='custom' && appearance.custom) return loadImage(appearance.custom.dataUrl).then(image => ({ kind:appearance.custom!.kind,image,width:image.naturalWidth,height:image.naturalHeight }));
  const animated = animatedCharacterChoices.find(choice => choice.id === id);
  if (animated) {
    if (!builtins.has(id)) builtins.set(id, loadImage(`characters/${animated.asset}.png`).then(image => {
      if (image.naturalWidth !== 1254 || image.naturalHeight !== 1254) throw new Error('Invalid built-in character dimensions.');
      const layout = layouts()[animated.id];
      return { kind: 'atlas', image, layout, width: layout.canvas.width, height: layout.canvas.height };
    }));
    return builtins.get(id)!;
  }
  if (id==='default' || !Object.hasOwn(descriptors,id)) {
    if (!builtins.has('default')) builtins.set('default',loadImage('robot.png').then(image => ({kind:'sprite',image,width:image.naturalWidth,height:image.naturalHeight})));
    return builtins.get('default')!;
  }
  if (!builtins.has(id)) builtins.set(id,(async () => {
    const name=characterChoices.find(choice=>choice.id===id)!.name;
    const image=await loadImage(`characters/${name}.png`), blink=await loadImage(`characters/${name}Blink.png`).catch(()=>undefined);
    if (image.naturalWidth!==1254 || image.naturalHeight!==1254 || (blink && (blink.naturalWidth!==1254 || blink.naturalHeight!==1254))) throw new Error('Invalid built-in character dimensions.');
    const descriptor=descriptors[id as LegacyCharacterChoice], open=pixels(image), closed=blink?pixels(blink):undefined;
    const idle=pose(open,closed,{x:0,y:0,width:descriptor.split+40,height:1254},descriptor.idle,!!descriptor.matchColors);
    const working=pose(open,closed,{x:descriptor.split-40,y:0,width:1254-descriptor.split+40,height:1254},descriptor.working,!!descriptor.matchColors);
    return {kind:'builtin',idle,working,width:Math.max(idle.image.width,working.image.width),height:Math.max(idle.image.height,working.image.height)};
  })());
  return builtins.get(id)!;
}
const legacyDurations=[[280,110,110,140,140,320],[120,120,120,120,120,120,120,220],[120,120,120,120,120,120,120,220],[140,140,140,280],[140,140,140,140,280],[140,140,140,140,140,140,140,240],[150,150,150,150,150,260],[120,120,120,120,120,220],[150,150,150,150,150,280]];
function waitingBadge(context: CanvasRenderingContext2D, bounds: Rectangle): void {
  const side=Math.min(bounds.width,bounds.height)*.18, x=bounds.x+bounds.width-side*.7, y=bounds.y+side*.2;
  context.fillStyle='#ffd05b'; context.beginPath(); context.roundRect(x-side/2,y-side/2,side,side,side*.25); context.fill();
  context.fillStyle='#3d321e'; context.font=`700 ${side*.8}px sans-serif`; context.textAlign='center'; context.textBaseline='middle'; context.fillText('!',x,y+side*.04);
}
function workingOverlay(context: CanvasRenderingContext2D, bounds: Rectangle, phase: number): void {
  const cx=bounds.x+bounds.width*.465,cy=bounds.y+bounds.height*.69,side=bounds.width*.055;
  context.globalAlpha=.7+.3*(Math.sin(phase*Math.PI/1.2)+1)/2; context.fillStyle='#20d9ff'; context.beginPath();
  const points=[[0,-1],[.32,-.32],[1,0],[.32,.32],[0,1],[-.32,.32],[-1,0],[-.32,-.32]];
  points.forEach(([x,y],i)=>i?context.lineTo(cx+x!*side,cy+y!*side):context.moveTo(cx+x!*side,cy+y!*side)); context.closePath();context.fill();context.globalAlpha=1;
  if (isBlinking(phase)) for (const fraction of [.39,.685]) {
    const x=bounds.x+bounds.width*fraction,y=bounds.y+bounds.height*.452;
    context.fillStyle='#141f38';context.beginPath();context.ellipse(x,y,bounds.width*.09,bounds.height*.095,0,0,Math.PI*2);context.fill();
    context.strokeStyle='#20d9ff';context.lineWidth=Math.max(1,bounds.width*.012);context.lineCap='round';context.beginPath();context.moveTo(x-bounds.width*.04,y);context.quadraticCurveTo(x,y+bounds.height*.025,x+bounds.width*.04,y);context.stroke();
  }
}
export function drawCharacter(context: CanvasRenderingContext2D, drawing: Drawing, bounds: Rectangle, mood: Mood, phase: number): void {
  context.save(); context.imageSmoothingEnabled=true;
  let destination: Rectangle;
  if (drawing.kind==='atlas') {
    const row=mood==='working'?1:mood==='waiting'?2:0,source=drawing.layout!.frames[row*4+atlasFrameIndex(mood,phase)]!;
    const scale=Math.min(bounds.width/drawing.width,bounds.height/drawing.height);
    destination={x:bounds.x+(bounds.width-source.width*scale)/2,y:bounds.y+bounds.height-source.height*scale,width:source.width*scale,height:source.height*scale};
    context.drawImage(drawing.image!,source.x,source.y,source.width,source.height,destination.x,destination.y,destination.width,destination.height);
  } else if (drawing.kind==='builtin') {
    const selected=mood==='working'?drawing.working!:drawing.idle!, scale=Math.min(bounds.width/drawing.width,bounds.height/drawing.height);
    destination={x:bounds.x+(bounds.width-selected.image.width*scale)/2,y:bounds.y+bounds.height-selected.image.height*scale,width:selected.image.width*scale,height:selected.image.height*scale};
    context.drawImage(selected.image,destination.x,destination.y,destination.width,destination.height);
    if (isBlinking(phase)) for (const patch of selected.patches) {
      const r=patch.rectangle;context.drawImage(patch.image,destination.x+r.x*scale,destination.y+r.y*scale,r.width*scale,r.height*scale);
    }
  } else {
    const compact=drawing.kind==='sprite'&&drawing.width===1254&&drawing.height===1254;
    const width=drawing.kind==='still'?drawing.width:compact?313.5:192,height=drawing.kind==='still'?drawing.height:compact?418:208;
    const scale=Math.min(bounds.width/width,bounds.height/height);
    destination={x:bounds.x+(bounds.width-width*scale)/2,y:bounds.y+(bounds.height-height*scale)/2,width:width*scale,height:height*scale};
    if (drawing.kind==='still') context.drawImage(drawing.image!,destination.x,destination.y,destination.width,destination.height);
    else {
      const row=compact?(mood==='working'?1:mood==='waiting'?2:0):(mood==='working'?7:mood==='waiting'?6:0);
      const frame=compact?(mood==='working'?0:frameIndex(mood==='idle'?[250,160,130,200]:[240,240,240,300],mood==='idle'?4:0,phase)):
        frameIndex(legacyDurations[row]!,row===0?3.5:row===6?1.6:.6,phase,row===0?.75:row===6?.65:.65);
      const x=compact?Math.floor(frame*drawing.width/4):frame*192,y=compact?row*418:row*208;
      const frameWidth=compact?Math.floor((frame+1)*drawing.width/4)-x:192;
      context.drawImage(drawing.image!,x,y,frameWidth,compact?418:208,destination.x,destination.y,destination.width,destination.height);
      if (compact&&mood==='working') workingOverlay(context,destination,phase);
    }
  }
  if (mood==='waiting' && drawing.kind!=='atlas') waitingBadge(context,destination);
  context.restore();
}
