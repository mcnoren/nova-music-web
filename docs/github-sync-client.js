import {NovaSyncClient,accountLibraryKey} from './sync-client.js?v=1370aeeba3ab';
import {emptyDocument,validateDocument,mergeDocuments,updateDocument,valuesOf,documentsEqual} from './sync-model.js?v=dbd0efff3529';

const SESSION='nova-music-auth-session-v1';
export function validRepository(raw){
 const value=String(raw||'').trim();
 if(!/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9_.-]{1,100}$/.test(value)||['.','..'].includes(value.split('/')[1]))throw Error('Enter a private repository as owner/name.');
 return value;
}
export function libraryOnly(document){validateDocument(document);return {...document,records:Object.fromEntries(Object.entries(document.records).filter(([key])=>!key.startsWith('connect:')))};}
function privateRepository(value){if(value.private!==true||value.archived||value.disabled)throw Error('Choose an active private repository. Your library is never uploaded to a public repository.');if(value.permissions?.push===false)throw Error('The token needs Contents read and write access.');}
async function repositoryIdentity(id){
 if(!Number.isSafeInteger(id)||id<=0)throw Error('GitHub returned an invalid repository identity.');
 const bytes=new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode('github-repo:'+id))).slice(0,16);
 bytes[6]=(bytes[6]&15)|80;bytes[8]=(bytes[8]&63)|128;
 const hex=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
function encode(document){const bytes=new TextEncoder().encode(JSON.stringify(document));if(bytes.length>8000000)throw Error('The library is too large to sync. Reduce custom artwork sizes.');let value='';for(let i=0;i<bytes.length;i+=8192)value+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(value);}
function decode(value){const text=atob(value.replace(/\s/g,''));if(text.length>8000000)throw Error('The library exceeds the sync limit.');return validateDocument(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(Uint8Array.from(text,c=>c.charCodeAt(0)))));}

