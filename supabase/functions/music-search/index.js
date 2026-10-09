// Public metadata only. No database, account tokens, cookies, or media URLs.
const FILTERS = {Songs:'EgWKAQIIAWoKEAkQChAFEAMQBA==',Artists:'EgWKAQIgAWoKEAkQChAFEAMQBA==',Albums:'EgWKAQIYAWoKEAkQChAFEAMQBA==',Playlists:'EgWKAQIoAWoKEAkQChAFEAMQBA=='};
export function* walk(value) {
  if (!value || typeof value !== 'object') return;
  if (!Array.isArray(value)) yield value;
  for (const [key, child] of Object.entries(value)) if (!/tracking|menu|adSlot/i.test(key)) yield* walk(child);
}
const text = value => value?.simpleText || value?.runs?.map(r=>r.text||'').join('') || '';
const browse = run => run?.navigationEndpoint?.browseEndpoint?.browseId || '';
const duration = value => /^\d+:\d\d(?::\d\d)?$/.test(value) ? value.split(':').reduce((a,b)=>a*60+Number(b),0) : 0;
const image = item => {
  for (const node of walk(item.thumbnail || item.thumbnailRenderer || {})) {
    const url=node.thumbnails?.at(-1)?.url;
    if (url && /^https:\/\//.test(url)) return url.replace(/=w\d+-h\d+/, '=w544-h544');
  }
  return '';
};
export function parseCatalog(root) {
  const result={songs:[],artists:[],albums:[],playlists:[],correction:'',cursor:'',top:null,order:[]};
  const seen=new Set();
  const inherited=new Map();
  for(const node of walk(root)) {
    const card=node.musicCardShelfRenderer,id=browse(card?.title?.runs?.[0]);
    if(!id.startsWith('UC'))continue;
    for(const child of walk(card.contents||[])) {
      const item=child.musicResponsiveListItemRenderer;
      if(item)inherited.set(item,{id,name:text(card.title)});
    }
  }
  for (const node of walk(root)) {
    const correction=node.showingResultsForRenderer || node.didYouMeanRenderer;
    if(correction) result.correction=text(correction.correctedQuery)||text(correction.correctedQueryText);
    const next=node.nextContinuationData?.continuation || node.continuationCommand?.token;
    if(next && !result.cursor) result.cursor=next;
    const item=node.musicCardShelfRenderer || node.musicResponsiveListItemRenderer || node.musicTwoRowItemRenderer;
    if(!item) continue;
    const columns=(item.flexColumns||[]).map(c=>c.musicResponsiveListItemFlexColumnRenderer?.text);
    const title=text(columns[0]||item.title);
    if(!title)continue;
    const metadata=columns.slice(1).flatMap(c=>c?.runs||[]).concat(item.subtitle?.runs||[]);
    const parts=(columns.length>1?columns.slice(1).map(text).join(' • '):text(item.subtitle)).split(' • ').map(s=>s.trim());
    // Search also contains user profiles and podcasts; these are not music artists/albums.
    if(parts.some(p=>/^(Profile|Podcast|Episode)$/.test(p)))continue;
    const endpoint=item.navigationEndpoint || (columns[0]||item.title)?.runs?.[0]?.navigationEndpoint || {};
    const id=endpoint.browseEndpoint?.browseId;
    const artwork=image(item);
    const artistRuns=metadata.filter(r=>browse(r).startsWith('UC'));
    const artist=artistRuns.map(r=>r.text).join(', ') || inherited.get(item)?.name || parts.find(p=>p&&!/^(Song|Video|Album|Single|EP|Playlist|Artist|\d{4}|\d+:\d\d|.*views|.*plays|.*songs|.*monthly audience|.*subscribers|.*listeners)$/i.test(p)) || '';
    let kind,entry;
    const popularity=parts.find(p=>/\b(views|plays|monthly audience|subscribers)\b/i.test(p))||'';
    if(id?.startsWith('UC')){kind='artists';entry={id,name:title,artwork,audience:popularity};}
    else if(id?.startsWith('MPRE')){kind='albums';entry={id,title,artist,artistId:browse(artistRuns[0]),artwork,year:parts.find(p=>/^\d{4}$/.test(p))||'',type:parts.find(p=>/^(Album|Single|EP)$/.test(p))||'Album',tracks:[],complete:false};}
    else if(id?.startsWith('VL')){kind='playlists';entry={id:id.slice(2),name:title,author:artist,artwork,remote:true};}
    else {
      const videoId=item.playlistItemData?.videoId || endpoint.watchEndpoint?.videoId;
      if(!/^[\w-]{11}$/.test(videoId||''))continue;
      const album=metadata.find(r=>browse(r).startsWith('MPRE'));
      const watch=endpoint.watchEndpoint || [...walk(item.overlay||{})].find(n=>n.watchEndpoint?.videoId===videoId)?.watchEndpoint;
      const fixed=(item.fixedColumns||[]).map(c=>text(c.musicResponsiveListItemFixedColumnRenderer?.text));
      const musicVideoType=watch?.watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType;
      if(musicVideoType==='MUSIC_VIDEO_TYPE_PODCAST_EPISODE'||parts[0]==='Episode')continue;
      kind='songs';entry={id:videoId,title,artist:artist||'YouTube Music',artistId:browse(artistRuns[0])||inherited.get(item)?.id||'',album:album?.text||'',albumId:browse(album),artwork:artwork||`https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`,duration:fixed.concat(parts).map(duration).find(Boolean)||0,views:popularity,explicit:[...walk(item.badges||[])].some(n=>n.iconType==='MUSIC_EXPLICIT_BADGE'),musicVideoType,source:'youtube'};
    }
    if(seen.has(kind+entry.id))continue;
    seen.add(kind+entry.id);result[kind].push(entry);result.order.push({kind,id:entry.id});
    if(node.musicCardShelfRenderer)result.top={kind,id:entry.id};
  }
  return result;
}
export function trackShelf(root) {
  for(const node of walk(root)) {
    const shelf=node.musicPlaylistShelfRenderer||node.musicPlaylistShelfContinuation||node.musicShelfContinuation||node.musicShelfRenderer;
    if(shelf && parseCatalog(shelf).songs.length)return shelf;
  }
  return root;
}
export async function musicRequest(endpoint, body, fetcher=fetch, timedLyrics=false) {
  const response=await fetcher(`https://music.youtube.com/youtubei/v1/${endpoint}?prettyPrint=false`,{
    method:'POST',headers:{'Content-Type':'application/json','User-Agent':'Mozilla/5.0','Origin':'https://music.youtube.com','Accept-Language':'en-US,en;q=0.9'},
    body:JSON.stringify({...body,context:{client:{clientName:timedLyrics?'ANDROID_MUSIC':'WEB_REMIX',clientVersion:timedLyrics?'7.21.50':'1.20240918.01.00',hl:'en',gl:'US'}}}),signal:AbortSignal.timeout(18000)
  });
  if(!response.ok)throw Error('YouTube Music is temporarily unavailable. Please retry.');
  return response.json();
}
export function validateRequest(input) {
  if(!input||typeof input!=='object')throw Error('Invalid request.');
  const op=input.op||'search',kind=input.kind||'All';
  if(!['search','browse','discover','lyrics'].includes(op))throw Error('Invalid operation.');
  if(!['All',...Object.keys(FILTERS)].includes(kind))throw Error('Invalid search filter.');
  const query=typeof input.query==='string'?input.query.trim():'';
  if(op==='search'&&(!query||query.length>200))throw Error('Search must contain 1–200 characters.');
  const id=typeof input.id==='string'?input.id:'';
  if(op==='browse'&&!/^(MPRE[\w-]{1,150}|UC[\w-]{1,150}|VL[\w-]{1,150})$/.test(id))throw Error('Invalid music collection.');
  if(op==='lyrics'&&!/^[A-Za-z0-9_-]{11}$/.test(id))throw Error('Invalid recording.');
  const duration=Number(input.duration??0);
  if(op==='lyrics'&&(!Number.isFinite(duration)||duration<0||duration>86400))throw Error('Invalid recording duration.');
  if(input.providerOrder!==undefined&&typeof input.providerOrder!=='boolean')throw Error('Invalid search ordering.');
  const cursor=input.cursor||'';
  if(typeof cursor!=='string'||cursor.length>12000||/[\s<>]/.test(cursor))throw Error('Invalid page.');
  return {op,kind,query,id,cursor,...(op==='lyrics'?{duration}:{}),...(input.providerOrder?{providerOrder:true}:{})};
}
export function parseMusicLyrics(root,{duration=0,recordingType=''}={}) {
  const timed=[];let plain='',source='',valid=true;
  for(const node of walk(root)){
    if(Array.isArray(node.timedLyricsData)){
      source=typeof node.sourceMessage==='string'?node.sourceMessage:text(node.sourceMessage);
      for(const row of node.timedLyricsData){
        if(typeof row.lyricLine!=='string'){valid=false;continue}
        const cue=row.cueRange||{},start=Number(cue.startTimeMilliseconds)/1000,end=cue.endTimeMilliseconds===undefined?undefined:Number(cue.endTimeMilliseconds)/1000;
        if(!Number.isFinite(start)||start<0||start>duration+2||end!==undefined&&(!Number.isFinite(end)||end<start||end>duration+2))valid=false;
        timed.push({time:start,text:row.lyricLine,...(end!==undefined?{endTime:end}:{})});
      }
    }
    const shelf=node.musicDescriptionShelfRenderer;
    if(shelf){plain=text(shelf.description);source=text(shelf.footer)||source}
  }
  if(!plain&&!timed.length)return null;
  return {plain:plain||timed.map(l=>l.text).join('\n'),lines:valid&&duration>0&&recordingType==='MUSIC_VIDEO_TYPE_ATV'?timed:[],source:source?source+' · YouTube Music':'YouTube Music',recordingType};
}
export async function execute(input, request=musicRequest) {
  const {op,kind,query,id,cursor,duration,providerOrder}=validateRequest(input);
  if(op==='lyrics'){
    const next=await request('next',{videoId:id,isAudioOnly:true});
    let browseID='',recordingType='';
    for(const node of walk(next)){
      const linked=node.browseEndpoint?.browseId;
      if(typeof linked==='string'&&/^MPLY[\w-]{1,4000}$/.test(linked))browseID=linked;
      const item=node.playlistPanelVideoRenderer;
      if(item?.videoId===id)recordingType=item.navigationEndpoint?.watchEndpoint?.watchEndpointMusicSupportedConfigs?.watchEndpointMusicConfig?.musicVideoType||'';
    }
    const root=browseID?await request('browse',{browseId:browseID},undefined,true):null;
    return {songs:[],artists:[],albums:[],playlists:[],lyrics:parseMusicLyrics(root,{duration,recordingType}),recordingType};
  }
  if(op==='search') {
    const requests=[request('search',cursor?{continuation:cursor}:{query,...(FILTERS[kind]?{params:FILTERS[kind]}:{})})];
    if(kind==='All'&&!providerOrder)requests.push(request('search',{query,params:FILTERS.Songs}));
    const responses=await Promise.all(requests),result=parseCatalog(responses[0]);
    if(kind==='All'&&!providerOrder){
      const tracks=parseCatalog(responses[1]);
      const trackById=new Map(tracks.songs.map(s=>[s.id,s]));
      result.songs=[...new Map([...tracks.songs,...result.songs].map(s=>[s.id,{...s,...trackById.get(s.id),views:trackById.get(s.id)?.views||s.views}])).values()];
      result.correction ||= tracks.correction;
      result.cursor=''; // Each overview shelf has its own page; filters paginate.
    }
    if(providerOrder){result.providerOrder=true;if(kind==='All')result.cursor='';}
    return result;
  }
  const root=await request('browse',cursor?{continuation:cursor}:{browseId:op==='discover'?'FEmusic_explore':id});
  const isCollection=op==='browse'&&!id.startsWith('UC');
  const result=parseCatalog(isCollection?trackShelf(root):root);
  if(isCollection) {
    for(const node of walk(root)) {
      const header=node.musicResponsiveHeaderRenderer||node.musicDetailHeaderRenderer||node.musicEditablePlaylistDetailHeaderRenderer?.header?.musicDetailHeaderRenderer;
      if(header){result.collection={id,title:text(header.title),artist:text(header.straplineTextOne)||text(header.straplineText),artistId:browse((header.straplineTextOne||header.straplineText)?.runs?.[0]),artwork:image(header)};break;}
    }
    result.complete=!result.cursor;
  } else if(id.startsWith('UC')) {
    for(const node of walk(root)) {
      const header=node.musicImmersiveHeaderRenderer||node.musicVisualHeaderRenderer;
      if(header){result.artist={id,name:text(header.title),artwork:image(header)};break;}
    }
    result.cursor='';

  }
  return result;
}
const cache=new Map(),limits=new Map();
export async function handler(req) {
  const origin=req.headers.get('origin')||'';
  const allowed=origin==='https://mcnoren.github.io'||/^http:\/\/(127\.0\.0\.1|localhost):417[3-6]$/.test(origin);
  const headers={'Content-Type':'application/json','Access-Control-Allow-Origin':allowed?origin:'https://mcnoren.github.io','Access-Control-Allow-Headers':'content-type, apikey, authorization, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin','Cache-Control':'no-store'};
  const reply=(data,status=200)=>new Response(JSON.stringify(data),{status,headers});
  if(origin&&!allowed)return reply({error:'Origin unavailable.'},403);
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(req.method!=='POST')return reply({error:'Use POST.'},405);
  if(Number(req.headers.get('content-length'))>16000)return reply({error:'Request too large.'},413);
  const ip=req.headers.get('x-forwarded-for')?.split(',')[0]||'unknown',now=Date.now();
  if(limits.size>2000)for(const [key,value]of limits)if(now-value.at>60000)limits.delete(key);
  let limit=limits.get(ip);if(!limit||now-limit.at>60000){limit={at:now,count:0};limits.set(ip,limit);}
  if(++limit.count>80)return reply({error:'Too many searches. Please wait a minute.'},429);
  let input;
  try{const raw=await req.text();if(raw.length>16000)return reply({error:'Request too large.'},413);input=validateRequest(JSON.parse(raw));}catch(e){return reply({error:e.message},400);}
  const key=JSON.stringify(input),hit=cache.get(key);
  if(hit&&now-hit.at<300000)return reply(hit.data);
  try{
    const data=await execute(input);cache.set(key,{at:now,data});
    while(cache.size>150)cache.delete(cache.keys().next().value);
    return reply(data);
  }catch{return reply({error:'Live music search is temporarily unavailable. Please retry.'},502);}
}
if(typeof Deno!=='undefined')Deno.serve(handler);
