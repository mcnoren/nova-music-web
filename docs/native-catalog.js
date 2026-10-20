import {execute} from './music-catalog.js?v=282cd9a4bdca';

export class NativeCatalogTransport {
 constructor({bridge=globalThis.novaDesktop,events=globalThis,uuid=()=>crypto.randomUUID()}={}){
  this.bridge=bridge;this.events=events;this.uuid=uuid;this.pending=new Map();
  this.listener=event=>{const result=event.detail,entry=this.pending.get(result?.requestID);if(entry)entry.finish(result.error?Error(result.error):null,result.data);};
  events.addEventListener('nova-native-catalog',this.listener);
 }
 request(operation,body,{signal,timedLyrics=false}={}){
  return new Promise((resolve,reject)=>{
   if(signal?.aborted){reject(new DOMException('Search cancelled','AbortError'));return;}
   const requestID=this.uuid();let timer;
   const finish=(error,data)=>{if(!this.pending.delete(requestID))return;clearTimeout(timer);signal?.removeEventListener('abort',abort);error?reject(error):resolve(data);};
   const abort=()=>{this.bridge.post({type:'catalogCancel',requestID});finish(new DOMException('Search cancelled','AbortError'));};
   this.pending.set(requestID,{finish,abort});signal?.addEventListener('abort',abort,{once:true});
   timer=setTimeout(()=>{this.bridge.post({type:'catalogCancel',requestID});finish(Error('Live search timed out. Try again.'));},operation==='lyricSearch'?4000:operation==='suggestions'?5000:20000);
   try{this.bridge.post({type:'catalog',requestID,operation,body,timedLyrics});}catch(error){finish(error);}
  });
 }
 dispose(){for(const entry of this.pending.values())entry.abort();this.events.removeEventListener('nova-native-catalog',this.listener);}
}
export class NativeCatalogClient {
 constructor({transport=new NativeCatalogTransport(),timeout=20000}={}){this.transport=transport;this.timeout=timeout;}
 async request(input,{signal}={}){
  const controller=new AbortController(),abort=()=>controller.abort();
  if(signal?.aborted)abort();else signal?.addEventListener('abort',abort,{once:true});
  const timer=setTimeout(abort,input.op==='suggestions'?5000:this.timeout);
  const request=(operation,body,_fetcher,timedLyrics=false)=>this.transport.request(operation,body,{signal:controller.signal,timedLyrics});
  try{
   const result=await execute({...input,providerOrder:true},request);
   if(controller.signal.aborted)throw new DOMException('Search cancelled or timed out. Try again.','AbortError');
   if(!input.op||input.op==='search'){
    const category=input.kind&&input.kind!=='All'?input.kind.toLowerCase():null;
    if(!result.top||category&&result.top.kind!==category)result.top=(result.order||[]).find(ref=>!category||ref.kind===category)||null;
   }
   return result;
  }finally{clearTimeout(timer);signal?.removeEventListener('abort',abort);}
 }
}
