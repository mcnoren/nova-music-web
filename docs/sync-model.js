// The same record envelope is used by the website and iOS app.
// Tombstones retain removals, so an offline device cannot resurrect old entries.
import {validateProfile,defaultProfile} from './profile.js?v=45be314c1460';
export const SYNC_VERSION = 1;
const actorPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const keyPattern = /^[A-Za-z]+:[A-Za-z0-9_.:-]{1,240}$/;
const json = value => JSON.parse(JSON.stringify(value));
const stable = value => JSON.stringify(sortJSON(value));
function sortJSON(value) {
  if (Array.isArray(value)) return value.map(sortJSON);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortJSON(value[key])]));
  return value;
}
export function emptyDocument() { return {version: SYNC_VERSION, records: {}}; }
export function documentsEqual(left, right) { return stable(left) === stable(right); }
export function validateDocument(document) {
  if (!document || document.version !== SYNC_VERSION || !document.records || Array.isArray(document.records) || typeof document.records !== 'object') throw Error('This account has an unsupported library format.');
  const entries = Object.entries(document.records);
  if (entries.length > 30000 || JSON.stringify(document).length > 8_000_000) throw Error('This library exceeds the sync limit.');
  for (const [key, record] of entries) {
    if (!keyPattern.test(key) || !record || !Number.isSafeInteger(record.clock) || record.clock < 1 || !actorPattern.test(record.actor) || typeof record.deleted !== 'boolean' || (!record.deleted && !Object.hasOwn(record, 'value'))) throw Error('The synced library contains an invalid record.');
  }
  return document;
}
export function mergeDocuments(left, right) {
  validateDocument(left); validateDocument(right);
  const result = json(left);
  for (const [key, incoming] of Object.entries(right.records)) {
    const current = result.records[key];
    if (!current || incoming.clock > current.clock || (incoming.clock === current.clock && incoming.actor.toLowerCase() > current.actor.toLowerCase())) result.records[key] = json(incoming);
    else if (incoming.clock === current.clock && incoming.actor.toLowerCase() === current.actor.toLowerCase() && stable(incoming) !== stable(current)) throw Error('Two library records have the same revision but different contents. Sync stopped to protect your data.');
  }
  return result;
}
export function updateDocument(document, previous, next, actor) {
  validateDocument(document);
  if (!actorPattern.test(actor)) throw Error('Invalid sync device.');
  const result = json(document);
  let clock = Math.max(0, ...Object.values(result.records).map(record => record.clock));
  for (const key of [...new Set([...Object.keys(previous), ...Object.keys(next)])].sort()) {
    if (stable(previous[key]) === stable(next[key])) continue;
    if (!keyPattern.test(key)) throw Error('A library item has an invalid ID.');
    if (++clock > Number.MAX_SAFE_INTEGER) throw Error('The library revision limit was reached.');
    result.records[key] = {clock, actor: actor.toLowerCase(), deleted: !Object.hasOwn(next, key), ...(Object.hasOwn(next, key) ? {value: json(next[key])} : {})};
  }
  return result;
}
export function valuesOf(document) {
  validateDocument(document);
  return Object.fromEntries(Object.entries(document.records).filter(([, record]) => !record.deleted).map(([key, record]) => [key, json(record.value)]));
}
export function libraryValues(state, catalog) {
  const values = {}, knownSongs = new Map(catalog.songs.map(song => [song.id, song])), knownAlbums = new Map(catalog.albums.map(album => [album.id, album])), knownArtists = new Map(catalog.artists.map(artist => [artist.id, artist]));
  Object.values(state.extraSongs || {}).forEach(song => knownSongs.set(song.id, song));
  Object.values(state.extraAlbums || {}).forEach(album => knownAlbums.set(album.id, album));
  Object.values(state.extraArtists || {}).forEach(artist => knownArtists.set(artist.id, artist));
  const remoteSong = id => typeof id === 'string' && !id.startsWith('local-') && knownSongs.get(id)?.source !== 'local';
  const addSong = id => { const song = knownSongs.get(id); if (song && remoteSong(id)) values['song:' + id] = json(song); };
  for (const [name, key] of [['liked', 'liked'], ['saved', 'saved'], ['albums', 'savedAlbum'], ['artists', 'followedArtist'], ['artistPins', 'artistPin']]) {
    (state[name] || []).filter(id => !['liked', 'saved'].includes(name) || remoteSong(id)).forEach((id, order) => {
      values[key + ':' + id] = {id, order};
      if (name === 'liked' || name === 'saved') addSong(id);
    });
  }
  for (const [order, playlist] of (state.playlists || []).entries()) {
    const copy = json(playlist); copy.order = order; copy.songs = (copy.songs || []).filter(remoteSong);
    copy.songs.forEach(addSong);
    values['playlist:' + copy.id.toLowerCase()] = copy;
  }
  for (const [order, folder] of (state.folders || []).entries()) values['folder:' + folder.id.toLowerCase()] = {...json(folder), order};
  for (const [artist, ids] of Object.entries(state.releaseChoices || {})) values['releases:' + artist] = ids;
  for (const [album, discs] of Object.entries(state.discChoices || {})) values['discs:' + album] = discs;
  for (const item of state.recent || []) if (remoteSong(item.id)) { values['recent:' + item.id] = item; addSong(item.id); }
  values['preference:genres'] = state.genres || [];
  if(state.profile){const profile=validateProfile(state.profile);if(stable(profile)!==stable(defaultProfile()))values['profile:main']=profile;}
  const albumIDs = new Set([...(state.albums || []), ...Object.values(state.releaseChoices || {}).flat(), ...(state.folders || []).flatMap(folder => folder.items.filter(item => item.kind === 'album').map(item => item.id))]);
  for (const id of albumIDs) {
    const album = knownAlbums.get(id); if (!album) continue;
    const copy = json(album); copy.tracks = (copy.tracks || []).filter(remoteSong); copy.tracks.forEach(addSong);
    values['album:' + id] = copy;
  }
  for (const id of state.artists || []) if (knownArtists.has(id)) values['artist:' + id] = json(knownArtists.get(id));
  return values;
}
export function applyLibraryValues(state, values) {
  // Native-only record types remain in the document, even when the web UI has no editor for them.
  const next = json(state), list = prefix => Object.entries(values).filter(([key]) => key.startsWith(prefix + ':')).map(([, value]) => value);
  next.profile=values['profile:main']?validateProfile(values['profile:main']):defaultProfile();
  const validID = id => typeof id === 'string' && /^[A-Za-z0-9_.:-]{1,240}$/.test(id);
  const ids = prefix => list(prefix).filter(value => value && validID(value.id)).sort((a, b) => (a.order || 0) - (b.order || 0) || a.id.localeCompare(b.id)).map(value => value.id);
  const localIDs = key => (state[key] || []).filter(id => id.startsWith('local-'));
  next.liked = [...ids('liked'), ...localIDs('liked')]; next.saved = [...ids('saved'), ...localIDs('saved')];
  next.albums = ids('savedAlbum'); next.artists = ids('followedArtist'); next.artistPins = ids('artistPin');
  // Browsed metadata is a device cache, not saved-library membership. Keep it
  // through same-account sync so open collections and playback retain their tracks.
  // Account activation resets state before applying another account's records.
  next.extraSongs ||= {};
  for (const song of list('song')) {
    if (!song || !validID(song.id) || typeof song.title !== 'string' || typeof song.artist !== 'string' || song.source === 'local' || song.id.startsWith('local-')) throw Error('A synced song is invalid.');
    if (song.source !== 'youtube') throw Error('This recording source is not supported by account sync.');
    if (song.artwork && !isImageURL(song.artwork)) delete song.artwork;
    next.extraSongs[song.id] = song;
  }
  next.extraAlbums ||= {};
  for (const album of list('album')) {
    if (!album || !validID(album.id) || typeof album.title !== 'string' || typeof album.artist !== 'string' || !Array.isArray(album.tracks) || !album.tracks.every(validID)) throw Error('A synced album is invalid.');
    if (album.artwork && !isImageURL(album.artwork)) delete album.artwork;
    next.extraAlbums[album.id] = album;
  }
  next.extraArtists ||= {};
  for (const artist of list('artist')) {
    if (!artist || !validID(artist.id) || typeof artist.name !== 'string') throw Error('A synced artist is invalid.');
    if (artist.artwork && !isImageURL(artist.artwork)) delete artist.artwork;
    next.extraArtists[artist.id] = artist;
  }
  next.playlists = list('playlist').sort((a,b)=>(a.order||0)-(b.order||0)).map(playlist => {
    if (!playlist || !actorPattern.test(playlist.id) || typeof playlist.name !== 'string' || !Array.isArray(playlist.songs) || !playlist.songs.every(validID)) throw Error('A synced playlist is invalid.');
    if (playlist.artwork && !isImageURL(playlist.artwork)) delete playlist.artwork;
    const local = state.playlists?.find(item => item.id.toLowerCase() === playlist.id.toLowerCase());
    playlist.songs.push(...(local?.songs || []).filter(id => id.startsWith('local-')));
    return playlist;
  });
  next.folders = list('folder').sort((a,b)=>(a.order||0)-(b.order||0)).map(folder => {
    if (!folder || !actorPattern.test(folder.id) || typeof folder.name !== 'string' || !Array.isArray(folder.items) || !folder.items.every(item => item && ['album', 'playlist'].includes(item.kind) && validID(item.id))) throw Error('A synced folder is invalid.');
    folder.pins = Array.isArray(folder.pins) ? folder.pins.filter(value => typeof value === 'string') : [];
    return folder;
  });
  next.releaseChoices = {}; next.discChoices = {};
  for (const [key, value] of Object.entries(values)) {
    if (key.startsWith('releases:')) { if (!Array.isArray(value) || !value.every(validID)) throw Error('Invalid release selection.'); next.releaseChoices[key.slice(9)] = value; }
    if (key.startsWith('discs:')) { if (!Array.isArray(value) || !value.every(number => Number.isSafeInteger(number) && number > 0 && number < 1000)) throw Error('Invalid disc selection.'); next.discChoices[key.slice(6)] = value; }
  }
  next.recent = [...list('recent'),...(state.recent||[]).filter(item=>item.id.startsWith('local-'))].filter(item => item && validID(item.id) && Number.isFinite(item.at)).sort((a, b) => b.at - a.at).slice(0, 100);
  if (Array.isArray(values['preference:genres']) && values['preference:genres'].every(value => typeof value === 'string')) next.genres = values['preference:genres'];
  return next;
}
function isImageURL(value) { try { const url = new URL(value); return url.protocol === 'https:' || /^data:image\/(png|jpeg|webp);base64,/.test(value); } catch { return false; } }
