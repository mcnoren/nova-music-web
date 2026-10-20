export const collectionKey=item=>item.kind+':'+item.id;
export function collectionCandidates(result){
 return [
  ...(result.albums||[]).map(a=>({kind:'album',id:a.id,name:a.title,detail:a.artist||'Album',artwork:a.artwork})),
  ...(result.playlists||[]).map(p=>({kind:'public-playlist',id:p.id,name:p.name||p.title,detail:p.author||'Playlist',artwork:p.artwork})),
 ];
}
// Keep separate cursors: Albums and Playlists are independent catalog searches.
export async function searchCollections(client,query,{signal,cursors=null}={}){
 const kinds=['Albums','Playlists'];
 const pages=await Promise.all(kinds.map(async kind=>{
  const cursor=cursors?.[kind];if(cursors&&!cursor)return {kind,items:[],cursor:''};
  const result=await client.request({query,kind,providerOrder:true,...(cursor?{cursor}:{})},{signal});
  return {kind,items:collectionCandidates(kind==='Albums'?{albums:result.albums}:{playlists:result.playlists}),cursor:result.cursor===cursor?'':result.cursor||''};
 }));
 return {items:pages.flatMap(p=>p.items),cursors:Object.fromEntries(pages.map(p=>[p.kind,p.cursor]))};
}
export function sameFolderSlot(folder,index,original){return Boolean(folder?.items[index]&&collectionKey(folder.items[index])===collectionKey(original));}
