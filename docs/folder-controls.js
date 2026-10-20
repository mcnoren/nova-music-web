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
