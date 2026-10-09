export const normalizeSearch=value=>String(value??'').normalize('NFD').replace(/\p{Diacritic}/gu,'').toLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim();
function distance(a,b) {
  const rows=Array.from({length:a.length+1},()=>Array(b.length+1).fill(0));
  for(let i=0;i<=a.length;i++)rows[i][0]=i;
  for(let j=0;j<=b.length;j++)rows[0][j]=j;
  for(let i=1;i<=a.length;i++)for(let j=1;j<=b.length;j++){
    rows[i][j]=Math.min(rows[i-1][j]+1,rows[i][j-1]+1,rows[i-1][j-1]+(a[i-1]===b[j-1]?0:1));
    if(i>1&&j>1&&a[i-1]===b[j-2]&&a[i-2]===b[j-1])rows[i][j]=Math.min(rows[i][j],rows[i-2][j-2]+1);
  }
  return rows[a.length][b.length];
}
export function rankLocal(items,query,kind='songs',lyrics=()=> '') {
  const q=normalizeSearch(query);if(!q)return[];
  const tokens=q.split(' ');
  return items.map((item,index)=>{
    const title=normalizeSearch(item.title||item.name),artist=normalizeSearch(item.artist),album=normalizeSearch(item.album),fields=[title,artist,album,normalizeSearch(item.genre)];
    const words=fields.join(' ').split(' ');
    const scores=tokens.map(token=>Math.max(...words.map(word=>{
      if(word===token)return 10;
      if(word.startsWith(token))return 8;
      if(token.length<4||word.length<3||Math.abs(token.length-word.length)>2)return 0;
      const d=distance(token,word),max=token.length>=8?2:1;
      return d<=max?6-d:0;
    })));
    let score=scores.every(Boolean)?scores.reduce((a,b)=>a+b,0):0;
    if(score){if(title===q)score+=100;else if(title.startsWith(q))score+=50;else if(title.includes(q))score+=30;if(artist===q)score+=40;}
    const lyricText=kind==='songs'?normalizeSearch(item.lyrics||lyrics(item.id)):'';
    if(tokens.length>=3&&lyricText.includes(q))score=Math.max(score,70);
    return {item,index,score};
  }).filter(x=>x.score>0).sort((a,b)=>b.score-a.score||a.index-b.index).map(x=>x.item);
}
export function mergeResults(first,second) {
  return [...new Map([...second,...first].map(item=>[item.id,item])).values()].sort((a,b)=>{
    const ai=first.findIndex(x=>x.id===a.id),bi=first.findIndex(x=>x.id===b.id);
    return (ai<0?first.length+second.findIndex(x=>x.id===a.id):ai)-(bi<0?first.length+second.findIndex(x=>x.id===b.id):bi);
  });
}
export class MusicSearchClient {
  constructor(url,{fetcher=(...args)=>fetch(...args),now=Date.now,publicKey=''}={}){this.url=url;this.publicKey=publicKey;this.fetcher=fetcher;this.now=now;this.cache=new Map();}
  async request(input,{signal}={}){
    const key=JSON.stringify(input),hit=this.cache.get(key);
    if(hit&&this.now()-hit.at<300000)return structuredClone(hit.data);
    const controller=new AbortController(),abort=()=>controller.abort();
    if(signal?.aborted)abort();else signal?.addEventListener('abort',abort,{once:true});
    const timer=setTimeout(abort,25000);let response,data;
    try{
      response=await this.fetcher(this.url,{method:'POST',headers:{'Content-Type':'application/json',...(this.publicKey?{apikey:this.publicKey}:{})},body:JSON.stringify(input),signal:controller.signal,cache:'no-store'});
      data=await response.json();
    }finally{clearTimeout(timer);signal?.removeEventListener('abort',abort);}
    if(!response.ok||data.error)throw Error(data.error||'Live music search is unavailable. Please retry.');
    if(!['songs','albums','artists','playlists'].every(key=>Array.isArray(data[key])))throw Error('Music search returned an incomplete response. Please retry.');
    this.cache.set(key,{at:this.now(),data});while(this.cache.size>80)this.cache.delete(this.cache.keys().next().value);
    return structuredClone(data);
  }
}
