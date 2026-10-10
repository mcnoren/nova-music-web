import {artistReleases,chosenReleases,releaseKind,releaseTracks,selectedTopSongs} from './artist-library.js?v=1694e5d06308';
import {validateCollectionArtwork,playlistCovers,artworkSymbols} from './collection-artwork.js?v=4aab16fb9b27';
import {NativeMusicPlayer} from './native-player.js?v=1cdf7f0c2811';
import {PlaybackHealth} from './playback-health.js?v=99516753ecf6';
import {applyPlayerCommand} from './connected-player.js?v=c72dd78f29fd';
import {parsePlaylistCSV, parseSongList, matchPlaylist, playlistReviewEntries, unmatchedKey, pairPlaylistEntry} from './playlist-import.js?v=078a6692de98';
import {defaultProfile, validateProfile, profileIcons, profileColors} from './profile.js?v=45be314c1460';
import {parseLRC, lookupLyrics, lyricData as providerLyricData, activeLyric, normalizedLines, playbackSample, preferredAudio} from './lyrics.js?v=8ecae04bc17e';
import {MusicSearchClient, rankLocal, mergeResults, normalizeSearch, rankSearch, providerItems} from './music-search.js?v=4098b6ac99a2';
import {syncConfig} from './sync-config.js?v=ebe8169ae84b';
import {NovaSyncClient, accountLibraryKey, parseAuthReturn} from './sync-client.js?v=b98686ee6edd';
import {libraryValues, applyLibraryValues} from './sync-model.js?v=013a31f554e0';
import {NovaConnect, snapshotPosition} from './connect.js?v=5fe39a74171c';
let accountClient = null, connect = null, applyingConnectedPlayback = false, mirroredPlayback = null;
const authReturn=parseAuthReturn(location.hash);
if(authReturn)history.replaceState(null,'',location.pathname+location.search);
const paths={home:'<path d="m3 10 9-7 9 7v10H3zM9 20v-7h6v7"/>',discover:'<circle cx="12" cy="12" r="9"/><path d="m10 8 6 4-6 4z"/>',classical:'<path d="M3 4h18v16H3zM7 4v16M12 4v16M17 4v16M6 4v8M11 4v8M16 4v8"/>',library:'<path d="M4 4h4v16H4zM11 4h4v16h-4zM18 3l3 16-3 1-3-16z"/>',search:'<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',play:'<path d="m8 5 11 7-11 7z"/>',pause:'<path d="M8 5v14M16 5v14"/>',next:'<path d="m5 5 10 7-10 7zM19 5v14"/>',previous:'<path d="m19 5-10 7 10 7zM5 5v14"/>',shuffle:'<path d="M3 7h3c5 0 7 10 12 10h3m-4-4 4 4-4 4M3 17h3c2 0 4-2 6-5m2-3c1-1 3-2 4-2h3m-4-4 4 4-4 4"/>',repeat:'<path d="M4 9V7a3 3 0 0 1 3-3h11l-3-3m3 3-3 3M20 15v2a3 3 0 0 1-3 3H6l3 3m-3-3 3-3"/>',heart:'<path d="M20.8 4.6a5.4 5.4 0 0 0-7.7 0L12 5.8l-1.1-1.2a5.4 5.4 0 0 0-7.7 7.7L12 21l8.8-8.7a5.4 5.4 0 0 0 0-7.7z"/>',plus:'<path d="M12 5v14M5 12h14"/>',settings:'<path d="m9 3-1 3-3 1 1 3-2 2 2 2-1 3 3 1 1 3h6l1-3 3-1-1-3 2-2-2-2 1-3-3-1-1-3z"/><circle cx="12" cy="12" r="3"/>',back:'<path d="m15 5-7 7 7 7"/>',more:'<circle cx="12" cy="5" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="12" cy="19" r="1"/>',queue:'<path d="M3 6h14M3 12h14M3 18h9m4-2 5 3-5 3z"/>',lyrics:'<path d="M4 4h16v13H9l-5 4zM8 8h8M8 12h5"/>',volume:'<path d="M3 9h4l5-5v16l-5-5H3zM16 8c3 2 3 6 0 8M19 5c5 4 5 10 0 14"/>',folder:'<path d="M3 7V4h7l3 3h8v13H3z"/>',album:'<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/>',artist:'<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2"/>',clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',download:'<path d="M12 3v12m-5-5 5 5 5-5M4 17v4h16v-4"/>',pin:'<path d="m9 3-1 7-3 4h14l-3-4-1-7zM12 14v7"/>',check:'<path d="m5 12 4 4L19 6"/>',info:'<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',expand:'<path d="M8 3H3v5M16 3h5v5M21 16v5h-5M3 16v5h5"/>',screen:'<rect x="2" y="3" width="20" height="14" rx="2"/><path d="M8 21h8M12 17v4"/>',up:'<path d="m6 15 6-6 6 6"/>',down:'<path d="m6 9 6 6 6-6"/>',trash:'<path d="M3 6h18M8 6V3h8v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>'};
Object.assign(paths,{note:'<path d="M9 18V5l11-2v13M9 8l11-2"/><ellipse cx="6" cy="18" rx="3" ry="2"/><ellipse cx="17" cy="16" rx="3" ry="2"/>',star:'<path d="m12 2 3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1z"/>',sparkles:'<path d="m12 3 2 6 6 3-6 2-2 6-2-6-6-2 6-3zM20 2v4M18 4h4"/>',moon:'<path d="M20 15A9 9 0 0 1 9 4a9 9 0 1 0 11 11z"/>',sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2"/>',guitar:'<path d="m14 10 6-7 2 2-7 7c2 4 0 7-4 6-1 4-5 4-8 1s-2-7 2-8c-1-4 3-5 7-3z"/><circle cx="9" cy="15" r="2"/>'});
const icon=name=>`<svg viewBox="0 0 24 24" aria-hidden="true">${paths[name]||paths.album}</svg>`;
const $=(s,root=document)=>root.querySelector(s), $$=(s,root=document)=>[...root.querySelectorAll(s)];
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const norm=normalizeSearch;
const time=n=>`${Math.floor((Number(n)||0)/60)}:${String(Math.floor((Number(n)||0)%60)).padStart(2,'0')}`;
const art=(url,cls='',alt='')=>url?`<img class="${cls}" src="${esc(url)}" alt="${esc(alt)}" loading="lazy" referrerpolicy="no-referrer">`:`<span class="art-placeholder ${cls}">♪</span>`;
const btn=(label,action,extra='',cls='secondary')=>`<button class="${cls}" data-action="${action}" ${extra}>${label}</button>`;
const empty=(title,description,action='')=>`<div class="empty"><h2>${esc(title)}</h2><p>${esc(description)}</p>${action}</div>`;
const KEY='nova-music-web-v1';
const defaults={profile:defaultProfile(),version:1,liked:[],saved:[],albums:[],artists:[],artistPins:[],releaseChoices:{},discChoices:{},playlists:[],folders:[],recent:[],extraSongs:{},extraAlbums:{},extraArtists:{},genres:['Pop','Rock','Electronic','R&B','Hip-hop','Jazz','Classical'],settings:{volume:80,lyricsOffset:0,lyricsOffsets:{},explicit:true,youtubeKey:'',spotifyClientId:''}};
let state;try{state={...structuredClone(defaults),...JSON.parse(localStorage.getItem(KEY)||'{}')};state.settings={...defaults.settings,...state.settings}}catch{state=structuredClone(defaults)}
let catalog={songs:[],albums:[],artists:[],composers:[],works:[],shelves:{}}, songs=new Map(),albums=new Map(),artists=new Map();
let routeToken=0,mood='For you',queue=[],queueIndex=-1,current=null,playing=false,shuffle=false,repeat=0,panelTab='song',lyricData=null,lyricToken=0,yt=null,ytPromise=null,seekDragging=false;
const audio=$('#audio');
function persist(){try{localStorage.setItem(accountClient?.user?accountLibraryKey(accountClient.user.id):KEY,JSON.stringify(state))}catch{toast('Your device storage is full. Export a library backup in Settings.')}sidebar();accountClient?.changed()}
function toast(message){const host=$('#modal').open?$('#modal'):$('#lyrics-fullscreen')?.open?$('#lyrics-fullscreen'):document.body;host.append($('#toast'));$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(toast.timer);toast.timer=setTimeout(()=>$('#toast').classList.remove('visible'),4200)}
function icons(root=document){$$('[data-icon]',root).forEach(el=>el.innerHTML=icon(el.dataset.icon))}
function remember(list){for(const song of list){songs.set(song.id,song);if(!catalog.songs.some(s=>s.id===song.id))state.extraSongs[song.id]=song}}
function getSongs(ids){return [...new Set(ids)].map(id=>songs.get(id)).filter(Boolean).filter(s=>state.settings.explicit||!s.explicit)}
function albumTracks(album){return getSongs(album?.tracks||[])}
function releasesForArtist(id){return artistReleases(artists.get(id)||{id,name:''},[...albums.values()],[...songs.values()],state.releaseChoices[id])}
function selectedArtistTracks(id){return releaseTracks(chosenReleases(releasesForArtist(id),state.releaseChoices[id]),[...songs.values()],state.discChoices).filter(s=>state.settings.explicit||!s.explicit)}
function playlistArtistId(p){return Object.hasOwn(p,'artistId')?p.artistId:p.native?.artist?.id||''}
function playlistCover(p,cls='',alt=p.name){
 const choice=Object.hasOwn(p,'collectionArtwork')?p.collectionArtwork:(p.native?.customArtwork?.style!=='photo'?p.native?.customArtwork:null);
 if(choice?.style==='photo')return art(choice.image,cls,alt);
 if(choice?.style==='icon')return `<span class="collection-icon ${cls}" role="img" aria-label="${esc(alt)}">${icon(artworkSymbols[choice.symbol])}</span>`;
 if(choice?.style==='collage'){const covers=playlistCovers({...p,songs:playlistSongs(p).map(s=>s.id)},[...songs.values()]).slice(0,4);return `<span class="collection-collage ${cls}" role="img" aria-label="${esc(alt)}">${Array.from({length:4},(_,i)=>art(covers.length?covers[i%covers.length]:'','','')).join('')}</span>`}
 return art(p.artwork||playlistSongs(p)[0]?.artwork,cls,alt);
}
let showingAllArtistReleases=new Set(),showingAllArtistTopSongs=new Set();
async function loadArtistSelection(id){for(const albumId of state.releaseChoices[id]||[]){let page=await loadCollection(albumId);const seen=new Set();while(page.cursor&&!seen.has(page.cursor)){seen.add(page.cursor);page=await loadCollection(albumId,true)}}}

function orderedArtists(){return state.artists.map(id=>artists.get(id)).filter(Boolean).sort((a,b)=>Number(state.artistPins.includes(b.id))-Number(state.artistPins.includes(a.id)))}
function playlistSongs(p){if(!p)return[];if(!p.rules)return getSongs(p.songs||[]);const filters=(p.rules.artists?.length?p.rules.artists:(p.rules.artist||'').split(',')).map(norm).filter(Boolean);let list=getSongs(p.rules.source==='saved'?state.saved:state.liked).filter(s=>(!filters.length||filters.some(a=>norm(s.artist).includes(a)))&&(!p.rules.title||norm(s.title).includes(norm(p.rules.title)))&&(!p.rules.album||norm(s.album).includes(norm(p.rules.album))));if(p.rules.sort==='title')list.sort((a,b)=>a.title.localeCompare(b.title));if(p.rules.sort==='artist')list.sort((a,b)=>a.artist.localeCompare(b.artist));return p.rules.limit?list.slice(0,p.rules.limit):list}
function folderTracks(folder){return getSongs((folder?.items||[]).flatMap(item=>item.kind==='album'?albums.get(item.id)?.tracks||[]:playlistSongs(state.playlists.find(p=>p.id===item.id)).map(s=>s.id)))}
let libraryFilter='All',libraryQuery='';
function sidebar(){
 renderAvatar();
 const entries=[...(playlistReviewEntries(state.playlists).length?[{id:'review',href:'#review',name:'Songs to review',type:'Playlists',detail:playlistReviewEntries(state.playlists).length+' to pair',symbol:'check'}]:[]),{id:'liked',href:'#liked',name:'Liked Songs',type:'Playlists',detail:state.liked.length+' songs',symbol:'heart',special:'liked'},...state.playlists.map(p=>({id:p.id,href:'#playlist/'+encodeURIComponent(p.id),name:p.name,type:'Playlists',detail:p.rules?'Smart playlist':'Playlist',artwork:p.artwork||playlistSongs(p)[0]?.artwork,playlist:p,symbol:'queue'})),...state.folders.map(f=>({id:f.id,href:'#folder/'+encodeURIComponent(f.id),name:f.name,type:'Folders',detail:'Folder · '+f.items.length+' items',symbol:'folder'})),...state.albums.map(id=>albums.get(id)).filter(Boolean).map(a=>({id:a.id,href:'#album/'+encodeURIComponent(a.id),name:a.title,type:'Albums',detail:'Album · '+a.artist,artwork:a.artwork,symbol:'album'})),...orderedArtists().map(a=>({id:a.id,href:'#artist/'+encodeURIComponent(a.id),name:a.name,type:'Artists',detail:'Artist',artwork:a.artwork,symbol:'artist'}))];
 const visible=entries.filter(e=>(libraryFilter==='All'||e.type===libraryFilter)&&norm(e.name+' '+e.detail).includes(norm(libraryQuery)));
 $('#sidebar-playlists').innerHTML=visible.map(e=>`<a class="library-entry ${e.type==='Artists'?'is-artist':''} ${location.hash===e.href?'active':''}" href="${e.href}">${e.playlist?playlistCover(e.playlist,'library-art',''):e.artwork?art(e.artwork,'library-art',''):`<span class="library-art library-symbol ${e.special||''}">${icon(e.symbol)}</span>`}<span><strong>${esc(e.name)}</strong><small>${esc(e.detail)}</small></span></a>`).join('')||'<p class="library-empty">No matches in your library.</p>';
}

function songRow(s,index,list,options={}){return `<div data-song-row="${esc(s.id)}" class="song-row ${current?.id===s.id?'playing':''}">${options.number?`<button class="song-number" data-action="play-song" data-id="${esc(s.id)}" data-list="${esc(list)}" aria-label="Play ${esc(s.title)}">${current?.id===s.id?icon('volume'):index+1}</button>`:art(s.artwork,'song-image','')}<button class="song-info" data-action="play-song" data-id="${esc(s.id)}" data-list="${esc(list)}"><strong>${esc(s.title)}</strong><small>${s.explicit?'<span class="explicit" aria-label="Explicit">E</span>':''}${esc(s.artist)}${s.album?' · '+esc(s.album):''}</small></button><span class="song-time">${s.duration?time(s.duration):'—'}</span><button class="icon-button ${state.liked.includes(s.id)?'active':''}" data-action="like" data-id="${esc(s.id)}" aria-label="${state.liked.includes(s.id)?'Unlike':'Like'} ${esc(s.title)}">${icon('heart')}</button><button class="icon-button" data-action="song-menu" data-id="${esc(s.id)}" aria-label="Options for ${esc(s.title)}">${icon('more')}</button></div>`}
function rows(list,listId,number=false){viewLists.set(listId,list.map(s=>s.id));return list.map((s,i)=>songRow(s,i,listId,{number})).join('')}
const viewLists=new Map();
function songCard(s,listId){return `<article class="card"><button class="card-cover" data-action="play-song" data-id="${esc(s.id)}" data-list="${esc(listId)}" aria-label="Play ${esc(s.title)}">${art(s.artwork,'',s.title)}<span class="card-play">${icon('play')}</span></button><h3>${esc(s.title)}</h3><p>${esc(s.artist)}</p></article>`}
function albumCard(a){return `<article class="card"><a class="card-cover" href="#album/${encodeURIComponent(a.id)}">${art(a.artwork,'',a.title)}</a><h3><a href="#album/${encodeURIComponent(a.id)}">${esc(a.title)}</a></h3><p>${esc(a.artist)}${a.year?' · '+esc(a.year):''}</p></article>`}
function artistCard(a){return `<article class="card artist"><a class="card-cover" href="#artist/${encodeURIComponent(a.id)}">${art(a.artwork,'',a.name)}</a><h3><a href="#artist/${encodeURIComponent(a.id)}">${esc(a.name)}</a></h3><p>${state.artistPins.includes(a.id)?'Pinned artist':'Artist'}</p></article>`}
function heading(title,kicker='',actions=''){return `<div class="page-heading"><div>${kicker?`<p class="eyebrow">${esc(kicker)}</p>`:''}<h1>${esc(title)}</h1></div><div class="button-row">${actions}</div></div>`}
function section(title,body,action='',kicker=''){return `<section><div class="section-heading"><div>${kicker?`<p class="eyebrow">${esc(kicker)}</p>`:''}<h2>${esc(title)}</h2></div>${action}</div>${body}</section>`}
let liveDiscovery=null,liveMood=null;
async function refreshDiscovery(){try{const query={'Relax':'chill relaxing music','Focus':'focus piano music','Workout':'workout music','Energize':'energetic music'}[mood];const result=await musicSearch.request(query?{query,kind:'Songs'}:{op:'discover'});rememberSearch(result);liveDiscovery=result;liveMood=mood}catch{liveDiscovery=null}}
function discover(){const moodQuery={'Relax':'chill relaxing music','Focus':'focus piano music','Workout':'workout music','Energize':'Daft Punk'}[mood];let list=getSongs(moodQuery?catalog.shelves[moodQuery]||[]:Array.from({length:3},(_,i)=>Object.entries(catalog.shelves).slice(0,13).map(([_,ids])=>ids[i])).flat().filter(Boolean));if(!list.length)list=getSongs(catalog.songs.slice(0,30).map(s=>s.id));if(liveMood===mood&&liveDiscovery?.songs.length)list=getSongs(liveDiscovery.songs.map(s=>s.id));viewLists.set('discover',list.map(s=>s.id));const recent=getSongs(state.recent.map(r=>r.id));const releases=liveMood===mood&&liveDiscovery?.albums.length?liveDiscovery.albums:catalog.newReleases.map(id=>albums.get(id)).filter(Boolean);return `<div class="section-heading"><h2>Discover music</h2>${btn(icon('plus')+' Add music','import')}</div>`+`<div class="chips">${['For you','Relax','Energize','Focus','Workout'].map(m=>`<button data-action="mood" data-value="${m}" class="${mood===m?'active':''}">${m==='For you'?'Fresh finds':m}</button>`).join('')}</div>`+section(mood==='For you'?'Fresh finds':mood,`<div class="cards">${list.slice(0,6).map(s=>songCard(s,'discover')).join('')}</div>`,btn('Play all','play-list','data-list="discover"','text-button'),'FROM YOUTUBE MUSIC')+section('Made for your moment',`<div class="mixes">${['Relax','Energize','Focus','Workout'].map((m,i)=>`<button class="mix-card" data-action="mood-play" data-value="${m}"><span class="mix-label">NOVA MIX · 0${i+1}</span><strong>${m}</strong><span>${['Slow down the day','Find your rhythm','Room to concentrate','Keep moving'][i]}</span></button>`).join('')}</div>`)+section('Quick picks',`<div class="song-grid">${rows(list.slice(6,14),'quick')}</div>`,'','START A QUEUE')+section('Browse genres',`<div class="chips">${state.genres.map(g=>`<button data-action="genre" data-value="${esc(g)}">${esc(g)}</button>`).join('')}</div>`,btn('Customize','genres','','text-button'))+(releases.length?section('New releases',`<div class="cards">${releases.slice(0,6).map(albumCard).join('')}</div>`, '', liveDiscovery?'FROM YOUTUBE MUSIC':'RECENTLY DISCOVERED'):'')+(recent.length?section('Recently played',`<div class="song-grid">${rows(recent.slice(0,6),'recent')}</div>`):'')+`<p class="credit">Music plays through YouTube. Availability varies by recording and region.</p>`}
async function render(forceSearch=false){
 const token=++routeToken;let [page='library',id='']=location.hash.slice(1).split('/');page=page||'library';if(page==='discover'){page='search';id='';history.replaceState(null,'','#search')}try{id=decodeURIComponent(id)}catch{id=''}
 document.body.classList.toggle('receiver',page==='receiver');document.body.classList.toggle('search-page',page==='search');
 $('#content').classList.toggle('classical',['classical','composer','category','work'].includes(page));
 $$('[data-nav]').forEach(a=>a.classList.toggle('active',a.dataset.nav===(['classical','composer','category','work'].includes(page)?'classical':['library','review','liked','saved','playlist','folder','albums','artists','recent','locals'].includes(page)?'library':page)));
 document.title=(page==='library'?'Home · Nova Music':page.charAt(0).toUpperCase()+page.slice(1)+' · Nova Music');
 if(page==='search'){const input=$('#search-input');searchQuery=!forceSearch&&document.activeElement===input?input.value:id;if(input.value!==searchQuery)input.value=searchQuery;syncSearchControl()}else{++searchToken;searchAbort?.abort()}
 if(['album','artist','public-playlist'].includes(page))$('#content').innerHTML='<p class="loading"><span class="spinner"></span>Loading your music…</p>';
 if(page==='search'&&!searchQuery)await refreshDiscovery();
 const html=await renderPage(page,id,token);if(token!==routeToken)return;
 $('#content').innerHTML=html;icons($('#content'));sidebar();
 if(page==='search'&&searchQuery)await runSearch(searchQuery);if(page==='receiver')renderReceiver();
}

let actionAnchor=null,menuTrigger=null,profileDraft=null;
function closeMenu(restore=true){const menu=$('#context-menu');if(!menu||menu.hidden)return;menu.hidden=true;menuTrigger?.setAttribute('aria-expanded','false');if(restore&&menuTrigger?.isConnected)menuTrigger.focus();menuTrigger=null}
function menu(title,html){
 const el=$('#context-menu'),anchor=actionAnchor;if(!anchor?.isConnected){modal(title,html);return}
 closeMenu(false);menuTrigger=anchor;anchor.setAttribute('aria-haspopup','menu');anchor.setAttribute('aria-expanded','true');el.setAttribute('aria-label',title+' options');el.innerHTML=html;icons(el);$$('button,a',el).forEach(item=>item.setAttribute('role','menuitem'));el.hidden=false;
 const r=anchor.getBoundingClientRect(),width=el.offsetWidth,height=el.offsetHeight;el.style.left=Math.max(8,Math.min(r.left,innerWidth-width-8))+'px';el.style.top=Math.max(8,Math.min(r.bottom+6,innerHeight-height-8))+'px';el.querySelector('button,a')?.focus();
}
$('#context-menu').addEventListener('keydown',e=>{if(e.key==='Tab'){closeMenu();return}if(e.key==='Escape'){e.preventDefault();closeMenu();return}if(!['ArrowDown','ArrowUp','Home','End'].includes(e.key))return;e.preventDefault();const items=$$('button,a',$('#context-menu')),i=items.indexOf(document.activeElement),next=e.key==='Home'?0:e.key==='End'?items.length-1:(i+(e.key==='ArrowDown'?1:-1)+items.length)%items.length;items[next]?.focus()});
window.addEventListener('resize',()=>closeMenu(false));document.addEventListener('scroll',e=>{if(!e.target.closest?.('#context-menu'))closeMenu(false)},true);
function accountProfile(){try{return validateProfile(state.profile)}catch{return defaultProfile()}}
function avatarHTML(profile=accountProfile()){return profile.image?`<img src="${esc(profile.image)}" alt="">`:esc(profile.icon)}
function renderAvatar(){const button=$('.top-actions .avatar');if(!button)return;const profile=accountProfile();button.innerHTML=avatarHTML(profile);button.style.backgroundColor=profile.color;button.setAttribute('aria-label',profile.name?profile.name+' — Account':'Account');}
function profileSummary(){const profile=accountProfile();return `<div class="profile-summary"><span class="profile-avatar" style="background:${esc(profile.color)}">${avatarHTML(profile)}</span><div><h3>${esc(profile.name||'Your profile')}</h3><p class="small-copy">${accountClient?.user?'Your icon syncs with your account.':'Sign in to sync your icon across devices.'}</p></div></div>`}
function editProfile(){profileDraft=structuredClone(accountProfile());modal('Edit profile',`<form id="profile-form"><div class="profile-summary"><span id="profile-preview" class="profile-avatar"></span><label class="field">Display name<input name="name" maxlength="60" value="${esc(profileDraft.name)}" autocomplete="nickname"></label></div><h3>Choose an icon</h3><div class="profile-icons">${profileIcons.map(value=>`<button type="button" data-action="profile-icon" data-value="${esc(value)}" class="profile-choice" aria-label="Icon ${esc(value)}">${esc(value)}</button>`).join('')}</div><h3>Background color</h3><div class="profile-colors">${profileColors.map((value,i)=>`<button type="button" data-action="profile-color" data-value="${value}" class="profile-choice" style="background:${value}" aria-label="${['Green','Purple','Pink','Blue','Yellow','Orange'][i]}"></button>`).join('')}</div><label class="field profile-upload">Or choose a photo<input id="profile-photo" type="file" accept="image/jpeg,image/png,image/webp"></label><button type="button" data-action="profile-remove-photo" class="text-button">Remove photo</button><p class="small-copy">${accountClient?.user?'Saved privately with your account and synced across devices.':'Sign in to sync this profile across devices.'}</p><div class="modal-actions"><button class="primary">Save profile</button></div></form>`);updateProfilePreview()}
function updateProfilePreview(){const preview=$('#profile-preview');if(!preview)return;preview.innerHTML=avatarHTML(profileDraft);preview.style.backgroundColor=profileDraft.color;$$('[data-action="profile-icon"]').forEach(b=>b.setAttribute('aria-pressed',String(!profileDraft.image&&b.dataset.value===profileDraft.icon)));$$('[data-action="profile-color"]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.value===profileDraft.color)))}
document.addEventListener('change',async e=>{if(e.target.id!=='profile-photo')return;const file=e.target.files[0];if(!file)return;const draft=profileDraft,button=$('#profile-form button.primary');button.disabled=true;try{if(!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>15000000)throw Error('Choose a PNG, JPEG or WebP photo under 15 MB.');const bitmap=await createImageBitmap(file),canvas=document.createElement('canvas');canvas.width=canvas.height=256;const size=Math.min(bitmap.width,bitmap.height);canvas.getContext('2d').drawImage(bitmap,(bitmap.width-size)/2,(bitmap.height-size)/2,size,size,0,0,256,256);bitmap.close();const image=canvas.toDataURL('image/jpeg',.8);validateProfile({...draft,image});if(profileDraft!==draft)return;profileDraft.image=image;updateProfilePreview()}catch(error){toast(error.message)}finally{if(button.isConnected)button.disabled=false}});
function modal(title,body){stopSongSearch();closeMenu();$('#modal-title').textContent=title;$('#modal-body').innerHTML=body;icons($('#modal'));if(!$('#modal').open)$('#modal').showModal();setTimeout(()=>$('#modal input:not([type=checkbox])')?.focus(),50)}
document.addEventListener('click',async e=>{if(e.target.closest('.skip')){e.preventDefault();$('#content').focus();return}const b=e.target.closest('[data-action]');if(!e.target.closest('#context-menu'))closeMenu(false);if(!b)return;actionAnchor=b;if(b.closest('#context-menu'))closeMenu(false);try{await action(b.dataset.action,b.dataset)}catch(error){toast(error.message||'Something went wrong. Try again.')}});
window.addEventListener('hashchange',()=>{clearTimeout(searchTimer);render(true);$('.workspace').scrollTo(0,0)});
async function start(){icons();sidebar();try{catalog=await fetch('catalog.json').then(r=>{if(!r.ok)throw Error('Catalog unavailable');return r.json()});songs=new Map([...catalog.songs,...Object.values(state.extraSongs)].map(s=>[s.id,s]));albums=new Map([...catalog.albums,...Object.values(state.extraAlbums)].map(a=>[a.id,a]));artists=new Map([...catalog.artists,...Object.values(state.extraArtists)].map(a=>[a.id,a]));await render()}catch{ $('#content').innerHTML=empty('Music couldn’t load','Check your connection and reload the page.',btn('Reload','reload')) }}
const categories={greatPieces:'Great pieces',symphonies:'Symphonies',solo:'Solo',piano:'Piano',aria:'Arias',vocal:'Songs',orchestral:'Orchestral',concertos:'Concertos',chamber:'Chamber',choral:'Choral',ballet:'Ballet',opera:'Opera',organ:'Organ',all:'All works'};
function composerCard(c){return `<article class="card"><a class="card-cover" href="#composer/${c.id}">${art(c.artwork,'',c.name)}</a><h3><a href="#composer/${c.id}">${esc(c.name.split(' ').slice(-1)[0])}</a></h3><p>${esc(c.years)} · ${esc(c.era)}</p></article>`}
function workRows(works){return works.map(w=>`<a class="work-row" href="#work/${w.id}">${art(catalog.composers.find(c=>c.id===w.composerId)?.artwork,'',w.composer)}<span><span class="work-title">${esc(w.title)}</span><small>${esc(w.composer)} · ${esc(w.detail)}</small></span></a>`).join('')}
function playlistCard(p){const ss=playlistSongs(p);return `<article class="card"><a class="card-cover" href="#playlist/${p.id}">${playlistCover(p)}</a><h3><a href="#playlist/${p.id}">${esc(p.name)}</a></h3><p>${p.rules?'Smart playlist · ':''}${ss.length} songs${p.unmatched?.some(entry=>!entry.matchedSongId)?' · '+p.unmatched.filter(entry=>!entry.matchedSongId).length+' to pair':''}</p></article>`}
async function renderPage(page,id){
  if(page==='classical')return heading('Classical','THE CLASSICAL COLLECTION')+section('Explore composers',`<div class="cards composer-grid">${catalog.composers.map(composerCard).join('')}</div>`)+section('Explore the repertoire',`<div class="category-grid">${Object.entries(categories).map(([k,v])=>`<a class="category" href="#category/${k}">${icon(k==='piano'?'classical':'folder')}<strong>${v}</strong></a>`).join('')}</div>`)+section('Works to know',workRows(catalog.works.filter(w=>w.overview).slice(0,8)))+`<p class="credit">Composer portraits: <a href="assets/composers/Credits.json">source credits</a>. Work catalog adapted from Nova Music.</p>`;
  if(page==='composer'){const c=catalog.composers.find(c=>c.id===id);if(!c)return empty('Composer unavailable','Return to Classical to choose a composer.');return `<div class="collection-hero">${art(c.artwork,'collection-art',c.name)}<div><p class="eyebrow">${esc(c.era)} · ${esc(c.years)}</p><h1>${esc(c.name)}</h1><div class="button-row">${btn('Find recordings','search-query',`data-query="${esc(c.name)}"`)}${btn('Composer info','wiki',`data-query="${esc(c.name)}"`)}</div></div></div><div class="chips">${Object.entries(categories).filter(([k])=>catalog.works.some(w=>w.composerId===id&&w.tags.includes(k))).map(([k,v])=>`<a class="secondary" href="#category/${k}:${id}">${v}</a>`).join('')}</div>`+workRows(catalog.works.filter(w=>w.composerId===id))}
  if(page==='category'){const [cat,composer]=id.split(':');const works=catalog.works.filter(w=>w.tags.includes(cat)&&(!composer||w.composerId===composer));return heading(categories[cat]||'Works',catalog.composers.find(c=>c.id===composer)?.name||'CLASSICAL')+`<label class="search-form">${icon('search')}<input id="work-filter" placeholder="Work title or catalogue number" aria-label="Filter works"></label><div id="work-list">${workRows(works)}</div>`}
  if(page==='work'){const w=catalog.works.find(w=>w.id===id);if(!w)return empty('Work unavailable','Choose another work from Classical.');const c=catalog.composers.find(c=>c.id===w.composerId);const words=norm(w.title).replace(/no \d+/g,'').split(' ').filter(s=>s.length>3);let matches=[...songs.values()].filter(s=>norm(s.artist+' '+s.title).includes(norm(c.name.split(' ').pop()))&&words.some(word=>norm(s.title).includes(word))).slice(0,30);return heading(w.title,w.composer)+`<p class="muted">${esc(w.detail)}</p>${w.overview?`<p class="work-overview">${esc(w.overview)}</p>`:''}<div class="button-row">${btn('Find more recordings','search-query',`data-query="${esc(w.composer+' '+w.title)}"`)}${w.wiki?`<a class="secondary" href="https://en.wikipedia.org/wiki/${encodeURIComponent(w.wiki)}" target="_blank" rel="noopener">About this work</a>`:''}</div><hr class="divider">`+section('Recordings',matches.length?rows(matches,'work',true):empty('Find a recording','Search YouTube for this work or open a recording link.'))}
  if(page==='review')return reviewPage();
  if(page==='library')return reviewLibraryLink()+heading('Home','YOUR MUSIC',btn(icon('plus')+' New playlist','new-playlist'))+`<div class="library-grid">${[['liked','heart','Liked songs',state.liked.length+' songs'],['albums','album','Albums',state.albums.length+' albums'],['artists','artist','Artists',state.artists.length+' artists'],['saved','download','Saved songs',state.saved.length+' songs'],['recent','clock','Recently played',state.recent.length+' songs'],['locals','volume','Local music','Audio on this device']].map(([dest,ico,label,sub])=>`<a class="library-tile" href="#${dest}">${icon(ico)}<span><strong>${label}</strong><small>${sub}</small></span></a>`).join('')}</div><hr class="divider">`+section('Artists',state.artists.length?`<div class="cards">${orderedArtists().map(artistCard).join('')}</div>`:empty('Follow your favorites','Open an artist page and add them to your library.'),btn('Arrange','arrange-artists','','text-button'))+section('Playlists',state.playlists.length?`<div class="cards">${state.playlists.map(playlistCard).join('')}</div>`:empty('Make it your own','Save a collection of songs or create a smart playlist.',btn('Create playlist','new-playlist')),btn('New','new-playlist','','text-button'))+section('Folders',state.folders.length?`<div class="library-grid">${state.folders.map(f=>`<a class="library-tile" href="#folder/${f.id}">${icon('folder')}<span><strong>${esc(f.name)}</strong><small>${f.items.length} items</small></span></a>`).join('')}</div>`:empty('A place for your collections','Group albums and playlists into folders.',btn('New folder','new-folder')),btn('New','new-folder','','text-button'));
  if(['liked','saved','recent','locals'].includes(page)){const list=page==='liked'?getSongs(state.liked):page==='saved'?getSongs(state.saved):page==='recent'?getSongs(state.recent.map(r=>r.id)):[...songs.values()].filter(s=>s.source==='local');return heading({liked:'Liked songs',saved:'Saved songs',recent:'Recently played',locals:'Local music'}[page],'YOUR LIBRARY',btn('Shuffle','shuffle-list',`data-list="${page}"`))+`<p class="muted">${list.length} songs</p>`+(list.length?rows(list,page,true):empty('Nothing here yet',page==='locals'?'Import audio files to listen to complete songs on this device.':'Songs you save will appear here.',btn(page==='locals'?'Import audio':'Discover music',page==='locals'?'local-import':'discover')))}
  if(page==='albums')return heading('Albums','YOUR LIBRARY')+(state.albums.length?`<div class="cards">${state.albums.map(id=>albums.get(id)).filter(Boolean).map(albumCard).join('')}</div>`:empty('Save an album','Albums you save will appear here.'));
  if(page==='artists')return heading('Artists','YOUR LIBRARY',btn('Arrange','arrange-artists'))+(state.artists.length?`<div class="cards">${orderedArtists().map(artistCard).join('')}</div>`:empty('Follow your favorites','Find an artist in Search and add them to your library.'));
  if(page==='album'){let warning='';try{await loadCollection(id)}catch(e){warning=`<p class="notice">${esc(e.message)} ${btn('Retry','retry-route','','text-button')}</p>`}const a=albums.get(id);if(!a)return empty('Album unavailable','This release could not be loaded.',btn('Retry','retry-route'));let ss=albumTracks(a);const chosen=state.discChoices[id];if(chosen)ss=ss.filter(s=>chosen.includes(s.discNumber||1));viewLists.set('album',ss.map(s=>s.id));return `<div class="collection-hero">${art(a.artwork,'collection-art',a.title)}<div><p class="eyebrow">${esc(a.type||'Album')}${a.complete===false?(a.live?' · More tracks available':' · Selected recordings'):''}</p><h1>${esc(a.title)}</h1><p class="muted">${esc(a.artist)}${a.year?' · '+esc(a.year):''} · ${ss.length} songs</p><div class="button-row">${btn(icon('play')+' Play','play-list','data-list="album"','primary')}${btn(icon('shuffle')+' Shuffle','shuffle-list','data-list="album"')}${btn(state.albums.includes(id)?'Saved':'Save album','save-album',`data-id="${esc(id)}"`)}${btn(icon('more'),'album-menu',`data-id="${esc(id)}" aria-label="Album options"`)}</div></div></div>`+warning+rows(ss,'album',true)+collectionMore(id)}
  if(page==='artist'){
   let warning='';try{await loadCollection(id);await loadArtistSelection(id)}catch(e){warning=`<p class="notice">${esc(e.message)} ${btn('Retry','retry-route','','text-button')}</p>`}
   const a=artists.get(id);if(!a)return empty('Artist unavailable','Choose another artist from Search.');
   const all=releasesForArtist(id),selected=state.releaseChoices[id],chosen=chosenReleases(all,selected),shown=showingAllArtistReleases.has(id)?all:chosen;
   const ranked=collectionPages.get(id)?.songs||[...songs.values()].filter(s=>s.artistId===id),ss=selected===undefined?ranked:selectedArtistTracks(id),top=selected===undefined?ranked:selectedTopSongs(ranked,ss);
   viewLists.set('artist',ss.map(s=>s.id));const attached=state.playlists.filter(p=>playlistArtistId(p)===id);
   const shelf=(title,list)=>section(title,list.length?`<div class="cards artist-release-shelf">${list.map(albumCard).join('')}</div>`:`<p class="muted">${selected!==undefined&&!showingAllArtistReleases.has(id)?'No '+title.toLowerCase()+' selected. Choose releases to add them here.':'No releases available.'}</p>`,title==='Albums'?btn('Choose releases','choose-releases',`data-id="${esc(id)}"`,'text-button'):'');
   return `<div class="artist-hero">${art(a.artwork,'artist-hero-image',a.name)}<div class="artist-hero-title"><p class="eyebrow">ARTIST</p><h1>${esc(a.name)}</h1></div></div><div class="artist-actions button-row">${btn(icon('play')+' Play','play-list','data-list="artist"','primary')}${btn('Shuffle','shuffle-list','data-list="artist"')}${btn(state.artists.includes(id)?'In your library':'Follow artist','follow-artist',`data-id="${esc(id)}"`)}${btn(icon('settings'),'artist-menu',`data-id="${esc(id)}" aria-label="Artist settings"`)}</div>`+warning+shelf('Albums',shown.filter(r=>releaseKind(r)==='Albums'))+shelf('Singles & EPs',shown.filter(r=>releaseKind(r)!=='Albums'))+section('Your playlists',attached.length?`<div class="cards artist-release-shelf">${attached.map(playlistCard).join('')}</div>`:btn('Add a playlist','artist-playlists',`data-id="${esc(id)}"`),btn('Add','artist-playlists',`data-id="${esc(id)}"`,'text-button'))+section('Top songs',top.length?rows(showingAllArtistTopSongs.has(id)?top:top.slice(0,5),'artist-top',true):`<p class="muted">No top songs match your selected releases yet.</p>`,top.length>5?btn(showingAllArtistTopSongs.has(id)?'Show less':'See more','artist-top-more',`data-id="${esc(id)}"`,'text-button'):'')+((collectionPages.get(id)?.artist?.description)?section('About',`<p class="artist-about">${esc(collectionPages.get(id).artist.description)}</p>`):'')+(selected===undefined&&collectionPages.get(id)?.related?.length?section('Fans also like',`<div class="cards artist-release-shelf">${collectionPages.get(id).related.map(artistCard).join('')}</div>`):'')+(selected===undefined&&collectionPages.get(id)?.featuredPlaylists?.length?section('Featured playlists',`<div class="cards artist-release-shelf">${collectionPages.get(id).featuredPlaylists.map(publicPlaylistCard).join('')}</div>`):'');
  }
  if(page==='public-playlist'){
   const browseId='VL'+id;let warning='';try{await loadCollection(browseId)}catch(e){warning=`<p class="notice">${esc(e.message)} ${btn('Retry','retry-route','','text-button')}</p>`}
   const p=publicPlaylists.get(id),ss=getSongs(collectionPages.get(browseId)?.songs.map(s=>s.id)||[]);
   if(!p)return empty('Playlist unavailable','It may be private or no longer available.',btn('Retry','retry-route'));
   return `<div class="collection-hero">${playlistCover(p,'collection-art')}<div><p class="eyebrow">PUBLIC PLAYLIST</p><h1>${esc(p.name)}</h1><p class="muted">${esc(p.author||'YouTube Music')} · ${ss.length} songs${collectionPages.get(browseId)?.cursor?' loaded':''}</p><div class="button-row">${btn(icon('play')+' Play','play-list','data-list="public-playlist"','primary')}${btn('Shuffle','shuffle-list','data-list="public-playlist"')}${btn('Save playlist','import-youtube-playlist',`data-id="${esc(id)}"`)}</div></div></div>`+warning+rows(ss,'public-playlist',true)+collectionMore(browseId);
  }
  if(page==='playlist'){const p=state.playlists.find(p=>p.id===id);if(!p)return empty('Playlist unavailable','This playlist may have been deleted.');const ss=playlistSongs(p);return `<div class="collection-hero">${playlistCover(p,'collection-art')}<div><p class="eyebrow">${p.rules?'SMART PLAYLIST':'PLAYLIST'}</p><h1>${esc(p.name)}</h1><p class="muted">${ss.length} songs${p.description?' · '+esc(p.description):''}</p><div class="button-row">${btn(icon('play')+' Play','play-list','data-list="playlist"','primary')}${btn('Shuffle','shuffle-list','data-list="playlist"')}${btn('Edit','edit-playlist',`data-id="${id}"`)}${btn('Edit artwork','playlist-artwork',`data-id="${id}"`)}${btn(icon('folder'),'add-folder',`data-id="${id}" data-kind="playlist" aria-label="Add playlist to folder"`)}${btn(icon('plus'),'playlist-picker',`data-id="${id}" aria-label="Add songs to playlist"`)}</div></div></div>`+rows(ss,'playlist',true)+(p.sourceUrl?`<p class="small-copy"><a href="${safeURL(p.sourceUrl)}" target="_blank" rel="noopener">Original ${p.sourceUrl.includes('spotify.com')?'Spotify':'YouTube'} playlist</a> · Saved copy; future changes don’t sync.</p>`:'')+(p.unmatched?.length?section('Songs to review',reviewRows([p])+`<p class="small-copy"><a href="#review">Review songs from all imported playlists</a></p>`):'')}
  if(page==='folder'){const f=state.folders.find(f=>f.id===id);if(!f)return empty('Folder unavailable','This folder may have been deleted.');viewLists.set('folder',folderTracks(f).map(s=>s.id));const sorted=[...f.items].sort((a,b)=>Number(f.pins?.includes(b.kind+':'+b.id))-Number(f.pins?.includes(a.kind+':'+a.id)));return heading(f.name,'FOLDER',btn('Shuffle','shuffle-list','data-list="folder"')+btn('Edit folder','edit-folder',`data-id="${id}"`))+`<div class="button-row">${btn('Add or remove items','folder-members',`data-id="${id}"`)}</div><hr class="divider">`+(sorted.length?sorted.map(item=>{const obj=item.kind==='album'?albums.get(item.id):state.playlists.find(p=>p.id===item.id);if(!obj)return'';return `<div class="manage-row">${item.kind==='playlist'?playlistCover(obj,'song-image'):art(obj.artwork,'song-image',obj.title)}<a class="song-info" href="#${item.kind}/${encodeURIComponent(item.id)}"><strong>${esc(obj.title||obj.name)}</strong><small>${esc(item.kind)}</small></a><button class="icon-button ${f.pins?.includes(item.kind+':'+item.id)?'pin':''}" data-action="folder-pin" data-id="${id}" data-item="${esc(item.id)}" data-kind="${item.kind}" aria-label="Pin ${esc(obj.title||obj.name)}">${icon('pin')}</button></div>`}).join(''):empty('This folder is empty','Add albums or playlists to organize your music.'))}
  if(page==='search')return `<div class="search-toolbar"><div class="chips search-filters" aria-label="Filter search results">${['All','Songs','Artists','Albums','Playlists'].map(t=>`<button data-action="search-kind" data-value="${t}" aria-pressed="${searchKind===t}" class="${searchKind===t?'active':''}">${t}</button>`).join('')}</div><p id="search-status" class="search-status" role="status" aria-live="polite"></p></div><div id="search-results">${searchBrowse()}</div>`;

  if(page==='receiver')return `<button class="secondary" data-action="exit-receiver">Close display</button><div class="receiver-view"><div id="receiver-song"></div><div id="receiver-lyrics" class="receiver-lyrics"></div></div>`;
  return empty('Page unavailable','Return to Home.',btn('Home','library'));
}
function safeURL(raw){try{const u=new URL(raw);return ['https:','http:'].includes(u.protocol)?esc(u.href):'#'}catch{return'#'}}
let searchKind='All',searchToken=0,searchQuery='',searchTimer,searchAbort,searchPage;
const musicSearch=new MusicSearchClient(syncConfig.url+'/functions/v1/music-search',{publicKey:syncConfig.publishableKey});
const publicPlaylists=new Map(),collectionPages=new Map();
function rememberSearch(result){
 remember(result.songs.map(s=>{const old=songs.get(s.id);return {...old,...s,duration:s.duration||old?.duration||0,album:s.album||old?.album||'',albumId:s.albumId||old?.albumId||'',...(old?.lyrics?{lyrics:old.lyrics}:{})}}));
 for(const a of result.albums){const old=albums.get(a.id);const merged={...old,...a,kind:a.kind||a.type||old?.kind||'Album',tracks:old?.tracks||[],complete:old?.complete||false};albums.set(a.id,merged);state.extraAlbums[a.id]=merged}
 for(const a of result.artists){const merged={...artists.get(a.id),...a};artists.set(a.id,merged);state.extraArtists[a.id]=merged}
 for(const p of result.playlists)publicPlaylists.set(p.id,p);
}
async function loadCollection(id,more=false){
 const old=collectionPages.get(id);if(old&&!more&&Date.now()-old.at<300000&&old.songs.every(s=>songs.has(s.id))&&(!id.startsWith('MPRE')||albums.has(id))){
  // Rehydrate the open album from its provider page after account sync. The
  // shared release record may contain metadata without any loaded recordings.
  if(id.startsWith('MPRE')){const album={...albums.get(id),tracks:old.songs.map(s=>s.id),complete:!old.cursor,live:true};albums.set(id,album);state.extraAlbums[id]=album}
  return old;
 }
 const result=await musicSearch.request({op:'browse',id,...(more&&old?.cursor?{cursor:old.cursor}:{})});
 const meta=result.collection||{},album=id.startsWith('MPRE')?albums.get(id):null,playlist=publicPlaylists.get(id.slice(2));
 result.songs=result.songs.map((s,i)=>({...s,artist:s.artist==='YouTube Music'?(album?.artist||meta.artist||result.artist?.name||playlist?.author||s.artist):s.artist,artistId:s.artistId||album?.artistId||meta.artistId||(id.startsWith('UC')&&(!s.artistId||s.artist==='YouTube Music')?id:''),album:album?.title||(id.startsWith('MPRE')?meta.title:s.album),albumId:id.startsWith('MPRE')?id:s.albumId,artwork:s.artwork.includes('i.ytimg.com')?(album?.artwork||meta.artwork||s.artwork):s.artwork,trackNumber:(more?old?.songs.length||0:0)+i+1}));
 if(id.startsWith('UC')){const name=result.artist?.name||artists.get(id)?.name||'';result.albums=result.albums.map(a=>({...a,artist:a.artist||name,artistId:a.artistId||(!a.artist||norm(a.artist)===norm(name)?id:'')}));const official=result.songs.filter(s=>s.musicVideoType==='MUSIC_VIDEO_TYPE_ATV'&&s.artistId===id);if(official.length)result.songs=official}
 rememberSearch(result);
 const page={...result,songs:(more?mergeResults(old.songs,result.songs):result.songs).map(s=>songs.get(s.id)),at:Date.now()};collectionPages.set(id,page);
 if(id.startsWith('MPRE')){const a={...meta,...album,id,title:album?.title||meta.title||'Album',tracks:page.songs.map(s=>s.id),complete:!page.cursor,live:true};albums.set(id,a);state.extraAlbums[id]=a}
 else if(id.startsWith('VL')){const p={...playlist,id:id.slice(2),name:playlist?.name||meta.title||'Public playlist',artwork:playlist?.artwork||meta.artwork,author:playlist?.author||meta.artist,remote:true};publicPlaylists.set(p.id,p)}
 else if(id.startsWith('UC')){if(result.artist?.name){artists.set(id,{...artists.get(id),...result.artist});state.extraArtists[id]=artists.get(id)}for(const a of result.albums){if(!a.artistId&&norm(a.artist)===norm(artists.get(id)?.name)){a.artistId=id;albums.set(a.id,{...albums.get(a.id),artistId:id});state.extraAlbums[a.id]=albums.get(a.id)}}}
 return page;
}
function publicPlaylistCard(p){return `<article class="card"><a class="card-cover" href="#public-playlist/${encodeURIComponent(p.id)}">${art(p.artwork,'',p.name)}</a><h3><a href="#public-playlist/${encodeURIComponent(p.id)}">${esc(p.name)}</a></h3><p>Playlist${p.author?' · '+esc(p.author):''}</p></article>`}
function collectionMore(id){return collectionPages.get(id)?.cursor?btn('Load more tracks','collection-more',`data-id="${esc(id)}"`):''}

function ytLink(raw){try{const u=new URL(raw);if(u.hostname==='youtu.be')return /^[A-Za-z0-9_-]{11}$/.test(u.pathname.slice(1))?{video:u.pathname.slice(1)}:null;if(['youtube.com','www.youtube.com','music.youtube.com','m.youtube.com'].includes(u.hostname)){const v=u.searchParams.get('v'),p=u.searchParams.get('list');if(v&&/^[A-Za-z0-9_-]{11}$/.test(v))return{video:v};if(p&&/^[A-Za-z0-9_-]+$/.test(p))return{playlist:p}}}catch{}return null}
async function ytAPI(endpoint,params){if(!state.settings.youtubeKey)throw Error('Add a YouTube API key in Settings for live search and playlist imports. Live YouTube Music search and pasted song links work without a key.');const u=new URL('https://www.googleapis.com/youtube/v3/'+endpoint);for(const [k,v]of Object.entries({...params,key:state.settings.youtubeKey}))u.searchParams.set(k,v);const r=await fetch(u);const j=await r.json();if(!r.ok)throw Error(j.error?.message||'YouTube is unavailable. Try again.');return j}
function ytSong(item){const s=item.snippet;return{id:item.id.videoId||item.id,title:decodeHTML(s.title),artist:decodeHTML(s.channelTitle.replace(/ - Topic$/,'')),artistId:s.channelId,album:'',artwork:(s.thumbnails.high||s.thumbnails.medium||s.thumbnails.default)?.url,duration:0,source:'youtube'}}
function decodeHTML(s){const t=document.createElement('textarea');t.innerHTML=s;return t.value}

function syncSearchControl(){$('[data-action="clear-search"]').hidden=!$('#search-input').value}
function searchBrowse(){
 const names=['Music','Made for you','Classical',...state.genres.filter(g=>g!=='Classical'),'Focus','Workout'];
 const colors=['#dc148c','#006450','#7358ff','#e13300','#148a08','#8d67ab','#e8115b','#1e3264','#bc5900','#b02897','#477d95','#af2896'];
 return `<section class="browse-section"><h1>Search</h1><h2>Browse all</h2><div class="browse-grid">${names.map((name,i)=>{const cover=(name==='Classical'?catalog.composers[0]?.artwork:catalog.songs.find(s=>norm(s.genre)===norm(name))?.artwork)||catalog.albums[(i*7)%Math.max(1,catalog.albums.length)]?.artwork;const href=name==='Classical'?'#classical':['Music','Made for you','Focus','Workout'].includes(name)?'#search':'#search/'+encodeURIComponent(name);return `<a class="browse-tile" href="${href}" ${['Focus','Workout'].includes(name)?`data-action="browse-mood" data-value="${name}"`:''} style="--tile-color:${colors[i%colors.length]}"><strong>${esc(name)}</strong>${cover?art(cover,'',''):''}</a>`}).join('')}</div></section>`+discover();
}
async function submitMusicSearch(query){
 clearTimeout(searchTimer);searchQuery=query;syncSearchControl();
 const hash='#search'+(query.trim()?'/'+encodeURIComponent(query):'');
 if(location.hash===hash)await render(true);else location.hash=hash;
}
async function runSearch(query){
 const target=$('#search-results');if(!target)return;const token=++searchToken;query=query.trim();
 if(!query){searchAbort?.abort();searchPage=null;await refreshDiscovery();if(token!==searchToken)return;target.innerHTML=searchBrowse();$('#search-status').textContent='';return}
 const link=ytLink(query);if(link?.video){await addYouTube(link.video);return}if(link?.playlist){await importYouTubePlaylist(link.playlist);return}if(/(?:open\.spotify\.com\/playlist\/|spotify:playlist:)/.test(query)){spotifyImportDialog(query);return}
 target.innerHTML='<p class="loading"><span class="spinner"></span>Finding your music…</p>';
 searchAbort?.abort();searchAbort=new AbortController();
 const kind=searchKind;let result,note='';
 try{result=await musicSearch.request({query,kind,providerOrder:true},{signal:searchAbort.signal});}
 catch(e){if(token!==searchToken)return;result={songs:rankLocal([...songs.values()],query,'songs',id=>lyricsCache.get(id)?.plain||''),albums:rankLocal([...albums.values()],query,'albums'),artists:rankLocal([...artists.values()],query,'artists'),playlists:[],cursor:''};note='Live search is unavailable right now. '+(e.message||'Please retry.')+' Showing matches already on this device.';}
 if(token!==searchToken||!target.isConnected)return;
 rememberSearch(result);
 result.songs=result.songs.filter(s=>state.settings.explicit||!s.explicit);
 if(result.providerOrder)result.localPlaylists=rankLocal(state.playlists,query,'playlists');else result.playlists=mergeResults(result.playlists,rankLocal(state.playlists,query,'playlists'));
 searchPage={...(result.providerOrder?result:rankSearch(result,result.correction||query)),query,kind,note};drawSearch(target,searchPage);
}
function providerResultRow({kind,item},index){
 const name=item.title||item.name,label={songs:item.musicVideoType==='MUSIC_VIDEO_TYPE_ATV'?'Song':'Video',artists:'Artist',albums:item.type||'Album',playlists:'Playlist'}[kind];
 const details=[label,item.artist||item.author,item.year,item.views||item.audience].filter(Boolean).join(' · ');
 if(kind==='songs')return `<div class="song-row provider-result" data-song-row="${esc(item.id)}">${art(item.artwork,'song-image','')}<button class="song-info" data-action="play-song" data-id="${esc(item.id)}" data-list="provider-search"><strong>${esc(name)}</strong><small>${item.explicit?'<span class="explicit" aria-label="Explicit">E</span>':''}${esc(details)}</small></button><span class="song-time">${item.duration?time(item.duration):''}</span>${btn(icon('more'),'song-menu',`data-id="${esc(item.id)}" aria-label="Options for ${esc(name)}"`,'icon-button')}</div>`;
 const path={artists:'artist',albums:'album',playlists:item.remote?'public-playlist':'playlist'}[kind];
 return `<a class="provider-result entity-result ${kind==='artists'?'artist-result':''}" href="#${path}/${encodeURIComponent(item.id)}">${art(item.artwork,'song-image','')}<span class="song-info"><strong>${esc(name)}</strong><small>${esc(details)}</small></span><span class="entity-arrow">›</span></a>`;
}
function drawProviderSearch(target,result){
 const entries=providerItems(result),top=entries.find(e=>e.kind===result.top?.kind&&e.item.id===result.top?.id),remaining=top?entries.filter(e=>e!==top):entries;
 $('#search-status').textContent=result.correction?`Showing results for “${result.correction}”`:`YouTube Music results for “${result.query}”`;
 viewLists.set('provider-search',entries.filter(e=>e.kind==='songs').map(e=>e.item.id));
 let html=`<div class="provider-search-heading"><p>Results in YouTube Music’s order</p><a href="https://music.youtube.com/search?q=${encodeURIComponent(result.query)}" target="_blank" rel="noopener">Open YouTube Music ↗</a></div>`;
 if(top){const {item,kind}=top,name=item.title||item.name,label={songs:item.musicVideoType==='MUSIC_VIDEO_TYPE_ATV'?'Song':'Video',artists:'Artist',albums:'Album',playlists:'Playlist'}[kind],detail=item.artist||item.author||item.audience;
 const inside=`${art(item.artwork,'top-result-art','')}<div><h3>${esc(name)}</h3><span>${label}${detail?' · '+esc(detail):''}</span></div>`;
 const path={artists:'artist',albums:'album',playlists:'public-playlist'}[kind];
 html+=section('Top result',kind==='songs'?`<button class="top-result-card provider-top" data-action="play-song" data-id="${esc(item.id)}" data-list="provider-search">${inside}<i class="result-play">${icon('play')}</i></button>`:`<a class="top-result-card provider-top ${kind==='artists'?'artist-result':''}" href="#${path}/${encodeURIComponent(item.id)}">${inside}</a>`);
 }
 html+=remaining.length?section('Results',remaining.map(providerResultRow).join('')):top?'':empty('No results found','Try another title, artist, or lyric phrase.');
 if(result.localPlaylists?.length)html+=section('Your playlists',`<div class="cards">${result.localPlaylists.map(playlistCard).join('')}</div>`);
 html+='<p class="credit">Public YouTube Music search · Results can differ from your signed-in YouTube Music account.</p>';
 target.innerHTML=html;icons(target);
}
function drawSearch(target,result){
 const {songs:ss,albums:aa,artists:ar,playlists:pl,query,kind,note,correction,top}=result;
 if(result.providerOrder&&kind==='All'){drawProviderSearch(target,result);return}
 const count=kind==='All'?ss.length+ar.length+aa.length+pl.length:({Songs:ss,Artists:ar,Albums:aa,Playlists:pl}[kind]?.length||0);
 $('#search-status').textContent=correction?`Showing results for “${correction}”`:(count?`Results for “${query}”`:`No results for “${query}”`);
 let html=note?`<p class="notice">${esc(note)} ${btn('Retry','search-retry','','text-button')}</p>`:'';
 if(kind==='All'&&top){
 const item=result[top.kind]?.find(x=>x.id===top.id);let topCard='';
 if(item){const label={songs:'Song',artists:'Artist',albums:'Album',playlists:'Playlist'}[top.kind],name=item.title||item.name,details=item.artist||item.author||'';
 const content=`${art(item.artwork,'top-result-art','')}<h3>${esc(name)}</h3><span>${label}${details?' · '+esc(details):''}</span>`;
 topCard=top.kind==='songs'?`<button class="top-result-card" data-action="play-song" data-id="${esc(item.id)}">${content}<i class="result-play">${icon('play')}</i></button>`:`<a class="top-result-card ${top.kind==='artists'?'artist-result':''}" href="#${{artists:'artist',albums:'album',playlists:item.remote?'public-playlist':'playlist'}[top.kind]}/${encodeURIComponent(item.id)}">${content}</a>`;
 }
 html+=`<div class="search-leading">${section('Top result',topCard)}${ss.length?section('Songs',rows(ss.slice(0,4),'search-top'),btn('See all','search-kind','data-value="Songs"','text-button')):''}</div>`;
 }else if(['All','Songs'].includes(kind)&&ss.length)html+=section('Songs',rows(ss,'search',true));
 if(['All','Artists'].includes(kind)&&ar.length)html+=section('Artists',`<div class="cards">${ar.map(artistCard).join('')}</div>`,kind==='All'?btn('See all','search-kind','data-value="Artists"','text-button'):'');
 if(['All','Albums'].includes(kind)&&aa.length)html+=section('Albums',`<div class="cards">${aa.map(albumCard).join('')}</div>`,kind==='All'?btn('See all','search-kind','data-value="Albums"','text-button'):'');
 if(['All','Playlists'].includes(kind)&&pl.length)html+=section('Playlists',`<div class="cards">${pl.map(p=>p.remote?publicPlaylistCard(p):playlistCard(p)).join('')}</div>`,kind==='All'?btn('See all','search-kind','data-value="Playlists"','text-button'):'');
 if(!count)html+=empty('No results found','Try an artist, a song title, a few lyrics, or a YouTube link.',btn('Try again','search-retry'));
 if(result.cursor)html+=`<div class="button-row">${btn('Load more results','search-more','','primary')}</div>`;
 if(result.localPlaylists?.length&&kind==='Playlists')html+=section('Your playlists',`<div class="cards">${result.localPlaylists.map(playlistCard).join('')}</div>`);
 html+='<p class="credit">Search across YouTube Music · Songs, artists, albums and public playlists</p>';
 target.innerHTML=html;icons(target);
}
async function moreSearch(){
 const page=searchPage,token=searchToken;if(!page?.cursor)return;
 const button=$('[data-action="search-more"]');if(button){button.disabled=true;button.textContent='Loading…'}
 try{const result=await musicSearch.request({query:page.query,kind:page.kind,cursor:page.cursor,providerOrder:true},{signal:searchAbort?.signal});if(token!==searchToken||searchPage!==page)return;rememberSearch(result);for(const key of ['songs','artists','albums','playlists'])page[key]=mergeResults(page[key],result[key]);page.songs=page.songs.filter(s=>state.settings.explicit||!s.explicit);page.order=[...(page.order||[]),...(result.order||[])];page.cursor=result.cursor===page.cursor?'':result.cursor;drawSearch($('#search-results'),page)}catch(e){if(token===searchToken){toast(e.message);if(button){button.disabled=false;button.textContent='Load more results'}}}
}

async function addYouTube(id){let s=songs.get(id);if(!s){try{const r=await fetch('https://www.youtube.com/oembed?url='+encodeURIComponent('https://www.youtube.com/watch?v='+id)+'&format=json');if(!r.ok)throw Error();const j=await r.json();s={id,title:j.title,artist:j.author_name,album:'',artwork:j.thumbnail_url,duration:0,source:'youtube'}}catch{s={id,title:'YouTube recording',artist:'YouTube',album:'',artwork:'https://i.ytimg.com/vi/'+id+'/hqdefault.jpg',duration:0,source:'youtube'}}remember([s]);state.saved.unshift(id);state.saved=[...new Set(state.saved)];persist()}toast('Added '+s.title);await playSongs([s],0)}
async function importYouTubePlaylist(id){
 modal('Save YouTube playlist','<p class="loading"><span class="spinner"></span>Loading playlist…</p>');
 try{let page=await loadCollection('VL'+id);const seen=new Set();while(page.cursor){if(seen.has(page.cursor))throw Error('The next playlist page could not be loaded. Please retry.');seen.add(page.cursor);$('#modal-body').innerHTML=`<p class="loading"><span class="spinner"></span>Loaded ${page.songs.length} songs…</p>`;page=await loadCollection('VL'+id,true)}if(!page.songs.length)throw Error('This playlist has no available songs.');
 const meta=publicPlaylists.get(id),p={id:crypto.randomUUID(),name:meta?.name||'YouTube playlist',artwork:meta?.artwork,songs:[...new Set(page.songs.map(s=>s.id))],description:'Saved from YouTube Music',sourceUrl:'https://www.youtube.com/playlist?list='+id};state.playlists.push(p);persist();$('#modal').close();location.hash='playlist/'+p.id;toast('Saved '+p.songs.length+' songs');
 }catch(e){$('#modal-body').innerHTML=`<p class="notice error">${esc(e.message)}</p>${btn('Retry','import-youtube-playlist',`data-id="${esc(id)}"`)}`}
}

function libraryForm(p=null,smart=false){const r=p?.rules||{};modal(p?'Edit playlist':'New playlist',`<form id="playlist-form" data-id="${p?.id||''}"><label class="field">Name<input name="name" value="${esc(p?.name||'')}" required maxlength="100" placeholder="My playlist"></label><label class="field">Description<input name="description" value="${esc(p?.description||'')}" maxlength="300" placeholder="Optional"></label>${smart||p?.rules?`<label class="field">Source<select name="source"><option value="liked">Liked songs</option><option value="saved" ${r.source==='saved'?'selected':''}>Saved songs</option></select></label><label class="field">Artist contains<input name="artist" value="${esc(r.artist)}"></label><label class="field">Song title contains<input name="title" value="${esc(r.title)}"></label><label class="field">Album contains<input name="album" value="${esc(r.album)}"></label><label class="field">Order<select name="sort"><option value="newest">Recently added</option><option value="title" ${r.sort==='title'?'selected':''}>Song title</option><option value="artist" ${r.sort==='artist'?'selected':''}>Artist</option></select></label><label class="field">Maximum songs<input name="limit" type="number" min="1" value="${r.limit||''}" placeholder="No limit"></label>`:''}<div class="modal-actions">${p?btn('Delete playlist','delete-playlist',`data-id="${p.id}"`,'danger'):''}<button class="primary" type="submit">${p?'Save changes':'Create playlist'}</button></div></form>${!p&&!smart?`<hr class="divider"><div class="button-row">${btn('Smart playlist','new-smart')}${btn('Import from Spotify','spotify-import')}${btn('Import song list','text-import')}</div>`:''}${p&&!p.rules?`<hr class="divider"><h3>Songs</h3><div class="scroll-list">${playlistSongs(p).map((s,i)=>`<div class="manage-row"><span class="song-info"><strong>${esc(s.title)}</strong><small>${esc(s.artist)}</small></span>${btn(icon('up'),'playlist-move',`data-id="${p.id}" data-index="${i}" data-direction="-1" aria-label="Move ${esc(s.title)} up"`,'icon-button')}${btn(icon('down'),'playlist-move',`data-id="${p.id}" data-index="${i}" data-direction="1" aria-label="Move ${esc(s.title)} down"`,'icon-button')}${btn(icon('trash'),'playlist-remove',`data-id="${p.id}" data-song="${esc(s.id)}" aria-label="Remove ${esc(s.title)}"`,'icon-button')}</div>`).join('')}</div>`:''}`)}
function folderForm(f=null){modal(f?'Edit folder':'New folder',`<form id="folder-form" data-id="${f?.id||''}"><label class="field">Folder name<input name="name" required maxlength="100" value="${esc(f?.name||'')}" placeholder="Evening listening"></label><div class="modal-actions">${f?btn('Delete folder','delete-folder',`data-id="${f.id}"`,'danger'):''}<button class="primary">${f?'Save':'Create folder'}</button></div></form>`)}
function folderMembership(id){const f=state.folders.find(f=>f.id===id);const items=[...state.albums.map(id=>albums.get(id)).filter(Boolean).map(a=>({id:a.id,kind:'album',name:a.title,artwork:a.artwork})),...state.playlists.map(p=>({id:p.id,kind:'playlist',name:p.name,playlist:p,artwork:playlistSongs(p)[0]?.artwork}))];modal('Add or remove items',`<p class="small-copy">${esc(f.name)}</p><form id="folder-members-form" data-id="${id}"><div class="scroll-list">${items.map(i=>`<label class="check-row"><input name="items" type="checkbox" value="${i.kind}:${esc(i.id)}" ${f.items.some(x=>x.kind===i.kind&&x.id===i.id)?'checked':''}>${i.playlist?playlistCover(i.playlist):art(i.artwork,'',i.name)}<span>${esc(i.name)}<small>${i.kind}</small></span></label>`).join('')||'<p class="muted">Save an album or create a playlist first.</p>'}</div><div class="modal-actions"><button class="primary">Save items</button></div></form>`)}
function releasePicker(id){const choices=state.releaseChoices[id],releases=releasesForArtist(id);modal('Choose releases',`<p class="small-copy">Choose the releases you want to browse and play. New releases stay unselected after you save a selection.</p><div class="button-row">${btn('Select all','release-all')}${btn('Deselect all','release-none')}${btn('Use all automatically','release-auto',`data-id="${esc(id)}"`)}</div><form id="release-form" data-id="${esc(id)}"><label class="field">Find a release<input id="release-filter" type="search" placeholder="Album or single name"></label><div class="scroll-list">${['Albums','Singles & EPs'].map(kind=>`<h3>${kind}</h3>${releases.filter(a=>releaseKind(a)===kind).map(a=>`<label class="check-row" data-filter="${esc(norm(a.title))}"><input name="release" type="checkbox" value="${esc(a.id)}" ${choices===undefined||choices.includes(a.id)?'checked':''}>${art(a.artwork,'',a.title)}<span>${esc(a.title)}<small>${esc(a.kind||a.type||'Album')}${a.year?' · '+esc(a.year):''}</small></span></label>`).join('')}`).join('')}</div><div class="modal-actions"><button class="primary">Save selection</button></div></form>`)}
let playlistArtworkDraft=null;
function drawPlaylistArtworkPreview(){const form=$('#playlist-artwork-form'),p=state.playlists.find(p=>p.id===form?.dataset.id);if(p)$('#playlist-artwork-preview').innerHTML=playlistCover({...p,collectionArtwork:playlistArtworkDraft,native:undefined},'collection-art')}
function editPlaylistArtwork(id){const p=state.playlists.find(p=>p.id===id);playlistArtworkDraft=structuredClone(Object.hasOwn(p,'collectionArtwork')?p.collectionArtwork:(p.native?.customArtwork?.style!=='photo'?p.native?.customArtwork:null)??null);modal('Edit artwork',`<form id="playlist-artwork-form" data-id="${esc(id)}"><div id="playlist-artwork-preview"></div><label class="field">Choose your photo<input id="playlist-artwork-photo" type="file" accept="image/jpeg,image/png,image/webp"></label><div class="button-row">${btn('Album cover collage','artwork-collage','type="button"')}${btn('Use default artwork','artwork-default','type="button"')}</div><h3>Choose an icon</h3><div class="artwork-icon-options">${Object.entries(artworkSymbols).map(([symbol,name])=>btn(icon(name),'artwork-icon',`type="button" data-symbol="${symbol}" aria-label="${esc(symbol.replaceAll('.fill','').replaceAll('.',' '))}"`,'icon-button')).join('')}</div><p class="small-copy">Playlist artwork syncs across your devices.</p><div class="modal-actions"><button class="primary">Save artwork</button></div></form>`);drawPlaylistArtworkPreview()}
document.addEventListener('change',async e=>{if(e.target.id!=='playlist-artwork-photo')return;const file=e.target.files[0],form=e.target.closest('form');if(!file)return;const save=form.querySelector('.primary');save.disabled=true;try{if(!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>15000000)throw Error('Choose a PNG, JPEG or WebP photo under 15 MB.');const bitmap=await createImageBitmap(file),canvas=document.createElement('canvas');canvas.width=canvas.height=512;const side=Math.min(bitmap.width,bitmap.height);canvas.getContext('2d').drawImage(bitmap,(bitmap.width-side)/2,(bitmap.height-side)/2,side,side,0,0,512,512);bitmap.close();const draft=validateCollectionArtwork({style:'photo',image:canvas.toDataURL('image/jpeg',.8)});if(form.isConnected){playlistArtworkDraft=draft;drawPlaylistArtworkPreview()}}catch(e){toast(e.message)}finally{save.disabled=false}});
function artistPlaylistPicker(id){modal('Your playlists',`<form id="artist-playlists-form" data-id="${esc(id)}"><p class="small-copy">Choose playlists for ${esc(artists.get(id)?.name)}.</p><div class="scroll-list">${state.playlists.map(p=>`<label class="check-row"><input type="checkbox" name="playlist" value="${p.id}" ${playlistArtistId(p)===id?'checked':''}>${playlistCover(p)}<span>${esc(p.name)}</span></label>`).join('')||'<p class="muted">Create a playlist in Home first.</p>'}</div><div class="modal-actions"><button class="primary">Save playlists</button></div></form>`)}

function settings(){modal('Settings',`<h3>Nova Music account</h3><p class="small-copy">${accountClient?.user?'Signed in as '+esc(accountClient.user.email):'Sign in to use the same library in the app and browser.'}</p>${btn(accountClient?.user?'Account and sync':'Sign in','account')}<hr class="divider"><form id="settings-form"><h3>Playback</h3>${btn('Playback status','playback-health')}<label class="check-row"><input name="explicit" type="checkbox" ${state.settings.explicit?'checked':''}>Include explicit recordings</label><label class="field">Lyrics timing offset (seconds)<input name="lyricsOffset" type="number" min="-30" max="30" step="0.1" value="${state.settings.lyricsOffset}"></label><h3>Connected catalogs</h3><label class="field">YouTube Data API key<input name="youtubeKey" type="password" value="${esc(state.settings.youtubeKey)}" autocomplete="off" placeholder="Optional — additional import matching"></label><p class="small-copy">Live YouTube Music search and public playlists work without a key. This optional key is used only as an additional recording matcher for imports. Restrict your key to this website and the YouTube Data API in <a href="https://console.cloud.google.com/apis/credentials" target="_blank" rel="noopener">Google Cloud</a>. It is stored only in this browser.</p><label class="field">Spotify app client ID<input name="spotifyClientId" value="${esc(state.settings.spotifyClientId)}" placeholder="Optional — enables Spotify import"></label><p class="small-copy">Register <strong>${esc(location.origin+location.pathname)}</strong> as the exact redirect URL in your Spotify app. No client secret is needed.</p><div class="modal-actions"><button class="primary">Save settings</button></div></form><hr class="divider"><h3>Your library</h3><p class="small-copy">${accountClient?.user?'Your account library syncs across devices.':'Your library stays on this device until you sign in.'} Imported audio stays on its original device. Backups contain metadata; export audio separately.</p><div class="button-row">${btn('Export backup','export')}${btn('Restore backup','restore')}${btn('Import audio','local-import')}</div><hr class="divider"><p class="small-copy">The player displays album artwork while music plays. Background playback, AirPlay and lock-screen behavior depend on your browser and music source. Siri and iOS Live Activities are available in the native app.</p>`)}
function songMenu(id){const s=songs.get(id);if(!s)return;menu(s.title,`<div class="menu-list">${btn(icon('play')+' Play','play-song',`data-id="${esc(id)}"`)}${btn(icon('next')+' Play next','enqueue-next',`data-id="${esc(id)}"`)}${btn(icon('queue')+' Add to queue','enqueue',`data-id="${esc(id)}"`)}${btn(icon('heart')+(state.liked.includes(id)?' Unlike':' Like song'),'like',`data-id="${esc(id)}"`)}${btn(icon('download')+(state.saved.includes(id)?' Remove saved song':' Save song'),'save-song',`data-id="${esc(id)}"`)}${btn(icon('plus')+' Add to playlist','add-playlist',`data-id="${esc(id)}"`)}${s.albumId?`<a href="#album/${encodeURIComponent(s.albumId)}" data-action="close-modal">${icon('album')}Go to album</a>`:''}${s.artistId?`<a href="#artist/${encodeURIComponent(s.artistId)}" data-action="close-modal">${icon('artist')}Go to artist</a>`:''}${btn(icon('info')+' Song info','song-info',`data-id="${esc(id)}"`)}${btn(icon('lyrics')+' Add lyrics','edit-lyrics',`data-id="${esc(id)}"`)}${s.source==='youtube'?`<a href="https://music.youtube.com/watch?v=${encodeURIComponent(id)}" target="_blank" rel="noopener">${icon('play')}Open in YouTube Music</a>`:''}${btn('Share song','share',`data-id="${esc(id)}"`)}</div>`)}
function toggleIn(key,id){const index=state[key].indexOf(id);if(index<0)state[key].unshift(id);else state[key].splice(index,1);persist();return index<0}
function reviewLibraryLink(){
 const count=playlistReviewEntries(state.playlists).length;
 if(!count)return '';
 return `<a class="review-summary" href="#review">${icon('check')}<span><strong>Songs to review</strong><small>${count} to pair across your imported playlists</small></span>${icon('next')}</a>`;
}
function reviewRows(playlists,paired=false){
 return playlistReviewEntries(playlists,{paired}).map(({playlist,entry,key})=>{
  const chosen=songs.get(entry.matchedSongId);
  const body=`<span><strong>${esc(entry.title||'Unavailable song')}</strong><small>${esc(entry.artist)}${entry.album?' · '+esc(entry.album):''}</small><small class="review-playlist">${esc(playlist.name)}${Number.isInteger(entry.position)?' · Spotify #'+(entry.position+1):''}${entry.duration?' · '+time(entry.duration):''}</small><small>${esc(entry.reason||'No close match found')}</small>${paired?`<small>Paired: ${esc(chosen?.title||'Recording added')}${chosen?' · '+esc(chosen.artist):''}</small>`:''}</span>${icon(paired?'check':'search')}`;
  return paired?`<div class="review-row paired">${body}</div>`:btn(body,'pair-song',`data-id="${esc(playlist.id)}" data-key="${esc(key)}"`,'review-row');
 }).join('')||`<p class="muted">${paired?'No songs paired yet.':'All songs are paired.'}</p>`;
}
function reviewPage(){
 const count=playlistReviewEntries(state.playlists).length,paired=playlistReviewEntries(state.playlists,{paired:true}).length;
 return heading('Songs to review','IMPORTED PLAYLISTS')+`<p class="muted">${count} to pair · ${paired} paired</p><p class="small-copy">Tap an unpaired song to search the full music catalog. Choosing a recording adds it to its original playlist.</p>`+section('Needs pairing',reviewRows(state.playlists))+(paired?`<details class="paired-review"><summary>Paired songs · ${paired}</summary>${reviewRows(state.playlists,true)}</details>`:'');
}
let songSearch=null,songSearchTimer;
function stopSongSearch(){clearTimeout(songSearchTimer);songSearch?.controller?.abort();songSearch=null;}
function openSongSearch(context){
 const playlist=state.playlists.find(p=>p.id===context.playlistId);
 const entry=context.importIndex!==undefined?pendingImport?.entries[context.importIndex]?.source:playlist?.unmatched?.find((entry,i)=>unmatchedKey(entry,i)===context.key);
 if(context.key&&(!entry||entry.matchedSongId)||context.importIndex!==undefined&&!entry)return;
 const pairing=Boolean(entry),query=entry?[entry.title,entry.artist].filter(Boolean).join(' '):'';
 modal(pairing?'Pair song':'Add songs',`${pairing?`<p class="small-copy">Find a recording for <strong>${esc(entry.title)}</strong> · ${esc(entry.artist)}${playlist?' in '+esc(playlist.name):''}</p>`:''}<form id="song-search-form"><label class="field">Search all music<input id="song-search-input" name="query" type="search" value="${esc(query)}" placeholder="Song or artist" autocomplete="off" maxlength="200"></label></form><div id="song-search-results" class="scroll-list" aria-live="polite"><p class="muted">Search the full music catalog by song or artist.</p></div><div class="modal-actions">${context.importIndex!==undefined?btn('Back to review','song-search-back'):btn('Done','close-modal')}</div>`);
 songSearch={...context,pairing,query,results:[],cursor:'',token:0,controller:null};
 if(query)runSongSearch();
}
function queueSongSearch(){
 const picker=songSearch;if(!picker)return;
 clearTimeout(songSearchTimer);picker.controller?.abort();picker.token++;picker.results=[];picker.cursor='';
 $('#song-search-results').innerHTML='<p class="muted">Searching music…</p>';
 songSearchTimer=setTimeout(()=>runSongSearch(),350);
}
function drawSongSearch(){
 const picker=songSearch,root=$('#song-search-results');if(!picker||!root)return;
 const playlist=state.playlists.find(p=>p.id===picker.playlistId);
 root.innerHTML=picker.results.map(song=>{
  const added=!picker.pairing&&playlist?.songs.includes(song.id);
  return btn(`${art(song.artwork,'song-image','')}<span><strong>${esc(song.title)}</strong><small>${esc(song.artist)}${song.album?' · '+esc(song.album):''}${song.duration?' · '+time(song.duration):''}</small></span>${icon(added?'check':picker.pairing?'check':'plus')}`,'song-search-select',`data-song="${esc(song.id)}" aria-label="${esc((added?'Added ':picker.pairing?'Pair with ':'Add ')+song.title+' by '+song.artist)}" ${added?'disabled':''}`,'song-search-row');
 }).join('')||'<p class="muted">No songs found. Try another title or artist.</p>';
 if(picker.cursor)root.innerHTML+=btn('More results','song-search-more');
}
async function runSongSearch(more=false){
 const picker=songSearch,root=$('#song-search-results');if(!picker||!root)return;
 clearTimeout(songSearchTimer);picker.controller?.abort();const controller=new AbortController();picker.controller=controller;
 const token=++picker.token,query=$('#song-search-input').value.trim(),cursor=more?picker.cursor:'';
 picker.query=query;
 if(!query){picker.results=[];picker.cursor='';root.innerHTML='<p class="muted">Search the full music catalog by song or artist.</p>';return}
 if(!more){picker.results=[];picker.cursor='';root.innerHTML='<p class="loading"><span class="spinner"></span>Searching music…</p>'}else{const button=$('[data-action="song-search-more"]',root);if(button)button.disabled=true}
 try{
  const result=await musicSearch.request({query,kind:'Songs',providerOrder:true,...(cursor?{cursor}:{})},{signal:controller.signal});
  if(songSearch!==picker||token!==picker.token||controller.signal.aborted)return;
  picker.results=mergeResults(more?picker.results:[],result.songs||[]).filter(s=>state.settings.explicit||!s.explicit);
  picker.cursor=result.cursor===cursor?'':result.cursor||'';remember(picker.results);drawSongSearch();
 }catch(error){
  if(songSearch!==picker||token!==picker.token||controller.signal.aborted)return;
  root.innerHTML=`<p class="notice error">${esc(error.message||'Search failed. Try again.')}</p>${btn('Try again','song-search-retry')}`;
 }
}
function selectSearchSong(id){
 const picker=songSearch,song=picker?.results.find(s=>s.id===id);if(!picker||!song)return;
 if(picker.importIndex!==undefined){
  const entry=pendingImport?.entries[picker.importIndex];if(!entry)return;
  entry.song=song;entry.selected=true;entry.review=false;entry.failed=false;entry.detail='Recording chosen by you';entry.reason='';
  showImportReview();return;
 }
 const playlist=state.playlists.find(p=>p.id===picker.playlistId);if(!playlist||playlist.rules){toast('This playlist is no longer available.');return}
 if(picker.pairing){
  if(!pairPlaylistEntry(playlist,picker.key,song)){toast('This song has already been paired or removed.');return}
  persist();$('#modal').close();render();toast('Paired and added to '+playlist.name);
 }else{
  if(!playlist.songs.includes(id))playlist.songs.push(id);
  persist();render();drawSongSearch();toast('Added to '+playlist.name);
 }
}
$('#modal').addEventListener('close',()=>{
 const returnToImport=songSearch?.importIndex!==undefined;stopSongSearch();
 if(returnToImport&&pendingImport)setTimeout(showImportReview,0);
});
function collectionPicker(songId,playlistId){if(playlistId){const p=state.playlists.find(p=>p.id===playlistId);if(!p||p.rules){toast('Smart playlists use rules. Edit the rules to change their songs.');return}openSongSearch({playlistId})}else modal('Add to playlist',`<div class="menu-list">${state.playlists.filter(p=>!p.rules).map(p=>btn(esc(p.name),'playlist-add-song',`data-id="${p.id}" data-song="${esc(songId)}"`)).join('')||'<p class="muted">Create a playlist first.</p>'}${btn('New playlist','new-playlist')}</div>`)}
const playbackHealth=new PlaybackHealth();
let playToken=0,objectURL=null,youtubeClockId='',youtubeGeneration=0,cancelYouTube=null;
async function ensureYouTube(){
 if(yt)return yt;if(ytPromise)return ytPromise;
 const generation=youtubeGeneration;
 const events={
  onStateChange:e=>{
   if(e.data===3)playbackHealth.event('buffering');
   if(generation!==youtubeGeneration||connect?.remote)return;
   if(current?.source!=='youtube'||!playbackSample(current,yt,audio).confirmed)return;
   if(e.data===1){youtubeClockId=current.id;setPlaying(true);current.duration=yt.getDuration();remember([current]);tick();}
   if(e.data===2||e.data===5){youtubeClockId=current.id;setPlaying(false);tick();}
   if(e.data===0){setPlaying(false);nextSong(true)}
  },
  onPlaybackRateChange:e=>playbackHealth.event('rate',e.data),
  onAutoplayBlocked:()=>{if(generation!==youtubeGeneration||connect?.remote)return;setPlaying(false);toast('Press Play in this browser to enable audio on this device.');},
  onError:e=>{if(generation!==youtubeGeneration||connect?.remote)return;setPlaying(false);toast(e.message||([101,150].includes(e.data)?'This recording cannot play here. Open it in YouTube Music from Song options, or choose another recording.':'YouTube could not play this recording. Try another song.'))}
 };
 if(window.novaDesktop?.nativeAudio){yt=new NativeMusicPlayer(window.novaDesktop,events);return yt;}
 ytPromise=new Promise((resolve,reject)=>{
  cancelYouTube=()=>{clearTimeout(timer);reject(Error('Output changed.'))};
  const timer=setTimeout(()=>{ytPromise=null;reject(Error('YouTube couldn’t load. Check your connection or open the song in YouTube Music.'))},18000);
  window.onYouTubeIframeAPIReady=()=>{
   if(generation!==youtubeGeneration)return;
   yt=new YT.Player('youtube-player',{height:220,width:330,playerVars:{playsinline:1,origin:location.origin,controls:1,rel:0},events:{...events,onReady:e=>{clearTimeout(timer);if(generation!==youtubeGeneration){e.target.destroy();return;}cancelYouTube=null;yt.setVolume(state.settings.volume);resolve(yt)}}});
  };
  if(window.YT?.Player)window.onYouTubeIframeAPIReady();else{
   const script=document.createElement('script');script.src='https://www.youtube.com/iframe_api';script.onerror=()=>{clearTimeout(timer);ytPromise=null;reject(Error('YouTube player unavailable.'))};document.head.append(script)
  }
 });return ytPromise;
}
async function playSongs(list,index=0){
 if(!list.length){toast('No playable songs in this collection.');return;}
 if(accountClient?.user && !applyingConnectedPlayback){
  if(list.every(song=>song.source==='youtube')){await connect.command({queue:list,index:Math.max(0,Math.min(index,list.length-1)),position:0,playing:true,shuffle,repeat});return;}
  if(connect.remote)throw Error('Choose this browser as the output to play imported audio files.');
  // Local files stay playable here, while other devices see an empty transferable queue.
  await connect.command({queue:[],index:0,position:0,playing:false,shuffle:false,repeat:0},connect.id);
 }
 queue=list.map(s=>s.id);queueIndex=Math.max(0,Math.min(index,queue.length-1));await playCurrent();
}
const audioVersions=new Map();
async function playCurrent(startAt=0,shouldPlay=true){
 if(connect?.remote && !applyingConnectedPlayback){await connect.command({...connectedPlaybackSnapshot(),position:0,playing:true});return;}
 let s=songs.get(queue[queueIndex]);if(!s)return;const token=++playToken;
 youtubeClockId='';audio.pause();await yt?.pauseVideo?.();if(token!==playToken)return;lyricAbort?.abort();++lyricToken;lastLyric=-1;
 if(objectURL){URL.revokeObjectURL(objectURL);objectURL=null}
 current=s;lyricData=null;lyricDurationRequest='';setPlaying(false);renderPanel();
 try{if(s.musicVideoType==='MUSIC_VIDEO_TYPE_OMV'){
   const chosen=audioVersions.get(s.id)||await preferredAudio(s,input=>musicSearch.request(input));
   if(token!==playToken)return;audioVersions.set(s.id,chosen);s=chosen;remember([s]);queue[queueIndex]=s.id;current=s;
 }}catch{if(token!==playToken)return}
 state.recent=[{id:s.id,at:Date.now()},...state.recent.filter(r=>r.id!==s.id)].slice(0,100);persist();
 $('#current-song').innerHTML=art(s.artwork,s.artwork?'':'small',s.title)+`<span><strong>${esc(s.title)}</strong><small>${esc(s.artist)}</small></span>`;
 $('#seek').value=0;$('#elapsed').textContent='0:00';$('#duration').textContent=time(s.duration);
 if(s.source==='youtube'){
   $('#youtube-host').classList.remove('hidden');const player=await ensureYouTube();if(token!==playToken)return;
   playbackHealth.event('load',startAt);await player.setVolume(state.settings.volume);if(shouldPlay)await player.loadVideoById({videoId:s.id,startSeconds:startAt,title:s.title,artist:s.artist});else await player.cueVideoById({videoId:s.id,startSeconds:startAt,title:s.title,artist:s.artist});
 }else{
   if(window.novaDesktop?.nativeAudio){yt?.destroy?.();yt=null;ytPromise=null;}
   $('#youtube-host').classList.add('hidden');
   if(s.source==='local'){const file=await fileStore('get',s.id);if(token!==playToken)return;if(!file)throw Error('This audio file is missing on this device. Import it again.');objectURL=URL.createObjectURL(file);audio.src=objectURL}else audio.src=s.previewUrl||s.url;
   audio.volume=state.settings.volume/100;await audio.play();if(token!==playToken){audio.pause();return}setPlaying(true);
 }
 updateMediaSession();loadLyrics(s);renderPanel();$$('[data-song-row]').forEach(row=>row.classList.toggle('playing',row.dataset.songRow===s.id));
}
function setPlaying(value){const changed=playing!==value;playing=value;reportDesktopPlayback();if(changed)connect?.publishStatus();updateTransportButtons();if(!(window.novaDesktop?.nativeAudio&&current?.source==='youtube')&&navigator.mediaSession)navigator.mediaSession.playbackState=value?'playing':'paused'}
async function togglePlay(){if(connect?.remote && !applyingConnectedPlayback){await connect.setPlayingIntent(!(connect.pendingPlaying ?? playing));return;}if(!current){toast('Choose a song to start listening.');return}if(current.source==='youtube'){if(playing){await yt?.pauseVideo();setPlaying(false)}else{const p=await ensureYouTube();await p.playVideo()}}else if(playing)audio.pause();else await audio.play()}
async function nextSong(ended=false){if(connect?.remote && !applyingConnectedPlayback){if(!ended)await remotePlaybackAction('next',{});return;}if(!queue.length)return;if(ended&&repeat===2){await seekTo(0);if(current.source==='youtube')await yt.playVideo();else await audio.play();return}if(shuffle&&queue.length>1){const choices=queue.map((_,i)=>i).filter(i=>i!==queueIndex);queueIndex=choices[Math.floor(Math.random()*choices.length)]}else if(queueIndex+1<queue.length)queueIndex++;else if(repeat===1)queueIndex=0;else{if(!ended){if(current?.source==='youtube')yt?.pauseVideo();else audio.pause();toast('You’re at the end of the queue.')}setPlaying(false);return}await playCurrent()}
function samplePlayback(){if(connect?.remote && mirroredPlayback)return {position:snapshotPosition(mirroredPlayback),duration:mirroredPlayback.queue[mirroredPlayback.index]?.duration||0,confirmed:true};return playbackSample(current,yt,audio,youtubeClockId)}
function position(){return connect?.remote && mirroredPlayback?snapshotPosition(mirroredPlayback):samplePlayback().position}
function duration(){return connect?.remote && mirroredPlayback?mirroredPlayback.queue[mirroredPlayback.index]?.duration||0:samplePlayback().duration}
async function seekTo(seconds){if(connect?.remote && !applyingConnectedPlayback){connect.command(s=>({...s,position:Math.max(0,Number(seconds)||0),positionIntent:'seek'})).catch(e=>toast(e.message));return;}seconds=Math.max(0,Math.min(Number(seconds)||0,duration()));if(current?.source==='youtube'){playbackHealth.event('seek',seconds);await yt?.seekTo?.(seconds,true);}else if(current)audio.currentTime=seconds;tick();connect?.publishStatus()}
function updateMediaSession(){if(window.novaDesktop?.nativeAudio&&current?.source==='youtube'||!navigator.mediaSession||!current)return;try{navigator.mediaSession.metadata=new MediaMetadata({title:current.title,artist:current.artist,album:current.album||'',artwork:current.artwork?[{src:current.artwork}]:[]});for(const[name,fn]of Object.entries({play:()=>{if(!playing)togglePlay()},pause:()=>{if(playing)togglePlay()},previoustrack:()=>action('previous',{}),nexttrack:()=>nextSong(),seekto:e=>seekTo(e.seekTime),seekbackward:e=>seekTo(position()-(e.seekOffset||10)),seekforward:e=>seekTo(position()+(e.seekOffset||10))}))try{navigator.mediaSession.setActionHandler(name,fn)}catch{}}catch{}}
function openPanel(tab='song'){panelTab=tab;$('#player-panel').hidden=false;renderPanel()}
function renderPanel(){
 renderFullscreenLyrics();
 const body=$('#panel-body');$('#player-panel').dataset.view=panelTab;
 $('#panel-switcher').innerHTML=['song','lyrics','queue'].map(t=>`<button data-action="panel-tab" data-value="${t}" aria-pressed="${panelTab===t}" class="${panelTab===t?'active':''}">${{song:'Now playing',lyrics:'Lyrics',queue:'Queue'}[t]}</button>`).join('');
 if(!current){body.innerHTML='<p class="muted">Choose a song to start listening.</p>';return}
 if(panelTab==='lyrics'){body.innerHTML=`<div class="lyrics-track"><strong>${esc(current.title)}</strong><span>${esc(current.artist)}</span>${btn(icon('expand')+' Full screen','fullscreen-lyrics','','secondary')}${btn('Retry synced lyrics','lyrics-retry','','text-button')}<div class="lyrics-timing" aria-label="Lyrics timing">${btn('Earlier','lyrics-timing','data-value="0.25" aria-label="Show lyrics a quarter second earlier"')}${btn('Later','lyrics-timing','data-value="-0.25" aria-label="Show lyrics a quarter second later"')}<span>${Number(lyricOffset()).toFixed(2)} s</span>${btn('Reset','lyrics-timing','data-value="reset"')}</div></div><div class="lyrics-scroll" tabindex="0" aria-label="Song lyrics">${lyricsHTML()}</div>`;highlightLyrics(true);return}
 let html=panelTab==='song'?`<div class="panel-song">${art(current.artwork,'panel-art',current.title)}<h2>${esc(current.title)}</h2><p>${esc(current.artist)}</p><div class="button-row">${btn(icon('heart'),'like',`data-id="${esc(current.id)}" aria-label="Like song"`,'icon-button'+(state.liked.includes(current.id)?' active':''))}${btn(icon('more'),'song-menu',`data-id="${esc(current.id)}" aria-label="Song options"`,'icon-button')}${btn(icon('screen'),'output-location','aria-label="Output location"','icon-button')}${btn(icon('screen'),'receiver','aria-label="Artwork and lyrics display"','icon-button')}</div></div>`:'';
 if(panelTab==='queue')html+=`<h3>Up next · ${Math.max(0,queue.length-queueIndex-1)} songs</h3><div>${queue.map((id,i)=>{const s=songs.get(id);if(!s)return'';return `<div class="queue-row">${art(s.artwork,'song-image','')}<button class="song-info" data-action="queue-play" data-index="${i}"><strong>${i===queueIndex?'▶ ':''}${esc(s.title)}</strong><small>${esc(s.artist)}</small></button>${btn(icon('up'),'queue-move',`data-index="${i}" data-direction="-1" aria-label="Move up"`,'icon-button')}${btn('×','queue-remove',`data-index="${i}" aria-label="Remove ${esc(s.title)}"`,'icon-button')}</div>`}).join('')}</div>`;
 else html+=`<p class="small-copy">${esc(current.album||'')}${current.explicit?' · Explicit':''}</p><div class="button-row">${btn('Song info','song-info',`data-id="${esc(current.id)}"`)}${btn('Add to playlist','add-playlist',`data-id="${esc(current.id)}"`)}</div><div class="timeline panel-timeline"><span>${time(position())}</span><input type="range" data-panel-seek min="0" max="${duration()||100}" value="${position()}" step="0.1" aria-label="Seek song"><span>${time(duration())}</span></div><div class="transport panel-transport">${btn(icon('shuffle'),'shuffle','aria-label="Shuffle"','icon-button'+(shuffle?' active':''))}${btn(icon('previous'),'previous','aria-label="Previous song"','icon-button')}${btn(icon(playing?'pause':'play'),'toggle-play',`aria-label="${playing?'Pause':'Play'} song"`,'play-main')}${btn(icon('next'),'next','aria-label="Next song"','icon-button')}${btn(icon('repeat'),'repeat','aria-label="Repeat"','icon-button'+(repeat?' active':''))}</div>`;
 body.innerHTML=html;updateTransportButtons();
}
const lyricsCache=new Map();
let lyricAbort;
async function loadLyrics(s,matchedDuration=0){
 const token=++lyricToken;lyricAbort?.abort();lyricAbort=new AbortController();lastLyric=-1;lyricData=null;
 const show=()=>{renderPanel();renderReceiver();connect?.publishStatus()};show();
 const shared=sharedConnectedLyrics();
 if(shared?.loaded){lyricData=connectedLyricData(shared);show();return;}
 if(shared?.recordingID && shared.recordingID!==s.id)s={...s,id:shared.recordingID,musicVideoType:'MUSIC_VIDEO_TYPE_ATV'};
 if(s.lyrics){lyricData={plain:s.lyrics,lines:normalizedLines(parseLRC(s.lyrics)),source:'Your lyrics',custom:true};show();return}
 const sample=samplePlayback(),identity={...s,duration:matchedDuration||(sample.confirmed?sample.duration:0)||s.duration||0};
 const controller=lyricAbort,timeout=setTimeout(()=>controller.abort(),25000);let linked=null,recordingType=s.musicVideoType;
 try{
  if(s.source==='youtube'){
   try{const result=await musicSearch.request({op:'lyrics',id:s.id,duration:Math.round(identity.duration)},{signal:controller.signal});linked=result.lyrics;recordingType=result.recordingType||recordingType;
    if(linked){linked={...linked,lines:normalizedLines(linked.lines||[])};if(linked.lines.length||recordingType!=='MUSIC_VIDEO_TYPE_ATV'){if(token!==lyricToken)return;lyricData={...linked,requestedDuration:identity.duration};show();return}}
   }catch(error){if(controller.signal.aborted)throw error}
  }
  let record=lyricsCache.get(s.id);if(record&&identity.duration&&Math.abs(record.duration-identity.duration)>3)record=null;
  if(!record){record=await lookupLyrics({...identity,musicVideoType:recordingType},{signal:controller.signal});if(record)lyricsCache.set(s.id,record)}
  if(token!==lyricToken)return;
  const fallback=providerLyricData(record,{...identity,musicVideoType:recordingType});
  lyricData={...(fallback.lines.length||!linked?fallback:linked),requestedDuration:identity.duration};
 }catch{if(token!==lyricToken)return;lyricData={...(linked||{plain:'',lines:[],missing:true}),requestedDuration:identity.duration}}finally{clearTimeout(timeout)}
 show();
}
function lyricsHTML(){if(!lyricData)return '<p class="loading"><span class="spinner"></span>Finding lyrics…</p>';if(lyricData.instrumental)return '<p class="muted">Instrumental recording</p>';if(lyricData.missing||(!lyricData.plain&&!lyricData.lines.length))return `<p class="muted">Lyrics are unavailable for this recording.</p>${btn('Add your lyrics','edit-lyrics',`data-id="${esc(current.id)}"`)}`;return `<div class="lyric-lines">${(lyricData.lines.length?lyricData.lines:lyricData.plain.split('\n').map(text=>({text}))).map((line,i)=>line.time!==undefined?`<button class="lyric-line" data-action="lyric-seek" data-time="${line.time}" data-line="${i}">${esc(line.text)||'♪'}</button>`:`<p class="lyric-line">${esc(line.text)||' '}</p>`).join('')}</div><p class="lyrics-source">${lyricData.lines.length?'Synced lyrics':'Lyrics'} · ${esc(lyricData.source)}</p>`}
let lastLyric=-1;
function lyricOffset(){return sharedConnectedLyrics()?.offset ?? Number(state.settings.lyricsOffset||0)+Number(state.settings.lyricsOffsets?.[current?.id]||0)}
function lyricRate(){return sharedConnectedLyrics()?.rate ?? 1}
function lyricPlaybackTime(time){return Math.max(0,(time-lyricOffset())/lyricRate())}
function highlightLyrics(force=false){
 if(!lyricData?.lines?.length)return;
 const sample=samplePlayback(),active=sample.confirmed?activeLyric(lyricData.lines,sample.position*lyricRate()+lyricOffset()):-1;if(!force&&active===lastLyric)return;
 $$('[data-line]').forEach(el=>{const on=Number(el.dataset.line)===active;el.classList.toggle('active',on);if(on)el.setAttribute('aria-current','true');else el.removeAttribute('aria-current')});
 if(force||active!==lastLyric){lastLyric=active;for(const container of $$('.lyrics-scroll, #receiver-lyrics')){const target=container.querySelector(`[data-line="${active}"]`);if(target){const y=target.getBoundingClientRect().top-container.getBoundingClientRect().top+container.scrollTop-container.clientHeight*.35;container.scrollTo({top:Math.max(0,y),behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'})}}}
}
let lyricsFullscreenRequested=false;
async function openFullscreenLyrics(){
 const dialog=$('#lyrics-fullscreen');renderFullscreenLyrics();
 if(!dialog.open)dialog.showModal();
 if(window.novaDesktop){window.novaDesktop.post({type:'lyricsFullscreen',enabled:true});}
 else if(!document.fullscreenElement){try{await document.documentElement.requestFullscreen();lyricsFullscreenRequested=true}catch{}}
 $('#lyrics-fullscreen [data-action="close-fullscreen-lyrics"]')?.focus();highlightLyrics(true);
}
function closeFullscreenLyrics(){
 $('#lyrics-fullscreen').close();
 if(window.novaDesktop)window.novaDesktop.post({type:'lyricsFullscreen',enabled:false});
 if(lyricsFullscreenRequested && document.fullscreenElement)document.exitFullscreen().catch(()=>{});
 lyricsFullscreenRequested=false;
 $('[data-action="fullscreen-lyrics"]')?.focus();
}
function renderFullscreenLyrics(){
 const dialog=$('#lyrics-fullscreen');if(!dialog)return;
 // Preserve the scrolling view while the engine updates its clock.
 const key=JSON.stringify([current?.id,current?.title,current?.artist,current?.artwork,lyricData]);
 if(dialog.dataset.track===key)return;dialog.dataset.track=key;
 $('#fullscreen-lyrics-body').innerHTML=`<header class="fullscreen-lyrics-heading"><span>NOW PLAYING · LYRICS</span>${btn('×','close-fullscreen-lyrics','aria-label="Close full screen lyrics"','icon-button')}</header><div class="fullscreen-lyrics-layout"><aside class="fullscreen-track">${current?`${art(current.artwork,'fullscreen-cover',current.title)}<h1>${esc(current.title)}</h1><p>${esc(current.artist)}</p>`:'<h1>Choose a song to see its lyrics</h1>'}</aside><div class="lyrics-scroll fullscreen-lyrics-scroll" tabindex="0" aria-label="Full screen song lyrics">${current?lyricsHTML():'<p class="muted">Your synced lyrics will appear here.</p>'}</div></div><footer class="fullscreen-lyrics-controls"><div class="transport">${btn(icon('previous'),'previous','aria-label="Previous song"','icon-button')}${btn(icon(playing?'pause':'play'),'toggle-play',`aria-label="${playing?'Pause':'Play'} song"`,'play-main')}${btn(icon('next'),'next','aria-label="Next song"','icon-button')}${btn(icon('screen'),'output-location','aria-label="Output location"','icon-button')}</div><div class="timeline"><span>${time(position())}</span><input type="range" data-panel-seek min="0" max="${duration()||100}" value="${position()}" step="0.1" aria-label="Seek song in full screen"><span>${time(duration())}</span></div></footer>`;
 highlightLyrics(true);
}
$('#lyrics-fullscreen').addEventListener('cancel',event=>{event.preventDefault();closeFullscreenLyrics()});
document.addEventListener('fullscreenchange',()=>{if(lyricsFullscreenRequested&&!document.fullscreenElement)closeFullscreenLyrics()});
window.addEventListener('nova-desktop-command',event=>{const commands={lyrics:()=>openFullscreenLyrics(),home:()=>{location.hash='library'},search:()=>{location.hash='search';$('#search-input').focus()},output:outputLocation,play:togglePlay,next:()=>nextSong(),previous:()=>action('previous',{})};commands[event.detail]?.()});
function renderReceiver(){if(!$('#receiver-song'))return;$('#receiver-song').innerHTML=current?`${art(current.artwork,'receiver-art',current.title)}<h1>${esc(current.title)}</h1><p class="muted">${esc(current.artist)}</p>`:'<h1>Choose a song first</h1>';$('#receiver-lyrics').innerHTML=current?lyricsHTML():'';highlightLyrics(true)}
let lyricDurationRequest='';
function tick(){
 const d=duration(),p=position();
 if(!seekDragging){$('#seek').max=d||100;$('#seek').value=p;$('#elapsed').textContent=time(p);$('#duration').textContent=time(d)}
 for(const panel of $$('[data-panel-seek]'))if(document.activeElement!==panel){panel.max=d||100;panel.value=p;panel.previousElementSibling.textContent=time(p);panel.nextElementSibling.textContent=time(d)}
 if(lyricData&&!lyricData.custom&&!sharedConnectedLyrics()?.loaded&&samplePlayback().confirmed){
  const requested=lyricData.requestedDuration??0,key=current.id+':'+Math.round(d);
  if((!requested||Math.abs(requested-d)>1)&&lyricDurationRequest!==key){lyricDurationRequest=key;loadLyrics(current,d)}
 }
 highlightLyrics();if(!(window.novaDesktop?.nativeAudio&&current?.source==='youtube')&&navigator.mediaSession&&d>0&&p<=d)try{navigator.mediaSession.setPositionState({duration:d,playbackRate:1,position:p})}catch{}
}
function showPlaybackHealth(){modal('Playback status','<div id="playback-health"></div>');renderPlaybackHealth();}
function renderPlaybackHealth(){
 const target=$('#playback-health');if(!target)return;
 const r=playbackHealth.report(),speed=value=>value==null?'Measuring…':value.toFixed(3)+'×';
 target.innerHTML=`<p>${connect?.remote?'Playing on '+esc(connect.name):'Playing on this device'}</p><p>Audio engine: ${window.novaDesktop?.nativeAudio?'Native Mac audio':'Web player'}</p><p>Engine speed: ${speed(r.rate)}</p><p>Measured speed over ${r.seconds.toFixed(1)} seconds: ${speed(r.observed)}</p><p>Player state: ${{1:'Playing',2:'Paused',3:'Buffering',5:'Ready'}[r.state]||'Loading'}</p><p>Track loads: ${r.loads} · Seeks: ${r.seeks} · Buffering events: ${r.buffering} · Speed changes: ${r.rateChanges}</p>`;
}
setInterval(()=>{if(current?.source==='youtube'&&!connect?.remote&&yt){playbackHealth.sample(yt.getCurrentTime?.(),yt.getPlayerState?.(),yt.getPlaybackRate?.());}renderPlaybackHealth();},1000);
setInterval(tick,100);document.addEventListener('visibilitychange',()=>{if(!document.hidden)tick()});
audio.addEventListener('play',()=>{if(!connect?.remote)setPlaying(true)});audio.addEventListener('pause',()=>{if(!connect?.remote)setPlaying(false)});audio.addEventListener('ended',()=>nextSong(true));audio.addEventListener('error',()=>{setPlaying(false);toast('This audio format could not play in your browser. Try another file.');});
$('#seek').addEventListener('input',e=>{seekDragging=true;$('#elapsed').textContent=time(e.target.value)});$('#seek').addEventListener('change',async e=>{try{await seekTo(e.target.value)}catch(error){toast(error.message)}finally{seekDragging=false}});$('#seek').addEventListener('pointercancel',()=>seekDragging=false);
$('#volume').value=state.settings.volume;$('#volume').addEventListener('input',e=>{state.settings.volume=Number(e.target.value);audio.volume=state.settings.volume/100;yt?.setVolume?.(state.settings.volume)});$('#volume').addEventListener('change',persist);
document.addEventListener('change',e=>{if(e.target.matches('[data-panel-seek]'))seekTo(e.target.value).catch(error=>toast(error.message));if(e.target.matches('[data-check="unmatched"]')){const p=state.playlists.find(p=>p.id===e.target.dataset.id);p.unmatched[Number(e.target.dataset.index)].checked=e.target.checked;persist()}});
document.addEventListener('input',e=>{if(e.target.id==='library-search'){libraryQuery=e.target.value;sidebar()}if(e.target.id==='search-input'){syncSearchControl();clearTimeout(searchTimer);++searchToken;searchAbort?.abort();const query=e.target.value;searchTimer=setTimeout(async()=>{if(ytLink(query)||/(?:open\.spotify\.com|spotify:)/.test(query))return;const page=location.hash.split('/')[0];if(page!=='#search'){await submitMusicSearch(query)}else{searchQuery=query;history.replaceState(null,'','#search'+(query?'/'+encodeURIComponent(query):''));await runSearch(query)}},450)}if(e.target.id==='work-filter'){let [,id]=location.hash.slice(1).split('/');const [cat,c]=decodeURIComponent(id).split(':');$('#work-list').innerHTML=workRows(catalog.works.filter(w=>w.tags.includes(cat)&&(!c||w.composerId===c)&&norm(w.title+' '+w.detail).includes(norm(e.target.value))))}if(e.target.id==='song-search-input'){queueSongSearch()}if(['release-filter'].includes(e.target.id)){$$('[data-filter]',$('#modal')).forEach(row=>row.style.display=row.dataset.filter.includes(norm(e.target.value))?'':'none')}});
document.addEventListener('keydown',e=>{if(['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName)||$('#modal').open||!$('#context-menu').hidden)return;if(e.key==='/'){e.preventDefault();location.hash='search';$('#search-input')?.focus()}if(e.code==='Space'){e.preventDefault();togglePlay()}if(e.key==='ArrowRight'&&current){e.preventDefault();seekTo(position()+10)}if(e.key==='ArrowLeft'&&current){e.preventDefault();seekTo(position()-10)}});
async function action(name,data){
  if(name==='dismiss-keyboard'){$('#search-input').blur();return;}
  if(name==='output-location'){outputLocation();return;}
  if(name==='select-output'){await connect.transfer(data.id);outputLocation();return;}
  if(connect?.remote && !applyingConnectedPlayback && ['previous','shuffle','repeat','enqueue','enqueue-next','queue-play','queue-remove','queue-move','album-queue'].includes(name)){await remotePlaybackAction(name,data);return;}
  const id=data.id;
  if(name==='reload')location.reload();if(name==='search'){location.hash='search';$('#search-input').focus()}if(name==='discover')location.hash='search';if(name==='library')location.hash='library';if(name==='back')history.back();if(name==='close-modal')$('#modal').close();if(name==='settings')settings();if(name==='playback-health')showPlaybackHealth();
  if(name==='mood'||name==='mood-play'){mood=data.value;await render();if(name==='mood-play')await playSongs(getSongs(viewLists.get('discover')||[]))}
  if(name==='genre'){location.hash='search/'+encodeURIComponent(data.value)}
  if(name==='search-query'){ $('#modal').close();location.hash='search/'+encodeURIComponent(data.query)}
  if(name==='browse-mood'){mood=data.value;if(location.hash==='#search')await render()}
  if(name==='profile-menu')account();
  if(name==='edit-profile')editProfile();
  if(name==='profile-icon'){profileDraft.icon=data.value;profileDraft.image='';updateProfilePreview()}
  if(name==='profile-color'){profileDraft.color=data.value;updateProfilePreview()}
  if(name==='profile-remove-photo'){profileDraft.image='';updateProfilePreview()}
  if(name==='lyrics-timing' && connect?.remote){await connect.command(s=>({...s,position:snapshotPosition(s),lyrics:s.lyrics?{...s.lyrics,offset:data.value==='reset'?0:Math.max(-120,Math.min(120,s.lyrics.offset+Number(data.value)))}:s.lyrics}));return;}
  if(name==='lyrics-timing'){state.settings.lyricsOffsets||={};state.settings.lyricsOffsets[current.id]=data.value==='reset'?0:Math.max(-30,Math.min(30,Number(state.settings.lyricsOffsets[current.id]||0)+Number(data.value)));persist();renderPanel()}
  if(name==='lyrics-retry'){lyricsCache.delete(current.id);loadLyrics(current)}
  if(name==='clear-search'){$('#search-input').value='';await submitMusicSearch('');$('#search-input').focus()}
  if(name==='library-filter'){libraryFilter=data.value;$$('[data-action="library-filter"]').forEach(b=>{b.classList.toggle('active',b.dataset.value===libraryFilter);b.setAttribute('aria-pressed',String(b.dataset.value===libraryFilter))});sidebar()}
  if(name==='artist-releases'){searchKind='Albums';await submitMusicSearch(data.query)}
  if(name==='search-more')await moreSearch();
  if(name==='search-retry'){musicSearch.cache.clear();await runSearch($('#search-input').value)}
  if(name==='retry-route'){collectionPages.clear();musicSearch.cache.clear();await render()}
  if(name==='collection-more'){const b=$(`[data-action="collection-more"][data-id="${CSS.escape(id)}"]`);if(b){b.disabled=true;b.textContent='Loading…'}try{await loadCollection(id,true);await render()}catch(e){toast(e.message);if(b){b.disabled=false;b.textContent='Load more tracks'}}}
  if(name==='search-kind'){searchKind=data.value;$$('[data-action="search-kind"]').forEach(b=>(b.classList.toggle('active',b.dataset.value===searchKind),b.setAttribute('aria-pressed',String(b.dataset.value===searchKind))));await runSearch($('#search-input').value)}
  if(name==='play-song'){const list=getSongs(viewLists.get(data.list)||[id]);$('#modal').close();await playSongs(list,list.findIndex(s=>s.id===id))}
  if(name==='artist-top-more'){if(showingAllArtistTopSongs.has(data.id))showingAllArtistTopSongs.delete(data.id);else showingAllArtistTopSongs.add(data.id);await render()}
  if(name==='play-list'||name==='shuffle-list'){if(data.list==='artist'){const artistId=decodeURIComponent(location.hash.split('/')[1]||'');if(state.releaseChoices[artistId]!==undefined){toast('Loading selected releases…');for(const albumId of state.releaseChoices[artistId]){let page=await loadCollection(albumId);const seen=new Set();while(page.cursor&&!seen.has(page.cursor)){seen.add(page.cursor);page=await loadCollection(albumId,true)}}viewLists.set('artist',selectedArtistTracks(artistId).map(s=>s.id))}}let list=getSongs(viewLists.get(data.list)||[]);if(name==='shuffle-list')list=list.map(s=>({s,r:Math.random()})).sort((a,b)=>a.r-b.r).map(x=>x.s);await playSongs(list)}
  if(name==='toggle-play')await togglePlay();if(name==='next')await nextSong();if(name==='previous'){if(position()>3)await seekTo(0);else if(queueIndex>0){queueIndex--;await playCurrent()}}
  if(name==='shuffle'){shuffle=!shuffle;$$('[data-action="shuffle"]').forEach(b=>{b.classList.toggle('active',shuffle);b.setAttribute('aria-pressed',String(shuffle))});toast(shuffle?'Shuffle on':'Shuffle off')}
  if(name==='repeat'){repeat=(repeat+1)%3;$$('[data-action="repeat"]').forEach(b=>{b.classList.toggle('active',!!repeat);b.setAttribute('aria-label',['Repeat off','Repeat all','Repeat one'][repeat])});toast(['Repeat off','Repeat all','Repeat one'][repeat])}
  if(name==='player'||name==='lyrics'||name==='queue'||name==='panel-tab')openPanel(data.value||({lyrics:'lyrics',queue:'queue'}[name]||'song'));
  if(name==='close-panel'){$('#player-panel').hidden=true}
  if(name==='like'){const added=toggleIn('liked',id);toast(added?'Added to liked songs':'Removed from liked songs');render();renderPanel()}
  if(name==='save-song'){const added=toggleIn('saved',id);toast(added?'Saved to your library':'Removed saved song');$('#modal').close();render()}
  if(name==='save-album'){if(!state.albums.includes(id)){let page=await loadCollection(id);const seen=new Set();while(page.cursor){if(seen.has(page.cursor))throw Error('The remaining album tracks could not be loaded. Please retry.');seen.add(page.cursor);page=await loadCollection(id,true)}}toggleIn('albums',id);render()}
  if(name==='follow-artist'){toggleIn('artists',id);render()}
  if(name==='song-menu')songMenu(id);
  if(name==='enqueue'||name==='enqueue-next'){if(!current){await playSongs([songs.get(id)]);return}if(name==='enqueue-next')queue.splice(queueIndex+1,0,id);else queue.push(id);toast(name==='enqueue-next'?'Will play next':'Added to queue');$('#modal').close();renderPanel()}
  if(name==='queue-play'){queueIndex=Number(data.index);await playCurrent()}
  if(name==='queue-remove'){const i=Number(data.index);if(i===queueIndex){toast('Skip the current song before removing it.');return}queue.splice(i,1);if(i<queueIndex)queueIndex--;renderPanel()}
  if(name==='queue-move'){const i=Number(data.index),j=i+Number(data.direction);if(j<0||j>=queue.length)return;[queue[i],queue[j]]=[queue[j],queue[i]];if(queueIndex===i)queueIndex=j;else if(queueIndex===j)queueIndex=i;renderPanel()}
  if(name==='lyric-seek')await seekTo(lyricPlaybackTime(Number(data.time)));
  if(name==='fullscreen-lyrics'){await openFullscreenLyrics();return}
  if(name==='close-fullscreen-lyrics'){closeFullscreenLyrics();return}
  if(name==='receiver'){ $('#modal').close();location.hash='receiver';if(current?.source!=='youtube')$('#player-panel').hidden=true;document.documentElement.requestFullscreen?.().catch(()=>{})}
  if(name==='exit-receiver'){document.exitFullscreen?.().catch(()=>{});location.hash='library'}
  if(name==='new-playlist')libraryForm();if(name==='new-smart')libraryForm(null,true);if(name==='edit-playlist')libraryForm(state.playlists.find(p=>p.id===id));
  if(name==='new-folder')folderForm();if(name==='edit-folder')folderForm(state.folders.find(f=>f.id===id));if(name==='folder-members')folderMembership(id);
  if(name==='delete-playlist'||name==='delete-folder'){modal('Delete '+(name==='delete-folder'?'folder':'playlist')+'?',`<p class="muted">${name==='delete-folder'?'The albums and playlists inside will stay in your library.':'This playlist will be removed from this browser.'}</p><div class="modal-actions">${btn('Cancel','close-modal')}${btn('Delete','confirm-delete',`data-id="${id}" data-kind="${name==='delete-folder'?'folder':'playlist'}"`,'danger')}</div>`)}
  if(name==='confirm-delete'){state[data.kind==='folder'?'folders':'playlists']=state[data.kind==='folder'?'folders':'playlists'].filter(x=>x.id!==id);if(data.kind==='playlist')state.folders.forEach(f=>f.items=f.items.filter(i=>!(i.id===id&&i.kind==='playlist')));persist();$('#modal').close();location.hash='library'}
  if(name==='playlist-move'){const p=state.playlists.find(p=>p.id===id),i=Number(data.index),j=i+Number(data.direction);if(j<0||j>=p.songs.length)return;[p.songs[i],p.songs[j]]=[p.songs[j],p.songs[i]];persist();libraryForm(p);render()}
  if(name==='playlist-remove'){const p=state.playlists.find(p=>p.id===id);p.songs=p.songs.filter(x=>x!==data.song);persist();libraryForm(p);render()}
  if(name==='pair-song')openSongSearch({playlistId:id,key:data.key});
  if(name==='pair-import-song'){captureImportChoices();openSongSearch({importIndex:Number(data.index)})}
  if(name==='song-search-select')selectSearchSong(data.song);
  if(name==='song-search-more')await runSongSearch(true);
  if(name==='song-search-retry')await runSongSearch();
  if(name==='song-search-back'){stopSongSearch();showImportReview()}
  if(name==='playlist-picker')collectionPicker(null,id);if(name==='add-playlist')collectionPicker(id);
  if(name==='playlist-add-song'){const p=state.playlists.find(p=>p.id===id);if(!p.songs.includes(data.song))p.songs.push(data.song);persist();$('#modal').close();toast('Added to '+p.name);render()}
  if(name==='folder-pin'){const f=state.folders.find(f=>f.id===id);f.pins=f.pins||[];const key=data.kind+':'+data.item;f.pins=f.pins.includes(key)?f.pins.filter(p=>p!==key):[key,...f.pins];persist();render()}
  if(name==='add-folder')modal('Add to folder',`<div class="menu-list">${state.folders.map(f=>btn((f.items.some(i=>i.id===id&&i.kind===data.kind)?'✓ ':'')+esc(f.name),'folder-add-item',`data-id="${f.id}" data-item="${esc(id)}" data-kind="${data.kind}"`)).join('')||'<p class="muted">Create a folder in Library first.</p>'}${btn('New folder','new-folder')}</div>`);
  if(name==='folder-add-item'){const f=state.folders.find(f=>f.id===id);if(!f.items.some(i=>i.id===data.item&&i.kind===data.kind))f.items.push({id:data.item,kind:data.kind});persist();$('#modal').close();toast('Added to '+f.name)}
  if(name==='album-menu'){const a=albums.get(id);menu(a.title,`<div class="menu-list">${btn('Add to folder','add-folder',`data-id="${esc(id)}" data-kind="album"`)}${btn('Add album to queue','album-queue',`data-id="${esc(id)}"`)}${btn('Choose discs','choose-discs',`data-id="${esc(id)}"`)}${btn('Album info','wiki',`data-query="${esc(a.title+' '+a.artist)}"`)}</div>`)}
  if(name==='album-queue'){queue.push(...albumTracks(albums.get(id)).map(s=>s.id));$('#modal').close();toast('Album added to queue');renderPanel()}
  if(name==='choose-discs'){const a=albums.get(id),discs=[...new Set(albumTracks(a).map(s=>s.discNumber||1))];modal('Choose discs',`<p class="small-copy">Only confirmed disc numbers are shown. Recordings without disc metadata stay together.</p><form id="disc-form" data-id="${esc(id)}">${discs.map(n=>`<label class="check-row"><input name="disc" type="checkbox" value="${n}" ${!state.discChoices[id]||state.discChoices[id].includes(n)?'checked':''}>Disc ${n}</label>`).join('')}<div class="modal-actions"><button class="primary">Save selection</button></div></form>`)}
  if(name==='artist-menu'){const a=artists.get(id);menu(a.name,`<div class="menu-list">${btn('Add playlists','artist-playlists',`data-id="${esc(id)}"`)}${btn('Choose releases','choose-releases',`data-id="${esc(id)}"`)}${state.releaseChoices[id]!==undefined?btn(showingAllArtistReleases.has(id)?'Show selected releases':'Show all releases','artist-show-all',`data-id="${esc(id)}"`):''}${btn(state.artistPins.includes(id)?'Unpin artist':'Pin artist','pin-artist',`data-id="${esc(id)}"`)}${btn('Move to front','artist-front',`data-id="${esc(id)}"`)}${btn('Artist info','wiki',`data-query="${esc(a.name)}"`)}</div>`)}
  if(name==='artist-playlists')artistPlaylistPicker(id);if(name==='artist-show-all'){showingAllArtistReleases.has(id)?showingAllArtistReleases.delete(id):showingAllArtistReleases.add(id);render()}if(name==='playlist-artwork')editPlaylistArtwork(id);if(name==='artwork-icon'){playlistArtworkDraft={style:'icon',symbol:data.symbol};drawPlaylistArtworkPreview()}if(name==='artwork-collage'){playlistArtworkDraft={style:'collage'};drawPlaylistArtworkPreview()}if(name==='artwork-default'){playlistArtworkDraft=null;drawPlaylistArtworkPreview()}if(name==='choose-releases')releasePicker(id);if(name==='release-all'||name==='release-none')$$('input[name="release"]').forEach(c=>c.checked=name==='release-all');if(name==='release-auto'){delete state.releaseChoices[id];persist();$('#modal').close();render()}
  if(name==='pin-artist'){if(!state.artists.includes(id))state.artists.unshift(id);toggleIn('artistPins',id);$('#modal').close();render()}
  if(name==='artist-front'){state.artists=[id,...state.artists.filter(x=>x!==id)];persist();$('#modal').close();render()}
  if(name==='arrange-artists'){modal('Arrange artists',`<div class="scroll-list">${state.artists.map((id,i)=>{const a=artists.get(id);if(!a)return'';return `<div class="manage-row"><span class="song-info"><strong>${esc(a.name)}</strong></span>${btn(icon('up'),'artist-move',`data-index="${i}" data-direction="-1" aria-label="Move ${esc(a.name)} up"`,'icon-button')}${btn(icon('down'),'artist-move',`data-index="${i}" data-direction="1" aria-label="Move ${esc(a.name)} down"`,'icon-button')}${btn(icon('pin'),'pin-artist',`data-id="${esc(id)}" aria-label="Pin ${esc(a.name)}"`,'icon-button'+(state.artistPins.includes(id)?' pin':''))}</div>`}).join('')||'<p class="muted">Follow an artist first.</p>'}</div>`)}
  if(name==='artist-move'){const i=Number(data.index),j=i+Number(data.direction);if(j<0||j>=state.artists.length)return;[state.artists[i],state.artists[j]]=[state.artists[j],state.artists[i]];persist();await action('arrange-artists',{});render()}
  if(name==='genres'){modal('Customize genres',`<form id="genre-form">${['Pop','Rock','Electronic','R&B','Hip-hop','Jazz','Classical','Alternative','Latin'].map(g=>`<label class="check-row"><input name="genre" type="checkbox" value="${g}" ${state.genres.includes(g)?'checked':''}>${g}</label>`).join('')}<div class="modal-actions"><button class="primary">Save genres</button></div></form>`)}
  if(name==='edit-lyrics'){const s=songs.get(id);modal('Add lyrics',`<form id="lyrics-form" data-id="${esc(id)}"><p class="small-copy">Paste plain lyrics or timed LRC lines such as [00:12.50]Your lyric. These lyrics are saved with the recording on this device.</p><label class="field">Lyrics<textarea name="lyrics" rows="10">${esc(s.lyrics||'')}</textarea></label><div class="modal-actions"><button class="primary">Save lyrics</button></div></form>`)}
  if(name==='song-info'){const s=songs.get(id);modal('Song info',`${art(s.artwork,'panel-art',s.title)}<h3>${esc(s.title)}</h3><p class="muted">${esc(s.artist)}<br>${esc(s.album)}<br>${time(s.duration)}${s.explicit?' · Explicit':''}</p>${btn('Read about this song','wiki',`data-query="${esc(s.title+' '+s.artist.split(',')[0])}"`)}${s.source==='local'?btn('Edit metadata','edit-metadata',`data-id="${esc(id)}"`):''}`)}
  if(name==='wiki')await wikipediaInfo(data.query);
  if(name==='share'){const url=current?.source==='local'?'':songs.get(id)?.source==='youtube'?'https://music.youtube.com/watch?v='+id:location.href;if(!url){toast('Local audio cannot be shared as a public link.');return}if(navigator.share)try{await navigator.share({title:songs.get(id)?.title,url})}catch{}else{await navigator.clipboard.writeText(url);toast('Song link copied')}}
  if(name==='import')modal('Add music',`<div class="menu-list">${btn('Paste a YouTube song or playlist link','youtube-import')}${btn('Import from Spotify','spotify-import')}${btn('Import playlist CSV','csv-import')}${btn('Import a song list','text-import')}${btn('Import audio files','local-import')}</div>`);
  if(name==='youtube-import')modal('YouTube link',`<form id="youtube-link-form"><label class="field">Song or playlist link<input name="link" type="url" required placeholder="https://music.youtube.com/watch?v=…"></label><p class="small-copy">Song links work immediately. Playlist imports require a YouTube API key in Settings.</p><div class="modal-actions"><button class="primary">Add music</button></div></form>`);
  if(name==='import-youtube-playlist')await importYouTubePlaylist(id);
  if(name==='csv-import')csvImportDialog();if(name==='import-retry')await retryImport();if(name==='spotify-import')spotifyImportDialog();if(name==='connect-spotify')await connectSpotify();if(name==='spotify-find')await importSpotify();if(name==='save-import')saveImport();
  if(name==='text-import')modal('Import a song list',`<form id="text-import-form"><label class="field">Playlist name<input name="name" required placeholder="Imported playlist"></label><label class="field">One song per line: Artist — Title<textarea name="list" required rows="9" placeholder="Daft Punk — Get Lucky"></textarea></label><p class="small-copy">Each song is searched online. Matches are reviewed before saving. Missing songs remain in a checklist.</p><div class="modal-actions">${btn('Use a CSV file','csv-import')}<button class="primary">Find songs</button></div></form>`);
  if(name==='local-import')await importLocal();if(name==='edit-metadata'){const s=songs.get(id);modal('Edit song details',`<form id="metadata-form" data-id="${esc(id)}">${['title','artist','album'].map(k=>`<label class="field">${k.charAt(0).toUpperCase()+k.slice(1)}<input name="${k}" value="${esc(s[k])}" ${k==='title'?'required':''}></label>`).join('')}<div class="modal-actions"><button class="primary">Save details</button></div></form>`)}
  if(name==='export'){const backup=structuredClone(state);backup.settings.youtubeKey='';backup.settings.spotifyClientId='';downloadJSON(backup,'nova-music-library.json');toast('Library backup exported')}
  if(name==='restore')await restoreBackup();
}
async function wikipediaInfo(query){modal('About '+query,'<p class="loading"><span class="spinner"></span>Looking up Wikipedia…</p>');try{const u='https://en.wikipedia.org/w/api.php?'+new URLSearchParams({action:'query',format:'json',origin:'*',generator:'search',gsrsearch:query,gsrlimit:'1',prop:'extracts|info',inprop:'url',exintro:'1',explaintext:'1'});const j=await fetch(u).then(r=>r.json());const page=Object.values(j.query?.pages||{})[0];if(!page)throw Error('No Wikipedia description found.');$('#modal-body').innerHTML=`<h3>${esc(page.title)}</h3><p class="muted">${esc(page.extract||'No introduction available.')}</p><p class="small-copy">Search result from <a href="${safeURL(page.fullurl)}" target="_blank" rel="noopener">Wikipedia</a> · CC BY-SA. Check the page title to confirm the recording or artist.</p>`}catch{$('#modal-body').innerHTML='<p class="muted">A description is unavailable right now.</p>'}}
document.addEventListener('submit',async e=>{const f=e.target;if(!(f instanceof HTMLFormElement)||f.id.startsWith('account-'))return;e.preventDefault();const values=new FormData(f),id=f.dataset.id;try{
  if(f.id==='search-form'){await submitMusicSearch(String(values.get('q')||''));return}
  if(f.id==='playlist-form'){let p=state.playlists.find(p=>p.id===id);if(!p){p={id:crypto.randomUUID(),songs:[],createdAt:Date.now()};state.playlists.push(p)}p.name=String(values.get('name')).trim()||'Untitled playlist';p.description=String(values.get('description')||'');if(values.has('source'))p.rules={source:values.get('source'),artist:String(values.get('artist')||''),title:String(values.get('title')||''),album:String(values.get('album')||''),sort:values.get('sort'),limit:Number(values.get('limit'))||null};persist();$('#modal').close();location.hash='playlist/'+p.id;render();return}
  if(f.id==='folder-form'){let item=state.folders.find(x=>x.id===id);if(!item){item={id:crypto.randomUUID(),items:[],pins:[]};state.folders.push(item)}item.name=String(values.get('name')).trim()||'New folder';persist();$('#modal').close();location.hash='folder/'+item.id;render();return}
  if(f.id==='folder-members-form'){state.folders.find(x=>x.id===id).items=values.getAll('items').map(v=>{const colon=v.indexOf(':');return{kind:v.slice(0,colon),id:v.slice(colon+1)}})}
  if(f.id==='playlist-artwork-form'){const p=state.playlists.find(p=>p.id===id);if(p)p.collectionArtwork=validateCollectionArtwork(playlistArtworkDraft)}
  if(f.id==='artist-playlists-form'){const chosen=values.getAll('playlist');for(const p of state.playlists){if(chosen.includes(p.id))p.artistId=id;else if(playlistArtistId(p)===id)p.artistId=''}}
  if(f.id==='release-form')state.releaseChoices[id]=values.getAll('release');
  if(f.id==='disc-form')state.discChoices[id]=values.getAll('disc').map(Number);
  if(f.id==='song-search-form'){await runSongSearch();return}
  if(f.id==='settings-form'){state.settings={...state.settings,explicit:values.has('explicit'),lyricsOffset:Math.max(-30,Math.min(30,Number(values.get('lyricsOffset'))||0)),youtubeKey:String(values.get('youtubeKey')||'').trim(),spotifyClientId:String(values.get('spotifyClientId')||'').trim()}}
  if(f.id==='genre-form')state.genres=values.getAll('genre');
  if(f.id==='profile-form'){state.profile=validateProfile({...profileDraft,name:String(values.get('name')||'')});}
  if(f.id==='lyrics-form'){const s=songs.get(id);s.lyrics=String(values.get('lyrics'));state.extraSongs[id]=s;if(current?.id===id)loadLyrics(s)}
  if(f.id==='metadata-form'){const s=songs.get(id);for(const k of ['title','artist','album'])s[k]=String(values.get(k)||'').trim();state.extraSongs[id]=s}
  if(f.id==='youtube-link-form'){const link=ytLink(String(values.get('link')));if(!link)throw Error('Paste a valid YouTube song or playlist link.');$('#modal').close();if(link.video)await addYouTube(link.video);else await importYouTubePlaylist(link.playlist);return}
  if(f.id==='text-import-form'){await matchImport(String(values.get('name')),parseSongList(values.get('list')));return}
  if(f.id==='csv-import-form'){const file=$('#playlist-csv').files[0];if(!file)throw Error('Choose a playlist CSV first.');if(file.size>5*1024*1024)throw Error('Choose a CSV smaller than 5 MB.');const tracks=parsePlaylistCSV(await file.text());await matchImport(String(values.get('name')).trim()||file.name.replace(/\.csv$/i,'').replace(/_/g,' '),tracks);return}
  persist();$('#modal').close();render();renderPanel();toast('Saved');
}catch(error){toast(error.message||'Couldn’t save. Try again.')}});
let pendingImport=null;
function spotifyImportDialog(link=''){modal('Import from Spotify',`<label class="field">Spotify playlist link<input id="spotify-link" type="text" value="${esc(link||sessionStorage.getItem('nova-spotify-playlist')||'')}" placeholder="https://open.spotify.com/playlist/…"></label><p class="small-copy">Import a copy, review matches, and keep a checklist of missing songs. For full access, connect Spotify using your app client ID in Settings. Spotify may require that you own or collaborate on the playlist.</p><div class="button-row">${btn('Connect Spotify','connect-spotify')}${btn('Find songs','spotify-find','','primary')}</div>${!state.settings.spotifyClientId?'<p class="notice">Spotify is not configured yet. Add your Spotify app client ID in Settings, or import a pasted song list.</p>'+btn('Settings','settings'):''}`)}
function randomString(){return Array.from(crypto.getRandomValues(new Uint8Array(32)),x=>x.toString(16).padStart(2,'0')).join('')}
async function connectSpotify(){if(!/^[a-fA-F0-9]{32}$/.test(state.settings.spotifyClientId))throw Error('Add your Spotify app client ID in Settings first.');const verifier=randomString(),oauthState=randomString(),redirect=location.origin+location.pathname;const hash=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier));const challenge=btoa(String.fromCharCode(...new Uint8Array(hash))).replace(/=/g,'').replace(/\+/g,'-').replace(/\//g,'_');sessionStorage.setItem('nova-spotify-verifier',verifier);sessionStorage.setItem('nova-spotify-state',oauthState);sessionStorage.setItem('nova-spotify-playlist',$('#spotify-link')?.value||'');const u=new URL('https://accounts.spotify.com/authorize');u.search=new URLSearchParams({response_type:'code',client_id:state.settings.spotifyClientId,redirect_uri:redirect,state:oauthState,scope:'playlist-read-private playlist-read-collaborative',code_challenge_method:'S256',code_challenge:challenge});location.assign(u)}
async function spotifyCallback(){const params=new URLSearchParams(location.search);if(!params.has('code')&&!params.has('error'))return;const returned=params.get('state'),expected=sessionStorage.getItem('nova-spotify-state');const code=params.get('code'),verifier=sessionStorage.getItem('nova-spotify-verifier');history.replaceState(null,'',location.pathname+'#library');sessionStorage.removeItem('nova-spotify-state');sessionStorage.removeItem('nova-spotify-verifier');if(!expected||returned!==expected){toast('Spotify sign-in could not be verified. Reconnect.');return}if(params.has('error')){toast('Spotify connection was cancelled.');return}try{const r=await fetch('https://accounts.spotify.com/api/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({grant_type:'authorization_code',client_id:state.settings.spotifyClientId,redirect_uri:location.origin+location.pathname,code,code_verifier:verifier})});const j=await r.json();if(!r.ok||!j.access_token)throw Error('Spotify connection failed. Check the client ID and redirect URL.');sessionStorage.setItem('nova-spotify-token',j.access_token);sessionStorage.setItem('nova-spotify-expires',String(Date.now()+j.expires_in*1000));spotifyImportDialog();toast('Spotify connected')}catch(e){toast(e.message)}}
async function spotifyAPI(url){const token=sessionStorage.getItem('nova-spotify-token');if(!token||Number(sessionStorage.getItem('nova-spotify-expires'))<Date.now())throw Error('Connect Spotify before importing this playlist.');const u=new URL(url);if(u.origin!=='https://api.spotify.com'||!u.pathname.startsWith('/v1/playlists/'))throw Error('Unexpected Spotify page.');const r=await fetch(u,{headers:{Authorization:'Bearer '+token}});const j=await r.json();if(!r.ok)throw Error(r.status===403?'Spotify does not grant access to this playlist. Make an owned copy in Spotify and try its link.':j.error?.message||'Spotify could not return every song.');return j}
async function importSpotify(){const raw=$('#spotify-link')?.value.trim()||'';const id=raw.match(/(?:open\.spotify\.com\/playlist\/|spotify:playlist:)([A-Za-z0-9]{22})/)?.[1];if(!id)throw Error('Paste a Spotify playlist URL or spotify:playlist: URI. Short spotify.link URLs must be opened in Spotify first.');modal('Import from Spotify','<p class="loading"><span class="spinner"></span>Reading the complete playlist…</p>');try{const base='https://api.spotify.com/v1/playlists/'+id;const meta=await spotifyAPI(base);let next=base+'/items?limit=50&offset=0',all=[],total=null;const seenPages=new Set();while(next){if(seenPages.has(next))throw Error('Spotify returned a repeated page. No playlist was created.');seenPages.add(next);const page=await spotifyAPI(next);if(!Array.isArray(page.items))throw Error('Spotify returned an incomplete page.');if(total===null)total=page.total;if(typeof total!=='number'||page.total!==total)throw Error('The playlist changed during import. Try again.');all.push(...page.items);next=page.next;if(next){const u=new URL(next);if(u.pathname!==new URL(base+'/items').pathname)throw Error('Spotify returned an unexpected page.')}}if(all.length!==total)throw Error('Spotify omitted songs. No partial playlist was created.');const latest=await spotifyAPI(base+'?fields=snapshot_id');if(meta.snapshot_id!==latest.snapshot_id)throw Error('The Spotify playlist changed during import. Try again.');const tracks=all.map((row,i)=>{const s=row.item||row.track;return{title:s?.name||'Unavailable song',artist:s?.artists?.map(a=>a.name).join(', ')||'',album:s?.album?.name||'',duration:s?.duration_ms/1000||0,explicit:s?.explicit,uri:s?.uri||'',position:i,reason:!s?'Removed or unavailable song':row.is_local||s.is_local?'Spotify local file':s.type==='episode'?'Podcast episode':''}});await matchImport(meta.name,tracks,'https://open.spotify.com/playlist/'+id)}catch(e){$('#modal-body').innerHTML=`<p class="notice error">${esc(e.message)}</p>${btn('Try again','spotify-import')}`}}
function csvImportDialog(){modal('Import playlist CSV',`<form id="csv-import-form"><label class="field">Playlist name<input name="name" placeholder="Use the CSV filename"></label><label class="field">Exportify CSV<input id="playlist-csv" type="file" accept=".csv,text/csv,text/tab-separated-values" required></label><p class="small-copy">Import the complete exported list without a Spotify connection. Album names and song lengths help identify recordings. The file is read on this device; song titles and artists are searched online.</p><div class="modal-actions"><button class="primary">Find songs</button></div></form>`)}
let importAbort=null;
$('#modal').addEventListener('close',()=>importAbort?.abort());
async function matchImport(name,tracks,sourceUrl='',existing=[]){
 importAbort?.abort();const controller=new AbortController();importAbort=controller;
 pendingImport={name,sourceUrl,entries:existing,total:existing.length+tracks.length};
 modal('Finding playlist songs',`<p class="loading"><span class="spinner"></span>Searching for ${tracks.length} songs…</p><progress id="import-progress" max="${tracks.length}" value="0"></progress><p id="import-status" class="muted" aria-live="polite">0 of ${tracks.length} checked</p><p class="small-copy">You can cancel and retry later. Nothing is added to your library until you save.</p><div class="modal-actions">${btn('Cancel','close-modal')}</div>`);
 try{
  const entries=await matchPlaylist(tracks,{signal:controller.signal,localSongs:[...songs.values()],search:(query,{signal})=>musicSearch.request({query,kind:'Songs',providerOrder:true},{signal}),onWait:()=>{if(importAbort===controller)$('#import-status').textContent='Search is busy. Waiting before continuing…'},onProgress:(done,total)=>{if(importAbort!==controller||controller.signal.aborted)return;$('#import-progress').value=done;$('#import-status').textContent=`${done} of ${total} checked`;}});
  if(controller.signal.aborted||importAbort!==controller)return;
  importAbort=null;pendingImport.entries=[...existing,...entries].sort((a,b)=>a.source.position-b.source.position);remember(entries.filter(e=>e.song).map(e=>e.song));showImportReview();
 }catch(error){if(error.name!=='AbortError')throw error;}
 finally{if(importAbort===controller)importAbort=null;}
}
function captureImportChoices(){if(!pendingImport)return;pendingImport.name=$('#import-name')?.value.trim()||pendingImport.name;for(const checkbox of $$('[data-import-index]'))pendingImport.entries[Number(checkbox.dataset.importIndex)].selected=checkbox.checked;}
async function retryImport(){if(!pendingImport)return;captureImportChoices();const p=pendingImport,remaining=p.entries.filter(e=>!e.song&&!e.source.reason);await matchImport(p.name,remaining.map(e=>e.source),p.sourceUrl,p.entries.filter(e=>e.song||e.source.reason));}
function importReviewRow(entry,i){
 const {source,song,review,detail,reason}=entry;
 const pairing=btn(song?'Choose another recording':'Find a recording','pair-import-song',`data-index="${i}"`,'text-button');
 return `<div class="import-review-row">${song?`<label class="check-row"><input type="checkbox" data-import-index="${i}" ${(entry.selected??!review)?'checked':''}><span>${esc(source.title)}<small>${esc(source.artist)}${source.duration?' · '+time(source.duration):''}<br>${review?'Suggested':'Matched'}: ${esc(song.title)} · ${esc(song.artist)}${detail?'<br>'+esc(detail):''}</small></span></label>`:btn(`<span><strong>${esc(source.title)}</strong><small>${esc(source.artist)}<br>${esc(reason)}</small></span>`,'pair-import-song',`data-index="${i}"`,'review-row')}${song?pairing:''}</div>`;
}
function showImportReview(){
 if(!pendingImport)return;const p=pendingImport,matched=p.entries.filter(e=>e.song&&!e.review).length,suggested=p.entries.filter(e=>e.song&&e.review).length,missing=p.entries.filter(e=>!e.song&&!e.failed).length,failed=p.entries.filter(e=>!e.song&&e.failed).length;
 modal('Review matches',`<label class="field">Playlist name<input id="import-name" value="${esc(p.name)}" required></label><p class="muted">${matched} matched · ${suggested} to review · ${missing} unmatched${failed?` · ${failed} search failures`:""} · ${p.total} original entries</p>${section('Needs your review',`<div class="scroll-list">${p.entries.map((entry,i)=>({entry,i})).filter(({entry})=>!entry.song||entry.review).map(({entry,i})=>importReviewRow(entry,i)).join('')||'<p class="muted">All recordings matched.</p>'}</div>`)}${section('Matched songs',`<div class="scroll-list">${p.entries.map((entry,i)=>({entry,i})).filter(({entry})=>entry.song&&!entry.review).map(({entry,i})=>importReviewRow(entry,i)).join('')}</div>`)}<p class="small-copy">Suggested recordings start unselected. Review them before saving. Song order is preserved; repeated recordings are added once. Unmatched entries keep their original metadata.</p><div class="modal-actions">${p.entries.some(e=>!e.song&&!e.source.reason)?btn('Retry unmatched songs','import-retry'):''}${btn('Create playlist','save-import','','primary')}</div>`);
}
function saveImport(){
 if(!pendingImport)return;captureImportChoices();const p=pendingImport,selected=p.entries.filter(e=>e.song&&e.selected),unmatched=p.entries.filter(e=>!e.song||!e.selected).map(e=>({...e.source,id:crypto.randomUUID(),reason:e.song?(e.detail||'Suggested match not selected'):e.reason,checked:false}));
 const playlist={id:crypto.randomUUID(),name:p.name.trim()||'Imported playlist',songs:[...new Set(selected.map(e=>e.song.id))],sourceUrl:p.sourceUrl,unmatched,importEntries:p.entries.map(e=>({...e.source,matchedSongId:e.song&&e.selected?e.song.id:null}))};
 state.playlists.push(playlist);persist();pendingImport=null;$('#modal').close();location.hash='playlist/'+playlist.id;render();toast('Playlist created');
}
let dbPromise;
function database(){if(!dbPromise)dbPromise=new Promise((resolve,reject)=>{const req=indexedDB.open('nova-music-audio',1);req.onupgradeneeded=()=>req.result.createObjectStore('files');req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(Error('Audio storage is unavailable in this browser.'))});return dbPromise}
async function fileStore(operation,id,value){const db=await database();return new Promise((resolve,reject)=>{const tx=db.transaction('files',operation==='get'?'readonly':'readwrite');const request=operation==='get'?tx.objectStore('files').get(id):tx.objectStore('files').put(value,id);let result;request.onsuccess=()=>result=request.result;tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(Error('Not enough device storage for this audio file.'));tx.onabort=()=>reject(Error('Audio import could not be saved.'))})}
function selectFiles(accept,multiple=false){return new Promise(resolve=>{const input=document.createElement('input');input.type='file';input.accept=accept;input.multiple=multiple;input.onchange=()=>resolve([...input.files]);input.addEventListener('cancel',()=>resolve([]));input.click()})}
async function audioMetadata(file){const blobURL=URL.createObjectURL(file);return new Promise(resolve=>{const a=new Audio();const timeout=setTimeout(()=>finish(0),7000);function finish(duration){clearTimeout(timeout);a.removeAttribute('src');URL.revokeObjectURL(blobURL);resolve(duration)}a.preload='metadata';a.onloadedmetadata=()=>finish(Number.isFinite(a.duration)?a.duration:0);a.onerror=()=>finish(0);a.src=blobURL})}
async function importLocal(){const files=await selectFiles('audio/*,.mp3,.m4a,.wav,.flac,.ogg,.aac',true);if(!files.length)return;modal('Importing audio','<p class="loading"><span class="spinner"></span>Saving audio on this device…</p>');let count=0;for(const file of files){const id='local-'+norm(file.name)+'-'+file.size+'-'+file.lastModified;await fileStore('put',id,file);const title=file.name.replace(/\.[^.]+$/,'');const parts=title.split(' - ');const s={id,title:parts.length>1?parts.slice(1).join(' - '):title,artist:parts.length>1?parts[0]:'Unknown artist',album:'Imported audio',duration:await audioMetadata(file),artwork:'',source:'local'};remember([s]);state.saved=[id,...state.saved.filter(x=>x!==id)];count++}persist();$('#modal').close();location.hash='locals';render();toast('Imported '+count+' audio files')}
function downloadJSON(value,name){const url=URL.createObjectURL(new Blob([JSON.stringify(value,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}
async function restoreBackup(){const [file]=await selectFiles('.json,application/json');if(!file)return;let data;try{data=JSON.parse(await file.text())}catch{throw Error('This file is not a valid library backup.')}if(data.version!==1||!['liked','saved','albums','artists','artistPins','playlists','folders','recent','genres'].every(k=>Array.isArray(data[k]))||!data.extraSongs||typeof data.extraSongs!=='object')throw Error('This is not a Nova Music web library backup.');modal('Restore this library?',`<p class="muted">This replaces this browser’s library with ${data.playlists.length} playlists and ${data.liked.length} liked songs. Audio files are not included in a metadata backup.</p><div class="modal-actions">${btn('Cancel','close-modal')}${btn('Restore library','restore-confirm','','primary')}</div>`);pendingRestore=data}
let pendingRestore;
const originalAction=action;
action=async function(name,data){if(name==='restore-confirm'&&pendingRestore){const configured=state.settings;state={...structuredClone(defaults),...pendingRestore,settings:{...defaults.settings,...pendingRestore.settings,youtubeKey:configured.youtubeKey,spotifyClientId:configured.spotifyClientId}};pendingRestore=null;for(const s of Object.values(state.extraSongs))songs.set(s.id,s);for(const a of Object.values(state.extraAlbums||{}))albums.set(a.id,a);for(const a of Object.values(state.extraArtists||{}))artists.set(a.id,a);persist();$('#modal').close();render();toast('Library restored');return}return originalAction(name,data)};
function registerTools(){const context=document.modelContext;if(!context?.registerTool)return;const lifecycle=new AbortController();window.addEventListener('pagehide',()=>lifecycle.abort(),{once:true});const tools=[{name:'search_music',description:'Search YouTube Music for songs by title, artist or lyric fragment. Returns recording IDs without changing playback.',inputSchema:{type:'object',properties:{query:{type:'string'}},required:['query'],additionalProperties:false},annotations:{readOnlyHint:true},execute:async({query})=>{if(typeof query!=='string'||!query.trim()||query.length>200)throw Error('Provide a query of 1–200 characters');const result=await musicSearch.request({query,kind:'Songs'});rememberSearch(result);return result.songs.filter(s=>state.settings.explicit||!s.explicit).map(({id,title,artist,album})=>({id,title,artist,album}))}},{name:'create_playlist',description:'Create and save a playlist in this device’s Nova Music library using known recording IDs.',inputSchema:{type:'object',properties:{name:{type:'string'},songIds:{type:'array',items:{type:'string'}}},required:['name','songIds'],additionalProperties:false},annotations:{readOnlyHint:false},execute:async({name,songIds})=>{if(typeof name!=='string'||!name.trim()||!Array.isArray(songIds)||songIds.some(id=>typeof id!=='string'||!songs.has(id)))throw Error('Provide a name and valid recording IDs');const p={id:crypto.randomUUID(),name:name.trim().slice(0,100),songs:[...new Set(songIds)]};state.playlists.push(p);persist();location.hash='playlist/'+p.id;await render();return{id:p.id,name:p.name,songs:p.songs.length}}},{name:'get_music_library',description:'Read this device’s playlist and folder names and liked song count.',inputSchema:{type:'object',properties:{},additionalProperties:false},annotations:{readOnlyHint:true},execute:()=>({likedSongs:state.liked.length,playlists:state.playlists.map(p=>({id:p.id,name:p.name,songs:playlistSongs(p).length})),folders:state.folders.map(f=>({id:f.id,name:f.name,items:f.items.length}))})}];for(const tool of tools)try{Promise.resolve(context.registerTool(tool,{signal:lifecycle.signal})).catch(()=>{})}catch{}}
let accountEmail='', accountMode='signin';
function updateAccountStatus(client){renderAvatar();const label=$('#account-label');if(label)label.textContent=client.user?'Account':'Sign in';const status=$('#account-sync-status');if(status)status.textContent=client.message||({synced:'Your library is synced.',syncing:'Syncing your library…',pending:'Your changes are saved here and waiting to sync.',offline:'You are offline. Edits will sync when you reconnect.',error:'Sync needs attention.'}[client.status]||'');}
function account(reauth=false){
 if(!accountClient?.configured){modal('Nova Music account','<p class="notice">Account sync is not available yet.</p>');return}
 if(accountClient.user&&!reauth&&accountMode!=='recovery'){
 modal('Nova Music account',`${profileSummary()}${btn('Edit profile icon','edit-profile')}<p>Signed in as <strong>${esc(accountClient.user.email)}</strong></p><p id="account-sync-status" class="notice"></p><p class="small-copy">Your likes, saved music, playlists and folders sync with the same account in the app and browser. Your profile picture syncs too. Playlist artwork syncs too. Imported audio stays on its original device.</p><div class="button-row">${btn('Sync now','account-sync','','primary')}${btn('Sign out','account-sign-out')}${btn('Sign in again','account-reauth')}</div><p class="small-copy">Signing out removes this account’s library from this browser. Your cloud library stays saved.</p>`);updateAccountStatus(accountClient);return}
 const mode=accountMode, creating=mode==='signup', recovering=mode==='recovery', forgot=mode==='forgot';
 const title=creating?'Create your account':recovering?'Set a new password':forgot?'Reset your password':'Sign in to Nova Music';
 modal(title,`${profileSummary()}${btn('Edit profile icon','edit-profile')}<p class="muted">${recovering?'Choose a new password, then sign in again.':'Use the same account in the app and browser to share your library.'}</p><form id="account-${mode}-form"><label class="field">Email address<input name="email" type="email" autocomplete="email" required value="${esc(recovering?accountEmail:accountClient.user?.email||accountEmail)}" ${recovering||accountClient.user?'readonly':''}></label>${forgot?'':`<label class="field">${recovering?'New password':'Password'}<input name="password" type="password" autocomplete="${creating||recovering?'new-password':'current-password'}" ${creating||recovering?'minlength="12"':''} required></label>`}${creating||recovering?'<label class="field">Confirm password<input name="confirm" type="password" autocomplete="new-password" minlength="12" required></label><p class="small-copy">Use at least 12 characters.</p>':''}${mode==='signin'&&!accountClient.user?'<label class="check-row"><input name="merge" type="checkbox" checked>Add this device’s library to my account</label>':''}<p id="account-form-message" role="status"></p><div class="modal-actions"><button class="primary">${creating?'Create account':recovering?'Save new password':forgot?'Send reset link':'Sign in'}</button></div></form><div class="button-row">${mode==='signin'&&!reauth?btn('Create account','account-mode','data-value="signup"')+btn('Forgot password?','account-mode','data-value="forgot"'):btn('Back to sign in','account-mode','data-value="signin"')}</div><p class="small-copy">${creating?'Confirm your email before signing in. ':''}Provider keys and imported audio are excluded from sync.</p>`)
}
async function initializeAccountSync(){try{accountClient=new NovaSyncClient(syncConfig,{values:()=>libraryValues(state,catalog),activate:(user,cached)=>{connect?.reset();collectionPages.clear();publicPlaylists.clear();const deviceSettings={...state.settings};state=cached?{...structuredClone(defaults),...cached}:structuredClone(defaults);state.settings=deviceSettings;},apply:values=>{const next=applyLibraryValues(state,values);state=next;songs=new Map([...catalog.songs,...Object.values(state.extraSongs)].map(s=>[s.id,s]));albums=new Map([...catalog.albums,...Object.values(state.extraAlbums)].map(a=>[a.id,a]));artists=new Map([...catalog.artists,...Object.values(state.extraArtists)].map(a=>[a.id,a]));persist();render();renderPanel();},deactivate:()=>{connect?.reset();collectionPages.clear();publicPlaylists.clear();const deviceSettings={...state.settings};try{state={...structuredClone(defaults),...JSON.parse(localStorage.getItem(KEY)||'{}')}}catch{state=structuredClone(defaults)}state.settings=deviceSettings;songs=new Map([...catalog.songs,...Object.values(state.extraSongs)].map(s=>[s.id,s]));albums=new Map([...catalog.albums,...Object.values(state.extraAlbums)].map(a=>[a.id,a]));artists=new Map([...catalog.artists,...Object.values(state.extraArtists)].map(a=>[a.id,a]));persist();render();},status:updateAccountStatus,connect:values=>{connect?.receive(values)},});
connect=new NovaConnect(accountClient,{id:browserOutputID(),name:browserOutputName(),snapshot:connectedPlaybackSnapshot,apply:applyConnectedPlayback,freeze:freezeConnectedPlayback,stop:stopConnectedPlayback,mirror:mirrorConnectedPlayback,changed:updateOutputButton,error:message=>toast(message)});
setInterval(()=>connect.tick().catch(()=>{}),2000);
await accountClient.initialize();await connect.tick();updateAccountStatus(accountClient);if(authReturn){if(authReturn.type==='recovery'){try{accountEmail=await accountClient.beginPasswordRecovery(authReturn.token);accountMode='recovery';account()}catch(error){modal('Password reset',`<p class="notice">${esc(error.message)}</p>${btn('Request a new link','account-mode','data-value="forgot"')}`)}}else{accountMode='signin';account();$('#account-form-message').textContent=authReturn.type==='error'?authReturn.message:'Email confirmed. Sign in with your email and password.'}}}catch{toast('Account sync could not initialize. Your device library is still available.')}}
const actionBeforeAccount=action;
action=async function(name,data){if(name==='account'){account();return}if(name==='account-reauth'){accountMode='signin';accountEmail=accountClient.user.email;account(true);return}if(name==='account-mode'){accountMode=['signin','signup','forgot'].includes(data.value)?data.value:'signin';accountClient.recovery=null;account(Boolean(accountClient.user));return}if(name==='account-sync'){await accountClient.sync();return}if(name==='account-sign-out'){await accountClient.signOut();accountMode='signin';accountEmail='';$('#modal').close();toast('Signed out. Your cloud library remains saved.');return}return actionBeforeAccount(name,data)};
document.addEventListener('submit',async e=>{
 const form=e.target;if(!(form instanceof HTMLFormElement)||!/^account-(signin|signup|forgot|recovery)-form$/.test(form.id))return;e.preventDefault();
 const values=new FormData(form),button=form.querySelector('button'),message=form.querySelector('#account-form-message');button.disabled=true;message.textContent='Please wait…';
 try{accountEmail=String(values.get('email')||'').trim();const password=String(values.get('password')||'');
 if(['signup','recovery'].includes(accountMode)&&password!==values.get('confirm'))throw Error('The passwords do not match.');
 if(accountMode==='forgot'){await accountClient.sendPasswordReset(accountEmail);message.textContent='If an account exists for this email, a password reset link has been sent. Open the link in this browser.';button.disabled=false}
 else if(accountMode==='signup'){await accountClient.createAccount(accountEmail,password);accountMode='signin';account();$('#account-form-message').textContent='Check your email to confirm your account, then sign in.'}
 else if(accountMode==='recovery'){await accountClient.finishPasswordRecovery(password);accountMode='signin';account(Boolean(accountClient.user));$('#account-form-message').textContent='Password saved. Sign in with your new password.'}
 else{await accountClient.signIn(accountEmail,password,values.has('merge'));account();toast('Signed in to Nova Music')}
 }catch(error){message.textContent=error.message;button.disabled=false}
 finally{form.querySelectorAll('input[type="password"]').forEach(input=>input.value='')}
});
await start();await spotifyCallback();await initializeAccountSync();registerTools();
if('serviceWorker' in navigator)navigator.serviceWorker.register('sw.js',{updateViaCache:'none'}).catch(()=>{});

let lastUpdateCheck=0;
async function checkWebsiteUpdate(){
 if(document.hidden||Date.now()-lastUpdateCheck<60000)return;lastUpdateCheck=Date.now();
 try{const html=await fetch('index.html',{cache:'no-store'}).then(r=>r.ok?r.text():''),latest=html.match(/src="app\.js\?v=([a-f0-9]+)"/)?.[1],currentVersion=new URL(import.meta.url).searchParams.get('v');
 if(latest&&currentVersion&&latest!==currentVersion)$('#update-banner').hidden=false;
 }catch{}
}
document.addEventListener('visibilitychange',()=>{if(!document.hidden)checkWebsiteUpdate()});
window.addEventListener('online',checkWebsiteUpdate);setInterval(checkWebsiteUpdate,60000);


function browserOutputID(){const storage=window.novaDesktop?localStorage:sessionStorage,key=window.novaDesktop?'nova-music-mac-output':'nova-music-playback-tab';let id=storage.getItem(key);if(!id){id=crypto.randomUUID();storage.setItem(key,id)}return id;}
function browserOutputName(){if(window.novaDesktop)return 'Mac · Nova Music';const platform=navigator.userAgent;return /Macintosh/.test(platform)?'Mac browser':/Windows/.test(platform)?'Windows browser':/iPhone|iPad/.test(platform)?'iPhone browser':/Android/.test(platform)?'Android browser':'Web browser';}
function sharedConnectedLyrics(){const value=connect?.remote && mirroredPlayback?.lyrics;return value?.songID===current?.id?value:null;}
function connectedLyricData(value){return {plain:value.plain,lines:normalizedLines(value.lines),source:value.source,sourceURL:value.sourceURL,instrumental:value.instrumental,missing:!value.instrumental&&!value.plain&&!value.lines.length,custom:true};}
function connectedPlaybackSnapshot(){
 const sample=samplePlayback(),list=queue.map(id=>songs.get(id)).filter(Boolean).map(s=>({...s}));
 if(list[queueIndex] && sample.duration>0)list[queueIndex].duration=sample.duration;
 const lyrics=current?.source==='youtube'?{songID:current.id,recordingID:current.id,loaded:Boolean(lyricData),plain:lyricData?.plain||'',lines:lyricData?.lines||[],instrumental:Boolean(lyricData?.instrumental),source:lyricData?.source||'Lyrics',sourceURL:lyricData?.sourceURL,offset:lyricOffset(),rate:lyricRate()}:undefined;
 return {queue:list,index:Math.max(0,queueIndex),position:Math.max(0,position()),playing,shuffle,repeat,at:Date.now(),lyrics};
}
function stopConnectedPlayback(){++playToken;++youtubeGeneration;cancelYouTube?.();cancelYouTube=null;audio.pause();audio.removeAttribute('src');audio.load();if(objectURL){URL.revokeObjectURL(objectURL);objectURL=null}yt?.destroy?.();yt=null;ytPromise=null;$('#youtube-host').innerHTML='<div id="youtube-player"></div>';$('#youtube-host').classList.add('hidden');lyricAbort?.abort();++lyricToken;lyricData=null;mirroredPlayback=null;queue=[];queueIndex=-1;current=null;setPlaying(false);$('#current-song').innerHTML='Choose a song';renderPanel();}
async function freezeConnectedPlayback(){
 const token=playToken;
 // Capture the engine after it has paused, never seek to the controller's estimate.
 if(current?.source==='youtube'){
  if(!playbackSample(current,yt,audio).confirmed)throw Error('Wait for the current output to finish loading, then transfer again.');
  youtubeClockId=current.id;await yt?.pauseVideo?.();
  const deadline=Date.now()+5000;
  while(yt && yt.getPlayerState?.()===1 && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,25));
  if(yt?.getPlayerState?.()===1)throw Error('The output could not pause. Try the transfer again.');
 }else audio.pause();
 if(token!==playToken)throw Error('Playback changed during transfer.');
 setPlaying(false);
}
async function applyConnectedPlayback(snapshot){
 const wasRemote=Boolean(mirroredPlayback),selected=snapshot.queue[snapshot.index];
 applyingConnectedPlayback=true;mirroredPlayback=null;
 try {
  if(!selected){stopConnectedPlayback();queue=[];queueIndex=-1;current=null;$('#current-song').innerHTML='Choose a song';renderPanel();return;}
  const needsLoad=wasRemote||current?.id!==selected.id;
  remember(snapshot.queue);queue=snapshot.queue.map(s=>s.id);queueIndex=snapshot.index;shuffle=snapshot.shuffle;repeat=snapshot.repeat;
  await applyPlayerCommand(snapshot,{
   needsLoad, load:playCurrent, seek:seekTo, playing:()=>playing, play:togglePlay,
   pause:async()=>{
    if(current?.source==='youtube'){
     await yt?.pauseVideo?.();const deadline=Date.now()+5000;
     while([1,3].includes(yt?.getPlayerState?.()) && Date.now()<deadline)await new Promise(resolve=>setTimeout(resolve,25));
     if([1,3].includes(yt?.getPlayerState?.()))throw Error('The output could not pause. Choose another output location.');
    }else audio.pause();
    setPlaying(false);
   }
  });
  renderPanel();updateOutputButton();
 }finally{applyingConnectedPlayback=false;}
}
function mirrorConnectedPlayback(snapshot){
 const panelChanged=JSON.stringify([mirroredPlayback?.queue,mirroredPlayback?.index,mirroredPlayback?.shuffle,mirroredPlayback?.repeat])!==JSON.stringify([snapshot.queue,snapshot.index,snapshot.shuffle,snapshot.repeat]);
 const previous=current?.id,previousLyrics=JSON.stringify(sharedConnectedLyrics());mirroredPlayback=snapshot;remember(snapshot.queue);queue=snapshot.queue.map(s=>s.id);queueIndex=snapshot.index;current=snapshot.queue[snapshot.index]||null;shuffle=snapshot.shuffle;repeat=snapshot.repeat;
 setPlaying(snapshot.playing);
 $('#current-song').innerHTML=current?art(current.artwork,'',current.title)+`<span><strong>${esc(current.title)}</strong><small>${esc(current.artist)}</small></span>`:'Choose a song';
 if(previous!==current?.id || previousLyrics!==JSON.stringify(sharedConnectedLyrics())){if(current)loadLyrics(current);else lyricData=null;updateMediaSession();}
 if(panelChanged)renderPanel();tick();
}
function updateTransportButtons(){const pending=connect?.pendingPlaying;const intent=pending ?? playing;for(const b of $$('[data-action="toggle-play"]')){b.innerHTML=icon(intent?'pause':'play')+(pending!=null?'<span class="transport-spinner" aria-hidden="true"></span>':'');b.setAttribute('aria-label',intent?'Pause':'Play');b.setAttribute('aria-busy',String(pending!=null));b.classList.toggle('transport-pending',pending!=null);}}
function reportDesktopPlayback(){window.novaDesktop?.post({type:'playback',playing:Boolean(playing&&!connect?.remote)});}
function updateOutputButton(){reportDesktopPlayback();updateTransportButtons();for(const button of $$('[data-action="output-location"]')){button.classList.toggle('active',Boolean(connect?.remote));button.setAttribute('aria-label','Output location: '+(connect?.remote?connect.name:window.novaDesktop?'This Mac':'This browser'));button.title=connect?.remote?'Playing on '+connect.name:'Output location';}if($('#output-device-list'))renderOutputDevices();}
function outputLocation(){modal('Output location','<div id="output-device-list"></div>');renderOutputDevices();connect?.tick().catch(()=>{});}
function renderOutputDevices(){const target=$('#output-device-list');if(!target)return;const model=JSON.stringify([Boolean(accountClient?.user),connect?.owner,connect?.online,connect?.devices]);if(target.dataset.model===model)return;target.dataset.model=model;target.innerHTML=accountClient?.user?`<p class="small-copy">Playing on ${esc(connect.owner===connect.id||!connect.owner?'this browser':connect.name)}${connect.remote&&!connect.online?' · unavailable':''}</p><div class="menu-list">${btn((window.novaDesktop?'This Mac':'This browser')+(connect.owner===connect.id||!connect.owner?' <span aria-label="Selected">✓</span>':''),'select-output',`data-id="${esc(connect.id)}"`)}${connect.remote&&!connect.online?'<p class="small-copy">'+esc(connect.name)+' · unavailable ✓</p>':''}${connect.devices.filter(d=>d.id!==connect.id).map(d=>btn(esc(d.name)+(d.id===connect.owner?' <span aria-label="Selected">✓</span>':''),'select-output',`data-id="${esc(d.id)}"`)).join('')}</div><p class="small-copy">Open Nova Music on another device signed into this account. Keep the browser open for playback. If audio is blocked, press Play in the output browser once.</p>`:`<p>Sign in to the same Nova Music account on both devices to connect playback.</p>${btn('Sign in','account')}`;}
async function remotePlaybackAction(name,data){
 await connect.command(current=>{
  const next=structuredClone(current);next.position=snapshotPosition(current);next.positionIntent=['next','previous','queue-play'].includes(name)?'seek':'preserve';
  if(name==='next'){if(next.index+1<next.queue.length){next.index++;next.position=0;next.playing=true}else if(next.repeat===1){next.index=0;next.position=0}}
  if(name==='previous'){if(next.position>3)next.position=0;else{next.index=Math.max(0,next.index-1);next.position=0}}
  if(name==='shuffle')next.shuffle=!next.shuffle;
  if(name==='repeat')next.repeat=(next.repeat+1)%3;
  if(name==='queue-play'){const index=Number(data.index);if(next.queue[index]){next.index=index;next.position=0;next.playing=true}}
  if(name==='queue-remove'){const i=Number(data.index);if(i!==next.index&&next.queue[i]){next.queue.splice(i,1);if(i<next.index)next.index--;}}
  if(name==='queue-move'){const i=Number(data.index),j=i+Number(data.direction);if(next.queue[i]&&next.queue[j]){[next.queue[i],next.queue[j]]=[next.queue[j],next.queue[i]];if(next.index===i)next.index=j;else if(next.index===j)next.index=i;}}
  if(name==='enqueue'||name==='enqueue-next'){const song=songs.get(data.id);if(song)next.queue.splice(name==='enqueue-next'?next.index+1:next.queue.length,0,song);}
  if(name==='album-queue')next.queue.push(...albumTracks(albums.get(data.id)));
  return next;
 });$('#modal').close();renderPanel();
}
