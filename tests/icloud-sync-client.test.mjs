import test from 'node:test';
import assert from 'node:assert/strict';
import {ICloudSyncClient,CloudKitWebStorage,webPartName,readWebParts} from '../docs/icloud-sync-client.js';
import {NovaConnect} from '../docs/connect.js';
import {emptyDocument,updateDocument,valuesOf,mergeDocuments} from '../docs/sync-model.js';
class Storage{constructor(){this.data=new Map()}getItem(k){return this.data.get(k)??null}setItem(k,v){this.data.set(k,String(v))}removeItem(k){this.data.delete(k)}}
const USER='00000000-0000-4000-8000-000000000001';
function fixture(t){
 globalThis.localStorage=new Storage();globalThis.sessionStorage=new Storage();globalThis.window={addEventListener(){}};globalThis.location={hostname:'localhost'};globalThis.document={addEventListener(){},visibilityState:'visible'};Object.defineProperty(globalThis,'navigator',{value:{onLine:true},configurable:true});
 const docs=new Map(),revisions=new Map(),writes=[];let id=USER,offline=false,conflict=false;
 const storage={configured:true,setup:async()=>true,accountID:async()=>id,load:async name=>{if(offline)throw Error('offline');return {document:structuredClone(docs.get(name)||emptyDocument()),revision:revisions.get(name)||null}},save:async(doc,name,revision)=>{
  if(offline)throw Error('offline');
  if(conflict){conflict=false;docs.set(name,updateDocument(emptyDocument(),{},{'saved:lmnopqrstuv':{id:'lmnopqrstuv',order:0}},crypto.randomUUID()));revisions.set(name,1);const error=Error('conflict');error.conflict=true;throw error;}
  if(revision!==(revisions.get(name)||null)){const error=Error('conflict');error.conflict=true;throw error;}
  docs.set(name,structuredClone(doc));revisions.set(name,(revisions.get(name)||0)+1);writes.push(name);
 }};
 let lan=emptyDocument();const transports=[];
 function transport(){
  const value={onDocument:()=>{},onPeers:()=>{},onError:()=>{},configure(id,key){this.id=id;this.key=key},publish(doc){if(this.key)lan=mergeDocuments(lan,structuredClone(doc))},async refresh(){if(!this.key)return;this.onPeers(transports.filter(t=>t.key===this.key&&t.id!==this.id).map(t=>t.id));await this.onDocument(structuredClone(lan))},stop(){this.key=null}};
  transports.push(value);return value;
 }
 const clients=[];
 function device(name){
  let current={'liked:abcdefghijk':{id:'abcdefghijk',order:0}},local={queue:[],index:0,position:0,playing:false,shuffle:false,repeat:0},applies=0;
  const account=new ICloudSyncClient({values:()=>structuredClone(current),activate(){},apply:values=>{current=structuredClone(values)},status(){},connect:values=>connect.receive(values)},{storage,localPlayback:transport()});
  // Each simulated installation has its own device ID even though this fixture shares browser storage.
  account.actor=crypto.randomUUID();
  const connect=new NovaConnect(account,{id:account.actor,name,handoffTimeout:1000,snapshot:()=>local,apply:async snapshot=>{local=structuredClone(snapshot);applies++},freeze:async()=>{local.playing=false},stop:()=>{local.playing=false},mirror(){}});
  clients.push({account,connect});return {account,connect,get current(){return current},get local(){return local},get applies(){return applies},edit:values=>{current=values;account.changed()}};
 }
 t.after(()=>{for(const {account,connect} of clients){connect.reset();clearInterval(account.poll);clearTimeout(account.timer)}});
 return {device,docs,writes,get lan(){return lan},setOffline:v=>offline=v,setIdentity:v=>id=v,conflict:()=>conflict=true};
}
test('iCloud uploads existing library and retries conflicting edits',async t=>{
 const env=fixture(t),phone=env.device('Phone');env.conflict();await phone.account.enable();assert.equal(phone.account.status,'synced');const values=valuesOf(env.docs.get('nova-library'));assert.ok(values['liked:abcdefghijk']);assert.ok(values['saved:lmnopqrstuv']);assert.ok(!Object.keys(values).some(k=>k.startsWith('connect:')));
});
test('offline and disconnect preserve unsent library edits',async t=>{
 const env=fixture(t),phone=env.device('Phone');await phone.account.enable();phone.edit({...phone.current,'saved:lmnopqrstuv':{id:'lmnopqrstuv',order:0}});env.setOffline(true);await phone.account.sync();assert.equal(phone.account.status,'error');await phone.account.signOut();assert.ok(phone.current['saved:lmnopqrstuv']);assert.equal(phone.account.user,null);assert.ok([...localStorage.data.values()].some(v=>v.includes('saved:lmnopqrstuv')));
});
test('changing Apple Accounts prevents uploads to the second account',async t=>{
 const env=fixture(t),phone=env.device('Phone');await phone.account.enable();const count=env.writes.length;phone.edit({...phone.current,'saved:lmnopqrstuv':{id:'lmnopqrstuv',order:0}});env.setIdentity('00000000-0000-4000-8000-000000000002');await phone.account.sync();assert.equal(env.writes.length,count);assert.equal(phone.account.user,null);assert.ok(phone.current['saved:lmnopqrstuv']);
});
test('device commands, queue mirroring and handoff use the independent iCloud record',async t=>{
 const env=fixture(t),mac=env.device('Mac'),phone=env.device('Phone');await mac.account.enable();await phone.account.enable();await mac.connect.tick();await phone.connect.tick();await mac.connect.tick();
 const song={id:'abcdefghijk',title:'Song',artist:'Artist',source:'youtube',duration:200};
 await mac.connect.command({queue:[song],index:0,position:37,playing:false,shuffle:true,repeat:2});await phone.connect.tick();assert.equal(phone.connect.owner,mac.account.actor);assert.equal(phone.connect.snapshot.queue[0].id,song.id);
 const libraryWrites=env.writes.filter(n=>n==='nova-library').length;
 let transferred=false;const transfer=phone.connect.transfer(phone.account.actor).finally(()=>{transferred=true});
 for(let i=0;i<100&&!transferred;i++){await mac.connect.tick();await new Promise(resolve=>setTimeout(resolve,10));}
 await transfer;await mac.connect.tick();await phone.connect.tick();
 assert.equal(phone.connect.owner,phone.account.actor);assert.equal(phone.local.position,37);assert.equal(phone.local.shuffle,true);assert.equal(phone.local.repeat,2);assert.ok(phone.applies>0);
 assert.equal(env.writes.filter(n=>n==='nova-library').length,libraryWrites);assert.ok(Object.keys(env.lan.records).some(key=>key.startsWith('connect:')));assert.ok(!env.docs.has('nova-connection'));
});
test('CloudKit JS uses the current-user identity API without requiring name discovery',async()=>{
 const storage=new CloudKitWebStorage({containerIdentifier:'iCloud.test',apiToken:'public'});storage.container={fetchCurrentUserIdentity:async()=>({userRecordName:'_opaque'})};assert.match(await storage.accountID(),/^[a-f0-9-]{36}$/);
});
test('unsigned Mac builds explain native provisioning instead of falling back to web auth',async t=>{
 const env=fixture(t);window.novaDesktop={nativeICloud:false,post(){throw Error('Unsigned builds must not send native iCloud requests')}};
 const mac=new ICloudSyncClient({values:()=>({}),status(){}},{config:{containerIdentifier:'iCloud.test',apiToken:'public'}});
 t.after(()=>{clearInterval(mac.poll);clearTimeout(mac.timer)});
 assert.equal(mac.configured,false);await assert.rejects(mac.prepareAuth(true),/Mac build is not signed for iCloud/);
});

