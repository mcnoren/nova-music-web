import test from 'node:test';
import assert from 'node:assert/strict';
import {lyricContentKey,patchLyricContent,lyricInterludeRange,interludeIllumination,presentedLyric,lyricSpring} from '../docs/lyric-presentation.js';
const data={plain:'First\nSecond',source:'Lyrics',lines:[{time:0,text:'First'},{time:10,text:''},{time:20,text:'Second'}]};
test('telemetry, provider payloads and key ordering do not invalidate rendered lyrics',()=>{
 const first=lyricContentKey('track',data);
 assert.equal(first,lyricContentKey('track',{record:{updated:Date.now()},custom:true,...data,lines:data.lines.map(l=>({endTime:undefined,text:l.text,time:l.time}))}));
 assert.notEqual(first,lyricContentKey('track',{...data,lines:[{time:0,text:'Corrected'}]}));
 assert.notEqual(first,lyricContentKey('next',data));
});
test('unchanged refreshes preserve lyric nodes, scroll position and mounted artwork',()=>{
 let writes=0,builds=0;const node={scrollTop:128,set innerHTML(value){writes++;this.scrollTop=0;}};
 const render=()=>{builds++;return '<p>First</p>'};
 const key=lyricContentKey('track',data);
 assert.equal(patchLyricContent(node,key,render),true);node.scrollTop=128;
 for(let i=0;i<50;i++)assert.equal(patchLyricContent(node,lyricContentKey('track',{...data,record:{at:i}}),render),false);
 assert.equal(writes,1);assert.equal(builds,1);assert.equal(node.scrollTop,128);
 assert.equal(patchLyricContent(node,lyricContentKey('next',data),render),true);assert.equal(writes,2);
});
test('instrumental countdown shares timing with native dots and follows seeks exactly',()=>{
 assert.deepEqual(lyricInterludeRange(data.lines,1),{start:10,end:20});assert.equal(lyricInterludeRange(data.lines,0),null);
 assert.equal(lyricInterludeRange([{time:10,text:''}],0),null);
 assert.deepEqual([0,1,2].map(i=>interludeIllumination(15,10,20,i)),[1,.5,0]);
 assert.deepEqual([0,1,2].map(i=>interludeIllumination(20,10,20,i)),[1,1,1]);
 assert.deepEqual([0,1,2].map(i=>interludeIllumination(10,10,20,i)),[0,0,0]);
 assert.equal(interludeIllumination(NaN,10,20,0),0);
});

test('visual handoff leads vocals, preserves pauses and gaps, and lands exactly on cue',()=>{
 const lines=[{time:0,text:'First',endTime:8},{time:10,text:'Second',endTime:12}];
 assert.equal(presentedLyric(lines,9,true),-1);
 assert.equal(presentedLyric(lines,9.7,true),1);
 assert.equal(presentedLyric(lines,9.7,false),-1);
 assert.equal(presentedLyric(lines,10,true),1);
 assert.equal(presentedLyric(lines,12,true),-1);
 assert.equal(presentedLyric(lines,NaN,true),-1);
 assert.equal(lyricSpring(0),0);assert.equal(lyricSpring(1),1);
 assert.ok(lyricSpring(.35)>1);assert.ok(lyricSpring(.9)<1);
});

test('rapid cues retain time on screen before the next handoff',()=>{
 const lines=[{time:0,text:'One'},{time:.2,text:'Two'},{time:.4,text:'Three'}];
 assert.equal(presentedLyric(lines,.05,true),0);assert.equal(presentedLyric(lines,.15,true),1);
});
