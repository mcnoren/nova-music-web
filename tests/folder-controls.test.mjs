import test from 'node:test';
import assert from 'node:assert/strict';
import {moveFolderItem,replaceFolderItem,sidebarSelection} from '../docs/folder-controls.js';
import {createLibraryStorage} from '../docs/library-storage.js';
test('mixed albums and playlists keep their explicit drag order',()=>{
 const f={items:[{kind:'album',id:'a'},{kind:'playlist',id:'p'},{kind:'album',id:'b'}]};
 assert.equal(moveFolderItem(f,2,0),true);assert.deepEqual(f.items.map(i=>i.id),['b','a','p']);
 assert.equal(moveFolderItem(f,-1,1),false);assert.equal(moveFolderItem(f,0,8),false);
});
test('replacement keeps the exact slot and transfers its pin',()=>{
 const f={items:[{kind:'album',id:'a'},{kind:'playlist',id:'p'},{kind:'album',id:'b'}],pins:['playlist:p']};
 assert.equal(replaceFolderItem(f,1,{kind:'album',id:'c'}),true);
 assert.deepEqual(f.items.map(i=>i.id),['a','c','b']);assert.deepEqual(f.pins,['album:c']);
 assert.equal(replaceFolderItem(f,1,{kind:'album',id:'b'}),false);
 assert.deepEqual(f.items.map(i=>i.id),['a','c','b']);
});
test('All shows five per type, ranks pins first, and includes every pin above five',()=>{
 const entries=Array.from({length:9},(_,i)=>({id:i,type:'Albums',pinned:i<6,visited:i}));
 entries.push(...Array.from({length:9},(_,i)=>({id:'p'+i,type:'Playlists',visited:i})));
 const list=sidebarSelection(entries);assert.equal(list.filter(e=>e.type==='Albums').length,6);
 assert.deepEqual(list.filter(e=>e.type==='Playlists').map(e=>e.id),['p8','p7','p6','p5','p4']);
 assert.equal(sidebarSelection(entries,false).length,18);
});
test('website reads legacy data for migration but never writes its library to device storage',()=>{
 let writes=0;const legacy={getItem:()=>'{"existing":true}',setItem:()=>writes++};
 const storage=createLibraryStorage({legacy});assert.equal(storage.getItem('library'),'{"existing":true}');
 storage.setItem('library','updated');assert.equal(storage.getItem('library'),'updated');assert.equal(writes,0);
 storage.removeItem('library');assert.equal(storage.getItem('library'),null);
});
test('unavailable native storage retains changes in memory',()=>{
 const storage=createLibraryStorage({persistent:{getItem(){throw Error()},setItem(){throw Error()}}});
 assert.equal(storage.getItem('library'),null);storage.setItem('library','cloud pending');assert.equal(storage.getItem('library'),'cloud pending');
});
