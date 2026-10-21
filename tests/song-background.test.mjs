import test from 'node:test';
import assert from 'node:assert/strict';
import {verifiedSongPage,songBackgroundText,songBackground} from '../docs/song-background.js';
const page = (title='Original (Artist song)', artist='Artist') => ({title, fullurl:'https://en.wikipedia.org/wiki/Original_(Artist_song)', extract:`Original is a song by ${artist}, released as a single from an acclaimed studio album. It was recorded with a full band.`});
test('song backgrounds require matching title, performer, subject and trusted source',()=>{
 assert.ok(verifiedSongPage([page()],'Original','Artist'));
 for(const bad of [page('Original (Other song)','Other'),page('Another song'),{...page(),pageprops:{disambiguation:''}},{...page(),fullurl:'https://other.example/wiki/Original'},{...page(),fullurl:'javascript:alert(1)'}])assert.equal(verifiedSongPage([bad],'Original','Artist'),null);
});
test('detailed background retains prose and omits chart tables and reference lists',()=>{
 const full=page().extract+'\n== Background and writing ==\nWritten during the album sessions.\n=== Recording ===\nRecorded with acoustic instruments.\n== Charts ==\nDo not show chart table.\n== Critical reception ==\nReviewers praised the vocal performance.\n== References ==\nDo not show reference list.';
 const result=songBackgroundText(full);
 assert.match(result,/album sessions/);assert.match(result,/acoustic instruments/);assert.match(result,/vocal performance/);assert.doesNotMatch(result,/Do not show/);
 assert.ok(songBackgroundText('A'.repeat(9001)).length<=9000);
});
test('lookup fetches detailed verified prose beyond the lead and coalesces requests',async()=>{
 const urls=[];const fetcher=async raw=>{const u=new URL(raw);urls.push(u);return {ok:true,json:async()=>({query:{pages:[{...page(),extract:page().extract+(u.searchParams.has('exintro')?'':'\n== Background ==\nThe artist wrote it during the album sessions.')} ]}})}};
 const [a,b]=await Promise.all([songBackground('Original','Artist',{fetcher,refresh:true}),songBackground('Original','Artist',{fetcher})]);
 assert.deepEqual(a,b);assert.equal(urls.length,2);assert.match(a.text,/album sessions/);assert.equal(urls[1].searchParams.get('exintro'),null);assert.match(a.sourceName,/CC BY-SA/);
});
test('search fallback rejects unrelated top results and finds matching recording',async()=>{
 let calls=0;const fetcher=async raw=>{calls++;const u=new URL(raw);return {ok:true,json:async()=>({query:{pages:u.searchParams.has('generator')?[page('Other song'),page('Search song (Artist song)')]:u.searchParams.has('exintro')?[]:[page('Search song (Artist song)')]}})}};
 const result=await songBackground('Search song','Artist',{fetcher,refresh:true});
 assert.ok(result);assert.equal(calls,3);
});
test('full-text network failure keeps a verified introduction and failures can retry',async()=>{
 let calls=0;const fetcher=async()=>{if(++calls===1)return {ok:true,json:async()=>({query:{pages:[page('Fallback (Artist song)')]}})};throw Error('offline')};
 const value=await songBackground('Fallback','Artist',{fetcher,refresh:true});assert.ok(value);assert.equal(value.text,page().extract);
 assert.equal(await songBackground('Absent','Artist',{fetcher,refresh:true}),null);
});

test('formula sections and headings without remaining prose are omitted',()=>{
 const result=songBackgroundText('Introduction text.\n== Composition ==\nFormula: {\\displaystyle x}\n== Recording ==\nRecorded with the band.');
 assert.doesNotMatch(result,/Formula|Composition|displaystyle/);assert.match(result,/Recorded with the band/);
 assert.equal(songBackgroundText('Introduction.\n== Background ==\n'+'A'.repeat(9001)),'Introduction.');
});
