// Render identity contains visible content only. Telemetry, provider records and
// calibration updates must not replace live lyric elements or reload artwork.
export function lyricContentKey(songID, data) {
  return JSON.stringify([songID||'',data ? [data.plain||'',Boolean(data.instrumental),Boolean(data.missing),data.source||'',data.sourceURL||'',(data.lines||[]).map(line=>[line.time,line.text,line.endTime??null])] : null]);
}
const rendered = new WeakMap();
export function patchLyricContent(element, key, html) {
  if (!element || rendered.get(element) === key) return false;
  element.innerHTML = typeof html === 'function' ? html() : html;
  rendered.set(element,key);
  return true;
}
export function lyricInterludeRange(lines,index) {
  const line=lines[index];
  if(!line || line.text.trim())return null;
  const next=lines.slice(index+1).find(next=>next.text.trim() && next.time>line.time);
  return next && next.time-line.time>=2 ? {start:line.time,end:next.time} : null;
}
export function interludeIllumination(time,start,end,dot) {
  if(![time,start,end].every(Number.isFinite)||end<=start)return 0;
  const progress=Math.min(1,Math.max(0,(time-start)/(end-start)));
  const value=Math.min(1,Math.max(0,progress*3-dot));
  return value*value*(3-2*value);
}

// The visual handoff leads the cue; semantic cue lookup stays on the audio clock.
export const lyricMotionDuration = .45;
export function presentedLyric(lines,time,playing) {
  if(!Number.isFinite(time))return -1;
  const next=lines.findIndex(line=>line.time>time);
  const lead=next>=0?Math.min(lyricMotionDuration,next>0?(lines[next].time-lines[next-1].time)/2:lyricMotionDuration):0;
  if(playing&&next>=0&&lines[next].time-time<=lead)return next;
  const index=next<0?lines.length-1:next-1;
  return index>=0&&(lines[index].endTime==null||time<lines[index].endTime)?index:-1;
}
// A finite spring: gentle overshoot and recoil, with an exact endpoint at the cue.
export function lyricSpring(progress) {
  const t=Math.max(0,Math.min(1,progress));
  return 1-Math.pow(1-t,5)*Math.cos(t*Math.PI*2.5);
}
