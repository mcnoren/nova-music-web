import test from 'node:test';
import assert from 'node:assert/strict';
import {NovaSyncClient} from '../docs/sync-client.js';
import {emptyDocument, updateDocument, valuesOf, libraryValues, applyLibraryValues} from '../docs/sync-model.js';
const A='00000000-0000-4000-8000-000000000001',B='00000000-0000-4000-8000-000000000002';
class Storage { constructor(){this.data=new Map()}getItem(k){return this.data.get(k)??null}setItem(k,v){this.data.set(k,String(v))}removeItem(k){this.data.delete(k)} }
function setup() { globalThis.localStorage=new Storage();globalThis.sessionStorage=new Storage();globalThis.window={addEventListener(){}};globalThis.location={hostname:"example.test"};globalThis.document={addEventListener(){},visibilityState:'visible'};Object.defineProperty(globalThis,'navigator',{value:{onLine:true},configurable:true}); }
function client(values={}) {
 let current=structuredClone(values),applied=[];
 const instance=new NovaSyncClient({url:'https://example.supabase.co',publishableKey:'sb_publishable_test_fixture'}, {values:()=>structuredClone(current),activate(){},apply(v){current=structuredClone(v);applied.push(v)},deactivate(){current={}},status(){}});
 return {instance,applied,edit:v=>{current=structuredClone(v);instance.changed()},close:()=>{clearInterval(instance.poll);clearTimeout(instance.timer)}};
}
const session=id=>({access_token:'test-access',refresh_token:'test-refresh',expires_at:Date.now()/1000+3600,user:{id,email:'test@example.com'}});
test('a revision conflict retries after reading the other device changes',async()=>{
 setup();const c=client();let remote=emptyDocument(),revision=0,writes=0;
 c.instance.request=async(path,options)=>{if(path.startsWith('/rest/v1/nova_music_libraries'))return revision?[{document:remote,revision}]:[];if(path.includes('/rpc/')){if(++writes===1){remote=updateDocument(remote,{}, {'saved:abcdefghijk':{id:'abcdefghijk',order:0}},B);revision++;return {conflict:true,revision}}remote=options.body.library_document;return{conflict:false,revision:++revision}}throw Error('Unexpected request')};
 await c.instance.activate(session(A),false);c.edit({'liked:abcdefghijk':{id:'abcdefghijk',order:0}});await c.instance.sync();
 assert.ok(valuesOf(remote)['liked:abcdefghijk']);assert.ok(valuesOf(remote)['saved:abcdefghijk']);assert.equal(c.instance.status,'synced');c.close();
});
test('an in-flight response cannot apply a former account library',async()=>{
 setup();const c=client();let resolveRead;
 c.instance.request=()=>new Promise(resolve=>{resolveRead=resolve});
 const activating=c.instance.activate(session(A),false);await Promise.resolve();
 c.instance.generation++;c.instance.activeUser={id:B,email:'second@example.com'};
 const count=c.applied.length;resolveRead([{document:updateDocument(emptyDocument(),{}, {'liked:abcdefghijk':{id:'abcdefghijk',order:0}},A),revision:1}]);await activating;
 assert.equal(c.applied.length,count);c.close();
});
test('changes made during a write are uploaded before sync reports success',async()=>{
 setup();const c=client();let remote=emptyDocument(),revision=0,writes=0;
 c.instance.request=async(path,options)=>{if(path.startsWith('/rest/v1/nova_music_libraries'))return revision?[{document:remote,revision}]:[];if(path.includes('/rpc/')){if(++writes===1)c.edit({...valuesOf(options.body.library_document),'saved:abcdefghijk':{id:'abcdefghijk',order:0}});remote=options.body.library_document;return{conflict:false,revision:++revision}}};
 await c.instance.activate(session(A),false);c.edit({'liked:abcdefghijk':{id:'abcdefghijk',order:0}});await c.instance.sync();assert.ok(valuesOf(remote)['saved:abcdefghijk']);assert.equal(writes,2);c.close();
});
test('playback, periodic polling and returning to a tab preserve a browsed album',async(t)=>{
 setup();t.mock.timers.enable({apis:['setTimeout','setInterval']});
 let visibilityChanged;document.addEventListener=(name,callback)=>{if(name==='visibilitychange')visibilityChanged=callback};
 let state={liked:[],saved:[],albums:[],artists:[],artistPins:[],playlists:[],folders:[],releaseChoices:{},discChoices:{},recent:[],extraSongs:{},extraAlbums:{},extraArtists:{},genres:[]};
 const catalog={songs:[],albums:[],artists:[]};
 const instance=new NovaSyncClient({url:'https://example.supabase.co',publishableKey:'sb_publishable_test_fixture'},{values:()=>libraryValues(state,catalog),activate(){},apply:values=>{state=applyLibraryValues(state,values)}});
 let remote=emptyDocument(),revision=0,reads=0;
 instance.request=async(path,options)=>{if(path.startsWith('/rest/v1/nova_music_libraries')){reads++;return revision?[{document:remote,revision}]:[]}remote=options.body.library_document;return{revision:++revision,conflict:false}};
 t.after(()=>{clearInterval(instance.poll);clearTimeout(instance.timer)});
 await instance.activate(session(A),false);
 for(const id of ['abcdefghijk','lmnopqrstuv'])state.extraSongs[id]={id,title:id,artist:'Artist',source:'youtube'};
 state.extraAlbums.MPREbrowse={id:'MPREbrowse',title:'Album',artist:'Artist',tracks:Object.keys(state.extraSongs)};
 const check=()=>{assert.equal(state.extraAlbums.MPREbrowse.tracks.filter(id=>state.extraSongs[id]).length,2);assert.deepEqual(state.albums,[]);assert.equal(instance.status,'synced')};
 state.recent=[{id:'abcdefghijk',at:100}];instance.changed();t.mock.timers.tick(701);await instance.inflight;check();
 let before=reads;t.mock.timers.tick(30001);await instance.inflight;assert.ok(reads>before);check();
 document.visibilityState='hidden';visibilityChanged();before=reads;t.mock.timers.tick(1);assert.equal(reads,before);
 document.visibilityState='visible';visibilityChanged();t.mock.timers.tick(1);await instance.inflight;assert.ok(reads>before);check();
});
test('a secret key cannot initialize a browser sync client',()=>{setup();assert.throws(()=>new NovaSyncClient({url:'https://example.supabase.co',publishableKey:'sb_secret_never_public'},{}),/secret key/)});
test('password login imports only after a valid session and never persists the password',async()=>{
 setup();const c=client({'liked:abcdefghijk':{id:'abcdefghijk',order:0}});const password='Fixture-password-123!';let remote=emptyDocument(),revision=0;
 c.instance.request=async(path,options)=>{if(path.includes('grant_type=password')){assert.deepEqual(options.body,{email:'test@example.com',password});return session(A)}if(path.startsWith('/rest/v1/nova_music_libraries'))return revision?[{document:remote,revision}]:[];remote=options.body.library_document;return{revision:++revision,conflict:false}};
 await c.instance.signIn('test@example.com',password,true);assert.equal(c.instance.user.id,A);assert.ok(valuesOf(remote)['liked:abcdefghijk']);assert.ok(!JSON.stringify([...localStorage.data,...sessionStorage.data]).includes(password));c.close();
});
test('failed password login and unconfirmed signup leave the device library alone',async()=>{
 setup();const c=client({'liked:abcdefghijk':{id:'abcdefghijk',order:0}});c.instance.request=async(path)=>{if(path.includes('/signup'))return{user:session(A).user};throw Error('Invalid login credentials')};
 await assert.rejects(c.instance.signIn('test@example.com','incorrect',true),/Invalid login/);await c.instance.createAccount('test@example.com','Fixture-password-123!');assert.equal(c.instance.user,null);assert.equal(c.applied.length,0);assert.equal(sessionStorage.data.size,0);c.close();
});
test('reauthentication rejects a different account without changing pending records',async()=>{
 setup();const c=client();c.instance.request=async(path)=>path.includes('grant_type=password')?session(B):[];await c.instance.activate(session(A),false);c.edit({'liked:abcdefghijk':{id:'abcdefghijk',order:0}});await assert.rejects(c.instance.signIn('other@example.com','Fixture-password-123!',true),/current account/);assert.equal(c.instance.user.id,A);assert.ok(valuesOf(c.instance.document)['liked:abcdefghijk']);c.close();
});
test('password recovery verifies the account without activating or importing a library',async()=>{
 setup();const c=client();let updated=false;c.instance.request=async(path,options)=>{if(path.includes('/logout'))return{};assert.equal(options.token,'recovery-fixture');if(options.method==='PUT'){updated=true;assert.equal(options.body.password,'Fixture-password-123!')}return session(A).user};
 await c.instance.beginPasswordRecovery('recovery-fixture');assert.equal(c.instance.user,null);assert.equal(sessionStorage.data.size,0);await c.instance.finishPasswordRecovery('Fixture-password-123!');assert.ok(updated);assert.equal(c.instance.recovery,null);assert.equal(c.applied.length,0);c.close();
});
test('email returns never activate arbitrary sessions',async()=>{
 const {parseAuthReturn}=await import('../docs/sync-client.js');assert.equal(parseAuthReturn('#discover'),null);assert.deepEqual(parseAuthReturn('#access_token=fixture&type=signup'),{type:'confirmed'});assert.deepEqual(parseAuthReturn('#access_token=fixture&type=recovery'),{type:'recovery',token:'fixture'});assert.deepEqual(parseAuthReturn('#access_token=fixture&type=magiclink'),{type:'confirmed'});
});
