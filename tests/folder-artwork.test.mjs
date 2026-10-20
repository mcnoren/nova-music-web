import test from 'node:test';
import assert from 'node:assert/strict';
import {folderCovers} from '../docs/collection-artwork.js';
test('folder collages follow mixed item order and use custom playlist photos',()=>{
 const folder={items:[{kind:'playlist',id:'mix'},{kind:'album',id:'a'},{kind:'album',id:'b'}]};
 const covers=folderCovers(folder,[{id:'a',artwork:'album-a'},{id:'b',artwork:'album-b'}],[{id:'mix',collectionArtwork:{style:'photo',image:'photo'}}],[]);
 assert.deepEqual(covers,['photo','album-a','album-b']);
});
test('folder collages skip missing items, deduplicate covers and stop at four',()=>{
 const albums=Array.from({length:6},(_,i)=>({id:String(i),artwork:'cover-'+i}));
 const folder={items:[{kind:'playlist',id:'missing'},...albums.map(a=>({kind:'album',id:a.id})),{kind:'album',id:'0'}]};
 assert.deepEqual(folderCovers(folder,albums,[],[]),['cover-0','cover-1','cover-2','cover-3']);
 assert.deepEqual(folderCovers({items:[]},albums,[],[]),[]);
});
