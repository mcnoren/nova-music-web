import test from 'node:test';
import assert from 'node:assert/strict';
import {NovaConnect, SESSION_KEY, STATUS_KEY, validSnapshot, validConnectedLyrics, snapshotPosition} from '../docs/connect.js';
import {NovaSyncClient} from '../docs/sync-client.js';
import {emptyDocument,valuesOf} from '../docs/sync-model.js';
const USER='00000000-0000-4000-8000-000000000001';
const song=(id='abcdefghijk')=>({id,title:id,artist:'Artist',duration:180,source:'youtube'});
const snapshot=(queue=[song()],index=0)=>({queue,index,position:12,playing:true,shuffle:false,repeat:0});
function setup(t){
 class Storage{constructor(){this.data=new Map()}getItem(k){return this.data.get(k)||null}setItem(k,v){this.data.set(k,String(v))}removeItem(k){this.data.delete(k)}}
 globalThis.localStorage=new Storage();globalThis.sessionStorage=new Storage();globalThis.window={addEventListener(){}};
 globalThis.document={visibilityState:'visible',addEventListener(){}};globalThis.location={hostname:'example.com'};Object.defineProperty(globalThis,'navigator',{value:{onLine:true},configurable:true});
 let remote=emptyDocument(),revision=0;
 const devices=[];
 function device(name){
  let library={},local=snapshot([],0),applies=0,stops=0,libraryApplies=0,mirrored;
  const account=new NovaSyncClient({url:'https://example.supabase.co',publishableKey:'sb_publishable_fixture'}, {values:()=>library,activate(){},apply:()=>libraryApplies++,connect:values=>connect.receive(values)});
  account.request=async(path,options)=>{
   if(path.startsWith('/rest/v1/nova_music_libraries'))return revision?[{document:structuredClone(remote),revision}]:[];
   assert.equal(options.body.expected_revision,revision);remote=structuredClone(options.body.library_document);return{revision:++revision,conflict:false};
  };
  const connect=new NovaConnect(account,{id:crypto.randomUUID(),name,snapshot:()=>local,apply:async s=>{local=structuredClone(s);applies++},stop:()=>{local.playing=false;stops++},mirror:s=>{mirrored=s}});
  devices.push(account);return{account,connect,get local(){return local},get applies(){return applies},get stops(){return stops},get mirrored(){return mirrored},get libraryApplies(){return libraryApplies},edit:value=>{library=value;account.changed()}};
 }
 t.after(()=>devices.forEach(a=>{clearInterval(a.poll);clearTimeout(a.timer)}));
 async function activate(d){await d.account.activate({access_token:'fixture',refresh_token:'fixture',expires_at:Date.now()/1000+3600,user:{id:USER,email:'fixture@example.com'}},false);await d.connect.tick();}
 return{device,activate,get remote(){return valuesOf(remote)}};
}
test('phone song selection controls the Mac output and shares the complete queue',async t=>{
 const env=setup(t),mac=env.device('Mac browser'),phone=env.device('iPhone');await env.activate(mac);await env.activate(phone);
 await mac.connect.command(snapshot([song(),song('lmnopqrstuv')]));await mac.account.sync();await phone.connect.tick();
 assert.equal(phone.connect.owner,mac.connect.id);assert.equal(phone.applies,0);assert.equal(phone.mirrored.queue.length,2);
 await phone.connect.command(snapshot([song('lmnopqrstuv'),song()],0));await mac.connect.tick();await phone.connect.tick();
 assert.equal(mac.local.queue[0].id,'lmnopqrstuv');assert.equal(mac.applies,2);assert.equal(phone.applies,0);
 assert.equal(phone.connect.owner,mac.connect.id);assert.equal(env.remote[SESSION_KEY].owner,mac.connect.id);
 const before=mac.applies;await mac.connect.tick();await phone.connect.tick();assert.equal(mac.applies,before,'heartbeats must not restart the recording');
});
test('output transfer stops the old output and retains queue, position, pause and modes',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);
 const state={...snapshot([song(),song('lmnopqrstuv')],1),position:47,playing:false,shuffle:true,repeat:2};
 await mac.connect.command(state);await mac.account.sync();await phone.connect.tick();
 await phone.connect.transfer(phone.connect.id);await mac.connect.tick();await phone.connect.tick();
 assert.equal(mac.stops,1);assert.equal(phone.local.index,1);assert.equal(phone.local.position,47);assert.equal(phone.local.playing,false);assert.equal(phone.local.shuffle,true);assert.equal(phone.local.repeat,2);
});
test('queue edits and seek commands preserve the selected output and current recording',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);
 await mac.connect.command(snapshot());await mac.account.sync();await phone.connect.tick();
 await phone.connect.command(s=>({...s,queue:[...s.queue,song('lmnopqrstuv')],position:65,playing:false}));await mac.connect.tick();
 assert.equal(mac.local.queue.length,2);assert.equal(mac.local.queue[mac.local.index].id,'abcdefghijk');assert.equal(mac.local.position,65);assert.equal(mac.local.playing,false);
});
test('playback records survive library edits without redrawing the library on heartbeats',async t=>{
 const env=setup(t),mac=env.device('Mac');await env.activate(mac);await mac.connect.command(snapshot());await mac.account.sync();
 const before=mac.libraryApplies;mac.connect.publishStatus();await mac.account.sync();assert.equal(mac.libraryApplies,before);
 mac.edit({'liked:abcdefghijk':{id:'abcdefghijk',order:0}});await mac.account.sync();assert.ok(env.remote[SESSION_KEY]);assert.ok(env.remote[STATUS_KEY]);assert.ok(env.remote['liked:abcdefghijk']);
});
test('offline outputs reject commands instead of silently playing on the controller',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);await mac.connect.command(snapshot());
 mac.account.setConnectValues({['connect:device.'+mac.connect.id]:{id:mac.connect.id,name:'Mac',at:Date.now()-100000}});await mac.account.sync();await phone.connect.tick();
 await assert.rejects(phone.connect.command(snapshot()),/unavailable/);assert.equal(phone.applies,0);
});
test('late telemetry cannot replace a newer remote command',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);await mac.connect.command(snapshot());await mac.account.sync();await phone.connect.tick();
 await phone.connect.command(snapshot([song('lmnopqrstuv')]));mac.connect.publishStatus();await mac.account.sync();await phone.account.sync();
 assert.equal(mac.local.queue[0].id,'lmnopqrstuv');assert.equal(phone.connect.snapshot.queue[0].id,'lmnopqrstuv');
});
test('malformed, local-file and oversized snapshots cannot be sent to another device',()=>{
 assert.equal(validSnapshot(snapshot()),true);assert.equal(validSnapshot({...snapshot(),index:5}),false);assert.equal(validSnapshot({...snapshot(),position:Infinity}),false);
 assert.equal(validSnapshot(snapshot([{...song(),source:'local'}])),false);assert.equal(validSnapshot(snapshot(Array(1001).fill(song()))),false);
 assert.equal(snapshotPosition({...snapshot(),at:1000},5000),16);
});
test('reopening the active browser restores matching telemetry instead of restarting the original command',async t=>{
 const env=setup(t),mac=env.device('Mac');await env.activate(mac);await mac.connect.command(snapshot());
 mac.local.position=74;mac.local.playing=false;mac.connect.publishStatus();await mac.account.sync();
 let restored;
 const reopened=new NovaConnect(mac.account,{id:mac.connect.id,name:'Mac',snapshot:()=>snapshot(),apply:async s=>{restored=s},stop(){},mirror(){}});
 await reopened.receive(env.remote);assert.equal(restored.position,74);assert.equal(restored.playing,false);
});
test('signing out clears a remote controller even after its account identity is removed',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);await mac.connect.command(snapshot());await phone.connect.tick();
 const stops=phone.stops;phone.account.activeUser=null;phone.connect.reset();assert.equal(phone.stops,stops+1);assert.equal(phone.connect.owner,undefined);
});

