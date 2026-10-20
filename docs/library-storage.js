// The website keeps library metadata and imported audio in this tab's memory.
// Native apps retain their offline library. Existing web data is read only to
// allow users to migrate it to iCloud; visiting the site never deletes it.
export function createLibraryStorage({persistent,legacy}={}) {
 const memory=new Map();
 return {
  getItem(key){if(memory.has(key))return memory.get(key);try{return (persistent||legacy)?.getItem(key)??null}catch{return null}},
  setItem(key,value){memory.set(key,String(value));if(persistent)try{persistent.setItem(key,String(value))}catch{/* Keep changes in memory; cloud sync still runs. */}},
  removeItem(key){memory.set(key,null);if(persistent)try{persistent.removeItem(key)}catch{}},
 };
}
const storageStateKey=Symbol.for('nova.music.libraryStorage');
const shared=globalThis[storageStateKey]??=( {} );
function currentStorage(){
 let deviceStorage;try{deviceStorage=globalThis.localStorage}catch{}
 const isNative=Boolean(globalThis.window?.novaDesktop);
 if(!shared.adapter||shared.backend!==deviceStorage||shared.native!==isNative){shared.backend=deviceStorage;shared.native=isNative;shared.adapter=createLibraryStorage(isNative?{persistent:deviceStorage}:{legacy:deviceStorage});}
 return shared.adapter;
}
export const libraryStorage={getItem:key=>currentStorage().getItem(key),setItem:(key,value)=>currentStorage().setItem(key,value),removeItem:key=>currentStorage().removeItem(key)};
