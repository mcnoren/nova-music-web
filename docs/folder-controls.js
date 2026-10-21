export function moveFolderItem(folder, from, to) {
 if(!Number.isInteger(from)||!Number.isInteger(to)||from<0||to<0||from>=folder.items.length||to>=folder.items.length)return false;
 const [item]=folder.items.splice(from,1);folder.items.splice(to,0,item);return true;
}
export function replaceFolderItem(folder,index,item) {
 if(!folder.items[index]||!['album','playlist'].includes(item.kind)||!item.id)return false;
 if(folder.items.some((other,i)=>i!==index&&other.kind===item.kind&&other.id===item.id))return false;
 const old=folder.items[index],key=old.kind+':'+old.id;
 folder.items[index]={kind:item.kind,id:item.id};
 folder.pins=(folder.pins||[]).map(pin=>pin===key?item.kind+':'+item.id:pin);return true;
}
export function sidebarSelection(entries,limited=true) {
 const types=[...new Set(entries.map(e=>e.type))];
 return types.flatMap(type=>{
  const list=entries.filter(e=>e.type===type).sort((a,b)=>Number(Boolean(b.pinned))-Number(Boolean(a.pinned))||(b.visited||0)-(a.visited||0));
  return limited?list.slice(0,Math.max(5,list.filter(e=>e.pinned).length)):list;
 });
}

// Library membership is independent of membership in any folder.
export function removePlaylistFromLibrary(state,id) {
 const playlist=state.playlists.find(p=>p.id===id);
 if(!playlist)return false;
 if(state.folders.some(f=>f.items.some(i=>i.kind==='playlist'&&i.id===id))){
  playlist.folderOnly=true;
  // A removed saved copy keeps its songs; it must not become a live YouTube reference.
  playlist.folderReference=false;
 }else state.playlists=state.playlists.filter(p=>p.id!==id);
 state.libraryPins=(state.libraryPins||[]).filter(href=>href!=='#playlist/'+encodeURIComponent(id));
 return true;
}
