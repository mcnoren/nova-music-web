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
  let library={},local=snapshot([],0),applies=0,stops=0,libraryApplies=0,mirrored,freezeHook;
  const account=new NovaSyncClient({url:'https://example.supabase.co',publishableKey:'sb_publishable_fixture'}, {values:()=>library,activate(){},apply:()=>libraryApplies++,connect:values=>connect.receive(values)});
  account.request=async(path,options)=>{
   if(path.startsWith('/rest/v1/nova_music_libraries'))return revision?[{document:structuredClone(remote),revision}]:[];
   assert.equal(options.body.expected_revision,revision);remote=structuredClone(options.body.library_document);return{revision:++revision,conflict:false};
  };
  const connect=new NovaConnect(account,{id:crypto.randomUUID(),name,handoffTimeout:1000,snapshot:()=>local,freeze:async()=>{if(freezeHook)await freezeHook();local.playing=false},apply:async s=>{local=structuredClone(s);applies++},stop:()=>{local.playing=false;stops++},mirror:s=>{mirrored=s}});
  t.after(()=>connect.reset());devices.push(account);return{account,connect,get local(){return local},get applies(){return applies},get stops(){return stops},get mirrored(){return mirrored},get libraryApplies(){return libraryApplies},onFreeze:hook=>{freezeHook=hook},edit:value=>{library=value;account.changed()}};
 }
 t.after(()=>devices.forEach(a=>{clearInterval(a.poll);clearTimeout(a.timer)}));
 async function activate(d){await d.account.activate({access_token:'fixture',refresh_token:'fixture',expires_at:Date.now()/1000+3600,user:{id:USER,email:'fixture@example.com'}},false);await d.connect.tick();}
 return{device,activate,get remote(){return valuesOf(remote)}};
}
async function transfer(controller,output,owner){
 let done=false,error;const work=controller.connect.transfer(output).catch(value=>{error=value}).finally(()=>{done=true});
 for(let i=0;i<100&&!done;i++){await owner.connect.tick();await new Promise(resolve=>setTimeout(resolve,20))}
 await work;if(error)throw error;
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
 await transfer(phone,phone.connect.id,mac);await mac.connect.tick();await phone.connect.tick();
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
 await transfer(mac,mac.connect.id,phone);assert.deepEqual(mac.local.lyrics,lyrics);
 assert.equal(validConnectedLyrics({...lyrics,rate:0}),false);
 assert.equal(validSnapshot({...snapshot(),lyrics:{...lyrics,lines:[{time:NaN,text:'Invalid'}]}}),false);
});

test('an output reopening after an expired command restores the last confirmed song paused instead of showing an empty player',async t=>{
 const env=setup(t),phone=env.device('Phone'),mac=env.device('Mac');await env.activate(phone);await env.activate(mac);
 await phone.connect.command({...snapshot(),position:42});await phone.account.sync();
 const session={...env.remote[SESSION_KEY],at:Date.now()-300000};
 const status={...env.remote[STATUS_KEY],position:71,at:Date.now()-300000};
 phone.account.setConnectValues({[SESSION_KEY]:session,[STATUS_KEY]:status});await phone.account.sync();await mac.connect.tick();
 assert.equal(mac.mirrored.position,71);assert.equal(mac.mirrored.playing,false);assert.equal(snapshotPosition(status),71);
 let restored;
 const reopened=new NovaConnect(phone.account,{id:phone.connect.id,name:'Phone',snapshot:()=>restored||snapshot(),apply:async s=>{restored=s},stop(){},mirror(){}});
 await reopened.receive(env.remote);
 assert.equal(restored.queue[0].id,'abcdefghijk');assert.equal(restored.position,71);assert.equal(restored.playing,false);
});

