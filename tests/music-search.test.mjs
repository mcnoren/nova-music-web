import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {rankLocal,mergeResults,MusicSearchClient,providerItems} from '../docs/music-search.js';
import {parseCatalog,parseMusicLyrics,execute,validateRequest,handler} from '../supabase/functions/music-search/index.js';
const catalog=JSON.parse(await readFile(new URL('../docs/catalog.json',import.meta.url)));
test('local fallback tolerates transpositions, mixed fields, accents, and prefixes',()=>{
  assert.match(rankLocal(catalog.songs,'daft pnuk')[0].artist,/Daft Punk/);
  assert.match(rankLocal(catalog.songs,'gett lucky daft')[0].title,/Get Lucky/);
  assert.equal(rankLocal([{id:'a',title:'Beyoncé'},{id:'b',title:'Beyonce Tribute'}],'beyonce')[0].id,'a');
  assert.equal(rankLocal([{id:'a',title:'東京'}],'東京')[0].id,'a');
  assert.deepEqual(rankLocal(catalog.songs,'zzqxxv nonsense'),[]);
});
test('lyrics fallback matches available lyrics without mistaking one common word for a match',()=>{
  const items=[{id:'a',title:'A song',lyrics:'One two three four five'},{id:'b',title:'Another'}];
  assert.equal(rankLocal(items,'two three four')[0].id,'a');
  assert.deepEqual(rankLocal(items,'two'),[]);
});
test('provider rank is preserved when merging saved results and newer metadata wins',()=>{
  assert.deepEqual(mergeResults([{id:'b',title:'new'},{id:'a'}],[{id:'a'},{id:'b',title:'old'},{id:'c'}]),[{id:'b',title:'new'},{id:'a'},{id:'c'}]);
});
test('search client caches safely, expires, forwards cancellation, and surfaces errors',async()=>{
  let calls=0,now=0;const abort=new AbortController();
  const client=new MusicSearchClient('https://example.test',{now:()=>now,fetcher:async(url,options)=>{calls++;assert.equal(options.signal.aborted,false);return Response.json({songs:[{id:'a'}],artists:[],albums:[],playlists:[]});}});
  const first=await client.request({query:'song'},{signal:abort.signal});first.songs.length=0;
  assert.equal((await client.request({query:'song'})).songs.length,1);assert.equal(calls,1);
  now=300001;await client.request({query:'song'});assert.equal(calls,2);
  const failing=new MusicSearchClient('https://example.test',{fetcher:async()=>Response.json({error:'Try again'},{status:502})});
  await assert.rejects(failing.request({query:'song'}),/Try again/);
});
const run=(text,id)=>({text,navigationEndpoint:{browseEndpoint:{browseId:id}}});
const song=(id,title)=>({musicResponsiveListItemRenderer:{playlistItemData:{videoId:id},flexColumns:[{musicResponsiveListItemFlexColumnRenderer:{text:{runs:[{text:title,navigationEndpoint:{watchEndpoint:{videoId:id}}}]}}},{musicResponsiveListItemFlexColumnRenderer:{text:{runs:[run('An artist','UCartist'),{text:' • '},run('An album','MPREalbum')]}}}],fixedColumns:[{musicResponsiveListItemFixedColumnRenderer:{text:{runs:[{text:'3:42'}]}}}]}});
test('provider parser extracts identity, album, duration, correction, and next page',()=>{
  const result=parseCatalog({contents:[song('12345678901','Song')],showingResultsForRenderer:{correctedQuery:{runs:[{text:'correct spelling'}]}},continuations:[{nextContinuationData:{continuation:'next'}}]});
  assert.equal(result.songs[0].artistId,'UCartist');assert.equal(result.songs[0].albumId,'MPREalbum');assert.equal(result.songs[0].duration,222);assert.equal(result.correction,'correct spelling');assert.equal(result.cursor,'next');
});
test('overview keeps provider song rank and filtered queries paginate',async()=>{
  const requests=[];const request=async(e,body)=>{requests.push(body);return{contents:[song('12345678901','Song')],continuations:[{nextContinuationData:{continuation:'next'}}]};};
  assert.equal((await execute({query:'lyrics',kind:'All'},request)).cursor,'');assert.equal(requests.length,2);
  assert.equal((await execute({query:'lyrics',kind:'Songs'},request)).cursor,'next');
  await execute({query:'lyrics',kind:'Songs',cursor:'next'},request);assert.deepEqual(requests.at(-1),{continuation:'next'});
});
test('service rejects arbitrary fetch targets, huge inputs, unexpected origins and methods',async()=>{
  for(const input of [{op:'proxy',id:'https://example.com'},{op:'browse',id:'https://example.com'},{query:'a'.repeat(201)},{query:'a',kind:'Private'},{query:'a',cursor:'<script>'}])assert.throws(()=>validateRequest(input));
  assert.equal((await handler(new Request('https://example.test',{method:'POST',headers:{Origin:'https://evil.test'},body:'{}'}))).status,403);
  assert.equal((await handler(new Request('https://example.test'))).status,405);
  assert.equal((await handler(new Request('https://example.test',{method:'OPTIONS',headers:{Origin:'https://mcnoren.github.io'}}))).status,204);
});

