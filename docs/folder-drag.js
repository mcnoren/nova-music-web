// Cross a card's midpoint before moving its slot, so the layout stays steady.
export function dragDestination(current,candidate,point,rects,gallery=false) {
 if(candidate<0||candidate===current)return current;
 const target=rects[candidate],source=rects[current];
 if(!target||!source)return current;
 const sameLine=gallery&&Math.abs(target.top-source.top)<Math.min(target.height,source.height)/2;
 const position=sameLine?point.x:point.y;
 const midpoint=sameLine?target.left+target.width/2:target.top+target.height/2;
 return (candidate>current?position>=midpoint:position<=midpoint)?candidate:current;
}

export function startFolderDrag(event,{row=event.target.closest('[data-reorder-index]'),container=row?.parentElement,onStart,onDrop,onEnd}) {
 if(!row||!container||event.isPrimary===false||document.body.classList.contains('folder-drag-active'))return;
 event.preventDefault();
 const pointer=event.pointerId,handle=container;
 const original=[...container.children],from=Number(row.dataset.reorderIndex),bounds=row.getBoundingClientRect();
 const scroller=container.closest('.scroll-list,#panel-body,.workspace'),gallery=container.classList.contains('folder-gallery');
 const reduced=matchMedia('(prefers-reduced-motion: reduce)').matches;
 const preview=row.cloneNode(true),offset={x:event.clientX-bounds.left,y:event.clientY-bounds.top};
 preview.removeAttribute('data-folder-index');preview.removeAttribute('data-reorder-index');preview.querySelectorAll('[id]').forEach(el=>el.removeAttribute('id'));
 preview.setAttribute('aria-hidden','true');preview.classList.add('folder-drag-preview');
 if(gallery)preview.classList.add('folder-drag-gallery');
 Object.assign(preview.style,{width:bounds.width+'px',height:bounds.height+'px',left:'0',top:'0'});
 document.body.append(preview);row.classList.add('folder-drag-slot');document.body.classList.add('folder-drag-active');
 handle.setPointerCapture(pointer);onStart();
 let point={x:event.clientX,y:event.clientY},frame=0,ended=false,lastTime=performance.now();
 const animations=new Map();
 const lift=reduced?null:preview.animate([{scale:'1'},{scale:'1.025'}],{duration:180,easing:'cubic-bezier(.2,.8,.2,1)',fill:'forwards'});
 function place(){preview.style.transform=`translate3d(${point.x-offset.x}px,${point.y-offset.y}px,0)`;}
 place();
 function rearrange(target){
  const rows=[...container.children],current=rows.indexOf(row),candidate=rows.indexOf(target);
  const before=rows.map(el=>el.getBoundingClientRect());
  const destination=dragDestination(current,candidate,point,before,gallery);
  if(destination===current)return;
  // Capture the current visual position before interrupting the previous FLIP.
  for(const animation of animations.values())animation.cancel();animations.clear();
  container.insertBefore(row,destination>current?target.nextSibling:target);
  if(reduced)return;
  for(let i=0;i<rows.length;i++){
   const el=rows[i],after=el.getBoundingClientRect(),dx=before[i].left-after.left,dy=before[i].top-after.top;
   if(el===row||(!dx&&!dy))continue;
   const animation=el.animate([{transform:`translate(${dx}px,${dy}px)`},{transform:'translate(0,0)'}],{duration:240,easing:'cubic-bezier(.2,.8,.2,1)'});
   animations.set(el,animation);animation.onfinish=()=>{if(animations.get(el)===animation)animations.delete(el);};
  }
 }
 function tick(now){
  if(ended)return;
  if(!container.isConnected){finish(true);return;}
  const delta=Math.min(32,now-lastTime);lastTime=now;
  if(scroller){
   const rect=scroller.getBoundingClientRect(),edge=72;
   const speed=point.y<rect.top+edge?-Math.min(1,(rect.top+edge-point.y)/edge):point.y>rect.bottom-edge?Math.min(1,(point.y-rect.bottom+edge)/edge):0;
   scroller.scrollTop+=speed*Math.abs(speed)*delta*.8;
  }
  place();
  const target=document.elementFromPoint(point.x,point.y)?.closest('[data-reorder-index]');
  if(target?.parentElement===container)rearrange(target);
  frame=requestAnimationFrame(tick);
 }
 function preventScroll(e){e.preventDefault();}
 function move(e){if(e.pointerId!==pointer||ended)return;e.preventDefault();point={x:e.clientX,y:e.clientY};}
 async function finish(cancel=false){
  if(ended)return;ended=true;cancelAnimationFrame(frame);
  document.removeEventListener('touchmove',preventScroll);
  document.removeEventListener('pointermove',move);document.removeEventListener('pointerup',up);document.removeEventListener('pointercancel',abort);
  document.removeEventListener('keydown',key);window.removeEventListener('blur',abort);handle.removeEventListener('lostpointercapture',lost);
  if(handle.hasPointerCapture(pointer))handle.releasePointerCapture(pointer);
  if(cancel&&container.isConnected)original.forEach(el=>container.append(el));
  const slot=[...container.children].indexOf(row),to=Number(original[slot]?.dataset.reorderIndex),target=row.getBoundingClientRect();
  const scale=getComputedStyle(preview).scale;lift?.cancel();preview.style.scale=scale;
  if(!reduced&&container.isConnected){
   const animation=preview.animate([{transform:preview.style.transform,scale},{transform:`translate3d(${target.left}px,${target.top}px,0)`,scale:'1',boxShadow:'0 0 0 0 transparent'}],{duration:210,easing:'cubic-bezier(.2,.8,.2,1)',fill:'forwards'});
   await animation.finished.catch(()=>{});
  }
  for(const animation of animations.values())animation.cancel();
  preview.remove();row.classList.remove('folder-drag-slot');document.body.classList.remove('folder-drag-active');
  if(!cancel&&to>=0)onDrop(from,to);onEnd();
 }
 function up(e){if(e.pointerId===pointer)finish();}
 function abort(e){if(e.pointerId===undefined||e.pointerId===pointer)finish(true);}
 function lost(e){if(e.pointerId===pointer)finish(true);}
 function key(e){if(e.key==='Escape'){e.preventDefault();finish(true);}}
 document.addEventListener('touchmove',preventScroll,{passive:false});
 document.addEventListener('pointermove',move,{passive:false});document.addEventListener('pointerup',up);document.addEventListener('pointercancel',abort);
 document.addEventListener('keydown',key);window.addEventListener('blur',abort);handle.addEventListener('lostpointercapture',lost);
 frame=requestAnimationFrame(tick);
}
