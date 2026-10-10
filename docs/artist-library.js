import {normalizeSearch} from './music-search.js?v=4098b6ac99a2';
export const releaseKind=release=>/^(single|ep)$/i.test(release.kind||release.type||'')?'Singles & EPs':'Albums';
export function artistReleases(artist,albums,songs,selected){
 const chosen=new Set(selected||[]),tracks=new Map(songs.map(song=>[song.id,song]));
 return [...new Map(albums.filter(album=>chosen.has(album.id)||album.artistId===artist.id||normalizeSearch(album.artist)===normalizeSearch(artist.name)||(album.tracks||[]).some(id=>tracks.get(id)?.artistId===artist.id)).map(album=>[album.id,album])).values()].sort((a,b)=>String(b.releaseDate||b.native?.releaseDate||b.year||'').localeCompare(String(a.releaseDate||a.native?.releaseDate||a.year||''))||a.title.localeCompare(b.title));
}
export function chosenReleases(releases,selection){return selection===undefined?releases:releases.filter(release=>selection.includes(release.id))}
export function releaseTracks(releases,songs,discs={}){
 const tracks=new Map(songs.map(song=>[song.id,song])),seen=new Set();
 return releases.flatMap(release=>(release.tracks||[]).map(id=>tracks.get(id)).filter(song=>song&&(!discs[release.id]||discs[release.id].includes(song.discNumber||1))&&!seen.has(song.id)&&seen.add(song.id)));
}
export function selectedTopSongs(ranked,selected){
 const ids=new Set(selected.map(song=>song.id)),titles=new Set(selected.map(song=>normalizeSearch(song.title)+'|'+normalizeSearch(song.artist)));
 return ranked.filter(song=>ids.has(song.id)||titles.has(normalizeSearch(song.title)+'|'+normalizeSearch(song.artist)));
}
