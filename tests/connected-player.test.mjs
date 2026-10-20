import test from 'node:test';
import assert from 'node:assert/strict';
import {applyPlayerCommand,snapshotLyrics} from '../docs/connected-player.js';
import {validSnapshot} from '../docs/connect.js';
function fixture(){
 let clock=42.75,playing=true;const calls=[];
 return {calls,get clock(){return clock},get playing(){return playing},engine:{needsLoad:false,
  load:async(p,play)=>{calls.push('load');clock=p;playing=play},
  seek:p=>{calls.push('seek');clock=p},playing:()=>playing,
  play:async()=>{calls.push('play');playing=true},pause:async()=>{calls.push('pause');playing=false}}};
}
test('remote pause and resume preserve the audible clock despite delayed controller estimates',async()=>{
 const f=fixture();await applyPlayerCommand({position:39,playing:false,positionIntent:'preserve'},f.engine);
 assert.equal(f.clock,42.75);assert.deepEqual(f.calls,['pause']);
 await applyPlayerCommand({position:39,playing:true,positionIntent:'preserve'},f.engine);
 assert.equal(f.clock,42.75);assert.deepEqual(f.calls,['pause','play']);
});
test('queue edits, shuffle, repeat and repeated status do not seek or restart playing audio',async()=>{
 const f=fixture();for(let i=0;i<10;i++)await applyPlayerCommand({position:39+i,playing:true,positionIntent:'preserve'},f.engine);
 assert.equal(f.clock,42.75);assert.deepEqual(f.calls,[]);
});
test('explicit seeks and repeated-song selections still seek exactly once',async()=>{
 const f=fixture();await applyPlayerCommand({position:8,playing:true,positionIntent:'seek'},f.engine);
 assert.equal(f.clock,8);assert.deepEqual(f.calls,['seek']);
 await applyPlayerCommand({position:0,playing:true},f.engine);assert.equal(f.clock,0);
});
test('new outputs load at the requested clock without adding preparation time or an extra seek',async()=>{
 const f=fixture();f.engine.needsLoad=true;
 await applyPlayerCommand({position:18.125,playing:true,positionIntent:'preserve'},f.engine);
 assert.equal(f.clock,18.125);assert.deepEqual(f.calls,['load']);
});
test('pause remains in flight until the output engine confirms it',async()=>{
 const f=fixture();let release,complete=false;f.engine.pause=()=>new Promise(resolve=>{release=resolve});
 const work=applyPlayerCommand({position:12,playing:false,positionIntent:'preserve'},f.engine).then(()=>{complete=true});
 assert.equal(complete,false);release();await work;assert.equal(complete,true);assert.equal(f.clock,42.75);
});
test('position intent is optional for existing clients and rejects unsupported values',()=>{
 const s={queue:[],index:0,position:0,playing:false,shuffle:false,repeat:0};
 assert.equal(Boolean(validSnapshot(s)),true);assert.equal(Boolean(validSnapshot({...s,positionIntent:'preserve'})),true);
 assert.equal(Boolean(validSnapshot({...s,positionIntent:'seek'})),true);assert.equal(Boolean(validSnapshot({...s,positionIntent:'estimate'})),false);
});
test('explicit seeks finish before the connected command is acknowledged',async()=>{
 const f=fixture();let finishSeek,complete=false;
 f.engine.seek=()=>new Promise(resolve=>{finishSeek=resolve});
 const work=applyPlayerCommand({position:8,playing:true,positionIntent:'seek'},f.engine).then(()=>complete=true);
 await Promise.resolve();assert.equal(complete,false);finishSeek();await work;assert.equal(complete,true);
});

test('Mac keeps session lyrics and calibration before loading audio, and through seeks in either direction',async()=>{
 const {activeLyric}=await import('../docs/lyrics.js');
 const lyrics={songID:'abcdefghijk',recordingID:'lmnopqrstuv',loaded:true,plain:'First\nSecond',lines:[{time:0,text:'First'},{time:10,text:'Second'}],offset:1.25,rate:1.02};
 const snapshot={queue:[{id:lyrics.songID}],index:0,lyrics,position:12,playing:false};
 const f=fixture();let installed=null;
 f.engine.lyrics=value=>{installed=value};f.engine.needsLoad=true;
 f.engine.load=async p=>{assert.equal(installed,lyrics);f.engine.seek(p)};
 await applyPlayerCommand(snapshot,f.engine);
 const active=()=>activeLyric(installed.lines,f.clock*installed.rate+installed.offset);
 assert.equal(active(),1);assert.equal(installed.recordingID,'lmnopqrstuv');
 f.engine.needsLoad=false;
 await applyPlayerCommand({...snapshot,position:3,positionIntent:'seek'},f.engine);assert.equal(active(),0);
 await applyPlayerCommand({...snapshot,position:15,positionIntent:'seek'},f.engine);assert.equal(active(),1);
 await applyPlayerCommand({...snapshot,queue:[{id:'anotherSong'}]},f.engine);assert.equal(installed,null,'Previous recording cues must not survive a song change');
 assert.equal(snapshotLyrics(null),null);
});
