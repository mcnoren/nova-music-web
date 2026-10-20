import test from 'node:test';
import assert from 'node:assert/strict';
import {NativeMusicPlayer} from '../docs/native-player.js';
function fixture(){
 const target=new EventTarget(),sent=[],states=[];
 const player=new NativeMusicPlayer({post:value=>sent.push(value)},{onStateChange:value=>states.push(value.data)},target);
 function reply(command,value={}){
  const request=sent.findLast(s=>s.command===command);
  player.receive({request:request.request,state:{id:'abcdefghijk',position:0,duration:180,state:2,rate:1,generation:request.generation,...value}});
 }
 return {player,sent,states,reply};
}
test('native loads preserve the exact position and wait for native preparation',async()=>{
 const f=fixture();let settled=false;f.player.setVolume(65);
 const work=f.player.loadVideoById({videoId:'abcdefghijk',startSeconds:18.125,title:'Track',artist:'Artist'}).then(()=>settled=true);
 assert.equal(settled,false);assert.equal(f.sent[0].position,18.125);assert.equal(f.sent[0].volume,65);assert.equal(f.sent[0].playing,true);
 f.reply('load',{position:18.125,state:1});await work;
 assert.equal(f.player.getCurrentTime(),18.125);assert.equal(f.player.getPlaybackRate(),1);f.player.destroy();
});
test('pause waits for the native clock and does not send a seek',async()=>{
 const f=fixture(),load=f.player.loadVideoById({videoId:'abcdefghijk'});f.reply('load',{position:42.75,state:1});await load;
 const work=f.player.pauseVideo();assert.equal(f.player.getPlayerState(),1);
 f.reply('pause',{position:43.125,state:2});await work;
 assert.equal(f.player.getCurrentTime(),43.125);assert.equal(f.sent.filter(s=>s.command==='seek').length,0);f.player.destroy();
});
test('late samples from the previous recording cannot rewind or change the new recording',async()=>{
 const f=fixture(),first=f.player.loadVideoById({videoId:'abcdefghijk'});const old=f.sent[0].generation;
 f.reply('load',{position:50,state:1});await first;
 const second=f.player.cueVideoById({videoId:'lmnopqrstuv',startSeconds:0});f.reply('load',{id:'lmnopqrstuv',position:0,state:2});await second;
 f.player.receive({state:{id:'abcdefghijk',position:99,duration:180,state:1,rate:1,generation:old}});
 assert.equal(f.player.getCurrentTime(),0);assert.equal(f.player.getPlayerState(),2);assert.match(f.player.getVideoUrl(),/lmnopqrstuv/);f.player.destroy();
});
test('native errors reject pending commands instead of falsely confirming playback',async()=>{
 const f=fixture(),work=f.player.loadVideoById({videoId:'abcdefghijk'});
 f.player.receive({request:f.sent[0].request,error:'Stream unavailable'});
 await assert.rejects(work,/Stream unavailable/);f.player.destroy();
});
test('native loads include current album and cover art for macOS Now Playing',async()=>{
 const f=fixture(),artwork='https://example.com/cover.jpg';
 const work=f.player.loadVideoById({videoId:'abcdefghijk',title:'Track',artist:'Artist',album:'Album',artwork});
 assert.equal(f.sent[0].album,'Album');assert.equal(f.sent[0].artwork,artwork);f.reply('load');await work;f.player.destroy();
});
test('native queue preparation keeps the active generation and adopts the next track before state events',async()=>{
 const target=new EventTarget(),sent=[],changes=[];
 const player=new NativeMusicPlayer({post:value=>sent.push(value)},{onTrackChange:value=>changes.push(value.id)},target);
 const load=player.loadVideoById({videoId:'abcdefghijk'});const generation=player.generation;
 player.receive({request:sent[0].request,state:{id:'abcdefghijk',generation,state:1,position:0,duration:180}});await load;
 const preparing=player.queueNext({id:'lmnopqrstuv',title:'Next',artist:'Artist'});const request=sent.at(-1);
 assert.equal(request.command,'queue-next');assert.equal(request.generation,generation);
 player.receive({request:request.request});await preparing;
 player.receive({advanced:'lmnopqrstuv',state:{id:'lmnopqrstuv',generation,state:1,position:0,duration:200}});
 assert.deepEqual(changes,['lmnopqrstuv']);assert.match(player.getVideoUrl(),/lmnopqrstuv/);
 player.receive({advanced:'abcdefghijk',state:{id:'abcdefghijk',generation:'stale',state:1,position:0}});
 assert.deepEqual(changes,['lmnopqrstuv']);player.destroy();
});
