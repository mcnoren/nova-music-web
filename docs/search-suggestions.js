// Optional live query suggestions. A newer input always owns the visible list.
export class SearchSuggestions {
 constructor({request,render=()=>{},select=()=>{},delay=250}={}){this.request=request;this.render=render;this.onSelect=select;this.delay=delay;this.items=[];this.index=-1;this.generation=0;}
 update(query){
  this.dismiss();query=String(query||'').trim();if(!query||query.length>200)return;
  const generation=this.generation;this.controller=new AbortController();const signal=this.controller.signal;
  this.timer=setTimeout(async()=>{
   try{const result=await this.request(query,{signal});if(generation!==this.generation||signal.aborted)return;
    const seen=new Set();this.items=(result||[]).map(x=>typeof x==='string'?x:x.text).filter(x=>typeof x==='string'&&x&&!seen.has(x)&&seen.add(x)).slice(0,8);this.render(this.items,this.index);
   }catch{if(generation===this.generation)this.render([], -1);}
  },this.delay);
 }
 move(offset){if(!this.items.length)return false;this.index=this.index<0?(offset>0?0:this.items.length-1):(this.index+offset+this.items.length)%this.items.length;this.render(this.items,this.index);return true;}
 choose(index=this.index){const query=this.items[index];if(!query)return false;this.dismiss();this.onSelect(query);return true;}
 dismiss(){this.generation++;clearTimeout(this.timer);this.controller?.abort();this.items=[];this.index=-1;this.render([], -1);}
}
