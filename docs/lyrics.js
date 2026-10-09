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
export function lyricIdentity(record,song){
 const title=normalize(cleanLyricTitle(song.title)),artist=normalize(cleanLyricArtist(song.artist));
 return Boolean(title&&artist&&normalize(cleanLyricTitle(record?.trackName))===title&&normalize(cleanLyricArtist(record?.artistName))===artist);
}
export function lyricData(record,song){
 const valid=record&&lyricIdentity(record,song),timed=valid&&Number(song.duration)>0&&Number(record.duration)>0&&Math.abs(record.duration-song.duration)<=3;
 return valid?{plain:record.plainLyrics||'',lines:timed&&record.syncedLyrics?parseLRC(record.syncedLyrics):[],instrumental:record.instrumental,source:'LRCLIB',record}:{plain:'',lines:[],missing:true};
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
export function activeLyric(lines,seconds){let active=-1;for(let i=0;i<lines.length;i++){if(lines[i].time>seconds)break;active=i}return active;}
