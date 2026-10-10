import test from 'node:test';
import assert from 'node:assert/strict';
import {PlaybackHealth} from '../docs/playback-health.js';
test('measures the engine clock rather than an assumed speed',()=>{
 const health=new PlaybackHealth();
 for(let i=0;i<=10;i++)health.sample(40+i*1.25,1,1.25,i*1000);
 assert.equal(health.report().observed,1.25);assert.equal(health.report().rate,1.25);
});
test('detects stopped progress while the engine still claims to play',()=>{
 const health=new PlaybackHealth();
 for(let i=0;i<=10;i++)health.sample(40,1,1,i*1000);
 assert.equal(health.report().observed,0);
});
test('seeks and new tracks restart measurement without reporting a speed jump',()=>{
 const health=new PlaybackHealth();
 for(let i=0;i<=6;i++)health.sample(40+i,1,1,i*1000);
 health.event('seek',100,6500);
 for(let i=0;i<=6;i++)health.sample(100+i,1,1,7000+i*1000);
 assert.equal(health.report().observed,1);assert.equal(health.report().seeks,1);
 health.event('load',0,14000);assert.equal(health.report().observed,null);
});
test('pause and buffering do not masquerade as slow playback; history is bounded',()=>{
 const health=new PlaybackHealth();
 for(let i=0;i<=10;i++)health.sample(40,2,1,i*1000);
 assert.equal(health.report().observed,null);
 for(let i=0;i<100;i++)health.event('buffering',null,i);
 assert.equal(health.report().events.length,40);assert.equal(health.report().buffering,100);
 for(let i=0;i<=100;i++)health.sample(i,1,1,i*1000);
 assert.equal(health.samples.length,16);assert.equal(health.report().observed,1);
});
