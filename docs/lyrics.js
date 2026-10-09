const normalize=value=>String(value||'').normalize('NFD').replace(/\p{Diacritic}/gu,'').toLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim();
export const cleanLyricTitle=value=>String(value||'').replace(/\s*[\[(](?:official (?:audio|video|music video)|lyrics?|audio|music video|feat\.?|ft\.?).*?[\])]/gi,'').trim();
export const cleanLyricArtist=value=>String(value||'').split(/\s[•·]\s|,|\s&\s|\sfeat\.?\s|\sft\.?\s/i)[0].replace(/\s*- Topic$/i,'').trim();
export function parseLRC(text){
 const offset=Number(String(text).match(/\[offset:([+-]?\d+)\]/i)?.[1]||0)/1000;
 return String(text).split(/\r?\n/).flatMap(line=>{
  const content=line.replace(/\[[^\]]*\]/g,'').trim();
  return [...line.matchAll(/\[(\d{1,3}):(\d{2}(?:[.:]\d+)?)\]/g)].filter(m=>Number(m[2].replace(':','.'))<60).map(m=>({time:Math.max(0,Number(m[1])*60+Number(m[2].replace(':','.'))+offset),text:content}));
 }).sort((a,b)=>a.time-b.time);
}
export function normalizedLines(input){
 const sorted=input.filter(l=>Number.isFinite(l.time)&&l.time>=0).map(l=>({...l,text:/^(?:[♪♫\s]+|\.\.\.|…|\[instrumental(?: break)?\]|\(instrumental\))$/i.test(l.text.trim())?'':l.text.trim()})).sort((a,b)=>a.time-b.time),lines=[];
 for(const line of sorted){const last=lines.at(-1);if(last?.time===line.time){if(line.text&&line.text!==last.text)last.text=[last.text,line.text].filter(Boolean).join('\n');last.endTime=Math.max(last.endTime||0,line.endTime||0)||undefined}else lines.push(line)}
 return lines;
}
export function lyricIdentity(record,song){
 const title=normalize(cleanLyricTitle(song.title)),artist=normalize(cleanLyricArtist(song.artist));
 return Boolean(title&&artist&&normalize(cleanLyricTitle(record?.trackName))===title&&normalize(cleanLyricArtist(record?.artistName))===artist);
}
export function lyricData(record,song){
 const valid=record&&lyricIdentity(record,song),video=song.source==='youtube'&&song.musicVideoType!=='MUSIC_VIDEO_TYPE_ATV';
 const parsed=record?.syncedLyrics?normalizedLines(parseLRC(record.syncedLyrics)):[];
 const timed=valid&&!video&&Number(song.duration)>0&&Number(record.duration)>0&&Math.abs(record.duration-song.duration)<=3&&parsed.every(l=>l.time<=song.duration+2);
 return valid?{plain:record.plainLyrics||parsed.map(l=>l.text).join('\n'),lines:timed?parsed:[],instrumental:record.instrumental,source:'LRCLIB',record}:{plain:'',lines:[],missing:true};
}
export function chooseLyrics(records,song){
 return records.filter(r=>lyricIdentity(r,song)).map((record,index)=>({record,index,score:(lyricData(record,song).lines.length?100:0)+(normalize(record.albumName)===normalize(song.album)&&song.album?20:0)-(song.duration?Math.min(15,Math.abs(record.duration-song.duration)||0):0)})).sort((a,b)=>b.score-a.score||a.index-b.index)[0]?.record||null;
}
export async function lookupLyrics(song,{fetcher=fetch,signal}={}){
 const title=cleanLyricTitle(song.title),artist=cleanLyricArtist(song.artist);
 const read=async path=>{const r=await fetcher('https://lrclib.net/api/'+path,{signal});if(r.status===404)return null;if(!r.ok)throw Error('Lyrics could not load. Please retry.');return r.json()};
 const params=new URLSearchParams({track_name:title,artist_name:artist,...(song.album?{album_name:song.album}:{}),...(song.duration?{duration:String(Math.round(song.duration))}:{})});
 let exact=null;try{exact=await read('get?'+params)}catch(e){if(signal?.aborted)throw e;}
 if(lyricData(exact,song).lines.length||exact?.instrumental&&lyricIdentity(exact,song))return exact;
 const candidates=exact?[exact]:[];
 try{const found=await read('search?'+new URLSearchParams({track_name:title,artist_name:artist}));if(Array.isArray(found))candidates.push(...found)}catch(e){if(signal?.aborted||!exact)throw e;}
 if(!candidates.some(r=>lyricData(r,song).lines.length)){
  try{const found=await read('search?'+new URLSearchParams({q:artist+' '+title}));if(Array.isArray(found))candidates.push(...found)}catch(e){if(signal?.aborted)throw e;}
 }
 return chooseLyrics(candidates,song);
}
export function activeLyric(lines,seconds){if(!Number.isFinite(seconds))return -1;let active=-1;for(let i=0;i<lines.length;i++){if(lines[i].time>seconds)break;active=i}return active>=0&&lines[active].endTime!==undefined&&seconds>=lines[active].endTime?-1:active;}
// Ignore the previous recording's cached YouTube clock while a new one loads.
export function playbackSample(song,player,audio,readyId=song?.id){
 const finite=value=>Number.isFinite(Number(value))&&Number(value)>=0?Number(value):0;
 if(!song)return {position:0,duration:0,confirmed:false};
 if(song.source!=='youtube')return {position:finite(audio?.currentTime),duration:finite(audio?.duration)||finite(song.duration),confirmed:finite(audio?.duration)>0};
 let id='';try{id=new URL(player?.getVideoUrl?.()||'').searchParams.get('v')||''}catch{}
 const confirmed=readyId===song.id&&id===song.id&&finite(player?.getDuration?.())>0;
 return {position:confirmed?finite(player?.getCurrentTime?.()):0,duration:confirmed?finite(player.getDuration()):finite(song.duration),confirmed};
}
export async function preferredAudio(song,request){
 if(song.source!=='youtube'||song.musicVideoType!=='MUSIC_VIDEO_TYPE_OMV')return song;
 const result=await request({query:cleanLyricTitle(song.title)+' '+cleanLyricArtist(song.artist),kind:'Songs',providerOrder:true});
 return result.songs.find(candidate=>candidate.musicVideoType==='MUSIC_VIDEO_TYPE_ATV'&&(!candidate.artistId||!song.artistId||candidate.artistId===song.artistId)&&lyricIdentity({trackName:candidate.title,artistName:candidate.artist},song))||song;
}