test('search top result changes between artist, album and song according to query intent',async()=>{
 const {rankSearch}=await import('../docs/music-search.js');
 const input={songs:[{id:'song',title:'After Midnight',artist:'Chappell Roan',musicVideoType:'MUSIC_VIDEO_TYPE_ATV'}],artists:[{id:'artist',name:'Chappell Roan'}],albums:[{id:'album',title:'The Rise and Fall of a Midwest Princess',artist:'Chappell Roan'}],playlists:[],top:{kind:'artists',id:'artist'}};
 assert.deepEqual(rankSearch(input,'Chappell Roan').top,{kind:'artists',id:'artist'});
 assert.deepEqual(rankSearch(input,'The Rise and Fall of a Midwest Princess').top,{kind:'albums',id:'album'});
 assert.deepEqual(rankSearch(input,'After Midnight Chappell Roan').top,{kind:'songs',id:'song'});
 assert.deepEqual(rankSearch({...input,songs:[]},'The Rise and Fall of a Midwest Princess').top,{kind:'albums',id:'album'});
});
test('popularity helps close matches without elevating unrelated or unwanted versions',async()=>{
 const {rankSearch,popularityCount}=await import('../docs/music-search.js');
 assert.equal(popularityCount('1.2B views'),1.2e9);assert.equal(popularityCount('123,456 plays'),123456);
 const songs=[{id:'small',title:'Hello',artist:'Adele',views:'1K views'},{id:'popular',title:'Hello',artist:'Adele',views:'1B views'},{id:'cover',title:'Hello Cover',artist:'Adele',views:'9B views'},{id:'unrelated',title:'Another song',artist:'Other',views:'99B views'}];
 assert.equal(rankSearch({songs},'Hello Adele').songs[0].id,'popular');
 assert.equal(rankSearch({songs},'Hello Cover Adele').songs[0].id,'cover');
});

