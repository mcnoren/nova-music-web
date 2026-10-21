import test from 'node:test';
import assert from 'node:assert/strict';
import {dragDestination} from '../docs/folder-drag.js';
const rect=(left,top,width=100,height=80)=>({left,top,width,height});
test('list reordering waits for the next midpoint in either direction',()=>{
 const rows=[rect(0,0),rect(0,88),rect(0,176)];
 assert.equal(dragDestination(0,1,{x:20,y:120},rows),0);
 assert.equal(dragDestination(0,1,{x:20,y:130},rows),1);
 assert.equal(dragDestination(2,1,{x:20,y:140},rows),2);
 assert.equal(dragDestination(2,1,{x:20,y:120},rows),1);
 assert.equal(dragDestination(0,-1,{x:20,y:130},rows),0);
});
test('gallery reordering follows columns and wraps across rows',()=>{
 const rows=[rect(0,0),rect(120,0),rect(0,100),rect(120,100)];
 assert.equal(dragDestination(0,1,{x:160,y:20},rows,true),0);
 assert.equal(dragDestination(0,1,{x:175,y:20},rows,true),1);
 assert.equal(dragDestination(1,2,{x:40,y:145},rows,true),2);
 assert.equal(dragDestination(3,2,{x:40,y:145},rows,true),2);
});
