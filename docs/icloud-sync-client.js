import {NovaSyncClient} from './sync-client.js?v=1370aeeba3ab';
import {emptyDocument,validateDocument,mergeDocuments,updateDocument,valuesOf,documentsEqual} from './sync-model.js?v=dbd0efff3529';

const partition=(doc,connection)=>({...doc,records:Object.fromEntries(Object.entries(doc.records).filter(([key])=>key.startsWith('connect:')===connection))});
const cacheKey=id=>'nova-icloud-document-v1:'+id;
const read=(key,fallback)=>{try{return JSON.parse(localStorage.getItem(key))??fallback}catch{return fallback}};
async function identity(name){
 const hash=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(name)));
 const hex=Array.from(hash.slice(0,16),b=>b.toString(16).padStart(2,'0')).join('');
 return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
function cloudError(error){
 const code=error?.ckErrorCode||error?.code;
 const result=Error(error?.reason||error?.message||'iCloud could not sync. Your changes are saved here.');
 result.conflict=['CONFLICT','SERVER_RECORD_CHANGED'].includes(code);result.retryAfter=error?.retryAfter;return result;
}
function checked(response,{missing=false}={}){
 if(response.hasErrors){if(missing&&response.errors.length===1&&response.errors[0].ckErrorCode==='UNKNOWN_ITEM')return null;throw cloudError(response.errors[0]);}
 if(!response.records?.length)throw Error('iCloud returned an incomplete record.');return response.records[0];
}
export class CloudKitWebStorage {
 constructor(config){this.config=config;this.configured=Boolean(config.containerIdentifier&&config.apiToken);}
 mountAuth(target){
  if(!this.authHost){this.authHost=document.createElement('div');this.authHost.innerHTML='<div id="apple-sign-in-button"></div><div id="apple-sign-out-button" hidden></div>';this.authHost.hidden=true;document.body.append(this.authHost);}
  if(target){this.authHost.hidden=false;target.append(this.authHost);}
  return this.authHost;
 }
 async setup(){
  this.mountAuth();
  if(!this.configured)throw Error('iCloud is not available in this web build yet. Your library stays here.');
  if(!globalThis.CloudKit){await new Promise((resolve,reject)=>{const script=document.createElement('script');script.src='https://cdn.apple-cloudkit.com/ck/2/cloudkit.js';script.onload=resolve;script.onerror=()=>reject(Error('iCloud could not load. Check your connection.'));document.head.append(script)});}
  if(!this.container){
   CloudKit.configure({containers:[{containerIdentifier:this.config.containerIdentifier,apiTokenAuth:{apiToken:this.config.apiToken,persist:true,signInButton:{id:'apple-sign-in-button'},signOutButton:{id:'apple-sign-out-button'}},environment:this.config.environment||'production'}]});
   this.container=CloudKit.getDefaultContainer();this.database=this.container.privateCloudDatabase;
  }
  return this.container.setUpAuth();
 }
 async accountID(){const user=await this.container.fetchCurrentUserIdentity();if(!user?.userRecordName&&!user?.lookupInfo?.userRecordName)throw Error('Sign in to iCloud to sync.');return identity(user.userRecordName||user.lookupInfo.userRecordName);}
 async load(name){
  const record=checked(await this.database.fetchRecords(name),{missing:true});
  if(!record)return {document:emptyDocument(),revision:null};
  const asset=record.fields?.document?.value;
  if(!asset?.downloadURL||asset.size>10000000)throw Error('iCloud returned an invalid document asset.');
  const url=new URL(asset.downloadURL.replace('${f}','nova.json'));
  if(url.protocol!=='https:')throw Error('iCloud returned an insecure asset.');
  const response=await fetch(url,{cache:'no-store',credentials:'omit',signal:AbortSignal.timeout(20000)});
  if(!response.ok)throw Error('The iCloud document could not download.');
  const text=await response.text();if(new TextEncoder().encode(text).length>10000000)throw Error('The iCloud library is too large.');
  return {document:validateDocument(JSON.parse(text)),revision:record.recordChangeTag};
 }
 async save(document,name,revision){
  validateDocument(document);const text=JSON.stringify(document);
  if(new TextEncoder().encode(text).length>10000000)throw Error('The iCloud library is too large.');
  checked(await this.database.saveRecords({recordName:name,recordType:'NovaDocument',...(revision?{recordChangeTag:revision}:{}),fields:{document:{value:new Blob([text],{type:'application/json'})}}}));
 }
}
export class NativeCloudStorage {
 constructor({enabled=true}={}){this.configured=enabled;this.next=0;this.pending=new Map();window.addEventListener('nova-native-cloud',event=>{const value=event.detail,pending=this.pending.get(value?.id);if(!pending)return;this.pending.delete(value.id);clearTimeout(pending.timer);if(value.error){const error=Error(value.error);error.conflict=value.conflict;pending.reject(error)}else pending.resolve(value.result);});}
 request(action,values={}){return new Promise((resolve,reject)=>{const id='cloud-'+(++this.next)+'-'+crypto.randomUUID(),timer=setTimeout(()=>{this.pending.delete(id);reject(Error('iCloud did not respond. Your library is saved here.'));},45000);this.pending.set(id,{resolve,reject,timer});window.novaDesktop.post({type:'cloud',id,action,...values});});}
 async setup(){if(!this.configured)throw Error("This Mac build is not signed for iCloud yet. Its Apple iCloud provisioning profile must be added before syncing can work. Your library stays here.");return true;}
 accountID(){return this.request('account');}
 load(name){return this.request('load',{name});}
 save(document,name,revision){validateDocument(document);return this.request('save',{name,revision,document});}
}
// The web interface delegates LAN sockets to the trusted native Mac bridge.
export class NativeLocalPlayback {
 constructor(){
  this.onDocument=()=>{};this.onPeers=()=>{};this.onError=()=>{};
  window.addEventListener('nova-local-playback',event=>{
   const value=event.detail||{};
   if(value.document)this.onDocument(value.document);
   if(Array.isArray(value.peers))this.onPeers(value.peers);
   if(Object.hasOwn(value,'error'))this.onError(value.error);
  });
 }
 configure(id,key){if(this.id===id&&this.key===key)return;this.id=id;this.key=key;window.novaDesktop.post({type:'localPlayback',action:'configure',deviceID:id,key});}
 publish(document){window.novaDesktop.post({type:'localPlayback',action:'publish',document});}
 async refresh(){window.novaDesktop.post({type:'localPlayback',action:'refresh'});}
 stop(){this.id=null;this.key=null;window.novaDesktop.post({type:'localPlayback',action:'stop'});}
}
export class ICloudSyncClient extends NovaSyncClient {
 constructor(callbacks,{storage,config={},localPlayback}={}){
  super({},callbacks);this.storage=storage||(window.novaDesktop?new NativeCloudStorage({enabled:Boolean(window.novaDesktop.nativeICloud)}):new CloudKitWebStorage(config));this.configured=this.storage.configured;
  this.playbackIndependent=true;this.connection=emptyDocument();this.retryAt=0;
  this.playbackTransport=localPlayback||(window.novaDesktop?.nativeLocalPlayback?new NativeLocalPlayback():null);
  this.localPlaybackEnabled=Boolean(this.playbackTransport);this.connectedPeers=new Set();
  clearInterval(this.poll);this.poll=setInterval(()=>this.schedule(0),10000);
  if(this.playbackTransport){
   this.playbackTransport.onDocument=document=>this.receiveLocalDocument(document).catch(error=>this.callbacks.playbackError?.(error.message));
   this.playbackTransport.onPeers=peers=>{this.connectedPeers=new Set(peers);this.callbacks.connect?.(this.connectValues());};
   this.playbackTransport.onError=error=>this.callbacks.playbackError?.(error);
  }
 }
 async initialize(){
  // Recover the last cached library from the previous provider without contacting it.
  let old;try{old=JSON.parse(sessionStorage.getItem('nova-music-auth-session-v1'))}catch{}
  if(!localStorage.getItem('nova-icloud-identity')&&old?.user?.id){const cached=read('nova-music-account-library-v1:'+old.user.id,null);if(cached){this.applying=true;try{this.callbacks.activate(old.user,cached);this.callbacks.apply(this.callbacks.values())}finally{this.applying=false}}}
  if(!this.configured||localStorage.getItem('nova-icloud-enabled')==='false')return;
  const identity=localStorage.getItem('nova-icloud-identity'),cached=identity?read(cacheKey(identity),null):null;
  if(cached&&valuesOf(validateDocument(cached))['deviceTrust:localPlayback']){
   ++this.generation;this.activeUser={id:identity,email:'iCloud'};this.session={user:this.activeUser};this.connection=emptyDocument();
   this.document=partition(cached,false);this.previous=valuesOf(this.document);this.appliedLibrary=null;
   this.applying=true;try{this.callbacks.activate(this.user,null)}finally{this.applying=false}
   this.applyCurrent();this.sync();return;
  }
  const user=await this.storage.setup();if(user)await this.enable({automatic:true});
 }
 async prepareAuth(mergeLibrary){
  this.mergeOnSignIn=mergeLibrary;
  const user=await this.storage.setup();
  if(user){await this.enable({mergeLibrary});return;}
  if(!this.waitingForSignIn){this.waitingForSignIn=true;this.storage.container.whenUserSignsIn().then(async()=>{this.waitingForSignIn=false;try{await this.enable({mergeLibrary:this.mergeOnSignIn})}catch(error){this.updateStatus('error',error.message)}});}
 }
 async enable({mergeLibrary=true,automatic=false,synchronize=true}={}){
  const id=await this.storage.accountID(),old=localStorage.getItem('nova-icloud-identity');
  if(automatic&&old&&old!==id)throw Error('Your Apple Account changed. Enable iCloud again and choose whether to add this library.');
  if(this.user&&this.user.id!==id)await this.signOut();
  const guest=mergeLibrary?this.callbacks.values():null;
  ++this.generation;this.activeUser={id,email:'iCloud'};this.session={user:this.activeUser};this.connection=emptyDocument();
  this.document=partition(validateDocument(read(cacheKey(id),emptyDocument())),false);
  this.previous=valuesOf(this.document);this.appliedLibrary=null;
  this.applying=true;try{this.callbacks.activate(this.user,null)}finally{this.applying=false}
  if(guest)this.document=updateDocument(this.document,this.previous,{...this.previous,...guest},this.actor);
  this.previous=valuesOf(this.document);localStorage.setItem('nova-icloud-identity',id);localStorage.setItem('nova-icloud-enabled','true');
  this.applyCurrent();if(synchronize)await this.sync();
  if(this.storage.container)this.storage.container.whenUserSignsOut().then(()=>this.signOut());
 }
 saveSession(){}
 saveDocument(){if(this.user)localStorage.setItem(cacheKey(this.user.id),JSON.stringify(partition(this.document,false)));}
 connectValues(){return valuesOf(this.connection);}
 setConnectValues(values){
  if(!this.user)return;if(Object.keys(values).some(k=>!k.startsWith('connect:')))throw Error('Invalid playback record.');
  const old=valuesOf(this.connection);this.connection=updateDocument(this.connection,old,{...old,...values},this.actor);
  this.publishLocalDocument();
 }
 configureLocalPlayback(){
  const key=valuesOf(this.document)['deviceTrust:localPlayback'];
  if(!this.user||!this.playbackTransport||typeof key!=='string'||!/^[A-Za-z0-9+/]{43}=$/.test(key))return;
  if(this.localConfiguration===this.actor+key)return;
  this.localConfiguration=this.actor+key;this.playbackTransport.configure(this.actor,key);this.publishLocalDocument();
 }
 publishLocalDocument(){if(this.user)this.playbackTransport?.publish(this.connection);}
 async receiveLocalDocument(document){
  if(!this.user)return;const epoch=this.generation;
  validateDocument(document);if(Object.keys(document.records).some(key=>!key.startsWith('connect:')))throw Error('Invalid local playback document.');
  const merged=mergeDocuments(this.connection,document);if(documentsEqual(merged,this.connection))return;
  this.connection=merged;await this.callbacks.connect?.(this.connectValues());
  if(epoch===this.generation)this.publishLocalDocument();
 }
 changed(){
  if(!this.user||this.applying)return;
  try{const next={...this.callbacks.values()};const key=valuesOf(this.document)['deviceTrust:localPlayback'];if(key)next['deviceTrust:localPlayback']=key;const updated=updateDocument(this.document,this.previous,next,this.actor);
   if(documentsEqual(updated,this.document))return;this.document=partition(updated,false);this.previous=next;this.saveDocument();this.updateStatus('pending');this.schedule();
  }catch(error){this.updateStatus('error',error.message)}
 }
 applyCurrent(){
  this.applying=true;
  try{const values=valuesOf(this.document),serialized=JSON.stringify(this.document);if(serialized!==this.appliedLibrary){this.callbacks.apply(values);this.appliedLibrary=serialized;}this.previous=this.callbacks.values();this.saveDocument();this.configureLocalPlayback();}
  finally{this.applying=false;}
 }
 async assertAccount(){if(await this.storage.accountID()!==this.user?.id){await this.signOut();throw Error('Your Apple Account changed. Enable iCloud again to choose whether to add this library.');}}
 async exchange(name,connection){
  const epoch=this.generation,id=this.user.id;
  await this.assertAccount();this.assertCurrent(epoch,id);
  for(let attempt=0;attempt<5;attempt++){
   const remote=await this.storage.load(name);this.assertCurrent(epoch,id);
   if(!connection)this.changed();
   const current=connection?this.connection:this.document;let candidate=mergeDocuments(current,partition(validateDocument(remote.document),connection));
   if(!connection&&!valuesOf(candidate)['deviceTrust:localPlayback']){
    const key=btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
    const values=valuesOf(candidate);candidate=updateDocument(candidate,values,{...values,'deviceTrust:localPlayback':key},this.actor);
   }
   if(!documentsEqual(candidate,remote.document)){
    try{await this.storage.save(candidate,name,remote.revision)}catch(error){if(error.conflict)continue;throw error;}
   }
   this.assertCurrent(epoch,id);
   if(connection){this.connection=mergeDocuments(candidate,this.connection);await this.callbacks.connect?.(this.connectValues());if(!documentsEqual(candidate,this.connection))continue;}
   else{this.changed();this.document=mergeDocuments(candidate,this.document);this.applyCurrent();if(!documentsEqual(candidate,this.document))continue;}
   return;
  }
  throw Error('Another device is updating iCloud. Your changes are saved; sync will retry.');
 }
 schedule(delay=700){
  if(!this.configured||localStorage.getItem('nova-icloud-enabled')==='false')return;
  clearTimeout(this.timer);this.timer=setTimeout(()=>this.sync(),delay);
 }
 async runSync(){
  if(Date.now()<this.retryAt)return;
  if(!this.user){
   if(!this.configured||localStorage.getItem('nova-icloud-enabled')==='false')return;
   try{const user=await this.storage.setup();if(user)await this.enable({automatic:true,synchronize:false});}
   catch(error){this.retryAt=Date.now()+10000;this.updateStatus('error',error.message);return;}
   if(!this.user)return;
  }
  const epoch=this.generation;this.updateStatus('syncing');
  try{await this.exchange('nova-library',false);this.lastSynced=Date.now();this.updateStatus('synced');}
  catch(error){if(epoch===this.generation){this.retryAt=Date.now()+Math.max(10000,(error.retryAfter||0)*1000);this.updateStatus('error',error.message);}}
 }
 async pollConnect(){
  // Playback is local-only; no CloudKit read, write, auth refresh or retry gate.
  if(!this.user)return;
  this.configureLocalPlayback();this.publishLocalDocument();await this.playbackTransport?.refresh();
 }
 async signOut(){
  this.playbackTransport?.stop();this.localConfiguration=null;this.connectedPeers=new Set();
  this.changed();const values=valuesOf(this.document);++this.generation;clearTimeout(this.timer);this.activeUser=null;this.session=null;this.connection=emptyDocument();
  localStorage.setItem('nova-icloud-enabled','false');this.document=emptyDocument();this.previous={};
  this.applying=true;try{this.callbacks.deactivate?.();this.callbacks.apply(values)}finally{this.applying=false}
  this.updateStatus('signed-out','iCloud sync is off. Your library stays here.');
 }
}
