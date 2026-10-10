// Adapter for the trusted Mac bridge. AVPlayer owns the audio and clock; this
// object only presents the same controls/samples as the browser player.
export class NativeMusicPlayer {
  constructor(bridge,events={},target=window){
    this.bridge=bridge;this.events=events;this.target=target;this.pending=new Map();this.volume=80;
    this.generation=crypto.randomUUID();this.value={id:'',position:0,duration:0,state:2,rate:1};
    this.listener=event=>this.receive(event.detail);target.addEventListener('nova-native-audio',this.listener);
  }
  receive(value){
    if(!value||typeof value!=='object')return;
    const state=value.state;
    if(state?.generation===this.generation){
      const previous=this.value.state;
      this.value={...state};
      if(previous!==state.state)this.events.onStateChange?.({target:this,data:state.state});
    }
    const pending=this.pending.get(value.request);
    if(pending){clearTimeout(pending.timer);this.pending.delete(value.request);if(value.error)pending.reject(Error(value.error));else pending.resolve();}
    else if(value.error&&value.generation===this.generation)this.events.onError?.({message:value.error});
  }
  request(command,extra={}){
    const request=crypto.randomUUID();
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.pending.delete(request);reject(Error('The Mac audio player did not respond. Try playing again.'));},60000);
      this.pending.set(request,{resolve,reject,timer});
      try{this.bridge.post({type:'audio',command,request,generation:this.generation,...extra});}
      catch(error){clearTimeout(timer);this.pending.delete(request);reject(error);}
    });
  }
  loadVideoById({videoId,startSeconds=0,title='',artist=''},playing=true){
    for(const pending of this.pending.values()){clearTimeout(pending.timer);pending.reject(Error('Playback changed.'));}this.pending.clear();
    this.generation=crypto.randomUUID();this.value={id:videoId,position:startSeconds,duration:0,state:3,rate:1};
    return this.request('load',{videoId,position:startSeconds,playing,title,artist,volume:this.volume});
  }
  cueVideoById(value){return this.loadVideoById(value,false);}
  playVideo(){return this.request('play');}
  pauseVideo(){return this.request('pause');}
  seekTo(position){return this.request('seek',{position});}
  setVolume(volume){this.volume=volume;if(this.value.id)return this.request('volume',{volume});}
  getCurrentTime(){return this.value.position;}
  getDuration(){return this.value.duration;}
  getPlayerState(){return this.value.state;}
  getPlaybackRate(){return this.value.rate;}
  getVideoUrl(){return 'https://www.youtube.com/watch?v='+this.value.id;}
  destroy(){
    this.bridge.post({type:'audio',command:'stop',request:crypto.randomUUID(),generation:this.generation});
    this.target.removeEventListener('nova-native-audio',this.listener);
    for(const pending of this.pending.values()){clearTimeout(pending.timer);pending.reject(Error('Output changed.'));}this.pending.clear();
  }
}
