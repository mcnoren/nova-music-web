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
    (value.at==null || Number.isFinite(value.at)) && (value.lyrics==null || validConnectedLyrics(value.lyrics));
}
export function snapshotPosition(snapshot, now = Date.now()) {
  const age=now-(snapshot.at ?? now);
  const elapsed = snapshot.playing && age<ONLINE_MS ? Math.max(0,age/1000) : 0;
  return Math.min(snapshot.queue[snapshot.index]?.duration || Infinity, snapshot.position + elapsed);
}
export class NovaConnect {
  constructor(account, options) {
    this.account = account; this.options = options; this.id = options.id;
    this.values = {}; this.applied = null; this.wasOwner = false; this.wasRemote = false; this.generation = 0; this.serial = Promise.resolve();
  }
  get devices() {
    const now = Date.now();
    return Object.entries(this.values).filter(([key,v]) => key.startsWith('connect:device.') && v && typeof v.id === 'string' && typeof v.name === 'string' && now-v.at < ONLINE_MS && v.at <= now+10000).map(([,v]) => v);
  }
  get session() { const s=this.values[SESSION_KEY]; return s && typeof s.owner === 'string' && typeof s.command === 'string' && Number.isFinite(s.at) && validSnapshot(s.snapshot) ? s : null; }
  get owner() { return this.session?.owner; }
  get remote() { return Boolean(this.account.user && this.owner && this.owner !== this.id); }
  get online() { return this.devices.some(d=>d.id === this.owner); }
  get name() { return this.devices.find(d=>d.id === this.owner)?.name || 'Unavailable device'; }
  get snapshot() {
    const status=this.values[STATUS_KEY], session=this.session;
    const snapshot=session && status?.owner === session.owner && status?.command === session.command && validSnapshot(status)?status:session?.snapshot;
    if(snapshot && Date.now()-(snapshot.at ?? session.at)>=ONLINE_MS)return {...snapshot,playing:false};
    return snapshot;
  }
  reset() { this.generation++; if(this.wasOwner || this.wasRemote || this.owner && this.owner!==this.id)this.options.stop();this.values={};this.applied=null;this.wasOwner=false;this.wasRemote=false;this.lastPresence=null;this.lastStatus=null;this.options.changed?.(); }
  async receive(values) {
    this.values=Object.fromEntries(Object.entries(values).filter(([key])=>key.startsWith('connect:')));
    const session=this.session, owner=session?.owner === this.id;
    if(this.wasOwner && !owner || this.remote && !this.wasRemote)this.options.stop();
    this.wasOwner=owner;this.wasRemote=this.remote;
    if(owner && session.command !== this.applied && (Date.now()-session.at < COMMAND_MS || this.applied===null) && session.at <= Date.now()+10000) {
      this.applied=session.command;
      const generation=this.generation;
      try { await this.options.apply(this.snapshot || session.snapshot); if(generation!==this.generation || this.owner!==this.id){this.options.stop();return;} this.publishStatus(); }
      catch(error){if(generation===this.generation && this.owner===this.id)this.options.error?.(error.message);}
    } else if(this.remote && this.snapshot) this.options.mirror(this.snapshot, this.name, this.online);
    this.options.changed?.();
  }
  publishStatus() {
    if(!this.account.user || this.owner !== this.id || this.applied !== this.session?.command)return;
    const snapshot=this.options.snapshot();if(!validSnapshot(snapshot))return;
    this.account.setConnectValues({[STATUS_KEY]:{...snapshot,owner:this.id,command:this.applied,at:Date.now()}});
  }
  async tick() {
    if(!this.account.user)return;
    if(!this.lastPresence || Date.now()-this.lastPresence>15000) {
      this.lastPresence=Date.now();this.account.setConnectValues({['connect:device.'+this.id]:{id:this.id,name:this.options.name,at:Date.now()}});
    }
    if(!this.lastStatus || Date.now()-this.lastStatus>5000){this.lastStatus=Date.now();this.publishStatus();}
    await this.account.pollConnect();
    // Signing in while a song is already playing must announce that output too.
    const local=this.options.snapshot();
    if(!this.session && this.account.status==='synced' && local?.playing && local.queue?.length && validSnapshot(local))await this.command(local);
  }
  command(snapshot, output) {
    // Serialize local gestures, refreshing the selected output before publishing intent.
    const generation=this.generation;
    const work=this.serial.catch(()=>{}).then(async()=>{
      if(!this.account.user)throw Error('Sign in on both devices to connect playback.');
      await this.account.sync();if(generation!==this.generation)throw Error('The account changed.');
      if(['error','offline'].includes(this.account.status))throw Error('Could not reach your devices. Try again when connected.');
      const owner=output || this.owner || this.id;
      if(owner!==this.id && !this.devices.some(d=>d.id===owner))throw Error('That device is unavailable. Choose an output location.');
      const base=this.owner===this.id&&this.applied===this.session?.command?this.options.snapshot():this.snapshot||this.options.snapshot();
      const next=typeof snapshot === 'function' ? snapshot(base) : snapshot;
      if(!validSnapshot(next))throw Error('Only YouTube Music songs can be played across devices.');
      const session={owner,command:crypto.randomUUID(),at:Date.now(),snapshot:{...next,at:Date.now()}};
      this.account.setConnectValues({[SESSION_KEY]:session});
      await this.account.sync();if(generation!==this.generation)return;
      if(['error','offline'].includes(this.account.status))throw Error('Playback change could not be sent. Check your connection.');
    });this.serial=work;return work;
  }
  transfer(output) { return this.command(s=>({...s,position:snapshotPosition(s)}), output); }
}