export class GitHubSyncClient extends NovaSyncClient {
 constructor(callbacks,{fetcher=(...args)=>fetch(...args),now=Date.now}={}){
  super({},callbacks);this.configured=true;this.fetcher=fetcher;this.now=now;this.retryAt=0;
  clearInterval(this.poll);this.poll=setInterval(()=>{if(document.visibilityState==='visible')this.schedule(0)},300000);
 }
 async initialize(){
  let stored;try{stored=JSON.parse(sessionStorage.getItem(SESSION))}catch{return}
  if(stored?.repository&&stored?.access_token&&stored?.user?.id){await this.activate(stored,false);return;}
  // Recover this browser's last cached Supabase library without contacting that service.
  if(stored?.user?.id){let cached;try{cached=JSON.parse(localStorage.getItem(accountLibraryKey(stored.user.id)))}catch{}
   if(cached){this.callbacks.activate(stored.user,cached);this.callbacks.apply(this.callbacks.values());this.updateStatus('signed-out','Your previous library is available here. Connect a private GitHub repository to sync it.');}
  }
 }
 async signIn(repository,token,mergeLibrary=true){return this.connectGitHub(repository,token,mergeLibrary)}
 async connectGitHub(raw,rawToken,mergeLibrary=true){
  const repository=validRepository(raw),token=String(rawToken||'').trim();
  if(!token||token.length>1000||/\s/.test(token))throw Error('Enter a GitHub access token.');
  const metadata=await this.github('/repos/'+repository,{token});privateRepository(metadata);
  const id=await repositoryIdentity(metadata.id);
  if(this.user&&this.user.id!==id)throw Error('Disconnect the current repository before choosing another. Your local library will stay here.');
  await this.activate({access_token:token,refresh_token:'',repository,user:{id,email:repository}},this.user?false:mergeLibrary);
 }
 connectValues(){return {}}
 async pollConnect(){}
 setConnectValues(){throw Error('Live device controls have been removed.')}
 schedule(delay=5000){return super.schedule(delay)}
 changed(){this.capture(true)}
 capture(schedule){
  if(!this.user||this.applying)return;
  try{const next=this.callbacks.values(),updated=updateDocument(this.document,this.previous,next,this.actor);
   if(documentsEqual(updated,this.document))return;
   this.document=libraryOnly(updated);this.previous=next;this.saveDocument();this.updateStatus('pending');if(schedule)this.schedule();
  }catch(error){this.updateStatus('error',error.message)}
 }
 applyCurrent(){this.document=libraryOnly(this.document);super.applyCurrent()}
 async token(){if(!this.session?.access_token)throw Error('Connect GitHub to sync.');return this.session.access_token}
 async runSync(){
  if(!this.user||this.busy)return;
  const epoch=this.generation,id=this.user.id,repository=this.session.repository;
  this.busy=true;this.capture(false);this.updateStatus('syncing');
  try{
   const metadata=await this.github('/repos/'+repository);this.assertCurrent(epoch,id);privateRepository(metadata);
   if(await repositoryIdentity(metadata.id)!==id)throw Error('The repository identity changed. Reconnect GitHub.');
   for(let attempt=0;attempt<3;attempt++){
    const path='/repos/'+repository+'/contents/nova-library.json',file=await this.github(path,{allowMissing:true});this.assertCurrent(epoch,id);
    let remote=emptyDocument();
    if(file!==null){
     if(file.type!=='file'||typeof file.sha!=='string')throw Error('GitHub returned an unexpected library file.');
     let content=file.content;
     if(file.encoding==='none'){const blob=await this.github('/repos/'+repository+'/git/blobs/'+file.sha);this.assertCurrent(epoch,id);if(blob.sha!==file.sha||blob.encoding!=='base64')throw Error('Invalid library content.');content=blob.content;}
     else if(file.encoding!=='base64')throw Error('Invalid library encoding.');
     if(typeof content!=='string')throw Error('GitHub returned an incomplete library.');remote=libraryOnly(decode(content));
    }
    this.capture(false);const candidate=mergeDocuments(this.document,remote);
    if(documentsEqual(candidate,remote)){this.document=candidate;this.applyCurrent();this.lastSynced=this.now();this.updateStatus('synced');return;}
    privateRepository(await this.github('/repos/'+repository));this.assertCurrent(epoch,id);
    const saved=await this.github(path,{method:'PUT',allowConflict:true,body:{message:'Sync Nova Music library',content:encode(candidate),...(file?.sha?{sha:file.sha}:{})}});this.assertCurrent(epoch,id);
    if(saved===null)continue;
    if(!saved.content?.sha)throw Error('GitHub did not confirm the saved library.');
    this.capture(false);this.document=mergeDocuments(candidate,this.document);this.applyCurrent();
    if(!documentsEqual(candidate,this.document))continue;
    this.lastSynced=this.now();this.updateStatus('synced');return;
   }
   throw Error('Another device updated the library. Your edits are saved here; sync will retry.');
  }catch(error){if(epoch===this.generation)this.updateStatus('error',error.message)}
  finally{this.busy=false;if(epoch!==this.generation&&this.user)this.schedule(0)}
 }
 async github(path,options={}){
  if(this.now()<this.retryAt)throw Error('GitHub asked Nova to wait before syncing. Your library remains saved here.');
  if(!path.startsWith('/repos/')||path.split('/').includes('..'))throw Error('Invalid GitHub resource.');
  const response=await this.fetcher('https://api.github.com'+path,{method:options.method||'GET',redirect:'error',headers:{Authorization:'Bearer '+(options.token||await this.token()),Accept:path.includes('/contents/')?'application/vnd.github.object+json':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28',...(options.body?{'Content-Type':'application/json'}:{})},...(options.body?{body:JSON.stringify(options.body)}:{}),cache:'no-store',signal:AbortSignal.timeout(20000)});
  if(response.status===404&&options.allowMissing)return null;
  if([409,422].includes(response.status)&&options.allowConflict)return null;
  if(!response.ok){
   if([403,429].includes(response.status)){const retry=Number(response.headers.get('Retry-After'))||60,reset=response.headers.get('X-RateLimit-Remaining')==='0'?Number(response.headers.get('X-RateLimit-Reset'))*1000:0;this.retryAt=Math.max(this.now()+retry*1000,reset);}
   throw Error(response.status===401?'Your GitHub token expired or was revoked. Reconnect GitHub.':response.status===404?'Private repository not found. Check the name and token access.':'GitHub could not sync. Check repository access or try later. Your library is saved here.');
  }
  const text=await response.text();if(text.length>16000000)throw Error('GitHub returned too much data.');return JSON.parse(text);
 }
 async signOut(){
  this.capture(false);const values=valuesOf(this.document);
  ++this.generation;clearTimeout(this.timer);this.session=null;this.activeUser=null;
  sessionStorage.removeItem(SESSION);window.novaDesktop?.post({type:'session',value:null});
  this.document=emptyDocument();this.previous={};this.callbacks.apply(values);this.updateStatus('signed-out','GitHub disconnected. Your library and cached unsent edits remain on this device.');
 }
}
