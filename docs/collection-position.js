export function collectionContext(kind,id){
 if(!['album','playlist','public-playlist','chart'].includes(kind)||typeof id!=='string'||! /^[A-Za-z0-9_.:-]{1,200}$/.test(id))return null;
 return kind+':'+(kind==='playlist'?id.toLowerCase():id);
}
export function validCollectionContext(value){return typeof value==='string'&&value===collectionContext(value.slice(0,value.indexOf(':')),value.slice(value.indexOf(':')+1));}
export function rememberCollection(state,context,songID,at=Date.now()){
 if(!validCollectionContext(context)||typeof songID!=='string'||! /^[A-Za-z0-9_.:-]{1,240}$/.test(songID))return false;
 state.collectionPositions ||= {};
 if(state.collectionPositions[context]?.songID===songID)return false;
 state.collectionPositions[context]={songID,at};return true;
}
export function collectionSong(state,context){return state.collectionPositions?.[context]?.songID;}
