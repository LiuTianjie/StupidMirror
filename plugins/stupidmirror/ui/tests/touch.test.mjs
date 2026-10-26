import test from 'node:test';
import assert from 'node:assert/strict';
import { build } from 'esbuild';

const bundled = await build({ entryPoints:[new URL('../src/touch.ts', import.meta.url).pathname], bundle:true, write:false, format:'esm', target:'es2022' });
const { createTouchSender } = await import(`data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString('base64')}`);
function harness() {
  const sent = [], failures = [];
  const channel = { readyState:'open', bufferedAmount:0, send(value) { sent.push(JSON.parse(value)); }, close() { this.readyState='closed'; } };
  const sender = createTouchSender(message => failures.push(message));
  sender.attach(channel);
  channel.onmessage({data:JSON.stringify({type:'status',ready:true})});
  return { sender, channel, sent, failures };
}
const message = (phase, seq, gesture_id='finger-1') => ({type:'touch',phase,gesture_id,seq,x:.25,y:.75,geometry_id:'3'});

test('touch down and every move leave immediately; release remains ordered', () => {
  const h = harness();
  for (const [index, phase] of ['down','move','move','up'].entries()) {
    assert.equal(h.sender.send(message(phase,index)), true);
    assert.equal(h.sent.length,index+1);
  }
  assert.deepEqual(h.sent.map(value=>value.phase),['down','move','move','up']);
  h.sender.close();
});

test('pressure coalesces pending moves without dropping down, release, or next gesture', () => {
  const h = harness(); h.channel.bufferedAmount=32*1024;
  h.sender.send(message('down',0));
  for(let i=1;i<=1000;i++) h.sender.send(message('move',i));
  h.sender.send(message('up',1001));
  h.sender.send(message('down',0,'finger-2'));
  h.channel.bufferedAmount=0; h.channel.onbufferedamountlow();
  assert.deepEqual(h.sent.map(value=>[value.phase,value.seq,value.gesture_id]),[
    ['down',0,'finger-1'],['move',1000,'finger-1'],['up',1001,'finger-1'],['down',0,'finger-2'],
  ]);
  h.sender.close();
});

test('rejection closes the stream and discards pending input without replay', () => {
  const h = harness(); h.sender.send(message('down',0));
  h.channel.bufferedAmount=32*1024; h.sender.send(message('move',1));
  h.channel.onmessage({data:JSON.stringify({type:'ack',accepted:false,error:'Device disconnected'})});
  assert.equal(h.sender.ready,false);
  assert.equal(h.sender.send(message('up',2)),false);
  assert.deepEqual(h.sent.map(value=>value.phase),['down']);
  assert.deepEqual(h.failures,['Device disconnected']);
  assert.equal(h.channel.readyState,'closed');
});

test('relative wheel increments remain ordered under pressure instead of coalescing', () => {
  const h = harness(); h.channel.bufferedAmount=32*1024;
  for (const [index, phase] of ['down','move','move','up'].entries()) {
    h.sender.send({...message(phase,index),scroll:{delta_x:0,delta_y:phase==='up'?0:-index}});
  }
  h.channel.bufferedAmount=0; h.channel.onbufferedamountlow();
  assert.deepEqual(h.sent.map(value=>[value.phase,value.scroll.delta_y]),[
    ['down',0],['move',-1],['move',-2],['up',0],
  ]);
  h.sender.close();
});

test('relative wheel overflow closes the channel without silently dropping movement', () => {
  const h = harness(); h.channel.bufferedAmount=32*1024;
  for(let index=0;index<33;index++) h.sender.send({...message(index?'move':'down',index),scroll:{delta_x:0,delta_y:1}});
  assert.equal(h.sender.ready,false);
  assert.equal(h.failures.length,1);
  assert.equal(h.sent.length,0);
});
