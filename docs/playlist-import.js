import {normalizeSearch} from './music-search.js?v=4098b6ac99a2';

// CSV is decoded on the device. Only title/artist queries leave the importer.
export function parseCSV(text,delimiter=','){
 const rows=[];let row=[],field='',quoted=false,closed=false;
 const finishField=()=>{row.push(field);field='';closed=false};
 const finishRow=()=>{finishField();if(row.some(value=>value.trim()))rows.push(row);row=[]};
 text=String(text).replace(/^\uFEFF/,'');
 for(let i=0;i<text.length;i++){
  const char=text[i];
  if(quoted){if(char==='"'){if(text[i+1]==='"'){field+='"';i++}else{quoted=false;closed=true}}else field+=char;continue}
  if(char==='"'){if(field||closed)throw Error('The CSV has an unexpected quote. Export it again as CSV.');quoted=true}
  else if(char===delimiter)finishField();
  else if(char==='\r'||char==='\n'){if(char==='\r'&&text[i+1]==='\n')i++;finishRow()}
  else if(closed){if(!/\s/.test(char))throw Error('The CSV has text after a closing quote. Export it again as CSV.')}
  else field+=char;
 }
 if(quoted)throw Error('The CSV ends inside a quoted field. Export the complete file again.');
 if(field||row.length||closed)finishRow();
 return rows;
}
const tidy=value=>String(value||'').replace(/\s+/g,' ').trim();
export function parsePlaylistCSV(text){
 if(new TextEncoder().encode(text).length>5*1024*1024)throw Error('Choose a CSV smaller than 5 MB.');
 let rows,header;
 for(const delimiter of [',','\t',';']){
  try{const parsed=parseCSV(text,delimiter),labels=(parsed[0]||[]).map(normalizeSearch);
   if(labels.includes('track name')&&labels.some(label=>['artist name s','artist names','artists','artist'].includes(label))){rows=parsed;header=labels;break}
  }catch(error){if(delimiter===',')rows=error}
 }
 if(!header){if(rows instanceof Error)throw rows;throw Error('Choose an Exportify CSV with Track Name and Artist Name(s) columns.');}
 const index=(...labels)=>header.findIndex(label=>labels.includes(label));
 const titleIndex=index('track name'),artistIndex=index('artist name s','artist names','artists','artist');
 const value=(row,...labels)=>row[index(...labels)]||'';
 const data=rows.slice(1);if(!data.length)throw Error('This CSV contains no songs.');
 if(data.length>10000)throw Error('Import at most 10,000 entries at a time.');
 return data.map((row,position)=>{
  if(row.length!==header.length)throw Error(`CSV entry ${position+1} has missing or extra columns. Export the file again.`);
  const title=tidy(row[titleIndex]),artists=row[artistIndex].split(';').map(tidy).filter(Boolean),artist=artists.join(', '),uri=tidy(value(row,'track uri','spotify uri'));
  const millis=Number(value(row,'duration ms')),explicit=tidy(value(row,'explicit')).toLowerCase();
  return {title:title||'Unavailable song',artist,artists,album:tidy(value(row,'album name')),uri,isrc:tidy(value(row,'isrc')),duration:Number.isFinite(millis)&&millis>0&&millis<=86400000?millis/1000:0,explicit:['true','false'].includes(explicit)?explicit==='true':undefined,position,reason:!title||!artist?'Missing song title or artist':uri.startsWith('spotify:local:')?'Spotify local file':uri.startsWith('spotify:episode:')?'Podcast episode':''};
 });
}
export function parseSongList(text){
 return String(text).split(/\r?\n/).map(tidy).filter(Boolean).map((line,position)=>{
  // Split once so edition labels and hyphens inside titles survive intact.
  const separator=line.match(/\s+[—–]\s+|\s+-\s+/),at=separator?.index;
  return {title:separator?line.slice(at+separator[0].length):line,artist:separator?line.slice(0,at):'',position,reason:''};
 });
}
const primary=track=>tidy(track.artists?.[0]||track.artist?.split(/;|,|\sfeat\.?\s|\sft\.?\s/i)[0]);
const titleIdentity=value=>normalizeSearch(String(value||'').replace(/\s*[\[(](?:official (?:audio|video|music video)|lyrics?|audio|music video|feat\.?|ft\.?|with\s).*?[\])]/gi,'').replace(/\s+feat\.?\s+.+$/i,''));
const baseTitle=value=>titleIdentity(String(value||'').replace(/\s*[\[(](?:from\s|\d{4}\s*(?:remaster|mix)|remaster|single version|radio edit|mono|stereo).*?[\])]/gi,'').replace(/\s+[-–—]\s+(?:from\s|(?:\d{4}\s+)?remaster|single version|radio edit|original\s.*version|mono|stereo|\d{4}\s+mix).*$/i,''));
function performance(value){
 const text=String(value||'').toLowerCase(),tags=['remix','acoustic','instrumental','karaoke','cover','tribute','sped up','slowed','re-recording'];
 const found=tags.filter(tag=>new RegExp('\\b'+tag+'\\b').test(text));
 if(/(?:[\[(]|\s[-–—]\s).*\blive\b/.test(text))found.push('live');
 return found.sort().join(',');
}
export function chooseImportMatch(track,candidates){
 const title=titleIdentity(track.title),base=baseTitle(track.title),artist=normalizeSearch(primary(track));
 if(track.reason||!title)return null;
 const ranked=[];
 for(const [index,song] of candidates.entries()){
  if(song.liveNow||!song.id||performance(song.title)!==performance(track.title))continue;
  const actualTitle=titleIdentity(song.title),exact=actualTitle===title;
  if(!exact&&baseTitle(song.title)!==base)continue;
  const actualArtist=normalizeSearch(String(song.artist||'').replace(/\s*- Topic$/i,''));
  if(artist&&!(' '+actualArtist.replace(/^the /,'')+' ').includes(' '+artist.replace(/^the /,'')+' '))continue;
  const delta=track.duration&&song.duration?Math.abs(track.duration-song.duration):0;
  if(track.duration&&song.duration&&delta>Math.max(12,track.duration*.06))continue;
  const differentExplicit=typeof track.explicit==='boolean'&&typeof song.explicit==='boolean'&&track.explicit!==song.explicit;
  const official=song.musicVideoType==='MUSIC_VIDEO_TYPE_ATV',review=differentExplicit||!artist||!exact||!official||Boolean(track.duration&&!song.duration);
  const detail=differentExplicit?'Clean/explicit version differs':!exact?'Check recording edition':!artist?'Check artist':!official?'Check recording source':review?'Check recording length':'';
  ranked.push({song,review,detail,score:Number(exact)*100+Number(official)*30-Number(differentExplicit)*40+Number(normalizeSearch(song.album)===normalizeSearch(track.album)&&Boolean(track.album))*15-delta-index*.01});
 }
 ranked.sort((a,b)=>b.score-a.score);return ranked[0]||null;
}
export async function matchPlaylist(tracks,{search,localSongs=[],onProgress=()=>{},onWait=()=>{},signal,concurrency=2,requestInterval=1100}={}){
 const entries=new Array(tracks.length),requests=new Map();let cursor=0,completed=0,nextRequestAt=0;
 const check=()=>{if(signal?.aborted)throw new DOMException('Import cancelled','AbortError')};
 const wait=milliseconds=>new Promise((resolve,reject)=>{
  const done=()=>{signal?.removeEventListener('abort',cancel);resolve()},timer=setTimeout(done,Math.max(0,milliseconds));
  const cancel=()=>{clearTimeout(timer);signal?.removeEventListener('abort',cancel);reject(new DOMException('Import cancelled','AbortError'))};
  signal?.addEventListener('abort',cancel,{once:true});if(signal?.aborted)cancel();
 });
 const query=async text=>{
  check();if(!requests.has(text))requests.set(text,(async()=>{
   for(let attempt=0;attempt<2;attempt++){
    const at=Math.max(Date.now(),nextRequestAt);nextRequestAt=at+requestInterval;await wait(at-Date.now());check();
    try{return await search(text,{signal})}catch(error){check();if(error.status!==429||attempt)throw error;const delay=error.retryAfterMs||60000;nextRequestAt=Math.max(nextRequestAt,Date.now()+delay);onWait(delay);}
   }
  })());return requests.get(text);
 };
 async function worker(){
  while(cursor<tracks.length){check();const index=cursor++,source={...tracks[index],position:tracks[index].position??index};let result=null,error='';
   if(!source.reason){
    try{
     const found=await query(tidy(source.title+' '+primary(source)).slice(0,200));check();
     let candidates=Array.isArray(found)?found:found.songs||[];
     result=chooseImportMatch(source,candidates);
     const base=baseTitle(source.title);
     if((!result||result.review)&&base!==titleIdentity(source.title)){
      const extra=await query(tidy(base+' '+primary(source)).slice(0,200));check();
      candidates=[...candidates,...(Array.isArray(extra)?extra:extra.songs||[])];result=chooseImportMatch(source,candidates);
     }
    }catch(cause){check();error='Search unavailable — retry this entry';}
    const local=chooseImportMatch(source,localSongs);
    if(local&&(!result||result.review&&!local.review))result=local;
   }
   entries[index]=result?{source,...result}:{source,reason:source.reason||error||'No confident recording found',failed:Boolean(error)};
   onProgress(++completed,tracks.length,entries[index]);
  }
 }
 await Promise.all(Array.from({length:Math.min(Math.max(1,concurrency),3,tracks.length)},worker));check();return entries;
}