test('play counts are metadata and never become the artist on album tracks',()=>{
 const item=song('12345678901','After Midnight');
 item.musicResponsiveListItemRenderer.flexColumns[1].musicResponsiveListItemFlexColumnRenderer.text={runs:[{text:'19M plays'}]};
 const result=parseCatalog({contents:[item]});
 assert.equal(result.songs[0].artist,'YouTube Music');assert.equal(result.songs[0].views,'19M plays');
});
test('artist searches keep official songs ahead of uploader titles that repeat the artist name',async()=>{
 const {rankSearch}=await import('../docs/music-search.js');
 const songs=[{id:'upload',title:'Chappell Roan - Pink Pony Club (Lyrics)',artist:'Lost Panda',views:'20M views'},{id:'official',title:'Pink Pony Club',artist:'Chappell Roan',musicVideoType:'MUSIC_VIDEO_TYPE_ATV',views:'316M plays'}];
 assert.equal(rankSearch({songs},'Chappell Roan').songs[0].id,'official');
 const artistSearch=rankSearch({songs:[{id:'namesake',title:'Chappell Roan',artist:'Down Periscope'},...songs],artists:[{id:'artist',name:'Chappell Roan'}]},'Chappell Roan');
 assert.equal(artistSearch.songs[0].id,'official');assert.equal(artistSearch.top.kind,'artists');
});
test('direct YouTube Music search keeps its featured result and mixed order without a second songs query',async()=>{
 const raw={contents:[song('12345678901','Provider first'),{musicTwoRowItemRenderer:{title:{runs:[run('An album','MPREalbum')]},subtitle:{runs:[{text:'Album • An artist'}]}}},song('abcdefghijk','Provider second')]};
 let calls=0;const result=await execute({query:'An album',providerOrder:true},async()=>{calls++;return raw});
 assert.equal(calls,1);assert.equal(result.providerOrder,true);
 assert.deepEqual(providerItems(result).map(e=>e.item.id),['12345678901','MPREalbum','abcdefghijk']);
 assert.deepEqual(result.songs.map(s=>s.id),['12345678901','abcdefghijk']);
 assert.deepEqual(providerItems({...result,order:[...result.order,result.order[0],{kind:'songs',id:'missing'}]}).map(e=>e.item.id),['12345678901','MPREalbum','abcdefghijk']);
});
test('YouTube user profiles and podcasts are never presented as music artists or playlists',()=>{
 const item=(id,kind)=>({musicTwoRowItemRenderer:{title:{runs:[run('A name',id)]},subtitle:{runs:[{text:kind+' • A creator'}]}}});
 const result=parseCatalog({contents:[item('UCprofile','Profile'),item('VLpodcast','Podcast'),item('UCartist','Artist')]});
 assert.deepEqual(result.artists.map(a=>a.id),['UCartist']);assert.deepEqual(result.playlists,[]);
});
test('linked YouTube Music lyric cues retain millisecond starts and ends only for the song recording',async()=>{
 const root={timedLyricsData:[{lyricLine:'Example',cueRange:{startTimeMilliseconds:'15350',endTimeMilliseconds:'22620'}}],sourceMessage:'Source: Example provider'};
 const data=parseMusicLyrics(root,{duration:225,recordingType:'MUSIC_VIDEO_TYPE_ATV'});
 assert.deepEqual(data.lines,[{time:15.35,endTime:22.62,text:'Example'}]);assert.match(data.source,/YouTube Music/);
 assert.equal(parseMusicLyrics(root,{duration:251,recordingType:'MUSIC_VIDEO_TYPE_OMV'}).lines.length,0);
 assert.equal(parseMusicLyrics(root,{duration:0,recordingType:'MUSIC_VIDEO_TYPE_ATV'}).lines.length,0);
 assert.equal(parseMusicLyrics(root,{duration:10,recordingType:'MUSIC_VIDEO_TYPE_ATV'}).lines.length,0);
 const calls=[];const result=await execute({op:'lyrics',id:'abcdefghijk',duration:225},async(endpoint,body,fetcher,timed)=>{
  calls.push({endpoint,body,timed});return endpoint==='next'?{browseEndpoint:{browseId:'MPLYlinked'},playlistPanelVideoRenderer:{videoId:'abcdefghijk',navigationEndpoint:{watchEndpoint:{watchEndpointMusicSupportedConfigs:{watchEndpointMusicConfig:{musicVideoType:'MUSIC_VIDEO_TYPE_ATV'}}}}}}:root;
 });
 assert.equal(result.lyrics.lines[0].time,15.35);assert.equal(calls[1].timed,true);assert.equal(calls[1].body.browseId,'MPLYlinked');
 for(const input of [{op:'lyrics',id:'https://evil.test'},{op:'lyrics',id:'abcdefghijk',duration:-1},{op:'lyrics',id:'abcdefghijk',duration:1e10},{query:'hi',providerOrder:'yes'}])assert.throws(()=>validateRequest(input));
});
