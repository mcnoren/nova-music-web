import test from 'node:test';
import assert from 'node:assert/strict';
import {emptyDocument, updateDocument, mergeDocuments, valuesOf, libraryValues, applyLibraryValues, documentsEqual, validateDocument} from '../docs/sync-model.js';
const A='00000000-0000-4000-8000-000000000001', B='00000000-0000-4000-8000-000000000002';
const song={id:'abcdefghijk',title:'Song',artist:'Artist',album:'Album',source:'youtube',artwork:'https://example.com/art.jpg',duration:120};
const baseState=()=>({liked:[song.id],saved:[],albums:[],artists:[],artistPins:[],playlists:[],folders:[],releaseChoices:{},discChoices:{},recent:[],extraSongs:{},extraAlbums:{},extraArtists:{},genres:['Rock'],settings:{youtubeKey:'do-not-upload',spotifyClientId:'also-device-local'}});
test('independent offline changes converge in either merge direction',()=>{
 const base=updateDocument(emptyDocument(),{}, {'liked:abcdefghijk':{id:song.id,order:0}},A);
 const av=valuesOf(base), bv=valuesOf(base); av['playlist:'+A]={id:A,name:'A',songs:[song.id]};bv['folder:'+B]={id:B,name:'B',items:[]};
 const left=updateDocument(base,valuesOf(base),av,A),right=updateDocument(base,valuesOf(base),bv,B);
 assert.ok(documentsEqual(mergeDocuments(left,right),mergeDocuments(right,left)));
 assert.equal(Object.keys(valuesOf(mergeDocuments(left,right))).length,3);
});
test('an offline old copy cannot resurrect a deleted playlist',()=>{
 const base=updateDocument(emptyDocument(),{}, {['playlist:'+A]:{id:A,name:'Playlist',songs:[]}},A);
 const deleted=updateDocument(base,valuesOf(base),{},B);
 assert.equal(valuesOf(mergeDocuments(deleted,base))['playlist:'+A],undefined);
 assert.equal(mergeDocuments(base,deleted).records['playlist:'+A].deleted,true);
});
test('records with same revision and different contents stop sync',()=>{
 const base=updateDocument(emptyDocument(),{},{'preference:genres':['Jazz']},A),bad=structuredClone(base);bad.records['preference:genres'].value=['Rock'];
 assert.throws(()=>mergeDocuments(base,bad),/same revision/);
});
test('JSON object order does not create unnecessary sync writes',()=>{
 assert.ok(documentsEqual({version:1,records:{}},{records:{},version:1}));
});
test('provider credentials and local audio never enter the cloud document',()=>{
 const state=baseState();state.extraSongs['local-file']={id:'local-file',title:'Private',artist:'Me',source:'local'};state.saved=['local-file'];state.playlists=[{id:A,name:'Mix',songs:[song.id,'local-file']}];
 const values=libraryValues(state,{songs:[song],albums:[],artists:[]}),encoded=JSON.stringify(values);
 assert.ok(!encoded.includes('do-not-upload'));assert.ok(!encoded.includes('also-device-local'));assert.ok(!encoded.includes('local-file'));assert.equal(values['playlist:'+A].songs.length,1);
});
test('local audio references and device settings survive cloud updates',()=>{
 const state=baseState();state.saved=['local-file'];state.extraSongs['local-file']={id:'local-file',title:'Private',artist:'Me',source:'local'};
 const values=libraryValues(baseState(),{songs:[song],albums:[],artists:[]}),next=applyLibraryValues(state,values);
 assert.equal(next.settings.youtubeKey,'do-not-upload');assert.ok(next.saved.includes('local-file'));assert.equal(next.extraSongs['local-file'].source,'local');
});
test('browsed albums keep all tracks through playback and periodic sync without becoming saved',()=>{
 const catalog={songs:[],albums:[],artists:[]},state=baseState();state.liked=[];
 const second={...song,id:'lmnopqrstuv',title:'Second song'};
 const album={id:'MPREbrowse',title:'Album',artist:'Artist',tracks:[song.id,second.id],complete:true};
 state.extraSongs={[song.id]:song,[second.id]:second};state.extraAlbums={[album.id]:album};state.extraArtists.UCartist={id:'UCartist',name:'Artist'};
 let next=applyLibraryValues(state,libraryValues(state,catalog));
 next.recent=[{id:song.id,at:100}];
 for(let i=0;i<3;i++)next=applyLibraryValues(next,libraryValues(next,catalog));
 assert.deepEqual(next.extraAlbums[album.id],album);
 assert.deepEqual(album.tracks.map(id=>next.extraSongs[id].title),['Song','Second song']);
 assert.equal(next.extraArtists.UCartist.name,'Artist');
 assert.deepEqual(next.albums,[]);
 const uploaded=libraryValues(next,catalog);
 assert.ok(uploaded['song:'+song.id]);
 assert.equal(uploaded['song:'+second.id],undefined);
 assert.equal(uploaded['album:'+album.id],undefined);
 assert.equal(uploaded['artist:UCartist'],undefined);
});
test('sync removals still remove saved membership while newer metadata overrides cached details',()=>{
 const state=baseState();state.albums=['MPREbrowse'];state.extraSongs[song.id]=song;
 state.extraAlbums.MPREbrowse={id:'MPREbrowse',title:'Album',artist:'Artist',tracks:[song.id]};
 const next=applyLibraryValues(state,{['song:'+song.id]:{...song,title:'Updated title'}});
 assert.deepEqual(next.liked,[]);assert.deepEqual(next.albums,[]);
 assert.equal(next.extraSongs[song.id].title,'Updated title');
 assert.ok(next.extraAlbums.MPREbrowse);
 // Account activation supplies the new account's own state, never the outgoing account's cache.
 const other=applyLibraryValues(baseState(),{});
 assert.equal(other.extraAlbums.MPREbrowse,undefined);assert.equal(other.extraSongs[song.id],undefined);
});
test('native-only records survive a web edit',()=>{
 let document=updateDocument(emptyDocument(),{},{['artistFolder:'+B]:{id:B,name:'Native only'},...libraryValues(baseState(),{songs:[song],albums:[],artists:[]})},A);
 const applied=applyLibraryValues(baseState(),valuesOf(document)),previous=libraryValues(applied,{songs:[song],albums:[],artists:[]});applied.liked=[];
 document=updateDocument(document,previous,libraryValues(applied,{songs:[song],albums:[],artists:[]}),B);
 assert.equal(document.records['artistFolder:'+B].deleted,false);
});
test('empty release and disc selections remain deliberately empty',()=>{
 const state=baseState();state.releaseChoices.UCartist=[];state.discChoices.album=[];
 const next=applyLibraryValues(baseState(),libraryValues(state,{songs:[song],albums:[],artists:[]}));assert.deepEqual(next.releaseChoices.UCartist,[]);assert.deepEqual(next.discChoices.album,[]);
});
test('malformed synced collection IDs and dangerous artwork are rejected or removed',()=>{
 const state=baseState(),values=libraryValues(state,{songs:[song],albums:[],artists:[]});values['playlist:'+A]={id:'" onclick="alert(1)',name:'Bad',songs:[]};assert.throws(()=>applyLibraryValues(state,values),/invalid/);
 delete values['playlist:'+A];values['song:'+song.id].artwork='javascript:alert(1)';assert.equal(applyLibraryValues(state,values).extraSongs[song.id].artwork,undefined);
 assert.throws(()=>validateDocument({version:1,records:{'bad-key':{clock:1,actor:A,deleted:true}}}),/invalid/);
});
test('playlist photos, icons, collages and artist association survive a web round trip',()=>{
 for(const collectionArtwork of [{style:'photo',image:'data:image/jpeg;base64,/9j/2Q=='},{style:'icon',symbol:'heart.fill'},{style:'collage'},null]){
  const state=baseState();state.playlists=[{id:A,name:'Artwork',songs:[song.id],collectionArtwork,artistId:'UCartist'}];
  const values=libraryValues(state,{songs:[song],albums:[],artists:[]}),next=applyLibraryValues(baseState(),values);
  assert.deepEqual(next.playlists[0].collectionArtwork,collectionArtwork);assert.equal(next.playlists[0].artistId,'UCartist');
  assert.deepEqual(libraryValues(next,{songs:[song],albums:[],artists:[]})['playlist:'+A].collectionArtwork,collectionArtwork);
 }
});
test('invalid custom playlist artwork is rejected before account state changes',()=>{
 const state=baseState(),values=libraryValues(state,{songs:[song],albums:[],artists:[]});
 for(const collectionArtwork of [{style:'photo',image:'file:///private/photo.jpg'},{style:'icon',symbol:'<script>'},{style:'photo',image:'data:image/jpeg;base64,'+'A'.repeat(600001)}]){
  values['playlist:'+A]={id:A,name:'Unsafe',songs:[],collectionArtwork};assert.throws(()=>applyLibraryValues(state,values),/Invalid playlist/);assert.deepEqual(state.playlists,[]);
 }
});