test('a delayed new-song command starts at zero without adding network or loading time',async()=>{
 const id=crypto.randomUUID();let applied;
 const account={user:{},setConnectValues(){}};
 const output=new NovaConnect(account,{id,name:'Mac',snapshot:()=>applied,apply:async value=>{await new Promise(resolve=>setTimeout(resolve,80));applied=value},stop(){},mirror(){}});
 const desired={...snapshot(),position:0,at:Date.now()-4000};
 const session={owner:id,command:crypto.randomUUID(),at:Date.now()-4000,snapshot:desired};
 await output.receive({[SESSION_KEY]:session});
 assert.equal(applied.position,0);assert.equal(applied.playing,true);
});
test('handoff waits for the old engine and resumes at its frozen clock with a complete queue',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);
 await mac.connect.command({...snapshot([song(),song('lmnopqrstuv'),song()],1),position:10,shuffle:true,repeat:2});await mac.account.sync();await phone.connect.tick();
 let frozen=false;mac.onFreeze(async()=>{await new Promise(resolve=>setTimeout(resolve,160));assert.equal(phone.applies,0);mac.local.position=13.375;frozen=true});
 await transfer(phone,phone.connect.id,mac);
 assert.equal(frozen,true);assert.equal(mac.local.playing,false);assert.equal(phone.local.position,13.375);assert.equal(phone.local.playing,true);
 assert.deepEqual(phone.local.queue.map(s=>s.id),['abcdefghijk','lmnopqrstuv','abcdefghijk']);assert.equal(phone.local.index,1);assert.equal(phone.local.shuffle,true);assert.equal(phone.local.repeat,2);
});
test('a recently closed output recovers at the last confirmed position without advancing its clock',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);await mac.connect.command(snapshot());await mac.account.sync();await phone.connect.tick();
 phone.connect.options.handoffTimeout=50;
 mac.local.position=37.125;mac.connect.publishStatus();await mac.account.sync();await phone.connect.tick();
 await phone.connect.transfer(phone.connect.id);
 assert.equal(env.remote[SESSION_KEY].owner,phone.connect.id);assert.equal(phone.local.position,37.125);assert.equal(phone.local.playing,true);
 await mac.connect.tick();assert.equal(mac.local.playing,false);
});

test('a newer song selection cancels an in-progress handoff instead of being overwritten',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);await mac.connect.command(snapshot());await mac.account.sync();await phone.connect.tick();
 mac.onFreeze(async()=>{await mac.connect.command({...snapshot([song('lmnopqrstuv')]),position:0})});
 await assert.rejects(transfer(phone,phone.connect.id,mac),/Playback changed/);
 assert.equal(env.remote[SESSION_KEY].owner,mac.connect.id);assert.equal(env.remote[SESSION_KEY].snapshot.queue[0].id,'lmnopqrstuv');assert.equal(phone.applies,0);
});

test('explicitly choosing this device recovers from an expired browser heartbeat',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);
 await mac.connect.command({...snapshot([song(),song('lmnopqrstuv')],1),position:48,playing:false});await mac.account.sync();
 mac.account.setConnectValues({['connect:device.'+mac.connect.id]:{id:mac.connect.id,name:'Mac',at:Date.now()-100000}});await mac.account.sync();await phone.connect.tick();
 await phone.connect.transfer(phone.connect.id);assert.equal(phone.local.position,48);assert.equal(phone.local.index,1);assert.equal(phone.local.playing,false);
});
test('remote play and pause show intent immediately and wait for matching actual telemetry',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);
 await mac.connect.command({...snapshot(),playing:false});await mac.account.sync();await phone.connect.tick();
 const play=phone.connect.setPlayingIntent(true);assert.equal(phone.connect.pendingPlaying,true);assert.equal(phone.connect.snapshot.playing,false);
 await play;assert.equal(phone.connect.pendingPlaying,true);assert.equal(phone.connect.snapshot.playing,false);
 await mac.connect.tick();await mac.account.sync();await phone.connect.tick();assert.equal(phone.connect.pendingPlaying,null);assert.equal(phone.connect.snapshot.playing,true);
 const pause=phone.connect.setPlayingIntent(false);assert.equal(phone.connect.pendingPlaying,false);await pause;assert.equal(phone.connect.pendingPlaying,false);
 await mac.connect.tick();await mac.account.sync();await phone.connect.tick();assert.equal(phone.connect.pendingPlaying,null);assert.equal(phone.connect.snapshot.playing,false);
 phone.connect.reset();
});
test('rapid remote transport changes keep the latest intent and rejected sends clear the spinner',async t=>{
 const env=setup(t),mac=env.device('Mac'),phone=env.device('Phone');await env.activate(mac);await env.activate(phone);
 await mac.connect.command({...snapshot(),playing:false});await mac.account.sync();await phone.connect.tick();
 const play=phone.connect.setPlayingIntent(true),pause=phone.connect.setPlayingIntent(false);assert.equal(phone.connect.pendingPlaying,false);
 await Promise.all([play,pause]);assert.equal(phone.connect.pendingPlaying,false);await mac.connect.tick();await mac.account.sync();await phone.connect.tick();assert.equal(phone.connect.pendingPlaying,null);
 mac.account.setConnectValues({['connect:device.'+mac.connect.id]:{id:mac.connect.id,name:'Mac',at:Date.now()-100000}});await mac.account.sync();await phone.connect.tick();
 await assert.rejects(phone.connect.setPlayingIntent(true),/unavailable/);assert.equal(phone.connect.pendingPlaying,null);phone.connect.reset();
});
