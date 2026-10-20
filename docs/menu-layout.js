// Position the menu at its trigger and keep it within the visible viewport.
export function menuPosition(point,size,viewport,gutter=8){
 return {
  left:Math.max(gutter,Math.min(point.x,viewport.width-size.width-gutter)),
  top:Math.max(gutter,Math.min(point.y,viewport.height-size.height-gutter)),
 };
}