test('joining a phone output stops preexisting browser audio and mirrors without loading another player',async t=>{
 const env=setup(t),phone=env.device('Phone'),mac=env.device('Mac');await env.activate(phone);
 await phone.connect.command(snapshot());await phone.account.sync();
 mac.local.queue=[song('lmnopqrstuv')];mac.local.playing=true;
 await env.activate(mac);
 assert.equal(mac.stops,1);assert.equal(mac.applies,0);assert.equal(mac.local.playing,false);
 assert.equal(mac.mirrored.queue[0].id,'abcdefghijk');
 await mac.connect.tick();assert.equal(mac.stops,1,'unchanged telemetry must not clear the player');
});
test('signing in while playing announces the existing song and clock to a newly opened controller',async t=>{
 const env=setup(t),phone=env.device('Phone'),mac=env.device('Mac');
 phone.local.queue=[song()];phone.local.position=67;phone.local.playing=true;
 await env.activate(phone);await env.activate(mac);
 assert.equal(mac.connect.owner,phone.connect.id);assert.equal(mac.mirrored.position,67);assert.equal(mac.applies,0);
});
test('phone lyrics include the exact recording, cues and timing calibration through pause, seek and transfer',async t=>{
 const env=setup(t),phone=env.device('Phone'),mac=env.device('Mac');await env.activate(phone);await env.activate(mac);
 const lyrics={songID:'abcdefghijk',recordingID:'lmnopqrstuv',loaded:true,plain:'First\nSecond',lines:[{time:0,text:'First',endTime:10},{time:10,text:'Second',endTime:20}],instrumental:false,source:'Phone provider',sourceURL:'https://lrclib.net',offset:1.25,rate:1.02};
 await phone.connect.command({...snapshot(),position:12,playing:false,lyrics});await phone.account.sync();await mac.connect.tick();
 assert.deepEqual(mac.mirrored.lyrics,lyrics);assert.equal(snapshotPosition(mac.mirrored,Date.now()+5000),12);
 await mac.connect.command(s=>({...s,position:5,playing:false}));await phone.connect.tick();
 assert.deepEqual(phone.local.lyrics,lyrics);assert.equal(phone.local.position,5);
 await mac.connect.transfer(mac.connect.id);assert.deepEqual(mac.local.lyrics,lyrics);
 assert.equal(validConnectedLyrics({...lyrics,rate:0}),false);
 assert.equal(validSnapshot({...snapshot(),lyrics:{...lyrics,lines:[{time:NaN,text:'Invalid'}]}}),false);
});
