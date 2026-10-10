import test from 'node:test';
import assert from 'node:assert/strict';
import {applyPlayerCommand} from '../docs/connected-player.js';
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
