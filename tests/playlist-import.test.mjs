import test from 'node:test';
import assert from 'node:assert/strict';
import {parseCSV,parsePlaylistCSV,parseSongList,chooseImportMatch,matchPlaylist} from '../docs/playlist-import.js';
const source={title:'California Gurls',artist:'Katy Perry, Snoop Dogg',artists:['Katy Perry','Snoop Dogg'],duration:234.653,album:'Teenage Dream',explicit:false};
const song={id:'official',title:'California Gurls',artist:'Katy Perry, Snoop Dogg',duration:235,album:'Teenage Dream',explicit:false,musicVideoType:'MUSIC_VIDEO_TYPE_ATV'};
test('Exportify CSV preserves reordered headers, quoted commas, quotes, Unicode, durations and duplicates',()=>{
 const csv='\uFEFFTrack URI,ISRC,Artist Name(s),Track Name,Album Name,Duration (ms),Explicit\r\nspotify:track:one,USCA21001135,Katy Perry;Snoop Dogg,"California Gurls","Teenage, Dream",234653,False\r\nspotify:track:two,,"Artist, Jr.","A ""quoted""\nSong",Album,180000,True\r\nspotify:track:one,USCA21001135,Katy Perry;Snoop Dogg,California Gurls,Teenage Dream,234653,False';
 const tracks=parsePlaylistCSV(csv);assert.equal(tracks.length,3);assert.deepEqual(tracks[0].artists,['Katy Perry','Snoop Dogg']);assert.equal(tracks[0].duration,234.653);assert.equal(tracks[0].isrc,'USCA21001135');assert.equal(tracks[0].explicit,false);assert.equal(tracks[1].title,'A "quoted" Song');assert.deepEqual(tracks.map(t=>t.position),[0,1,2]);
 assert.equal(parsePlaylistCSV('Track Name\tArtist Name(s)\nCafé\tBeyoncé')[0].title,'Café');
});
test('malformed and unrelated CSV files fail without silently dropping rows',()=>{
 for(const csv of ['hello,world\na,b','Track Name,Artist Name(s)\nSong,Artist,Extra','Track Name,Artist Name(s)\n"Unfinished,Artist'])assert.throws(()=>parsePlaylistCSV(csv));
 const tracks=parsePlaylistCSV('Track Name,Artist Name(s),Track URI\n,Artist,spotify:track:missing\nLocal,Artist,spotify:local:song\nPodcast,Host,spotify:episode:one');assert.ok(tracks.every(t=>t.reason));
 assert.deepEqual(parseCSV('a,b\r\n"c,d","e""f"'),[['a','b'],['c,d','e"f']]);
});
test('song list splits once and preserves hyphenated recording editions',()=>{
 assert.deepEqual(parseSongList('Michael Jackson — Thriller - Single Version')[0],{title:'Thriller - Single Version',artist:'Michael Jackson',position:0,reason:''});
});
test('recording matching rejects wrong artists, performances, explicitness and lengths',()=>{
 assert.equal(chooseImportMatch(source,[song]).song.id,'official');assert.equal(chooseImportMatch(source,[song]).review,false);
 for(const candidate of [{...song,artist:'Cover Band'},{...song,title:'California Gurls (Live)'},{...song,title:'California Gurls (Remix)'},{...song,duration:290}])assert.equal(chooseImportMatch(source,[candidate]),null);
 assert.equal(chooseImportMatch(source,[{...song,musicVideoType:'MUSIC_VIDEO_TYPE_OMV'}]).review,true);
 assert.equal(chooseImportMatch(source,[{...song,explicit:true}]).review,true);
 assert.equal(chooseImportMatch({...source,title:'California Gurls (with Snoop Dogg)'},[song]).review,false);
 assert.equal(chooseImportMatch({...source,artist:'The Jackson 5',artists:['The Jackson 5']},[{...song,artist:'Jackson 5'}]).review,false);
 assert.equal(chooseImportMatch({...source,title:'California Gurls - Remastered 2020'},[song]).review,true);
 const live={...song,title:'Live And Let Die'};assert.equal(chooseImportMatch({...source,title:live.title},[live]).review,false);
});
test('every entry uses live search, concurrent responses keep source order, duplicates share one query',async()=>{
 let calls=0,active=0,max=0;const tracks=[{...source,position:0},{...source,title:'Second',position:1},{...source,position:2}];
 const entries=await matchPlaylist(tracks,{requestInterval:0,localSongs:[song],search:async query=>{calls++;max=Math.max(max,++active);await new Promise(resolve=>setTimeout(resolve,query.startsWith('Second')?1:10));active--;return[{...song,id:query.startsWith('Second')?'second':'first',title:query.startsWith('Second')?'Second':source.title}]}});
 assert.equal(calls,2);assert.ok(max<=2);assert.deepEqual(entries.map(e=>e.source.position),[0,1,2]);assert.deepEqual(entries.map(e=>e.song.id),['first','second','first']);
});
test('edition fallback, search failures, unsupported entries and cancellation remain distinct',async()=>{
 const queries=[];const entry=(await matchPlaylist([{...source,title:'California Gurls - Remastered 2020'}],{requestInterval:0,search:async query=>{queries.push(query);return queries.length===1?[]:[song]}}))[0];assert.equal(queries.length,2);assert.equal(entry.review,true);
 const failed=(await matchPlaylist([source,{...source,reason:'Spotify local file'}],{requestInterval:0,search:async()=>{throw Error('Offline')}}));assert.equal(failed[0].failed,true);assert.equal(failed[1].reason,'Spotify local file');
 const abort=new AbortController();await assert.rejects(matchPlaylist([source],{requestInterval:0,signal:abort.signal,search:async()=>{abort.abort();return[song]}}),{name:'AbortError'});
});

