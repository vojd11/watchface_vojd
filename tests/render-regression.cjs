// Host-side regression harness for the actual Monkey C rendering methods.
// This substitutes a deterministic clipped raster for Garmin Dc; it is not a
// simulator or power profiler. Compile with monkeyc separately for API checks.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync('source/Instinct2DraftView.mc', 'utf8');
String.prototype.equals = function (other) { return String(this) === String(other); };
Number.prototype.toNumber = function () { return Math.trunc(this); };
Number.prototype.toFloat = function () { return Number(this); };
Number.prototype.format = function () { return String(this).padStart(2, '0'); };
const Graphics = {
  COLOR_BLACK: 0, COLOR_WHITE: 1, COLOR_TRANSPARENT: -1,
  FONT_TINY: 1, FONT_XTINY: 1, FONT_SYSTEM_XTINY: 1, FONT_NUMBER_MILD: 2,
  TEXT_JUSTIFY_LEFT: 0, TEXT_JUSTIFY_CENTER: 1, TEXT_JUSTIFY_VCENTER: 2,
  ARC_CLOCKWISE: 0
};
class Dc {
  constructor() { this.pixels = new Uint8Array(176 * 176); this.clearClip(); this.clears = []; }
  getWidth() { return 176; } getHeight() { return 176; }
  getFontHeight(f) { return f === 9 ? 72 : f === 2 ? 20 : 16; }
  getTextWidthInPixels(t, f) { return String(t).length * (f === 9 ? 29 : f === 2 ? 12 : 8); }
  clearClip() { this.clip = [0, 0, 176, 176]; }
  setClip(...r) { this.clip = r.map(Math.trunc); }
  setColor(f, b) { this.color = f; this.background = b; }
  setPenWidth() {}
  pixel(x, y, c = this.color) {
    x = Math.trunc(x); y = Math.trunc(y);
    const [cx, cy, w, h] = this.clip;
    if (x >= 0 && y >= 0 && x < 176 && y < 176 && x >= cx && y >= cy && x < cx+w && y < cy+h) this.pixels[y*176+x] = c;
  }
  clear() {
    this.clears.push([...this.clip]);
    const [x,y,w,h] = this.clip;
    for (let j=y;j<y+h;j++) for(let i=x;i<x+w;i++) this.pixel(i,j,this.background);
  }
  fillRectangle(x,y,w,h) { for(let j=y;j<y+h;j++) for(let i=x;i<x+w;i++) this.pixel(i,j); }
  drawPoint(x,y) { this.pixel(x,y); }
  drawLine(x,y,ex,ey) {
    const n=Math.max(Math.abs(ex-x),Math.abs(ey-y),1);
    for(let i=0;i<=n;i++) this.pixel(Math.round(x+(ex-x)*i/n),Math.round(y+(ey-y)*i/n));
  }
  drawRectangle(x,y,w,h) { this.drawLine(x,y,x+w,y); this.drawLine(x+w,y,x+w,y+h); this.drawLine(x+w,y+h,x,y+h); this.drawLine(x,y+h,x,y); }
  drawArc(x,y,r,dir,start,end) { for(let a=start;a>=end;a--) this.pixel(Math.round(x+r*Math.cos(a*Math.PI/180)),Math.round(y-r*Math.sin(a*Math.PI/180))); }
  drawText(x,y,font,text,flags) {
    text=String(text); const w=this.getTextWidthInPixels('0',font), h=this.getFontHeight(font);
    if(flags & 1) x-=Math.trunc(w*text.length/2);
    if(flags & 2) y-=Math.trunc(h/2);
    // Large font ink follows the checked-in BMFont's vertical metrics.
    for(let k=0;k<text.length;k++) for(let j=font===9?13:2;j<(font===9?67:h-2);j++)
      for(let i=1;i<w-1;i++) if((i+j+text.charCodeAt(k))%5<3) this.pixel(x+k*w+i,y+j);
  }
}
function view() {
  const ctx={Graphics,timeFontResource:9,_hrSamples:Array(90).fill(null)};
  for(const m of source.matchAll(/private var (_\w+) as [^;=]+ = ([^;]+);/g)) ctx[m[1]]=Function('return '+m[2])();
  const names=['drawChangedFrame','digitWidth','clearRegion','drawSeconds','drawDynamicRegions','renderHrGraph','invalidateSeconds'];
  for(const name of names) {
    const re=new RegExp('function '+name+'\\(([^)]*)\\) as \\w+ \\{');
    const m=re.exec(source); assert(m, name);
    const start=m.index+m[0].length; let end=start,depth=1;
    while(depth) { if(source[end]==='{')depth++; if(source[end]==='}')depth--; end++; }
    const params=m[1].replace(/ as [\w.]+/g,'');
    const body=source.slice(start,end-1).replace(/\.length\(\)/g,'.length');
    const run=Function('ctx','args',`with(ctx) { return (function(${params}) {${body}}).apply(ctx,args); }`);
    ctx[name]=(...args)=>run(ctx,args);
  }
  Object.assign(ctx,{_hoursStr:'12',_minutesStr:'34',_dateStr:'21.09.2026',_dayOfWeekStr:'MON',_batteryStr:'70%',_batteryLevel:70,_stepsStr:'1000',_stepsProgress:0.2});
  return ctx;
}
const v=view(), dc=new Dc();
v.drawChangedFrame(dc,0,'72',true);
// Incremental output must match a fresh render after independent data changes.
const fixtures=[
  {_minutesStr:'35'}, {_minutesStr:'40'}, {_hoursStr:'13',_minutesStr:'00'},
  {_batteryStr:'9%',_batteryLevel:9}, {_stepsProgress:0.9}, {_stepsProgress:0},
  {_dateStr:'22.09.2026',_dayOfWeekStr:'TUE'}, {_tempStr:'--',_hiLowStr:'--/--'},
  {_stepsStr:'9876',_drainStr:'2.1%/d'}, {_hoursStr:'00',_minutesStr:'00'},
];
for(const fixture of fixtures) {
  Object.assign(v,fixture); v.drawChangedFrame(dc,0,'72',false);
  const expected=new Dc(); v.drawChangedFrame(expected,0,'72',true);
  assert.deepEqual(dc.pixels,expected.pixels,JSON.stringify(fixture));
}
// Every second, including rollovers and repeated callbacks: only changed cells.
let previous='00';
for(let n=1;n<=86400;n++) {
  const second=n%60, text=String(second).padStart(2,'0');
  dc.clears=[]; v.drawSeconds(dc,second);
  const count=Number(previous[0]!==text[0])+Number(previous[1]!==text[1]);
  assert.equal(dc.clears.length,count);
  assert(dc.clears.every(r=>r[2]===v._secondDigitWidth && r[3]===v._secClipH));
  dc.clears=[]; v.drawSeconds(dc,second); assert.equal(dc.clears.length,0);
  previous=text;
}
v.invalidateSeconds(); dc.clears=[]; v.drawSeconds(dc,0); assert.equal(dc.clears.length,2);
// No whole-screen clear on minute update or a repeated frame.
v._minutesStr='01'; dc.clears=[]; v.drawChangedFrame(dc,0,'72',false);
assert(!dc.clears.some(r=>r[2]===176 && r[3]===176));
dc.clears=[]; v.drawChangedFrame(dc,0,'72',false); assert.equal(dc.clears.length,0);
// Check all minute/hour carries, including midnight, without repainting
// unchanged large digits.
let oldTime=v._hoursStr+v._minutesStr;
for(let n=2;n<=1440;n++) {
  const total=n%1440;
  v._hoursStr=String(Math.trunc(total/60)).padStart(2,'0');
  v._minutesStr=String(total%60).padStart(2,'0');
  const next=v._hoursStr+v._minutesStr;
  dc.clears=[]; v.drawChangedFrame(dc,0,'72',false);
  const cells=dc.clears.filter(r=>r[2]===29 && r[3]===72);
  assert.equal(cells.length,[...next].filter((d,i)=>d!==oldTime[i]).length);
  oldTime=next;
}
for(const hr of ['99','100','--','72']) {
  v.drawDynamicRegions(dc,1,hr);
  const expected=new Dc(); v.drawChangedFrame(expected,1,hr,true);
  assert.deepEqual(dc.pixels,expected.pixels,'HR transition '+hr);
}
v._hrSamples[0]=70; v._hrSamples[5]=90; v._hrMin=70; v._hrMax=90;
v._hrSampleCount=90; v._graphDirty=true;
v.drawChangedFrame(dc,1,'72',false);
let expected=new Dc(); v.drawChangedFrame(expected,1,'72',true);
assert.deepEqual(dc.pixels,expected.pixels,'new graph');
v._hrSampleCount=0; v._graphDirty=true; v.drawChangedFrame(dc,1,'72',false);
expected=new Dc(); v.drawChangedFrame(expected,1,'72',true);
assert.deepEqual(dc.pixels,expected.pixels,'empty graph');
console.log('PASS: raster equivalence, 86,400 seconds, 1,439 minute transitions, repeated callbacks, cache recovery, HR and graph changes');
