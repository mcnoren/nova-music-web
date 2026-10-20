import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {rankCatalog,mergeSearchPage,lyricMatch,lyricCandidates} from '../docs/search-ranking.js';
import {NativeCatalogTransport,NativeCatalogClient} from '../docs/native-catalog.js';
const fixtures=JSON.parse(await readFile(new URL('./fixtures/search-ranking.json',import.meta.url)));
test('shared Swift and JavaScript ranking fixtures preserve top choice and evidence',()=>{
 for(const f of fixtures){
  const ranked=rankCatalog(f.catalog,f.query);assert.equal(ranked.top?.id,f.expectedTop,f.name);
  assert.deepEqual(ranked.songs.map(s=>s.id),f.expectedSongs,f.name+' shared song order');
  assert.deepEqual(ranked.categoryOrder,f.expectedCategories,f.name+' shared category order');
  const again=rankCatalog(ranked,f.query);assert.deepEqual(again,ranked,f.name+' repeated ranking');
  const permuted={...ranked,songs:[...ranked.songs].reverse()};assert.deepEqual(rankCatalog(permuted,f.query).songs,ranked.songs,f.name+' permutation');
 }
});
test('pagination deduplicates and reranks without replacing provider evidence',()=>{
 const f=fixtures[0],ranked=rankCatalog(f.catalog,f.query),page={songs:[{id:'popular',title:'Hello',artist:'Adele',views:'2B plays',musicVideoType:'MUSIC_VIDEO_TYPE_ATV'},ranked.songs[0]],artists:[],albums:[],playlists:[],cursor:'page2'};
 const merged=mergeSearchPage({...ranked,cursor:'page2'},page,f.query,'Songs');
 assert.equal(merged.songs[0].id,'popular');assert.equal(merged.songs.filter(s=>s.id==='studio').length,1);assert.equal(merged.cursor,'');
 assert.equal(merged.evidence.positions['songs:studio'],2);assert.deepEqual(merged.evidence.providerTop,ranked.evidence.providerTop);
});
test('lyric verification requires recording identity and a complete phrase',()=>{
 const song={id:'a',title:'Hello',artist:'Adele'},record={trackName:'Hello',artistName:'Adele',plainLyrics:'some remembered lyric words'};
 assert.equal(lyricMatch(record,song,'some remembered lyric words'),true);
 assert.equal(lyricMatch({...record,artistName:'Tribute Artist'},song,'some remembered lyric words'),false);
 assert.equal(lyricMatch({...record,trackName:'Hello (Live)'},song,'some remembered lyric words'),false);
 assert.equal(lyricMatch(record,song,'remembered lyric'),false);
 assert.equal(lyricMatch(record,song,'some remembered lyric word'),false);
 const many={songs:Array.from({length:20},(_,i)=>({id:String(i),title:'Song '+i,artist:'Artist'}))};assert.equal(lyricCandidates(many).length,6);
});
test('Mac transport matches IDs, cancels native work, and ignores late replies',async()=>{
 const events=new EventTarget(),messages=[],transport=new NativeCatalogTransport({events,bridge:{post:m=>messages.push(m)},uuid:()=> 'request-1'});
 const controller=new AbortController(),pending=transport.request('search',{query:'Hello'},{signal:controller.signal});
 events.dispatchEvent(Object.assign(new Event('nova-native-catalog'),{detail:{requestID:'wrong',data:{wrong:true}}}));assert.equal(transport.pending.size,1);
 controller.abort();await assert.rejects(pending,{name:'AbortError'});assert.equal(messages.at(-1).type,'catalogCancel');
 events.dispatchEvent(Object.assign(new Event('nova-native-catalog'),{detail:{requestID:'request-1',data:{late:true}}}));assert.equal(transport.pending.size,0);transport.dispose();
});
const row=(id,title,artist='Adele',type='MUSIC_VIDEO_TYPE_ATV')=>({musicResponsiveListItemRenderer:{playlistItemData:{videoId:id},navigationEndpoint:{watchEndpoint:{videoId:id,watchEndpointMusicSupportedConfigs:{watchEndpointMusicConfig:{musicVideoType:type}}}},flexColumns:[{musicResponsiveListItemFlexColumnRenderer:{text:{runs:[{text:title}]}}},{musicResponsiveListItemFlexColumnRenderer:{text:{runs:[{text:artist,navigationEndpoint:{browseEndpoint:{browseId:'UCartist'}}}]}}}]}});
test('Mac client preserves the provider order with one overview or category request',async()=>{
 const fixture=JSON.parse(await readFile(new URL('./fixtures/provider-search.json',import.meta.url))),calls=[];
 const transport={request:async(op,body)=>{calls.push({op,body});return fixture.response;}};
 const result=await new NativeCatalogClient({transport}).request({query:fixture.query,kind:'All'});
 assert.equal(calls.length,1);assert.equal(result.top.id,'provider001');assert.equal(result.providerOrder,true);
 assert.deepEqual(result.order,fixture.expectedOrder);assert.equal(result.correction,'Hello Adele');
 await new NativeCatalogClient({transport}).request({query:fixture.query,kind:'Playlists'});
 assert.equal(calls.length,2);assert.ok(calls[1].body.params);
});
test('Mac search deadline cancels in-flight work without a lyric-ranking request',async()=>{
 const blocked={request:(_op,_body,{signal})=>new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(new DOMException('Cancelled','AbortError')),{once:true}))};
 await assert.rejects(new NativeCatalogClient({transport:blocked,timeout:20}).request({query:'Hello'}),{name:'AbortError'});
 const calls=[],transport={request:async(op)=>{calls.push(op);return{contents:[row('studio00001','Hello')]};}};
 const result=await new NativeCatalogClient({transport}).request({query:'lyrics: some remembered lyric words',kind:'Songs'});
 assert.equal(result.songs[0].id,'studio00001');assert.deepEqual(calls,['search']);
});
test('Mac browse, discovery, lyrics, and continuation all use the native transport',async()=>{
 const calls=[],transport={request:async(op,body)=>{calls.push({op,body});return{contents:[row('studio00001','Hello')]};}},client=new NativeCatalogClient({transport});
 await client.request({op:'browse',id:'MPREalbum'});await client.request({op:'discover'});await client.request({op:'lyrics',id:'studio00001'});
 await client.request({query:'Hello',kind:'Songs',cursor:'next_page'});
 assert.deepEqual(calls.map(c=>c.op),['browse','browse','next','search']);assert.deepEqual(calls.at(-1).body,{continuation:'next_page'});
});
