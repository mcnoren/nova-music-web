// Keep this policy aligned with MusicSearchRelevance; shared fixtures exercise both.
export const kinds=['songs','artists','albums','playlists'];
export const normalize=value=>String(value??'').normalize('NFD').replace(/\p{Diacritic}/gu,'').toLowerCase()
 .replace(/\b(\p{L}{3,}in)['’](?=\P{L}|$)/gu,'$1g').replace(/(?<=\p{L})['’](?=\p{L})/gu,'')
 .replace(/[^\p{L}\p{N}]+/gu,' ').trim();
export const cleanTitle=value=>String(value||'').replace(/\s*[\[(](?:official\s+)?(?:audio|music video|video|lyric video|lyrics|visualizer)[\])]/gi,'').trim();
export const cleanArtist=value=>String(value||'').split(' • ')[0].replaceAll(' - Topic','').trim();
export const lookupTitle=value=>cleanTitle(value).replace(/\s*[\[(](?:feat\.?|ft\.?|featuring)\s+[^\])]+[\])]/gi,'').trim();
export function searchQuery(input){
 const text=String(input||'').trim(),prefix=/^(?:(?:the\s+)?song\s+(?:that\s+)?(?:goes|with\s+(?:the\s+)?lyrics)|lyrics\s*:)\s*/i;
 const lyricsExplicit=prefix.test(text);
 return {term:(lyricsExplicit?text.replace(prefix,''):text.replace(/^(?:songs|music)\s+by\s+/i,'')).replace(/^[\s"“”]+|[\s"“”]+$/g,''),lyricsExplicit};
}
function distance(a,b){
 const rows=Array.from({length:a.length+1},()=>Array(b.length+1).fill(0));
 for(let i=0;i<=a.length;i++)rows[i][0]=i;for(let j=0;j<=b.length;j++)rows[0][j]=j;
 for(let i=1;i<=a.length;i++)for(let j=1;j<=b.length;j++){
  rows[i][j]=Math.min(rows[i-1][j]+1,rows[i][j-1]+1,rows[i-1][j-1]+(a[i-1]===b[j-1]?0:1));
  if(i>1&&j>1&&a[i-1]===b[j-2]&&a[i-2]===b[j-1])rows[i][j]=Math.min(rows[i][j],rows[i-2][j-2]+1);
 }return rows[a.length][b.length];
}
export function matchesMetadata(title,artist,query){
 const words=normalize(cleanTitle(title)+' '+cleanArtist(artist)).split(' '),tokens=normalize(searchQuery(query).term).split(' ');
 return tokens.some(t=>t&&t!=='by')&&tokens.every(t=>t==='by'||words.some(w=>w===t||t.length>=5&&w.length>=5&&Math.abs(t.length-w.length)<=1&&distance(t,w)<=1));
}
const versionWords=new Set(['live','remix','acoustic','instrumental','karaoke','cover','tribute','demo','rehearsal','take','sped','slowed','radio','extended','edit','clean','explicit']);
export function artistKeys(value){const clean=cleanArtist(value);return new Set([clean,...clean.split(/\s+(?:feat\.?|ft\.?|featuring|with)\s+|\s+[&•]\s+|,\s*/i)].map(normalize).filter(Boolean));}
export const baseTitle=value=>normalize(lookupTitle(value).replace(/\s*[\(\[][^\)\]]*\b(remaster(?:ed)?|stereo|mono|\d{4} mix|from|live|remix|acoustic|instrumental|karaoke|cover|tribute|demo|rehearsal|take|sped|slowed|radio|extended|edit|clean|explicit)\b[^\)\]]*[\)\]]|\s+[-–—]\s+(?:live|remix|acoustic|instrumental|karaoke|cover|demo|rehearsal|take|radio|extended|edit|clean|explicit)\b.*$|\s+(?:cover|karaoke|tribute)$/gi,''));
export function searchTitle(song){const title=song.title||'',match=/\s[-–—]\s/.exec(title);return match&&normalize(title.slice(0,match.index))===normalize(cleanArtist(song.artist))?title.slice(match.index+match[0].length):title;}
export function versions(song){
 const annotations=(searchTitle(song).match(/\([^)]*\)|\[[^]]*\]|\s+[-–—]\s+.*$|\s+(?:cover|karaoke|tribute)$/gi)||[]).join(' ');
 const words=new Set(normalize(annotations).split(' ').filter(w=>versionWords.has(w)));
 for(const w of normalize(song.artist).split(' '))if(['cover','karaoke','tribute'].includes(w))words.add(w);
 if(/^live (at|in|on)\b/.test(normalize(song.album)))words.add('live');return words;
}
export function recordingKey(song){let qualifiers=[...versions(song)].sort().join(' ');const take=normalize(song.title).match(/\btake \d+\b/);if(qualifiers.includes('take')&&take)qualifiers+=' '+take[0];return baseTitle(searchTitle(song))+'|'+normalize(cleanArtist(song.artist))+'|'+qualifiers;}
export function requestedVersions(query,title,artist=''){
 const request=searchQuery(query);if(request.lyricsExplicit)return new Set();const text=normalize(request.term),base=baseTitle(title),baseWords=new Set(base.split(' '));
 const requested=new Set(text.split(' ').filter(w=>!baseWords.has(w)&&versionWords.has(w)));if(!requested.size)return requested;
 const names=value=>matchesMetadata(base,artist,value)&&matchesMetadata(value,'',base);
 if(names(baseTitle(request.term)))return requested;
 if(names(text.replace(/\btake \d+\b/g,'').split(' ').filter(w=>!requested.has(w)).join(' ')))return requested;
 for(const w of requested){const index=text.search(new RegExp('\\b'+w+'\\b'));if(index>=0&&names(text.slice(0,index)))return requested;}
 return new Set();
}
export const popularity=value=>{const match=String(value||'').replaceAll(',','').match(/([\d.]+)\s*([KMB])?/i);return match?(Number(match[1])||0)*({K:1e3,M:1e6,B:1e9}[match[2]?.toUpperCase()]||1):0;};
const compare=(a,b)=>{for(let i=0;i<a.length;i++)if(a[i]!==b[i])return a[i]<b[i]?-1:1;return 0;};
const lexical=(a,b)=>a===b?0:a<b?-1:1;
const key=(kind,id)=>kind+':'+id;
export function recordEvidence(catalog,existing=catalog.evidence){
 const evidence=existing?structuredClone(existing):{providerTop:catalog.top||null,positions:{},overviewPositions:{}};
 for(const kind of kinds){let next=Math.max(-1,...Object.entries(evidence.positions).filter(([k])=>k.startsWith(kind+':')).map(([,v])=>v))+1;
  for(const item of catalog[kind]||[])if(evidence.positions[key(kind,item.id)]===undefined)evidence.positions[key(kind,item.id)]=next++;
 }return evidence;
}
export function mergeSearchPage(first,page,query,kind='All'){
 const result={...first,cursor:page.cursor===first.cursor?'':page.cursor,lyricSongIDs:[...new Set([...(first.lyricSongIDs||[]),...(page.lyricSongIDs||[])])]};
 for(const type of kinds){const seen=new Set((first[type]||[]).map(x=>x.id));result[type]=[...(first[type]||[]),...(page[type]||[]).filter(x=>!seen.has(x.id)&&seen.add(x.id))];}
 result.evidence=recordEvidence(result,first.evidence||recordEvidence(first));return rankCatalog(result,query,kind);
}
export function rankCatalog(catalog,query=catalog.correction||catalog.query||'',kind='All'){
 const result={...catalog},evidence=recordEvidence(catalog),request=searchQuery(query),q=normalize(request.term),provider=evidence.providerTop;
 result.evidence=evidence;for(const type of kinds)result[type]=[...(catalog[type]||[])];if(!q)return result;
 const pos=(type,id)=>evidence.positions[key(type,id)]??Number.MAX_SAFE_INTEGER,featured=(type,id)=>provider?.kind===type&&provider.id===id;
 const namedArtist=[...result.artists.map(x=>x.name),...result.songs.map(x=>cleanArtist(x.artist))].map(normalize).filter(name=>name&&(' '+q+' ').includes(' '+name+' ')&&(q===name||result.songs.some(s=>normalize(cleanArtist(s.artist))===name&&matchesMetadata(s.title,s.artist,request.term)))).sort((a,b)=>b.length-a.length||lexical(a,b))[0];
 const lyrics=new Set(catalog.lyricSongIDs||[]),hasLyrics=lyrics.size>0,groups=new Map(),vectors=new Map();
 for(const song of result.songs){const k=recordingKey(song);if(!groups.has(k))groups.set(k,[]);groups.get(k).push(song);}
 for(const [k,songs] of groups){
  const lyric=songs.some(s=>lyrics.has(s.id)),isFeatured=songs.some(s=>featured('songs',s.id));
  const constraints=songs.map(s=>{const wanted=requestedVersions(query,searchTitle(s),s.artist),actual=versions(s),take=q.match(/\btake \d+\b/);return [namedArtist&&!artistKeys(s.artist).has(namedArtist)?1:0,wanted.size&&(![...wanted].every(w=>actual.has(w))||wanted.has('take')&&take&&!normalize(s.title).includes(take[0]))?1:0];}).sort(compare)[0];
  const unwanted=Math.min(...songs.map(s=>!requestedVersions(query,searchTitle(s),s.artist).size&&versions(s).size?1:0));
  vectors.set(k,[...constraints,hasLyrics&&!lyric?1:0,unwanted,isFeatured||songs.some(s=>matchesMetadata(s.title,s.artist,request.term))?0:1,isFeatured?0:1,Math.min(...songs.map(s=>pos('songs',s.id)))]);
  if(lyric)for(const song of songs)lyrics.add(song.id);
 }
 result.songs.sort((a,b)=>{const ak=recordingKey(a),bk=recordingKey(b),v=compare(vectors.get(ak),vectors.get(bk));if(ak!==bk&&v)return v;
  const atv=s=>s.musicVideoType==='MUSIC_VIDEO_TYPE_ATV'?0:1;
  return atv(a)-atv(b)||Math.min(10,Math.log10(1+popularity(b.views)))-Math.min(10,Math.log10(1+popularity(a.views)))||pos('songs',a.id)-pos('songs',b.id)||lexical(a.id,b.id);
 });
 const title=x=>x.title||x.name||'',artist=x=>x.artist||x.author||'';
 for(const type of kinds.slice(1))result[type].sort((a,b)=>{const vector=x=>[normalize(title(x))===q?0:1,matchesMetadata(title(x),artist(x),request.term)||featured(type,x.id)?0:1,type==='playlists'&&(/^(RDCLAK5uy_|OLAK5uy_)/.test(x.id)||['YouTube Music','YouTube'].some(author=>(x.author||'').split(' • ').includes(author)))?0:1,featured(type,x.id)?0:1,pos(type,x.id)];return compare(vector(a),vector(b))||lexical(a.id,b.id);});
 const heads=kinds.flatMap(type=>result[type].length?[{kind:type,id:result[type][0].id}]:[]),item=head=>result[head.kind][0];
 const metadataSupported=kinds.some(type=>result[type].some(x=>matchesMetadata(title(x),artist(x),request.term)));
 const priority=head=>{
  if(kind!=='All')return head.kind.toLowerCase()===kind.toLowerCase()?0:10;
  if(request.lyricsExplicit||hasLyrics)return head.kind==='songs'?0:10;
  if(!metadataSupported&&provider?.kind===head.kind)return 1;
  if(head.kind==='artists'&&normalize(title(item(head)))===q)return 0;
  const exactSong=result.songs.some(s=>baseTitle(searchTitle(s))===q);
  if(head.kind==='albums'&&normalize(title(item(head)))===q&&!exactSong)return 0;
  if(head.kind==='playlists'&&normalize(title(item(head)))===q&&provider?.kind==='playlists')return 0;
  if(provider?.kind===head.kind&&(head.kind==='songs'||matchesMetadata(title(item(head)),artist(item(head)),request.term)))return 1;
  if(head.kind==='albums'&&normalize(title(item(head)))===q)return exactSong?4:2;
  return head.kind==='songs'?3:4;
 };
 heads.sort((a,b)=>priority(a)-priority(b)||pos(a.kind,a.id)-pos(b.kind,b.id)||lexical(a.kind,b.kind));
 result.top=heads[0]||null;result.categoryOrder=heads.map(x=>x.kind);result.lyricSongIDs=[...lyrics];
 result.ranking={top:result.top,categoryOrder:result.categoryOrder,songSupport:Object.fromEntries(result.songs.map(s=>[key('songs',s.id),lyrics.has(s.id)?'lyrics':matchesMetadata(s.title,s.artist,request.term)?'metadata':'provider']))};return result;
}
export function lyricCandidates(catalog){
 const evidence=recordEvidence(catalog),groups=new Map(),pos=s=>evidence.positions[key('songs',s.id)]??Number.MAX_SAFE_INTEGER;
 for(const song of catalog.songs||[]){const k=recordingKey(song);if(!groups.has(k))groups.set(k,[]);groups.get(k).push(song);}
 return [...groups.entries()].sort(([ak,a],[bk,b])=>Number(b.some(s=>evidence.providerTop?.kind==='songs'&&evidence.providerTop.id===s.id))-Number(a.some(s=>evidence.providerTop?.kind==='songs'&&evidence.providerTop.id===s.id))||Math.min(...a.map(pos))-Math.min(...b.map(pos))||lexical(ak,bk)).slice(0,6).map(([,songs])=>songs.sort((a,b)=>Number(b.musicVideoType==='MUSIC_VIDEO_TYPE_ATV')-Number(a.musicVideoType==='MUSIC_VIDEO_TYPE_ATV')||Number(normalize(b.title)===baseTitle(b.title))-Number(normalize(a.title)===baseTitle(a.title))||pos(a)-pos(b))[0]);
}
export function lyricMatch(record,song,phrase){
 if(record.instrumental||normalize(lookupTitle(record.trackName))!==normalize(lookupTitle(song.title))||!artistKeys(record.artistName).has(normalize(cleanArtist(song.artist)))&&!artistKeys(song.artist).has(normalize(cleanArtist(record.artistName))))return false;
 let query=normalize(phrase);const artists=[...artistKeys(song.artist)].flatMap(a=>a.startsWith('the ')?[a,a.slice(4)]:[a]).sort((a,b)=>b.length-a.length||lexical(a,b));
 for(const artist of artists){const suffix=[' by '+artist,' '+artist].find(s=>query.endsWith(s));if(suffix){query=query.slice(0,-suffix.length);break;}if(query.startsWith(artist+' ')){query=query.slice(artist.length+1);break;}}
 const text=normalize(record.plainLyrics||String(record.syncedLyrics||'').replace(/\[[^\]]*\]/g,''));return query.split(' ').length>=3&&(' '+text+' ').includes(' '+query+' ');
}
