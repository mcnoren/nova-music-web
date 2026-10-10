// Observe the engine clock, never the connected-device estimate. No audio or
// account data is captured; the bounded history lives only in this window.
export class PlaybackHealth {
  constructor(){this.reset();}
  reset(){this.samples=[];this.events=[];this.loads=0;this.seeks=0;this.buffering=0;this.rateChanges=0;}
  event(type,value,at=performance.now()){
    if(type==='load')this.loads++;
    if(type==='seek')this.seeks++;
    if(type==='buffering')this.buffering++;
    if(type==='rate')this.rateChanges++;
    this.events.push({type,value,at});this.events=this.events.slice(-40);
    if(type==='load'||type==='seek')this.samples=[];
  }
  sample(position,state,rate,at=performance.now()){
    if(!Number.isFinite(position)||!Number.isFinite(rate))return;
    this.samples.push({position,state,rate,at});this.samples=this.samples.filter(s=>at-s.at<=15000);
  }
  report(){
    const last=this.samples.at(-1);let media=0,wall=0;
    for(let i=1;i<this.samples.length;i++){
      const a=this.samples[i-1],b=this.samples[i],dt=(b.at-a.at)/1000;
      if(a.state===1&&b.state===1&&dt>0&&dt<3){media+=b.position-a.position;wall+=dt;}
    }
    return {rate:last?.rate??null,observed:wall>=5?media/wall:null,seconds:wall,state:last?.state??null,loads:this.loads,seeks:this.seeks,buffering:this.buffering,rateChanges:this.rateChanges,events:this.events};
  }
}
