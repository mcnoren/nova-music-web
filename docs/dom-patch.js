// Preserve images, focus, scroll positions and drag targets through background updates.
const key=node=>node.nodeType===1?(node.id||node.getAttribute('data-reorder-id')||node.getAttribute('data-key')||node.getAttribute('data-song-row')||''):'';
function compatible(a,b){return a&&a.nodeType===b.nodeType&&a.nodeName===b.nodeName&&key(a)===key(b);}
function update(current,next){
 if(current.nodeType!==1){if(current.nodeValue!==next.nodeValue)current.nodeValue=next.nodeValue;return;}
 for(const attribute of [...current.attributes])if(!next.hasAttribute(attribute.name))current.removeAttribute(attribute.name);
 for(const attribute of next.attributes)if(current.getAttribute(attribute.name)!==attribute.value)current.setAttribute(attribute.name,attribute.value);
 // Form state belongs to the user while they are editing.
 if(current===document.activeElement&&current.matches('input,textarea,select'))return;
 children(current,next);
}
function children(parent,next){
 const keyed=new Map([...parent.childNodes].filter(key).map(node=>[key(node),node]));
 let cursor=parent.firstChild;
 for(const wanted of [...next.childNodes]){
  let node=key(wanted)?keyed.get(key(wanted)):cursor;
  if(!compatible(node,wanted))node=wanted.cloneNode(true);
  if(node!==cursor)parent.insertBefore(node,cursor);
  update(node,wanted);cursor=node.nextSibling;
 }
 while(cursor){const old=cursor;cursor=cursor.nextSibling;old.remove();}
}
export function patchDOM(target,html){
 const active=document.activeElement,selection=active?.matches('input,textarea')?{start:active.selectionStart,end:active.selectionEnd,direction:active.selectionDirection}:null;
 const template=document.createElement('template');template.innerHTML=html;
 children(target,template.content);
 if(active?.isConnected&&target.contains(active)){
  if(document.activeElement!==active)active.focus({preventScroll:true});
  if(selection?.start!=null)active.setSelectionRange(selection.start,selection.end,selection.direction);
 }
}
