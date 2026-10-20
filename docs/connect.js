import {validCollectionContext} from './collection-position.js?v=ab58eb8758aa';
// Shared with the native app: seconds for positions, milliseconds for timestamps.
// Commands and telemetry are separate so a heartbeat cannot overwrite a remote action.
export const SESSION_KEY = 'connect:session', STATUS_KEY = 'connect:status';
export const ONLINE_MS = 90000, COMMAND_MS = 120000;
export function validConnectedLyrics(value) {
  return value && /^[A-Za-z0-9_-]{11}$/.test(value.songID) && /^[A-Za-z0-9_-]{11}$/.test(value.recordingID) &&
    typeof value.loaded === 'boolean' && Array.isArray(value.lines) && value.lines.length <= 2000 &&
    value.lines.every(line=>Number.isFinite(line.time) && line.time>=0 && typeof line.text==='string' && line.text.length<=8000 && (line.endTime==null || Number.isFinite(line.endTime)&&line.endTime>=line.time)) &&
    typeof value.plain==='string' && value.plain.length<=200000 && typeof value.source==='string' && typeof value.instrumental==='boolean' &&
    Number.isFinite(value.offset) && Math.abs(value.offset)<=120 && Number.isFinite(value.rate) && value.rate>=0.85 && value.rate<=1.15;
}
export function validSnapshot(value) {
  return value && Array.isArray(value.queue) && value.queue.length <= 1000 &&
    value.queue.every(s => s && /^[A-Za-z0-9_-]{11}$/.test(s.id) && typeof s.title === 'string' && typeof s.artist === 'string' && s.source === 'youtube') &&
    Number.isInteger(value.index) && (value.queue.length ? value.index >= 0 && value.index < value.queue.length : value.index === 0) &&
    Number.isFinite(value.position) && value.position >= 0 && typeof value.playing === 'boolean' &&
    typeof value.shuffle === 'boolean' && [0,1,2].includes(value.repeat) &&
    (value.queueOrigins==null || Array.isArray(value.queueOrigins) && value.queueOrigins.length===value.queue.length && value.queueOrigins.every(origin=>origin==null || validCollectionContext(origin))) &&
    (value.contextSongIDs==null || typeof value.contextSongIDs==='object' && !Array.isArray(value.contextSongIDs) && Object.keys(value.contextSongIDs).length<=1000 && Object.entries(value.contextSongIDs).every(([id,source])=>/^[A-Za-z0-9_-]{11}$/.test(id)&&typeof source==='string'&&/^[A-Za-z0-9_-]{11}$/.test(source))) && (value.context==null || validCollectionContext(value.context)) && (value.loading==null || typeof value.loading==='boolean') && (value.positionIntent==null || ['preserve','seek'].includes(value.positionIntent)) && (value.at==null || Number.isFinite(value.at)) && (value.activityAt==null || Number.isFinite(value.activityAt)) && (value.handoff==null || typeof value.handoff==='string' && /^[a-f0-9-]{36}$/i.test(value.handoff)) && (value.lyrics==null || validConnectedLyrics(value.lyrics));
}
export function snapshotPosition(snapshot, now = Date.now()) {
  const age=now-(snapshot.at ?? now);
  const elapsed = snapshot.playing && age<ONLINE_MS ? Math.max(0,age/1000) : 0;
  return Math.min(snapshot.queue[snapshot.index]?.duration || Infinity, snapshot.position + elapsed);
}
export class NovaConnect {
  constructor(account, options) {
    this.account = account; this.options = options; this.id = options.id;
    this.values = {}; this.applied = null; this.wasOwner = false; this.wasRemote = false; this.generation = 0; this.serial = Promise.resolve(); this.preparing=null; this.acknowledgedHandoff=null;
  }
  get devices() {
    const now = Date.now();
    return Object.entries(this.values).filter(([key,v]) => key.startsWith('connect:device.') && v && typeof v.id === 'string' && typeof v.name === 'string' && now-v.at < ONLINE_MS && v.at <= now+10000).map(([,v]) => v).filter(v=>!this.account.localPlaybackEnabled||v.id===this.id||this.account.connectedPeers.has(v.id));
  }
  get session() { const s=this.values[SESSION_KEY]; return s && typeof s.owner === 'string' && typeof s.command === 'string' && Number.isFinite(s.at) && validSnapshot(s.snapshot) ? s : null; }
  get owner() { return this.session?.owner; }
  get active() {
    const session=this.session;if(!session)return false;
    const status=this.values[STATUS_KEY];
    const confirmed=status?.owner===session.owner && status.command===session.command && validSnapshot(status);
    const snapshot=confirmed?status:session.snapshot,now=Date.now();
    return now-session.at<ONLINE_MS || snapshot.playing && now-(snapshot.at??session.at)<ONLINE_MS || now-(snapshot.activityAt??session.at)<ONLINE_MS;
  }
  get remote() { return Boolean(this.account.user && this.active && this.owner && this.owner !== this.id && (!this.account.localPlaybackEnabled || this.online)); }
  get online() { return this.devices.some(d=>d.id === this.owner); }
  get name() { const device=this.values['connect:device.'+this.owner];return typeof device?.name==='string'?device.name:'Unavailable device'; }
  get snapshot() {
    const status=this.values[STATUS_KEY], session=this.session;
    const confirmed=session && status?.owner === session.owner && status?.command === session.command && validSnapshot(status);
    const snapshot=confirmed?status:session?.snapshot;
    if(snapshot && Date.now()-(snapshot.at ?? session.at)>=ONLINE_MS)return {...snapshot,playing:false};
    return snapshot && !confirmed ? {...snapshot,playing:false} : snapshot;
  }
  get pendingPlaying() {
    if(this.intent)return this.intent.playing;
    const session=this.session,status=this.values[STATUS_KEY];
    if(!this.remote || !session || session.snapshot.handoff || Date.now()-session.at>=15000)return null;
    return status?.owner===session.owner && status.command===session.command && status.playing===session.snapshot.playing ? null : session.snapshot.playing;
  }
  setPlayingIntent(playing) {
    const intent={playing};this.intent=intent;this.options.changed?.();
    clearTimeout(this.intentTimer);
    this.intentTimer=setTimeout(()=>{if(this.intent===intent){this.intent=null;this.options.changed?.();this.options.error?.('The output did not respond. Choose another output location.');}},15000);
    return this.enqueue(async generation=>{
      try{const session=await this.send(s=>({...s,position:snapshotPosition(s),positionIntent:'preserve',playing}),undefined,generation);if(this.intent===intent){intent.command=session.command;this.settleIntent();}}
      catch(error){if(this.intent===intent){this.intent=null;clearTimeout(this.intentTimer);this.options.changed?.();}throw error;}
    });
  }
  settleIntent(){
    const status=this.values[STATUS_KEY];
    if(this.intent?.command && (this.session?.command!==this.intent.command || status?.owner===this.owner && status.command===this.intent.command && status.playing===this.intent.playing)){
      this.intent=null;clearTimeout(this.intentTimer);
    }
    this.settleOutput();this.options.changed?.();
  }
  get pendingOutput() { return this.outputIntent?.id || null; }
  settleOutput() {
    const intent=this.outputIntent,status=this.values[STATUS_KEY];if(!intent?.command)return;
    if(this.session?.command!==intent.command || status?.owner===intent.id && status.command===intent.command && !status.handoff && !status.loading && status.playing===intent.playing){this.outputIntent=null;clearTimeout(this.outputTimer);}
  }
  reset() { clearTimeout(this.outputTimer);this.outputIntent=null;clearTimeout(this.intentTimer);this.intent=null;this.generation++; if(this.wasOwner || this.wasRemote || this.owner && this.owner!==this.id)this.options.stop();this.values={};this.preparing=null;this.acknowledgedHandoff=null;this.activityAt=null;this.lastDisplay=null;this.applied=null;this.wasOwner=false;this.wasRemote=false;this.lastPresence=null;this.lastStatus=null;this.options.changed?.(); }
  async receive(values) {
    this.values=Object.fromEntries(Object.entries(values).filter(([key])=>key.startsWith('connect:')));
    const session=this.session, owner=session?.owner === this.id;
    if(this.wasOwner && !owner || this.remote && !this.wasRemote)this.options.stop();
    if(this.wasRemote && !this.remote)this.options.stop();
    this.wasOwner=owner;this.wasRemote=this.remote;
    if(owner && session.command !== this.applied && (Date.now()-session.at < COMMAND_MS || this.applied===null) && session.at <= Date.now()+10000) {
      const restored=this.applied===null && (this.values[STATUS_KEY]?.command===session.command || Date.now()-session.at>=ONLINE_MS) ? this.snapshot : null;
      this.applied=session.command; this.preparing=session.command; this.acknowledgedHandoff=null;
      const generation=this.generation;
      try {
        if(session.snapshot.handoff){
          if(!this.options.freeze)throw Error('Update this output before transferring playback.');
          await this.options.freeze();
        }else await this.options.apply(restored || session.snapshot);
        if(generation!==this.generation || this.owner!==this.id){this.options.stop();return;}
        if(this.applied!==session.command)return;
        this.preparing=null; this.acknowledgedHandoff=session.snapshot.handoff || null; this.publishStatus();
      }
      catch(error){if(generation===this.generation && this.owner===this.id)this.options.error?.(error.message);}
    } else if(this.remote && this.snapshot) this.options.mirror(this.snapshot, this.name, this.online);
    const display=this.values['connect:display.'+this.id];
    if(this.options.showLyrics && display?.target===this.id && display.action==='lyrics' &&
       /^[a-f0-9-]{36}$/i.test(display.id||'') && Number.isFinite(display.at) &&
       Date.now()-display.at>=-10000 && Date.now()-display.at<60000 && display.id!==this.lastDisplay){
      this.lastDisplay=display.id;await this.options.showLyrics(display);
      this.account.setConnectValues({['connect:display-status.'+this.id]:{id:display.id,target:this.id,at:Date.now()}});
      this.flush().catch(error=>this.options.error?.(error.message));
    }
    this.settleIntent();
  }
  flush() {
    // A publication during an in-flight exchange must be sent in a follow-up.
    this.flushPending=true;
    if(this.flushFlight)return this.flushFlight;
    this.flushFlight=(async()=>{while(this.flushPending){this.flushPending=false;await this.account.pollConnect();}})().finally(()=>{this.flushFlight=null;});
    return this.flushFlight;
  }
  playbackChanged() {
    if(!this.account.user || this.remote)return;
    this.activityAt=Date.now();this.lastStatus=0;
    this.publishStatus();
    if(!this.owner || this.owner!==this.id){
      const snapshot=this.options.snapshot();
      if(validSnapshot(snapshot)&&snapshot.queue.length)return this.announce(snapshot);
    }
    return this.flush();
  }
  showLyricsOn(target) {
    return this.enqueue(async generation=>{
      await this.refresh(generation);
      if(!this.devices.some(d=>d.id===target&&d.capabilities?.includes('lyricsDisplay')))throw Error('Open the updated Nova Music app on your Mac first.');
      const request={id:crypto.randomUUID(),target,action:'lyrics',at:Date.now()};
      this.account.setConnectValues({['connect:display.'+target]:request});
      await this.flush();return request;
    });
  }
  publishStatus() {
    if(this.preparing || !this.account.user || this.owner !== this.id || this.applied !== this.session?.command)return;
    const snapshot=this.options.snapshot();if(!validSnapshot(snapshot))return;
    this.account.setConnectValues({[STATUS_KEY]:{...snapshot,activityAt:this.activityAt??snapshot.activityAt??this.session.at,handoff:this.acknowledgedHandoff,owner:this.id,command:this.applied,at:Date.now()}});
  }
  async tick() {
    if(!this.account.user || this.ticking)return;
    this.ticking=true;try{
    if(!this.lastPresence || Date.now()-this.lastPresence>15000) {
      this.lastPresence=Date.now();this.account.setConnectValues({['connect:device.'+this.id]:{id:this.id,name:this.options.name,capabilities:this.options.showLyrics?['lyricsDisplay']:[],at:Date.now()}});
    }
    if(!this.lastStatus || Date.now()-this.lastStatus>5000){this.lastStatus=Date.now();this.publishStatus();}
    await this.account.pollConnect();
    // Signing in while a song is already playing must announce that output too.
    const local=this.options.snapshot();
    if(!this.session && (this.account.status==='synced'||this.account.playbackIndependent&&this.account.localConfiguration) && local?.playing && local.queue?.length && validSnapshot(local))await this.announce(local);
    }finally{this.ticking=false;}
  }
  enqueue(work) {
    const generation=this.generation;
    const pending=this.serial.catch(()=>{}).then(()=>work(generation));this.serial=pending;return pending;
  }
  async refresh(generation) {
    if(!this.account.user)throw Error('Sign in on both devices to connect playback.');
    if(this.account.playbackIndependent)await this.account.pollConnect();else await this.account.sync();
    if(generation!==this.generation)throw Error('The account changed.');
    if(!this.account.playbackIndependent&&['error','offline'].includes(this.account.status))throw Error('Could not reach your devices. Try again when connected.');
  }
  // Adopt audio the local user already started. Reapplying that snapshot can
  // pause a buffering engine or rewind it after the first audible samples.
  announce(snapshot) { return this.enqueue(generation=>this.send({...snapshot,positionIntent:'preserve'},this.id,generation,undefined,true)); }
  async send(snapshot, output, generation, expectedCommand, adoptLocal=false) {
    await this.refresh(generation);
    if(expectedCommand && this.session?.command!==expectedCommand)throw Error('Playback changed during transfer. Choose the output again.');
    const owner=output || (this.remote?this.owner:this.id);
    if(owner!==this.id && !this.devices.some(d=>d.id===owner))throw Error('That device is unavailable. Choose an output location.');
    const base=this.owner===this.id&&this.applied===this.session?.command?this.options.snapshot():this.snapshot||this.options.snapshot();
    const next=typeof snapshot === 'function' ? snapshot(base) : snapshot;
    if(!validSnapshot(next))throw Error('Only YouTube Music songs can be played across devices.');
    const session={owner,command:crypto.randomUUID(),at:Date.now(),snapshot:{...next,activityAt:Date.now(),at:Date.now()}};
    if(adoptLocal && owner===this.id){this.applied=session.command;this.wasOwner=true;this.preparing=null;this.acknowledgedHandoff=null;}
    this.account.setConnectValues({[SESSION_KEY]:session});
    const local=owner===this.id?this.receive({...this.values,...this.account.connectValues()}):null;
    if(adoptLocal)this.publishStatus();
    try{await this.refresh(generation);if(local)await local;return session;}
    catch(error){if(!adoptLocal && owner===this.id && this.session?.command===session.command)this.options.stop();throw error;}
  }
  command(snapshot, output) { return this.enqueue(generation=>this.send(snapshot,output,generation)); }
  seek(position) {
    return this.enqueue(async generation=>{
      const session=await this.send(s=>({...s,position:Math.max(0,Math.min(Number(position)||0,s.queue[s.index]?.duration||Infinity)),positionIntent:'seek'}),undefined,generation);
      if(session.owner===this.id)return session;
      const deadline=Date.now()+(this.options.seekTimeout||5000);
      while(Date.now()<deadline){
        if(this.session?.command!==session.command)return session;
        const status=this.values[STATUS_KEY];
        if(status?.owner===session.owner&&status.command===session.command&&!status.loading&&Math.abs(snapshotPosition(status)-snapshotPosition(session.snapshot))<2)return session;
        await new Promise(resolve=>setTimeout(resolve,this.options.pollDelay||25));await this.refresh(generation);
      }
      throw Error('The playing device did not confirm the new position. Keep both apps connected and try again.');
    });
  }
  transfer(output) {
    if(output===this.owner&&!this.outputIntent)return Promise.resolve(this.session);
    const intent={id:output};this.outputIntent=intent;clearTimeout(this.outputTimer);this.options.changed?.();
    this.outputTimer=setTimeout(()=>{if(this.outputIntent===intent){this.outputIntent=null;this.options.changed?.();this.options.error?.('The selected output did not respond. Choose another speaker.');}},30000);
    return this.enqueue(async generation=>{
      await this.refresh(generation);
      if(output===this.owner)return this.session;
      if(output!==this.id&&!this.devices.some(d=>d.id===output))throw Error('That device is unavailable. Choose an output location.');
      if(!this.session)return this.send(this.options.snapshot(),output,generation);
      const wasPlaying=this.snapshot?.playing ?? this.session.snapshot.playing;
      const checkpoint={...this.snapshot,playing:Boolean(wasPlaying),handoff:null};
      if(!this.online)return this.send(checkpoint,output,generation,this.session.command);
      if(this.owner===this.id&&this.options.freeze){
        const expected=this.session.command;await this.options.freeze();
        return this.send({...this.options.snapshot(),playing:Boolean(wasPlaying),handoff:null},output,generation,expected);
      }
      const handoff=crypto.randomUUID();
      const frozen=await this.send(s=>({...s,playing:false,handoff}),this.owner,generation);
      const deadline=Date.now()+(this.options.handoffTimeout || 4000);
      while(Date.now()<deadline){
        if(this.session?.command!==frozen.command)throw Error('Playback changed during transfer. Choose the output again.');
        const status=this.values[STATUS_KEY];
        if(status?.owner===frozen.owner&&status.command===frozen.command&&status.handoff===handoff&&!status.playing&&validSnapshot(status)){
          return this.send({...status,playing:Boolean(wasPlaying),handoff:null},output,generation,frozen.command);
        }
        await new Promise(resolve=>setTimeout(resolve,this.options.pollDelay||250));await this.refresh(generation);
      }
      if(this.account.playbackIndependent)throw Error('The previous output did not confirm its position. Keep both apps open and try again.');
      return this.send(checkpoint,output,generation,frozen.command);
    }).then(session=>{if(this.outputIntent===intent){intent.command=session.command;intent.playing=session.snapshot.playing;this.settleOutput();this.options.changed?.();}return session;},error=>{if(this.outputIntent===intent){this.outputIntent=null;clearTimeout(this.outputTimer);this.options.changed?.();}throw error;});
  }
}
