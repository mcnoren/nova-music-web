import test from 'node:test';
import assert from 'node:assert/strict';
import {NovaSyncClient} from '../docs/sync-client.js';
import {emptyDocument, updateDocument, valuesOf} from '../docs/sync-model.js';
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
test('a secret key cannot initialize a browser sync client',()=>{setup();assert.throws(()=>new NovaSyncClient({url:'https://example.supabase.co',publishableKey:'sb_secret_never_public'},{}),/secret key/)});