test('playback never contacts CloudKit and still works while library requests fail',async t=>{
 const env=fixture(t),phone=env.device('Phone'),mac=env.device('Mac');await phone.account.enable();await mac.account.enable();await phone.connect.tick();await mac.connect.tick();
 const writes=env.writes.length;env.setOffline(true);
 await phone.account.sync();assert.equal(phone.account.status,'error');
 const song={id:'abcdefghijk',title:'Local Wi-Fi song',artist:'Artist',source:'youtube',duration:200};
 await phone.connect.command({queue:[song],index:0,position:72,playing:true,shuffle:false,repeat:0});await mac.connect.tick();
 assert.equal(mac.connect.snapshot.position,72);assert.equal(mac.connect.owner,phone.account.actor);
 assert.equal(env.writes.length,writes);assert.ok(!env.docs.has('nova-connection'));
});

test('cached trust enables native LAN startup before an unavailable library can load',async t=>{
 const env=fixture(t),phone=env.device('Phone');await phone.account.enable();
 env.setOffline(true);const reopened=env.device('Mac restart');await reopened.account.initialize();
 assert.ok(reopened.account.user);assert.ok(reopened.account.playbackTransport.key);
 await reopened.connect.tick();assert.ok(!env.docs.has('nova-connection'));
});

test('automatic sync recovers after launch setup fails without user interaction',async t=>{
 const env=fixture(t),mac=env.device('Mac');
 const setup=mac.account.storage.setup;mac.account.storage.setup=async()=>{throw Error('temporarily unavailable')};
 await assert.rejects(mac.account.initialize(),/temporarily unavailable/);
 assert.equal(mac.account.user,null);
 mac.account.storage.setup=setup;
 await mac.account.sync();
 assert.equal(mac.account.status,'synced');assert.equal(mac.account.user.id,USER);
 assert.ok(env.docs.get('nova-library'));assert.ok(mac.account.localConfiguration);
});
test('explicitly disabled iCloud stays disabled during automatic recovery',async t=>{
 const env=fixture(t),mac=env.device('Mac');localStorage.setItem('nova-icloud-enabled','false');
 await mac.account.sync();assert.equal(mac.account.user,null);assert.equal(env.writes.length,0);
});
test('cached local trust announces playback even while iCloud is unavailable',async t=>{
 const env=fixture(t),mac=env.device('Mac');await mac.account.enable();
 mac.edit({...mac.current});env.setOffline(true);await mac.account.sync();
 assert.equal(mac.account.status,'error');
 Object.assign(mac.local,{queue:[{id:'abcdefghijk',title:'Song',artist:'Artist',source:'youtube',duration:200}],index:0,playing:true});
 await mac.connect.tick();assert.equal(mac.connect.owner,mac.account.actor);
});


