import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { transform } from 'esbuild';
import vm from 'node:vm';
const source=await readFile(new URL('../src/video.ts',import.meta.url),'utf8');
const {code}=await transform(source,{loader:'ts',format:'cjs',target:'es2022'});
function setup(reply) {
  const calls=[],connections=[],timers=new Map();let timerId=0;let now=0;let changed=0;const stopped=[];
  class Peer {
    constructor(){connections.push(this);this.iceGatheringState='complete';this.connectionState='new';}
    addTransceiver(kind,settings){assert.equal(kind,'video');assert.equal(settings.direction,'recvonly');}
    async createOffer(){return {type:'offer',sdp:'browser-offer'};}
    async setLocalDescription(value){this.localDescription=value;}
    async setRemoteDescription(value){this.remoteDescription=value;}
    close(){this.connectionState='closed';this.onconnectionstatechange?.();}
  }
  const module={exports:{}};
  vm.runInNewContext(code,{module,exports:module.exports,Error,AbortController,RTCPeerConnection:Peer,MediaStream:class{},performance:{now:()=>now},
    setTimeout(fn){const id=++timerId;timers.set(id,fn);return id;},clearTimeout(id){timers.delete(id);}});
  const video={hidden:true,videoWidth:1260,videoHeight:2736,play:async()=>{},requestVideoFrameCallback:()=>1,cancelVideoFrameCallback(){}};
  const app={callServerTool(params){calls.push(params);return reply?reply(params):Promise.resolve({structuredContent:{peer_id:'peer-1',type:'answer',sdp:'answer'}});}};
  const ready=[];const controller=module.exports.createVideo(app,video,{ready:size=>ready.push(size),stopped:(reason,retrying)=>{changed++;stopped.push({reason,retrying});},fps(){}});
  return {controller,calls,connections,video,ready,timers,stopped,get changed(){return changed;},advance(value){now+=value;}};
}
const flush=async()=>{for(let i=0;i<10;i++)await Promise.resolve();};
test('WebRTC sends only a receive-video offer through MCP and accepts a decoded full-size frame',async()=>{
  const h=setup();await h.controller.connect('phone-a');
  assert.equal(h.calls[0].name,'screen_signal');assert.equal(h.calls[0].arguments.device_id,'phone-a');
  assert.equal(h.controller.active,false);assert.equal(h.controller.pending,true);
  h.video.onloadeddata();assert.equal(h.controller.active,true);assert.equal(h.controller.pending,false);
  assert.equal(JSON.stringify(h.ready[0]),JSON.stringify({width:1260,height:2736}));
  await h.controller.connect('phone-a');assert.equal(h.calls.length,1);
  h.controller.close();await flush();assert.equal(h.calls.at(-1).arguments.peer_id,'peer-1');
  assert.equal(h.calls.at(-1).arguments.action,'close');assert.equal(h.video.srcObject,null);
});
test('switching while an offer is in flight closes the stale peer instead of attaching its video',async()=>{
  let answer;const h=setup(params=>params.arguments.action==='offer'?new Promise(resolve=>{answer=resolve;}):Promise.resolve({}));
  const connecting=h.controller.connect('phone-a');await flush();h.controller.close();
  answer({structuredContent:{peer_id:'stale',sdp:'old-answer'}});await connecting;await flush();
  assert.equal(h.connections[0].remoteDescription,undefined);
  assert.equal(h.calls.at(-1).arguments.peer_id,'stale');assert.equal(h.controller.active,false);
});
test('failed video backs off and can reconnect without retaining the old peer',async()=>{
  const h=setup();await h.controller.connect('phone-a');h.video.onloadeddata();
  h.connections[0].connectionState='failed';h.connections[0].onconnectionstatechange();
  assert.equal(h.controller.active,false);assert.equal(h.changed,1);
  await h.controller.connect('phone-a');assert.equal(h.connections.length,1);
  h.advance(4000);await h.controller.connect('phone-a');assert.equal(h.connections.length,2);
});
test('signaling failures preserve their reason, stop after three attempts, and manual retry starts immediately',async()=>{
  const h=setup(params=>params.arguments.action==='offer'?Promise.reject(new Error('App server request queue is full')):Promise.resolve({}));
  for(let i=0;i<3;i++){await h.controller.connect('phone-a');h.advance(5000);}
  assert.equal(h.changed,3);assert.equal(h.connections.length,3);
  assert.match(h.stopped[2].reason,/App server request queue is full/);assert.equal(h.stopped[2].retrying,false);
  await h.controller.connect('phone-a');assert.equal(h.connections.length,3);
  h.controller.retry();await h.controller.connect('phone-a');assert.equal(h.connections.length,4);
});
test('decoded video clears the first-frame watchdog; a transient disconnect can recover',async()=>{
  const h=setup();await h.controller.connect('phone-a');
  assert.equal(h.timers.size,1);h.video.onloadeddata();assert.equal(h.timers.size,0);
  h.connections[0].connectionState='disconnected';h.connections[0].onconnectionstatechange();
  assert.equal(h.controller.active,true);assert.equal(h.timers.size,1);
  h.connections[0].connectionState='connected';h.connections[0].onconnectionstatechange();
  assert.equal(h.timers.size,0);assert.equal(h.controller.active,true);assert.equal(h.changed,0);
});
