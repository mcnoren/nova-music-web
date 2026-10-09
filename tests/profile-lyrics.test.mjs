import test from 'node:test';
import assert from 'node:assert/strict';
import {defaultProfile,validateProfile} from '../docs/profile.js';
import {libraryValues,applyLibraryValues} from '../docs/sync-model.js';
import {parseLRC,activeLyric,lookupLyrics,lyricData,chooseLyrics,normalizedLines,playbackSample,preferredAudio} from '../docs/lyrics.js';
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
test('lyric highlighting ends with the provider cue and resumes after an instrumental gap or backward seek',()=>{
 const lines=normalizedLines([{time:0,endTime:15,text:'♪'},{time:15.35,endTime:22.62,text:'Example one'},{time:25,endTime:30,text:'Example two'}]);
 assert.equal(lines[0].text,'');assert.equal(activeLyric(lines,23),-1);assert.equal(activeLyric(lines,25),2);assert.equal(activeLyric(lines,16),1);
 assert.equal(activeLyric(lines,NaN),-1);
 const dupe=normalizedLines([{time:1,text:'A'},{time:1,text:''},{time:1,text:'B'}]);assert.equal(dupe[0].text,'A\nB');
});
test('the playback clock rejects the previous YouTube recording during a song switch',()=>{
 const song={id:'newtrack123',source:'youtube',duration:225};let id='oldtrack123';
 const player={getVideoUrl:()=> 'https://www.youtube.com/watch?v='+id,getDuration:()=>251,getCurrentTime:()=>140};
 assert.deepEqual(playbackSample(song,player),{position:0,duration:225,confirmed:false});
 id=song.id;assert.equal(playbackSample(song,player,null,'').confirmed,false);assert.deepEqual(playbackSample(song,player),{position:140,duration:251,confirmed:true});
 assert.deepEqual(playbackSample(null,player),{position:0,duration:0,confirmed:false});
});
test('music video playback resolves only the same artist/title official audio and preserves alternate versions',async()=>{
 const video={id:'video123456',title:'drop dead (Official Video)',artist:'Olivia Rodrigo',source:'youtube',musicVideoType:'MUSIC_VIDEO_TYPE_OMV'};
 const audio={id:'audio123456',title:'drop dead',artist:'Olivia Rodrigo',source:'youtube',musicVideoType:'MUSIC_VIDEO_TYPE_ATV'};
 const request=async()=>({songs:[{...audio,id:'cover',artist:'Another singer'},audio]});
 assert.equal((await preferredAudio(video,request)).id,audio.id);
 assert.equal((await preferredAudio({...video,title:'drop dead (Live)'},request)).id,video.id);
 assert.equal(lyricData({...record,duration:251},{...song,duration:251,source:'youtube',musicVideoType:'MUSIC_VIDEO_TYPE_OMV'}).lines.length,0);
});
