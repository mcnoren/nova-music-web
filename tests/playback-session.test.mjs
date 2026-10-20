import test from 'node:test';
import assert from 'node:assert/strict';
import {readPlaybackSession} from '../docs/playback-session.js';
const queue=[{id:'abcdefghijk',title:'First',duration:180},{id:'lmnopqrstuv',title:'Second',duration:240}];
const saved={queue,index:1,position:73.5,duration:240,playing:true,shuffle:true,repeat:2,context:'album:MPRE_saved',contextSongIDs:{lmnopqrstuv:'original123'},queueOrigins:['playlist:saved','album:MPRE_saved'],owner:'another-device'};
test('restore retains queue order, index, exact clock, source mappings and modes but always pauses',()=>{
 const result=readPlaybackSession(JSON.stringify(saved));
 assert.deepEqual(result.queue,queue);assert.equal(result.index,1);assert.equal(result.position,73.5);
 assert.equal(result.playing,false);assert.equal(result.shuffle,true);assert.equal(result.repeat,2);
 assert.deepEqual(result.contextSongIDs,saved.contextSongIDs);assert.deepEqual(result.queueOrigins,saved.queueOrigins);
 assert.equal(result.owner,undefined);
});
test('invalid stored queues and positions do not restore a broken player',()=>{
 for(const value of [null,{}, {...saved,queue:[]},{...saved,index:-1},{...saved,index:0.5},{...saved,index:2},{...saved,queue:[null,null]},{...saved,position:-1},{...saved,position:null}])assert.equal(readPlaybackSession(JSON.stringify(value)),null);
 assert.equal(readPlaybackSession('{'),null);
});
test('restored positions clamp to duration and missing origins recover collection context',()=>{
 const result=readPlaybackSession(JSON.stringify({...saved,position:500,queueOrigins:[]}));
 assert.equal(result.position,240);assert.deepEqual(result.queueOrigins,queue.map(()=>saved.context));
});
