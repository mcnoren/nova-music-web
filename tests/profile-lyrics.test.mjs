import test from 'node:test';
import assert from 'node:assert/strict';
import {defaultProfile,validateProfile} from '../docs/profile.js';
import {libraryValues,applyLibraryValues} from '../docs/sync-model.js';
import {parseLRC,activeLyric,lookupLyrics,lyricData,chooseLyrics} from '../docs/lyrics.js';
const state=()=>({liked:[],saved:[],albums:[],artists:[],artistPins:[],playlists:[],folders:[],recent:[],extraSongs:{},extraAlbums:{},extraArtists:{},settings:{},profile:defaultProfile()});
const catalog={songs:[],albums:[],artists:[]};
test('profile icon and photo round-trip across devices without replacing them on a fresh sign-in',()=>{
 const first=state();first.profile={name:'My profile',icon:'🌙',color:'#a78bfa',image:'data:image/jpeg;base64,/9j/AA=='};
 const values=libraryValues(first,catalog),second=applyLibraryValues(state(),values);
 assert.deepEqual(second.profile,first.profile);
 assert.deepEqual(libraryValues(second,catalog)['profile:main'],first.profile);
 assert.equal(libraryValues(state(),catalog)['profile:main'],undefined);
 assert.deepEqual(applyLibraryValues(second,{}).profile,defaultProfile());
});
test('profile validation rejects active image formats, remote images and oversized content',()=>{
 for(const image of ['https://evil.test/image','data:image/svg+xml;base64,AAAA','data:image/jpeg;base64,'+'A'.repeat(180001)])assert.throws(()=>validateProfile({...defaultProfile(),image}));
 assert.throws(()=>validateProfile({...defaultProfile(),name:'a'.repeat(61)}));
 assert.throws(()=>validateProfile({...defaultProfile(),color:'red;position:fixed'}));
});
test('LRC handles fractional cues, repeated timestamps, offset metadata, blank rests and seeks',()=>{
 const lines=parseLRC('[offset:-500]\n[00:01.50][00:03:50]First\n[00:05.00]\n[00:06.25]Next\n[00:99]invalid');
 assert.deepEqual(lines,[{time:1,text:'First'},{time:3,text:'First'},{time:4.5,text:''},{time:5.75,text:'Next'}]);
 assert.equal(activeLyric(lines,.9),-1);assert.equal(activeLyric(lines,1),0);assert.equal(activeLyric(lines,4.6),2);assert.equal(activeLyric(lines,5.8),3);assert.equal(activeLyric(lines,1.5),0);
});
const song={title:'After Midnight (Official Audio)',artist:'Chappell Roan • Album • 2023',album:'The Rise and Fall of a Midwest Princess',duration:205};
const record={trackName:'After Midnight',artistName:'Chappell Roan',albumName:song.album,duration:205,plainLyrics:'Example line',syncedLyrics:'[00:03.50]Example line'};
test('synced cues require the correct artist, title and actual recording duration',()=>{
 assert.equal(lyricData(record,song).lines[0].time,3.5);
 assert.equal(lyricData(record,{...song,duration:240}).lines.length,0);
 assert.equal(lyricData(record,{...song,duration:0}).lines.length,0);
 assert.equal(lyricData({...record,artistName:'Another artist'},song).missing,true);
 assert.equal(lyricData(record,{...song,title:'After Midnight (Live)'}).missing,true);
 assert.equal(chooseLyrics([{...record,syncedLyrics:''},{...record,duration:240},record],song),record);
});
test('plain exact responses still search for duration-matched synced lyrics',async()=>{
 const urls=[];const result=await lookupLyrics(song,{fetcher:async url=>{urls.push(url);return Response.json(url.includes('/get?')?{...record,syncedLyrics:''}:[{...record,duration:240},record])}});
 assert.equal(result.syncedLyrics,record.syncedLyrics);assert.equal(urls.length,2);
 assert.ok(urls[0].includes('artist_name=Chappell+Roan'));
});
test('lyric requests forward cancellation and unrelated lyric results are rejected',async()=>{
 const controller=new AbortController();controller.abort();
 await assert.rejects(lookupLyrics(song,{signal:controller.signal,fetcher:async(url,{signal})=>{assert.equal(signal.aborted,true);throw new DOMException('Aborted','AbortError')}}),/Aborted/);
 assert.equal(chooseLyrics([{...record,artistName:'Someone else'}],song),null);
});