test('rate limiting waits and retries while cancellation interrupts a pending delay',async()=>{
 let calls=0,waits=0;const entries=await matchPlaylist([source],{requestInterval:0,onWait:()=>waits++,search:async()=>{if(++calls===1){const error=Error('Busy');error.status=429;error.retryAfterMs=5;throw error}return[song]}});assert.equal(calls,2);assert.equal(waits,1);assert.equal(entries[0].song.id,'official');
 const controller=new AbortController();const pending=matchPlaylist([source],{signal:controller.signal,search:async()=>{const error=Error('Busy');error.status=429;error.retryAfterMs=60000;setTimeout(()=>controller.abort(),5);throw error}});await assert.rejects(pending,{name:'AbortError'});
});

test('one review list includes unpaired entries from every playlist, including legacy checked songs',async()=>{
 const {playlistReviewEntries}=await import('../docs/playlist-import.js');
 const playlists=[{id:'a',unmatched:[{title:'Missing',position:0,checked:true},{title:'Paired',matchedSongId:'official'}]},{id:'b',unmatched:[{title:'Missing',position:0}]}];
 const entries=playlistReviewEntries(playlists);assert.equal(entries.length,2);assert.deepEqual(entries.map(e=>e.playlist.id),['a','b']);assert.equal(playlistReviewEntries(playlists,{paired:true}).length,1);
});
test('manual pairing restores source order, retains failures, and persists duplicate entries independently',async()=>{
 const {pairPlaylistEntry,unmatchedKey,playlistReviewEntries}=await import('../docs/playlist-import.js');
 const p={id:'a',songs:['first','last'],unmatched:[{id:'one',title:'Middle',artist:'Artist',position:1,reason:'Search failed'},{id:'two',title:'Middle',artist:'Artist',position:2,reason:'No close match'}],importEntries:[{position:0,matchedSongId:'first'},{position:1,matchedSongId:null},{position:2,matchedSongId:null},{position:3,matchedSongId:'last'}]};
 assert.ok(pairPlaylistEntry(p,unmatchedKey(p.unmatched[0],0),{id:'middle'}));assert.deepEqual(p.songs,['first','middle','last']);assert.equal(p.unmatched[0].reason,'Search failed');assert.equal(p.importEntries[1].matchedSongId,'middle');assert.equal(playlistReviewEntries([p]).length,1);
 const restored=JSON.parse(JSON.stringify(p));assert.ok(pairPlaylistEntry(restored,'two',{id:'middle'}));assert.deepEqual(restored.songs,p.songs);assert.equal(playlistReviewEntries([restored]).length,0);
 assert.equal(pairPlaylistEntry(restored,'two',{id:'other'}),false);assert.equal(pairPlaylistEntry(restored,'removed',{id:'other'}),false);assert.equal(pairPlaylistEntry({...p,rules:{}},'one',{id:'other'}),false);
});
test('legacy imports without source mappings can pair and missing destinations cannot be edited',async()=>{
 const {pairPlaylistEntry,unmatchedKey}=await import('../docs/playlist-import.js');
 const p={songs:[],unmatched:[{title:'Legacy',checked:true}]};assert.ok(pairPlaylistEntry(p,unmatchedKey(p.unmatched[0],0),{id:'found'}));assert.deepEqual(p.songs,['found']);assert.equal(pairPlaylistEntry(null,'key',{id:'found'}),false);
});
