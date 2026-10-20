import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {collectionContext,rememberCollection,collectionSong} from '../docs/collection-position.js';
import {libraryValues,applyLibraryValues,emptyDocument,updateDocument,mergeDocuments,valuesOf} from '../docs/sync-model.js';
const actor='00000000-0000-4000-8000-000000000001',other='00000000-0000-4000-8000-000000000002';
const catalog={songs:[{id:'abcdefghijk',title:'One',artist:'Artist',source:'youtube'},{id:'lmnopqrstuv',title:'Two',artist:'Artist',source:'youtube'}],albums:[],artists:[]};
test('collection bookmarks remain independent across albums, playlists and ordinary playback',()=>{
 const state={},album=collectionContext('album','MPREone'),playlist=collectionContext('playlist',actor);
 rememberCollection(state,album,'abcdefghijk',1);assert.equal(collectionSong(state,playlist),undefined);
 rememberCollection(state,playlist,'abcdefghijk',2);rememberCollection(state,album,'lmnopqrstuv',3);
 assert.equal(collectionSong(state,playlist),'abcdefghijk');assert.equal(collectionSong(state,album),'lmnopqrstuv');
 assert.equal(rememberCollection(state,null,'abcdefghijk',4),false);
 assert.equal(rememberCollection(state,album,'lmnopqrstuv',5),false);assert.equal(state.collectionPositions[album].at,3);
});
test('offline collection positions merge and restore on another device and isolate account state',()=>{
 const left={},right={},album='album:MPREone',playlist='playlist:'+actor;
 rememberCollection(left,album,'abcdefghijk',1);rememberCollection(right,playlist,'lmnopqrstuv',2);
 const a=updateDocument(emptyDocument(),{},libraryValues(left,catalog),actor),b=updateDocument(emptyDocument(),{},libraryValues(right,catalog),other);
 const merged=mergeDocuments(a,b),state=applyLibraryValues({},valuesOf(merged));
 assert.equal(collectionSong(state,album),'abcdefghijk');assert.equal(collectionSong(state,playlist),'lmnopqrstuv');
 assert.deepEqual(applyLibraryValues(state,{}).collectionPositions,{});
 assert.throws(()=>applyLibraryValues({}, {'collectionPosition:artist:UCone':{songID:'abcdefghijk',at:1}}),/Invalid collection/);
});
test('repeated player telemetry preserves the existing artwork DOM and song changes replace it once',()=>{
 const source=readFileSync(new URL('../docs/app.js',import.meta.url),'utf8');
 const fn=source.match(/function updateCurrentSong\(\)\{[^\n]+\}/)[0];
 let updates=0;const node={dataset:{},set innerHTML(v){updates++;this.markup=v}};
 const context=vm.createContext({current:catalog.songs[0],$:()=>node,art:url=>`<img src="${url}">`,esc:s=>s});vm.runInContext(fn,context);
 for(let i=0;i<50;i++)vm.runInContext('updateCurrentSong()',context);
 assert.equal(updates,1);context.current=catalog.songs[1];vm.runInContext('updateCurrentSong()',context);assert.equal(updates,2);
 context.current=null;vm.runInContext('updateCurrentSong()',context);vm.runInContext('updateCurrentSong()',context);assert.equal(updates,3);
});
