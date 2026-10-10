import test from 'node:test';
import assert from 'node:assert/strict';
import {artistReleases,chosenReleases,releaseKind,releaseTracks,selectedTopSongs} from '../docs/artist-library.js';
const artist={id:'UCowner',name:'Owner'};
test('selected phone releases remain visible before their tracks load and unrelated releases stay out',()=>{
 const releases=artistReleases(artist,[{id:'MPREone',title:'One',artist:'Owner',year:'2023',kind:'Album',tracks:[]},{id:'MPREtwo',title:'Two',artist:'Owner',year:'2025',type:'Single',tracks:[]},{id:'MPREarchived',title:'Archived',artist:'Guest',kind:'EP',tracks:[]},{id:'MPREother',title:'Other',artist:'Other',tracks:[]}],[],['MPREarchived']);
 assert.deepEqual(releases.map(a=>a.id),['MPREtwo','MPREone','MPREarchived']);
 assert.equal(releaseKind(releases[0]),'Singles & EPs');assert.equal(releaseKind(releases[1]),'Albums');
 assert.deepEqual(chosenReleases(releases,[]),[]);assert.deepEqual(chosenReleases(releases,['MPREarchived']).map(a=>a.id),['MPREarchived']);
});
test('chosen album playback includes featured performers, respects disc choices and deduplicates recordings',()=>{
 const songs=[{id:'one',title:'One',artist:'Guest',discNumber:1},{id:'two',title:'Two',artist:'Owner',discNumber:2}];
 const albums=[{id:'a',tracks:['one','two']},{id:'b',tracks:['one']}];
 assert.deepEqual(releaseTracks(albums,songs,{a:[1]}).map(s=>s.id),['one']);
 assert.deepEqual(releaseTracks(albums,songs,{a:[],b:[]}),[]);
 assert.deepEqual(selectedTopSongs([{...songs[0],id:'alternate'},{id:'unselected',title:'Other',artist:'Owner'}],[songs[0]]).map(s=>s.id),['alternate']);
});
