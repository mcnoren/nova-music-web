export const profileIcons=['♪','♫','🎧','🎵','⭐','🌙','🌸','🦋','⚡','💿','🎹','🚀'];
export const profileColors=['#1ed760','#a78bfa','#fb7185','#38bdf8','#fbbf24','#fb923c'];
export const defaultProfile=()=>({name:'',icon:'♪',color:'#1ed760',image:''});
export function validateProfile(value){
 if(!value||typeof value!=='object'||typeof value.name!=='string'||value.name.length>60||!profileIcons.includes(value.icon)||!profileColors.includes(value.color))throw Error('The profile icon is invalid.');
 const image=value.image||'';
 if(typeof image!=='string'||image.length>180000||(image&&!/^data:image\/(?:jpeg|png);base64,[A-Za-z0-9+/]+={0,2}$/.test(image)))throw Error('Choose a smaller PNG or JPEG profile photo.');
 return {name:value.name.trim(),icon:value.icon,color:value.color,image};
}
