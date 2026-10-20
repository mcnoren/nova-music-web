import {libraryStorage} from '../docs/library-storage.js';
import test from 'node:test';
import assert from 'node:assert/strict';
import {GitHubSyncClient,validRepository,libraryOnly} from '../docs/github-sync-client.js';
import {emptyDocument,updateDocument,valuesOf} from '../docs/sync-model.js';
class Storage{constructor(){this.data=new Map()}getItem(key){return this.data.get(key)??null}setItem(key,value){this.data.set(key,String(value))}removeItem(key){this.data.delete(key)}}
function fixture(t,{privateRepo=true,conflict=false}={}){
 globalThis.localStorage=new Storage();globalThis.sessionStorage=new Storage();globalThis.window={addEventListener(){}};globalThis.location={hostname:'localhost'};globalThis.document={addEventListener(){},visibilityState:'visible'};Object.defineProperty(globalThis,'navigator',{value:{onLine:true},configurable:true});
 let current={'liked:abcdefghijk':{id:'abcdefghijk',order:0}},remote=null,sha=null,writes=0,status=200;const requests=[];
 const fetcher=async(url,options)=>{
  requests.push({url,options});assert.ok(url.startsWith('https://api.github.com/repos/'));assert.equal(options.redirect,'error');
  if(status!==200)return new Response('{}',{status,headers:{'Retry-After':'60'}});
  if(!url.includes('/contents/'))return Response.json({id:42,private:privateRepo,permissions:{push:true}});
  if(options.method==='PUT'){
   writes++;
   if(conflict){conflict=false;remote=updateDocument(emptyDocument(),{}, {'saved:lmnopqrstuv':{id:'lmnopqrstuv',order:0}},'00000000-0000-4000-8000-000000000002');sha='other';return new Response('{}',{status:409})}
   const body=JSON.parse(options.body);if(sha&&body.sha!==sha)return new Response('{}',{status:409});
   remote=JSON.parse(Buffer.from(body.content,'base64').toString('utf8'));sha='revision-'+writes;return Response.json({content:{sha}});
  }
  return remote?Response.json({type:'file',sha,encoding:'base64',content:Buffer.from(JSON.stringify(remote)).toString('base64')}):new Response('{}',{status:404});
 };
 const client=new GitHubSyncClient({values:()=>structuredClone(current),activate(){},apply:values=>{current=structuredClone(values)},status(){}},{fetcher});
 t.after(()=>{clearInterval(client.poll);clearTimeout(client.timer)});
 return {client,requests,get remote(){return remote},get writes(){return writes},get current(){return current},edit(values){current=values;client.changed()},setStatus(value){status=value}};
}
test('GitHub sync stores private metadata and credentials stay out of library records',async t=>{
 const f=fixture(t);await f.client.connectGitHub('tester/nova-library','github_pat_fixture');assert.equal(f.client.status,'synced');assert.ok(valuesOf(f.remote)['liked:abcdefghijk']);assert.ok(!JSON.stringify(f.remote).includes('github_pat_fixture'));assert.ok(!JSON.stringify([...localStorage.data]).includes('github_pat_fixture'));assert.ok(sessionStorage.getItem('nova-music-auth-session-v1').includes('github_pat_fixture'));assert.ok(f.requests.every(x=>!x.url.includes('supabase')));
});
test('public repositories cannot activate or receive writes',async t=>{
 const f=fixture(t,{privateRepo:false});await assert.rejects(f.client.connectGitHub('tester/public','github_pat_fixture'),/private/);assert.equal(f.client.user,null);assert.equal(f.writes,0);assert.ok(f.current['liked:abcdefghijk']);
});
test('Github conflicts merge other-device changes and preserve local edits',async t=>{
 const f=fixture(t,{conflict:true});await f.client.connectGitHub('tester/nova-library','github_pat_fixture');assert.equal(f.client.status,'synced');assert.equal(f.writes,2);assert.ok(valuesOf(f.remote)['liked:abcdefghijk']);assert.ok(valuesOf(f.remote)['saved:lmnopqrstuv']);
});
test('quota failures back off and disconnect preserves cached unsent edits',async t=>{
 const f=fixture(t);await f.client.connectGitHub('tester/nova-library','github_pat_fixture');const id=f.client.user.id;f.edit({...f.current,'saved:lmnopqrstuv':{id:'lmnopqrstuv',order:0}});f.setStatus(429);await f.client.sync();assert.equal(f.client.status,'error');const requests=f.requests.length;await f.client.sync();assert.equal(requests,f.requests.length);await f.client.signOut();assert.equal(f.client.user,null);assert.ok(f.current['saved:lmnopqrstuv']);assert.equal(sessionStorage.getItem('nova-music-auth-session-v1'),null);assert.ok(libraryStorage.getItem('nova-music-sync-document-v1:'+id).includes('saved:lmnopqrstuv'));assert.equal(localStorage.data.size,0);
});
test('retired playback records never enter GitHub metadata',()=>{
 const document=updateDocument(emptyDocument(),{}, {'connect:session':{owner:'old'},'liked:abcdefghijk':{id:'abcdefghijk'}},'00000000-0000-4000-8000-000000000001');assert.deepEqual(Object.keys(libraryOnly(document).records),['liked:abcdefghijk']);assert.throws(()=>validRepository('https://github.com/tester/repo'));assert.throws(()=>validRepository('tester/..'));
});
test('cached old account libraries are recovered without contacting Supabase',async t=>{
 const f=fixture(t);const old={access_token:'old-session',refresh_token:'old-refresh',user:{id:'00000000-0000-4000-8000-000000000001'}};sessionStorage.setItem('nova-music-auth-session-v1',JSON.stringify(old));localStorage.setItem('nova-music-account-library-v1:'+old.user.id,JSON.stringify({liked:['abcdefghijk']}));let recovered=false;f.client.callbacks.activate=(_,cached)=>{recovered=cached.liked[0]==='abcdefghijk'};await f.client.initialize();assert.equal(recovered,true);assert.equal(f.requests.length,0);assert.equal(f.client.user,null);
});
