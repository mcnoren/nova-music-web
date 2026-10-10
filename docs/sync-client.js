import {emptyDocument, validateDocument, mergeDocuments, updateDocument, valuesOf, documentsEqual} from './sync-model.js?v=21cc42183c54';

const SESSION = 'nova-music-auth-session-v1';
export const accountLibraryKey = id => 'nova-music-account-library-v1:' + id;
const documentKey = id => 'nova-music-sync-document-v1:' + id;
const actorKey = 'nova-music-sync-device-v1';
function read(key, fallback) { try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; } }

export class NovaSyncClient {
  constructor(config, callbacks) {
    this.config = config; this.callbacks = callbacks; this.session = null; this.document = emptyDocument();
    this.previous = {}; this.generation = 0; this.busy = false; this.status = 'signed-out'; this.lastSynced = null; this.connectDirty = true; this.serverRevision = null;
    this.actor = localStorage.getItem(actorKey) || crypto.randomUUID(); localStorage.setItem(actorKey, this.actor);
    this.configured = Boolean(config.url && config.publishableKey);
    if (this.configured) {
      const url = new URL(config.url);
      const localDevelopment = ['localhost','127.0.0.1'].includes(location.hostname) && ['localhost','127.0.0.1'].includes(url.hostname) && url.protocol === 'http:';
      if ((!localDevelopment && url.protocol !== 'https:') || url.username || url.password || url.pathname !== '/') throw Error('Account sync must use a secure project URL.');
      if (/^sb_secret_/.test(config.publishableKey) || isServiceKey(config.publishableKey)) throw Error('A secret key must never be used in the app or website.');
    }
    window.addEventListener('online', () => this.schedule(0));
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') this.schedule(0); });
    this.poll = setInterval(() => { if (document.visibilityState === 'visible') this.schedule(0); }, 30000);
  }
  get user() { return this.activeUser || null; }
  updateStatus(status, message = '') { this.status = status; this.message = message; this.callbacks.status?.(this); }
  async initialize() {
    if (!this.configured) return;
    let stored; try { stored = JSON.parse(sessionStorage.getItem(SESSION)); } catch { return; }
    if (!stored?.access_token || !stored?.refresh_token) return;
    const epoch = this.generation;
    try {
      this.session = stored;
      await this.token();
      const user = await this.request('/auth/v1/user', {authenticated: true});
      if (epoch !== this.generation) return;
      await this.activate({...this.session, user}, false);
    } catch (error) {
      if (epoch !== this.generation) return;
      this.session = null; this.activeUser = null; sessionStorage.removeItem(SESSION); window.novaDesktop?.post({type:'session',value:null}); this.updateStatus('signed-out', 'Sign in again to access your account library.');
    }
  }
  validateEmail(email) {
    this.requireConfiguration();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw Error('Enter a valid email address.');
  }
  async signIn(email, password, mergeGuest) {
    this.validateEmail(email);
    if (!password) throw Error('Enter your password.');
    const existingID = this.user?.id;
    if (existingID) this.changed();
    const session = await this.request('/auth/v1/token?grant_type=password', {method:'POST', body:{email,password}});
    if (!session.access_token || !session.refresh_token || !validUser(session.user)) throw Error('Sign-in did not return a valid session.');
    if (existingID && existingID !== session.user.id) throw Error('Sign in with the current account to preserve your pending changes.');
    await this.activate(session, existingID ? false : mergeGuest);
  }
  async createAccount(email, password) {
    this.validateEmail(email); validatePassword(password);
    const response = await this.request('/auth/v1/signup', {method:'POST',body:{email,password}});
    // Always require a deliberate password sign-in before importing a device library.
    if (response.access_token) {
      try { await this.request('/auth/v1/logout?scope=local',{method:'POST',token:response.access_token}); } catch {}
    }
  }
  async sendPasswordReset(email) {
    this.validateEmail(email);
    await this.request('/auth/v1/recover',{method:'POST',body:{email}});
  }
  async beginPasswordRecovery(accessToken) {
    this.requireConfiguration();
    const user = await this.request('/auth/v1/user',{token:accessToken});
    if (!validUser(user)) throw Error('This password reset link is invalid. Request a new link.');
    this.recovery = {token:accessToken,user};
    return user.email;
  }
  async finishPasswordRecovery(password) {
    validatePassword(password);
    if (!this.recovery) throw Error('Request a new password reset link.');
    const user = await this.request('/auth/v1/user',{method:'PUT',token:this.recovery.token,body:{password}});
    if (!validUser(user) || user.id !== this.recovery.user.id) throw Error('Password reset could not be confirmed.');
    const token = this.recovery.token; this.recovery = null;
    try { await this.request('/auth/v1/logout?scope=local',{method:'POST',token}); } catch {}
  }
  async activate(session, mergeGuest) {
    if (!validUser(session.user)) throw Error('Invalid account identity.');
    this.connectDirty = true; this.serverRevision = null;
    const epoch = ++this.generation, guestValues = mergeGuest ? this.callbacks.values() : null;
    this.session = session; this.activeUser = session.user; this.saveSession();
    this.document = validateDocument(read(documentKey(this.user.id), emptyDocument()));
    this.previous = valuesOf(this.document); this.appliedLibrary = null;
    const cached = read(accountLibraryKey(this.user.id), null);
    this.callbacks.activate(this.user, cached);
    if (guestValues) {
      const values = {...this.previous, ...guestValues};
      this.document = updateDocument(this.document, this.previous, values, this.actor);
      this.previous = values;
    }
    this.applyCurrent();
    this.updateStatus('syncing');
    if (epoch === this.generation) await this.sync();
  }
  changed() {
    if (!this.user || this.applying) return;
    try {
      const next = {...this.callbacks.values(), ...this.connectValues()};
      this.document = updateDocument(this.document, this.previous, next, this.actor);
      this.previous = next; this.connectDirty = true; this.saveDocument(); this.updateStatus('pending'); this.schedule();
    } catch (error) { this.updateStatus('error', error.message); }
  }
  schedule(delay = 700) { if (!this.user || !this.configured) return; clearTimeout(this.timer); this.timer = setTimeout(() => this.sync(), delay); }
  async sync() {
    if (this.inflight) return this.inflight;
    this.inflight = this.runSync().finally(() => { this.inflight = null; });
    return this.inflight;
  }
  async runSync() {
    if (!this.user || this.busy || !this.configured) return;
    const epoch = this.generation, userID = this.user.id;
    this.busy = true; this.updateStatus('syncing');
    try {
      for (let attempt = 0; attempt < 5; attempt++) {
        const rows = await this.request('/rest/v1/nova_music_libraries?select=document,revision&user_id=eq.' + encodeURIComponent(userID), {authenticated: true});
        this.assertCurrent(epoch, userID);
        if (!Array.isArray(rows) || rows.length > 1) throw Error('The sync service returned an unexpected response.');
        const remote = rows[0] ? validateDocument(rows[0].document) : emptyDocument();
        const candidate = mergeDocuments(this.document, remote), revision = rows[0]?.revision || 0;
        if (documentsEqual(candidate, remote)) {
          this.document = candidate; this.connectDirty = false; this.serverRevision = revision; this.applyCurrent(); this.lastSynced = Date.now(); this.updateStatus('synced'); return;
        }
        const result = await this.request('/rest/v1/rpc/save_nova_music_library', {method: 'POST', authenticated: true, body: {expected_revision: revision, library_document: candidate}});
        this.assertCurrent(epoch, userID);
        if (result.conflict) continue;
        if (!Number.isSafeInteger(result.revision) || result.revision <= revision) throw Error('The sync service did not confirm your changes.');
        // A user may edit while this request is in flight. Keep those newer records.
        this.document = mergeDocuments(candidate, this.document); this.connectDirty = !documentsEqual(this.document,candidate); this.serverRevision = result.revision; this.applyCurrent();
        if (!documentsEqual(this.document, candidate)) continue;
        this.lastSynced = Date.now(); this.updateStatus('synced');
        return;
      }
      throw Error('Another device is updating the library. Your changes remain saved here; sync will retry.');
    } catch (error) { if (epoch === this.generation) this.updateStatus(navigator.onLine ? 'error' : 'offline', error.message); }
    finally { this.busy = false; if (epoch !== this.generation && this.user) this.schedule(0); }
  }
  async pollConnect() {
    if(!this.user)return;
    if(this.connectDirty || this.serverRevision === null || ['error','offline'].includes(this.status)){await this.sync();return;}
    const epoch=this.generation,id=this.user.id;
    const rows=await this.request('/rest/v1/nova_music_libraries?select=revision&user_id=eq.'+encodeURIComponent(id),{authenticated:true});
    this.assertCurrent(epoch,id);
    if(!Array.isArray(rows)||rows.length>1)throw Error('Unexpected playback response.');
    if((rows[0]?.revision||0)!==this.serverRevision)await this.sync();
    else this.callbacks.connect?.(valuesOf(this.document));
  }
  connectValues() { return Object.fromEntries(Object.entries(valuesOf(this.document)).filter(([key])=>key.startsWith('connect:'))); }
  setConnectValues(values) {
    if (!this.user) return;
    if (Object.keys(values).some(key=>!key.startsWith('connect:'))) throw Error('Invalid playback record.');
    const previous=valuesOf(this.document),next={...previous,...values};
    this.document=updateDocument(this.document,previous,next,this.actor);
    this.previous={...this.previous,...values};this.connectDirty=true;this.saveDocument();
  }
  applyCurrent() {
    const values = valuesOf(this.document);
    this.applying = true;
    try {
      const library=JSON.stringify(sortLibrary(Object.fromEntries(Object.entries(values).filter(([key])=>!key.startsWith('connect:')))));
      if(library!==this.appliedLibrary){this.callbacks.apply(values);this.appliedLibrary=library;}
      this.previous = {...this.callbacks.values(),...this.connectValues()}; this.saveDocument();
      this.callbacks.connect?.(values);
    }
    finally { this.applying = false; }
  }
  async signOut() {
    if (!this.user) return;
    await this.sync();
    if (['error', 'offline', 'pending'].includes(this.status)) throw Error('Some changes have not synced. Go online and sync before signing out so those changes are preserved.');
    const old = this.session, id = this.user.id;
    ++this.generation; clearTimeout(this.timer); this.session = null; this.activeUser = null;
    sessionStorage.removeItem(SESSION); window.novaDesktop?.post({type:'session',value:null}); localStorage.removeItem(accountLibraryKey(id)); localStorage.removeItem(documentKey(id));
    this.document = emptyDocument(); this.previous = {}; this.callbacks.deactivate(); this.updateStatus('signed-out');
    try { await this.request('/auth/v1/logout?scope=local', {method: 'POST', token: old.access_token}); } catch { /* Local credentials have already been cleared. */ }
  }
  saveDocument() { if (this.user) localStorage.setItem(documentKey(this.user.id), JSON.stringify(this.document)); }
  saveSession() {
    if (this.session.expires_in && !this.session.expires_at) this.session.expires_at = Math.floor(Date.now() / 1000) + this.session.expires_in;
    sessionStorage.setItem(SESSION, JSON.stringify(this.session));
    window.novaDesktop?.post({type:'session',value:JSON.stringify(this.session)});
  }
  async token() {
    if (!this.session) throw Error('Sign in to sync your library.');
    if (this.session.expires_at > Date.now() / 1000 + 60) return this.session.access_token;
    if (!this.refreshing) {
      const epoch = this.generation;
      this.refreshing = this.request('/auth/v1/token?grant_type=refresh_token', {method: 'POST', body: {refresh_token: this.session.refresh_token}}).then(session => {
        if (epoch !== this.generation) throw Error('The account changed during sign-in.');
        if (!session.access_token || !session.refresh_token || !validUser(session.user) || session.user.id !== this.session?.user?.id) throw Error('Sign in again to continue syncing.');
        this.session = session; this.saveSession(); return session.access_token;
      }).finally(() => { this.refreshing = null; });
    }
    return this.refreshing;
  }
  async request(path, options = {}) {
    const token = options.token || (options.authenticated ? await this.token() : null);
    const response = await fetch(this.config.url.replace(/\/$/, '') + path, {method: options.method || 'GET', headers: {apikey: this.config.publishableKey, 'Content-Type': 'application/json', ...(token ? {Authorization: 'Bearer ' + token} : {})}, ...(options.body ? {body: JSON.stringify(options.body)} : {}), cache: 'no-store', signal: AbortSignal.timeout(20000)});
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw Error(response.status === 401 && options.authenticated ? 'Your session expired. Sign in again to sync.' : body.msg || body.message || body.error_description || 'Account sync could not complete. Your library remains saved here.');
    return body;
  }
  assertCurrent(epoch, id) { if (epoch !== this.generation || id !== this.user?.id) throw Error('The account changed while syncing.'); }
  requireConfiguration() { if (!this.configured) throw Error('Account sync is not available yet. Your library remains on this device.'); }
}
function sortLibrary(value) { if(Array.isArray(value))return value.map(sortLibrary);if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(key=>[key,sortLibrary(value[key])]));return value; }
function validUser(user) { return user && /^[0-9a-f-]{36}$/i.test(user.id) && typeof user.email === 'string'; }
function isServiceKey(key) { try { return JSON.parse(atob(key.split('.')[1])).role === 'service_role'; } catch { return false; } }

function validatePassword(password) { if (typeof password !== 'string' || password.length < 12) throw Error('Choose a password with at least 12 characters.'); }
export function parseAuthReturn(hash) {
  const params = new URLSearchParams(hash.replace(/^#/,''));
  if (!params.has('access_token') && !params.has('error_description')) return null;
  if (params.has('error_description')) return {type:'error',message:params.get('error_description').slice(0,500)};
  if (params.get('type') === 'recovery' && params.get('access_token') && hash.length < 20000) return {type:'recovery',token:params.get('access_token')};
  return {type:'confirmed'};
}