function webFixture(){
 const records=new Map(),writes=[];
 const storage=new CloudKitWebStorage({containerIdentifier:'iCloud.test',apiToken:'public'});
 storage.database={fetchRecords:async name=>records.has(name)?{records:[structuredClone(records.get(name))]}:{hasErrors:true,errors:[{ckErrorCode:'NOT_FOUND'}]},saveRecords:async record=>{
  const old=records.get(record.recordName);
  if(old&&old.recordChangeTag!==record.recordChangeTag)return {hasErrors:true,errors:[{ckErrorCode:'CONFLICT'}]};
  const saved={...record,recordChangeTag:String(Number(old?.recordChangeTag||0)+1),fields:{...old?.fields,...record.fields}};records.set(record.recordName,structuredClone(saved));writes.push(record);return {records:[saved]};
 }};return {storage,records,writes};
}
test('browser sync round-trips a library larger than one record without asset uploads',async()=>{
 const {storage,records,writes}=webFixture();
 const document=updateDocument(emptyDocument(),{},{'playlist:test':{name:'Music 🎵'.repeat(170000),songs:[]}},crypto.randomUUID());
 await storage.save(document,'nova-library',null);
 assert.ok(records.get('nova-library').fields.webParts.value.length>10);
 assert.ok(writes.every(record=>!record.fields.document));
 storage.partCache.clear();assert.deepEqual((await storage.load('nova-library')).document,document);
 const count=writes.length;await storage.save(document,'nova-library','1');assert.equal(writes.length,count+1);
});
test('partial browser writes do not publish an incomplete library manifest',async()=>{
 const {storage,records}=webFixture(),document=updateDocument(emptyDocument(),{},{'liked:abcdefghijk':{id:'abcdefghijk',order:0}},crypto.randomUUID());
 storage.database.saveRecords=async()=>{throw Error('offline')};
 await assert.rejects(storage.save(document,'nova-library',null),/offline/);
 assert.equal(records.has('nova-library'),false);
});
test('browser reads merge native asset edits with web edits and retain tombstones',async()=>{
 const {storage,records}=webFixture(),actor=crypto.randomUUID();
 const base=updateDocument(emptyDocument(),{},{'liked:abcdefghijk':{id:'abcdefghijk',order:0}},actor);
 const web=updateDocument(base,valuesOf(base),{'saved:lmnopqrstuv':{id:'lmnopqrstuv',order:0}},actor);
 await storage.save(web,'nova-library',null);
 records.get('nova-library').fields.document={value:{downloadURL:'https://example.com/nova.json',size:300}};
 const native=updateDocument(base,valuesOf(base),{...valuesOf(base),'folder:test':{name:'Native folder'}},crypto.randomUUID());
 const original=globalThis.fetch;globalThis.fetch=async()=>({ok:true,text:async()=>JSON.stringify(native)});
 try{assert.deepEqual((await storage.load('nova-library')).document,mergeDocuments(native,web));}finally{globalThis.fetch=original;}
 assert.equal(valuesOf((await readWebParts(records.get('nova-library').fields.webParts.value,async name=>records.get(name).fields.webText.value)))['liked:abcdefghijk'],undefined);
});
test('tampered or invalid library parts cannot replace the current document',async()=>{
 const text=JSON.stringify(emptyDocument()),name=await webPartName(text);
 await assert.rejects(readWebParts([name],async()=>text+' '),/damaged/);
 await assert.rejects(readWebParts(['another-record'],async()=>text),/manifest/);
});
