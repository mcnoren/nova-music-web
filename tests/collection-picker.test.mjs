import test from 'node:test';
import assert from 'node:assert/strict';
import {searchCollections,sameFolderSlot} from '../docs/collection-picker.js';
import {menuPosition} from '../docs/menu-layout.js';
test('folder replacement searches the external album and playlist catalogs with the cancellation signal',async()=>{
 const calls=[],signal=new AbortController().signal;
 const client={async request(input,options){calls.push({input,options});return {albums:input.kind==='Albums'?[{id:'MPREnew',title:'Outside the library',artist:'Artist'}]:[],playlists:input.kind==='Playlists'?[{id:'PLnew',name:'Unsaved playlist',author:'Curator'}]:[],cursor:input.kind==='Albums'?'album-page-2':'playlist-page-2'};}};
 const result=await searchCollections(client,'outside',{signal});
 assert.deepEqual(calls.map(c=>c.input.kind),['Albums','Playlists']);assert.ok(calls.every(c=>c.options.signal===signal&&c.input.query==='outside'));
 assert.deepEqual(result.items.map(i=>i.kind+':'+i.id),['album:MPREnew','public-playlist:PLnew']);
 assert.deepEqual(result.cursors,{Albums:'album-page-2',Playlists:'playlist-page-2'});
});
test('pagination continues only result types with another page and stops repeated cursors',async()=>{
 const calls=[],client={async request(input){calls.push(input);return {playlists:[{id:'PLnext',name:'More'}],cursor:input.cursor};}};
 const result=await searchCollections(client,'mix',{cursors:{Albums:'',Playlists:'playlist-page-2'}});
 assert.equal(calls.length,1);assert.equal(calls[0].kind,'Playlists');assert.equal(calls[0].cursor,'playlist-page-2');assert.equal(result.cursors.Playlists,'');
});
test('catalog failures are surfaced so the picker can retry without accepting a partial result',async()=>{
 const client={async request({kind}){if(kind==='Albums')throw Error('Network unavailable');return {playlists:[]};}};
 await assert.rejects(searchCollections(client,'album'),/Network unavailable/);
});
test('an asynchronous replacement cannot overwrite a slot changed by sync or reordering',()=>{
 const original={kind:'album',id:'first'},f={items:[original,{kind:'playlist',id:'mix'}]};assert.equal(sameFolderSlot(f,0,original),true);
 f.items.reverse();assert.equal(sameFolderSlot(f,0,original),false);assert.equal(sameFolderSlot(undefined,0,original),false);
});
test('right-click menu starts at the actual pointer instead of a previous button',()=>{
 assert.deepEqual(menuPosition({x:410,y:210},{width:190,height:100},{width:1200,height:800}),{left:410,top:210});
});
test('menu positioning stays inside small viewports and at screen edges',()=>{
 assert.deepEqual(menuPosition({x:1199,y:799},{width:220,height:180},{width:1200,height:800}),{left:972,top:612});
 assert.deepEqual(menuPosition({x:-10,y:-10},{width:190,height:100},{width:200,height:120}),{left:8,top:8});
});
