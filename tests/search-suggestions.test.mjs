import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {SearchSuggestions} from '../docs/search-suggestions.js';
import {NativeCatalogClient} from '../docs/native-catalog.js';
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
test('autocomplete uses the native suggestions operation and preserves provider order',async()=>{
 const fixture=JSON.parse(await readFile(new URL('./fixtures/provider-search.json',import.meta.url))),calls=[];
 const client=new NativeCatalogClient({transport:{request:async(op,body)=>{calls.push({op,body});return fixture.suggestions;}}});
 const result=await client.request({op:'suggestions',query:'adele he'});
 assert.deepEqual(calls,[{op:'suggestions',body:{input:'adele he'}}]);
 assert.deepEqual(result.suggestions,[{text:'adele hello'},{text:'adele hello live'}]);
});
test('debounce, cancellation, and late replies keep suggestions on the newest query',async()=>{
 const pending=[],renders=[];
 const controller=new SearchSuggestions({delay:5,render:x=>renders.push(x),request:(q,{signal})=>new Promise(resolve=>pending.push({q,signal,resolve}))});
 controller.update('old');await wait(10);controller.update('new');await wait(10);
 assert.equal(pending[0].signal.aborted,true);
 pending[1].resolve([{text:'new song'},{text:'new artist'}]);await wait(0);
 pending[0].resolve([{text:'old song'}]);await wait(0);
 assert.deepEqual(controller.items,['new song','new artist']);assert.deepEqual(renders.at(-1),controller.items);controller.dismiss();
});
test('keyboard selection, dismissal, limits, and failures keep typed submission available',async()=>{
 const selected=[],controller=new SearchSuggestions({delay:0,select:x=>selected.push(x),request:async()=>Array.from({length:12},(_,i)=>({text:'Song '+i}))});
 controller.update('Song');await wait(10);assert.equal(controller.items.length,8);
 assert.equal(controller.move(1),true);assert.equal(controller.index,0);assert.equal(controller.choose(),true);assert.deepEqual(selected,['Song 0']);assert.equal(controller.items.length,0);
 controller.update('');await wait(5);assert.equal(controller.choose(),false);
 const failed=new SearchSuggestions({delay:0,request:async()=>{throw Error('Offline');}});failed.update('typed query');await wait(10);assert.equal(failed.choose(),false);failed.dismiss();controller.dismiss();
});
