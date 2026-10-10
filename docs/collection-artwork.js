export const artworkSymbols={'folder.fill':'folder','music.note':'note','music.note.list':'queue','star.fill':'star','heart.fill':'heart',sparkles:'sparkles','moon.fill':'moon','sun.max.fill':'sun',pianokeys:'classical','guitars.fill':'guitar'};
export function validateCollectionArtwork(value){
 if(value==null)return null;
 if(!value||!['icon','photo','collage'].includes(value.style))throw Error('Invalid playlist artwork.');
 if(value.style==='photo'){
  if(typeof value.image!=='string'||value.image.length>600000||!/^data:image\/jpeg;base64,[A-Za-z0-9+/]+={0,2}$/.test(value.image))throw Error('Invalid playlist photo.');
  return {style:'photo',image:value.image};
 }
 if(value.style==='icon'){
  if(!Object.hasOwn(artworkSymbols,value.symbol))throw Error('Invalid playlist icon.');
  return {style:'icon',symbol:value.symbol};
 }
 return {style:'collage'};
}
export function playlistCovers(playlist,songs){
 const tracks=new Map(songs.map(song=>[song.id,song])),albums=new Set(),urls=new Set();
 return [playlist.artwork,...(playlist.songs||[]).map(id=>tracks.get(id)).filter(song=>{const album=song?.albumId||(song?.album? song.artist+'|'+song.album:'');if(album&&albums.has(album))return false;if(album)albums.add(album);return true}).map(song=>song?.artwork)].filter(url=>url&&!urls.has(url)&&urls.add(url));
}
