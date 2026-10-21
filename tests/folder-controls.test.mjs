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

test('removing a saved playlist preserves every folder slot, pin, songs and artwork',async()=>{
 const {removePlaylistFromLibrary}=await import('../docs/folder-controls.js');
 const p={id:'p',name:'Mix',songs:['a','b'],collectionArtwork:{kind:'icon',symbol:'star'},sourceUrl:'https://open.spotify.com/playlist/source'};
 const state={playlists:[p],libraryPins:['#playlist/p','#folder/f'],folders:[{items:[{kind:'album',id:'a'},{kind:'playlist',id:'p'}],pins:['playlist:p']},{items:[{kind:'playlist',id:'p'}]}]};
 const folders=structuredClone(state.folders);
 assert.equal(removePlaylistFromLibrary(state,'p'),true);
 assert.deepEqual(state.folders,folders);assert.equal(state.playlists[0],p);
 assert.deepEqual(p.songs,['a','b']);assert.deepEqual(p.collectionArtwork,{kind:'icon',symbol:'star'});
 assert.equal(p.folderOnly,true);assert.equal(p.folderReference,false);assert.deepEqual(state.libraryPins,['#folder/f']);
 p.folderOnly=false;assert.equal(state.playlists.length,1,'Adding back reuses the same playlist');
});
test('a removed saved YouTube copy stays a snapshot instead of becoming a live reference',async()=>{
 const {removePlaylistFromLibrary}=await import('../docs/folder-controls.js');
 const state={playlists:[{id:'p',songs:['saved-song'],sourceUrl:'https://www.youtube.com/playlist?list=PLsource'}],folders:[{items:[{kind:'playlist',id:'p'}]}]};
 removePlaylistFromLibrary(state,'p');assert.equal(state.playlists[0].folderReference,false);assert.deepEqual(state.playlists[0].songs,['saved-song']);
});
test('unreferenced playlists can be deleted without affecting other playlists or folders',async()=>{
 const {removePlaylistFromLibrary}=await import('../docs/folder-controls.js');
 const state={playlists:[{id:'p'},{id:'q'}],folders:[{items:[{kind:'playlist',id:'q'}]}]};
 assert.equal(removePlaylistFromLibrary(state,'missing'),false);removePlaylistFromLibrary(state,'p');
 assert.deepEqual(state.playlists,[{id:'q'}]);assert.deepEqual(state.folders[0].items,[{kind:'playlist',id:'q'}]);
});
