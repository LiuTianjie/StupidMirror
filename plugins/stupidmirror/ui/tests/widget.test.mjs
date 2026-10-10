import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

const source = await readFile(new URL('../src/app.ts', import.meta.url), 'utf8');
const bundled = await build({ stdin: {
  contents: source.replace("import { App } from '@modelcontextprotocol/ext-apps';", 'const App = globalThis.MockApp;'),
  loader: 'ts', resolveDir: fileURLToPath(new URL('../src', import.meta.url)),
}, bundle:true, write:false, format:'esm', target:'es2022' });
const code = `(async () => {${bundled.outputFiles[0].text}\n})()`;


const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };
const preview = (fields = {}) => ({ server_time: 1000, frame: null, viewport: null, busy: false, paused: false, events: [], ...fields });
// Fixtures exist only in this isolated DOM test, never in the shipped widget.
const frame = (seq = 1) => ({ seq, data: 'test-image-only', mimeType: 'image/png', width: 900, height: 1800 });

async function harness({ reducedMotion = false, context = { displayMode: 'inline', availableDisplayModes: ['fullscreen'] }, reply, connectReply, messageReply, messageImage = true } = {}) {
  let now = 0;
  let timerId = 0;
  let instance;
  let resize;
  const timers = new Map();
  const listeners = new Map();
  const calls = [];
  const sentMessages = [];
  const contextUpdates = [];
  const drawnRegions = [];
  const lifecycle = [];
  const requestOptions = [];
  let layoutReads = 0;
  let imageWrites = 0;
  const ids = ['app', 'device', 'screen', 'image', 'empty-state', 'empty-state-text', 'cursor', 'stage', 'model', 'live-text', 'toast',
    'empty-hint', 'empty-retry', 'tool-refresh', 'tool-home', 'tool-screenshot', 'tool-pause', 'device-picker', 'device-menu', 'device-switcher', 'pause-label', 'video', 'control-button', 'annotate-button', 'control-label',
    'annotation-overlay','annotation-editor','annotation-note','annotation-count','annotation-undo','annotation-delete','annotation-cancel','annotation-send','annotation-hint'];
  const elements = Object.fromEntries(ids.map(id => [id, {
    style: { setProperty(name, value) { this[name] = value; } }, dataset: {},
    hidden: ['device', 'screen', 'cursor', 'toast', 'device-menu'].includes(id), clientWidth: 400, clientHeight: 800,
    disabled: false, value: '', textContent: '', handlers: new Map(), children: [],
    addEventListener(name, fn) { this.handlers.set(name, fn); },
    removeEventListener(name) { this.handlers.delete(name); },
    click() { this.handlers.get('click')?.(); },
    setAttribute(name, value) { this[name] = value; },
    getAttribute(name) { return this[name]; },
    focus() { document.activeElement = this; },
    getBoundingClientRect() { return {left:100,top:50,width:400,height:800}; },
    setPointerCapture(id) { this.capturedPointer = id; },
    hasPointerCapture(id) { return this.capturedPointer === id; },
    releasePointerCapture() { this.capturedPointer = undefined; },
    contains(target) { return target === this || this.children.includes(target); },
    removeAttribute(name) { delete this[name]; },
    cloneNode() { return { ...this, style: { ...this.style }, dataset: { ...this.dataset }, children: [], animation: undefined }; },
    replaceChildren(...nodes) { this.children = nodes; },
    appendChild(node) { this.children.push(node); node.parent = this; return node; },
    remove() { const children = this.parent?.children; if (children?.includes(this)) children.splice(children.indexOf(this), 1); },
    animate(frames, options) {
      const animation = { frames, options, cancelled: false, cancel() { this.cancelled = true; } };
      this.animation = animation;
      return animation;
    },
  }]));
  // The stage is the area left between the status pill and the toolbar; reading it is a layout read.
  const stageSize = { width: 376, height: 776 };
  Object.defineProperty(elements.stage, 'clientWidth', { configurable: true, get: () => { layoutReads++; return stageSize.width; } });
  Object.defineProperty(elements.stage, 'clientHeight', { configurable: true, get: () => stageSize.height });
  let imageSource;
  Object.defineProperty(elements.image, 'src', {
    configurable: true, get: () => imageSource, set: value => { imageSource = value; imageWrites++; },
  });
  elements.image.removeAttribute = name => { if (name === 'src') imageSource = undefined; };
  class MockApp {
    constructor(info, capabilities, options) { Object.assign(this, { info, capabilities, options }); instance = this; }
    async connect() { lifecycle.push('connect'); if (connectReply) await connectReply(); }
    async close() { this.onclose?.(); }
    getHostContext() { return context; }
    getHostCapabilities() { return {message:{text:{},...(messageImage ? {image:{}} : {})},updateModelContext:{image:{}}}; }
    async sendMessage(params) { sentMessages.push(params); return messageReply ? messageReply(params) : {}; }
    async updateModelContext(params) { contextUpdates.push(params); return {}; }
    async requestDisplayMode(params) { lifecycle.push(params.mode); return { mode: params.mode }; }
    callServerTool(params, options) {
      calls.push(params);
      requestOptions.push(options);
      return reply ? reply(params, options) : Promise.resolve({ structuredContent: preview() });
    }
  }
  const document = {
    hidden: false,
    documentElement: { dataset: {} },
    getElementById: id => elements[id],
    createElement: tag => tag === 'canvas' ? {
      width:0,height:0,toDataURL:()=> 'data:image/png;base64,unit-test-frozen-pixels',
      getContext:()=>({drawImage(){},strokeRect(...bounds){drawnRegions.push(bounds);},fillText(){},fill(){},arc(){},beginPath(){}}),
    } : ({ ...elements.model, style: { ...elements.model.style }, dataset: {}, handlers: new Map(), children: [] }),
    createElementNS: () => ({ ...elements.model, style: { ...elements.model.style }, dataset: {}, handlers: new Map(), children: [] }),
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: name => listeners.delete(name),
  };
  await vm.runInNewContext(code, {
    MockApp, document, Error, AbortController, Image:class { async decode() {} },
    matchMedia: () => ({ matches: reducedMotion }),
    performance: { now: () => now },
    ResizeObserver: class { constructor(callback) { this.callback = callback; resize = this; } observe() {} disconnect() { this.disconnected = true; } },
    window: { addEventListener: (name, fn) => listeners.set(name, fn), removeEventListener: name => listeners.delete(name) },
    setTimeout: (fn, delay) => { const id = ++timerId; timers.set(id, { fn, delay, due: now + delay }); return id; },
    clearTimeout: id => timers.delete(id),
  });
  return {
    app: instance, calls, sentMessages, contextUpdates, drawnRegions, lifecycle, elements, document, timers, resize,
    requestOptions, stageSize,
    get layoutReads() { return layoutReads; },
    get imageWrites() { return imageWrites; },
    visibility(hidden) { document.hidden = hidden; listeners.get('visibilitychange')?.(); },
    event(name, value = {}) { listeners.get(name)?.(value); },
    async tick() {
      const entry = [...timers.entries()].sort((a, b) => a[1].due - b[1].due)[0];
      if (!entry) return;
      timers.delete(entry[0]); now = entry[1].due; entry[1].fn(); await flush();
    },
  };
}

test('connects before requesting only fullscreen, then polls only the app frame tool', async () => {
  const h = await harness();
  assert.equal(h.app.capabilities.availableDisplayModes.join(','), 'fullscreen');
  assert.equal(h.app.options.autoResize, false);
  assert.equal(h.lifecycle.join(','), 'connect,fullscreen');
  await h.tick();
  assert.equal(h.calls.length, 1);
  assert.equal(h.calls[0].name, 'screen_frame');
  assert.equal(JSON.stringify(h.calls[0].arguments), '{"after_seq":0}');
  assert.equal([...h.timers.values()][0].delay, 250);
  assert.equal(h.requestOptions[0].timeout, 3000);
});

test('preserves full frame aspect ratio and maps gestures using the point viewport', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(12), viewport: { width: 400, height: 800 }, busy: true,
    events: [{ id: 1, kind: 'tap', at: 1000, point: { x: 100, y: 200 }, viewport: { width: 400, height: 800 } }] }) });
  assert.equal(h.elements.app.dataset.frameSeq, '12');
  assert.equal(h.elements.app.dataset.busy, 'true');
  assert.equal(h.elements.device.hidden, false);
  assert.equal(h.elements.screen.hidden, false);
  const bezel = 0;
  const width = parseFloat(h.elements.device.style.width);
  const height = parseFloat(h.elements.device.style.height);
  assert.ok(Math.abs(width - 376) < 1e-8);
  assert.ok(Math.abs((width - 2 * bezel) / (height - 2 * bezel) - .5) < 1e-8);
  assert.ok(height <= 776);
  assert.equal(h.elements.device.dataset.orientation, 'portrait');
  assert.equal(h.elements.image.src, 'data:image/png;base64,test-image-only');
  assert.equal(h.elements.cursor.style.left, '25%');
  assert.equal(h.elements.cursor.style.top, '25%');
  assert.equal(h.elements.cursor.animation.options.duration, 1600);
  h.app.ontoolresult({ structuredContent: preview({ events: [{ id: 2, kind: 'drag', at: 1000, from: { x: 40, y: 80 }, to: { x: 360, y: 720 }, duration_ms: 650 }] }) });
  const drag = h.elements.screen.children[0];
  assert.equal(drag.style.left, '10%');
  assert.equal(drag.animation.frames[3].transform, 'translate(320px, 640px) scale(.92)');
  assert.equal(drag.animation.options.duration, 1650);
});

test('tap feedback stays readable for one to two seconds with a small press and rebound', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(), viewport: { width: 400, height: 800 },
    events: [{ id: 1, kind: 'tap', at: 1000, point: { x: 200, y: 400 } }] }) });
  const effect = h.elements.cursor.animation;
  assert.ok(effect.options.duration >= 1000 && effect.options.duration <= 2000);
  const visible = effect.frames.filter(frame => frame.opacity === 1);
  assert.ok((visible.at(-1).offset - visible[0].offset) * effect.options.duration >= 1200);
  const scales = effect.frames.map(frame => Number(frame.transform.match(/scale\(([^)]+)\)/)[1]));
  assert.ok(Math.min(...scales) >= .85 && Math.min(...scales) < 1);
  assert.ok(Math.max(...scales) > 1 && Math.max(...scales) <= 1.1);
  effect.onfinish();
  assert.equal(h.elements.cursor.hidden, true);
});

test('overlapping taps and short drags keep independent readable lifetimes', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(), viewport: { width: 400, height: 800 }, events: [
    { id: 1, kind: 'tap', at: 1000, point: { x: 100, y: 200 } },
    { id: 2, kind: 'drag', at: 1000, from: { x: 200, y: 400 }, to: { x: 200, y: 600 }, duration_ms: 120 },
  ] }) });
  const tap = h.elements.cursor.animation;
  const drag = h.elements.screen.children[0];
  assert.equal(tap.cancelled, false);
  assert.ok(drag.animation.options.duration >= 1600 && drag.animation.options.duration <= 2000);
  assert.equal(drag.animation.frames.at(-2).opacity, 1);
  tap.onfinish();
  assert.equal(drag.hidden, false);
  assert.equal(drag.animation.cancelled, false);
  drag.animation.onfinish();
  assert.equal(h.elements.screen.children.length, 0);
});

test('authentication pause removes every active gesture and its animation', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(), viewport: { width: 400, height: 800 }, events: [
    { id: 1, kind: 'tap', at: 1000, point: { x: 100, y: 200 } },
    { id: 2, kind: 'tap', at: 1000, point: { x: 200, y: 400 } },
  ] }) });
  const first = h.elements.cursor.animation;
  const second = h.elements.screen.children[0].animation;
  h.app.ontoolresult({ structuredContent: preview({ paused: true }) });
  assert.equal(first.cancelled, true);
  assert.equal(second.cancelled, true);
  assert.equal(h.elements.cursor.hidden, true);
  assert.equal(h.elements.screen.children.length, 0);
  first.onfinish(); second.onfinish();
  assert.equal(h.elements.cursor.hidden, true);
});

test('omitted frames preserve the displayed image and acknowledgements advance once', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(7), viewport: { width: 400, height: 800 },
    events: [{ id: 3, kind: 'tap', at: 1000, point: { x: 100, y: 200 } }] }) });
  const animation = h.elements.cursor.animation;
  h.app.ontoolresult({ structuredContent: preview({ events: [{ id: 3, kind: 'tap', at: 1000, point: { x: 200, y: 400 } }] }) });
  assert.equal(h.elements.cursor.animation, animation);
  assert.equal(h.elements.image.src, 'data:image/png;base64,test-image-only');
  await h.tick();
  assert.equal(JSON.stringify(h.calls[0].arguments), '{"after_seq":7}');
});

test('operation state survives tool gaps, hidden panels and temporary missing frames', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ stream_id: 'one', frame: frame(), frame_available: true }) });
  assert.equal(h.elements.app.dataset.operating, 'false');
  h.app.ontoolresult({ structuredContent: preview({ busy: true }) });
  for (let i = 0; i < 50; i++) h.app.ontoolresult({ structuredContent: preview({ busy: false }) });
  assert.equal(h.elements.app.dataset.busy, 'false');
  assert.equal(h.elements.app.dataset.operating, 'true');
  h.visibility(true);
  h.visibility(false);
  assert.equal(h.elements.app.dataset.operating, 'true');
  h.app.ontoolresult({ structuredContent: preview({ frame_available: false }) });
  assert.equal(h.elements.device.hidden, false);
  assert.equal(h.elements.app.dataset.operating, 'true');
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(2), frame_available: true }) });
  assert.equal(h.elements.device.hidden, false);
  assert.equal(h.elements.app.dataset.operating, 'true');
  h.app.ontoolresult({ structuredContent: preview({ paused: true }) });
  assert.equal(h.elements.app.dataset.operating, 'false');
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(3), busy: false }) });
  assert.equal(h.elements.app.dataset.operating, 'false');
  h.app.ontoolresult({ structuredContent: preview({ busy: true }) });
  h.app.ontoolresult({ structuredContent: preview({ stream_id: 'two', frame: frame(), busy: false }) });
  assert.equal(h.elements.app.dataset.operating, 'false');
});

test('fits the exact image in narrow and landscape panels without a chassis', async () => {
  const h = await harness();
  let seq = 0;
  for (const [panelWidth, panelHeight, imageWidth, imageHeight] of [[170, 450, 440, 956], [900, 270, 956, 440], [310, 140, 440, 956]]) {
    h.stageSize.width = panelWidth - 24;
    h.stageSize.height = panelHeight - 24;
    h.app.ontoolresult({ structuredContent: preview({ frame: { ...frame(++seq), width: imageWidth, height: imageHeight } }) });
    h.resize.callback();
    const bezel = 0;
    const width = parseFloat(h.elements.device.style.width);
    const height = parseFloat(h.elements.device.style.height);
    assert.ok(width <= (panelWidth - 24) + 1e-8);
    assert.ok(height <= (panelHeight - 24) + 1e-8);
    assert.ok(Math.abs((width - 2 * bezel) / (height - 2 * bezel) - imageWidth / imageHeight) < 1e-8);
    assert.equal(h.elements.device.dataset.orientation, imageWidth > imageHeight ? 'landscape' : 'portrait');
    assert.equal(h.elements.screen.style.width, undefined);
    assert.equal(h.elements.screen.style.height, undefined);
  }
});

test('a hidden panel stops polling, and slow calls never overlap', async () => {
  let resolve;
  const h = await harness({ reply: () => new Promise(done => { resolve = done; }) });
  await h.tick();
  assert.equal(h.calls.length, 1);
  h.app.ontoolresult({ structuredContent: preview() });
  await h.tick();
  assert.equal(h.calls.length, 1);
  h.visibility(true);
  resolve({ structuredContent: preview({ frame: frame(1) }) });
  await flush();
  assert.equal(h.timers.size, 0);
  assert.equal(h.elements.screen.hidden, true);
  assert.equal(h.elements['empty-state'].hidden, false);
  h.visibility(false);
  await h.tick();
  assert.equal(h.calls.length, 2);
});

test('paused clears the screen, errors back off with a bounded retry budget, teardown cancels work', async () => {
  const h = await harness({ reply: async () => ({ isError: true }) });
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(4), busy: true }) });
  h.app.ontoolresult({ structuredContent: preview({ paused: true }) });
  assert.equal(h.elements.screen.hidden, true);
  assert.equal(h.elements.image.hidden, true);
  assert.equal(h.elements['empty-state-text'].textContent, '预览已暂停');
  assert.equal(h.elements.image.src, undefined);
  assert.equal(h.elements.app.dataset.busy, 'false');
  assert.equal(h.elements.device.hidden, true);
  assert.equal(h.elements.app.dataset.operating, 'false');
  await h.tick();
  assert.equal([...h.timers.values()][0].delay, 500);
  await h.tick();
  assert.equal([...h.timers.values()][0].delay, 1000);
  await h.tick(); await h.tick(); await h.tick();
  assert.equal(h.timers.size, 0);
  assert.equal(h.calls.length, 3);
  await h.app.onteardown();
  assert.equal(h.timers.size, 0);
  assert.equal(h.resize.disconnected, true);
  assert.equal(h.elements.screen.hidden, true);
});

test('reduced motion shows a stationary cursor and old gestures are not replayed', async () => {
  const h = await harness({ reducedMotion: true, context: { displayMode: 'fullscreen', availableDisplayModes: ['fullscreen'] } });
  assert.equal(h.lifecycle.join(','), 'connect');
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(2), viewport: { width: 400, height: 800 },
    events: [{ id: 1, kind: 'drag', at: 1000, from: { x: 40, y: 80 }, to: { x: 360, y: 720 }, duration_ms: 900 }] }) });
  assert.equal(h.elements.cursor.style.left, '90%');
  assert.equal(h.elements.cursor.animation, undefined);
  h.app.ontoolresult({ structuredContent: preview({ server_time: 10000, events: [{ id: 2, kind: 'tap', at: 1000, point: { x: 200, y: 400 } }] }) });
  assert.equal(h.elements.cursor.style.left, '90%');
  for (let i = 0; i < 5; i++) await h.tick();
  assert.equal(h.elements.cursor.hidden, false);
  for (let i = 0; i < 4; i++) await h.tick();
  assert.equal(h.elements.cursor.hidden, true);
});

test('a reconnected server restarts acknowledgements and unavailable streams retain the last pixels', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ stream_id: 'old', frame: frame(800), frame_available: true }) });
  h.app.ontoolresult({ structuredContent: preview({ stream_id: 'new', frame_available: false }) });
  assert.equal(h.elements.screen.hidden, false);
  await h.tick();
  assert.equal(h.calls[0].arguments.after_seq, 0);
  h.app.ontoolresult({ structuredContent: preview({ stream_id: 'new', frame: frame(1), frame_available: true }) });
  assert.equal(h.elements.app.dataset.frameSeq, '1');
  assert.equal(h.elements.screen.hidden, false);
  h.app.ontoolresult({ structuredContent: preview({ stream_id: 'new', frame_available: false }) });
  assert.equal(h.elements.screen.hidden, false);
  assert.equal(h.elements.image.src, 'data:image/png;base64,test-image-only');
  assert.equal(h.elements.app.dataset.frameSeq, '1');
});

test('failed frame calls retain the previously visible image and back off', async () => {
  const h = await harness({ reply: async () => { throw new Error('disconnected'); } });
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(19), busy: true }) });
  assert.equal(h.elements.screen.hidden, false);
  await h.tick();
  assert.equal(h.elements.screen.hidden, false);
  assert.equal(h.elements.image.src, 'data:image/png;base64,test-image-only');
  assert.equal(h.elements.app.dataset.busy, 'false');
  assert.equal(h.elements.app.dataset.operating, 'true');
  assert.equal([...h.timers.values()][0].delay, 500);
});

test('page-cache suspension retains pixels, stops work, and resumes on pageshow', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(9), busy: true }) });
  h.event('pagehide', { persisted: true });
  assert.equal(h.elements.app.dataset.pageVisible, 'false');
  assert.equal(h.elements.screen.hidden, false);
  assert.equal(h.timers.size, 0);
  h.event('pageshow', { persisted: true });
  assert.equal(h.elements.app.dataset.pageVisible, 'true');
  await h.tick();
  assert.equal(h.calls[0].arguments.after_seq, 9);
  h.event('pagehide', { persisted: false });
  assert.equal(h.elements.screen.hidden, false);
  assert.equal(h.timers.size, 0);
  h.event('focus');
  await h.tick();
  assert.equal(h.calls.length, 2);
  h.event('pagehide', { persisted: false });
  h.visibility(true);
  h.visibility(false);
  await h.tick();
  assert.equal(h.calls.length, 3);
  await h.app.onteardown();
  assert.equal(h.elements.screen.hidden, true);
});

test('transport close retains pixels and reconnects without another fullscreen request', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(8) }) });
  h.app.onclose();
  assert.equal(h.elements.screen.hidden, false);
  await h.tick();
  assert.equal(h.lifecycle.join(','), 'connect,fullscreen,connect');
  assert.equal(h.calls[0].arguments.after_seq, 8);
  await h.app.onteardown();
  h.app.onclose();
  assert.equal(h.timers.size, 0);
});

test('an initial host handshake failure retries instead of permanently disposing the view', async () => {
  let connects = 0;
  const h = await harness({ connectReply: async () => { if (++connects === 1) throw Error('host asleep'); } });
  assert.equal(h.calls.length, 0);
  assert.equal([...h.timers.values()][0].delay, 1000);
  await h.tick();
  assert.equal(connects, 2);
  assert.equal(h.calls.length, 1);
  assert.notEqual(h.resize.disconnected, true);
});

test('same-size frames avoid repeated layout reads and duplicate sequences avoid image writes', async () => {
  const h = await harness();
  const initialLayouts = h.layoutReads; // One initial layout for the disconnected chassis.
  for (let seq = 1; seq <= 30; seq++) h.app.ontoolresult({ structuredContent: preview({ frame: frame(seq) }) });
  assert.equal(h.layoutReads, initialLayouts + 1);
  assert.equal(h.imageWrites, 30);
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(30) }) });
  assert.equal(h.imageWrites, 30);
  h.resize.callback();
  assert.equal(h.layoutReads, initialLayouts + 2);
});

test('no frame shows a status without drawing an empty phone shell', async () => {
  const h = await harness();
  assert.equal(h.elements.device.hidden, true);
  assert.equal(h.elements.screen.hidden, true);
  assert.equal(h.elements.image.hidden, true);
  h.app.ontoolresult({ structuredContent: preview({ frame_available: false }) });
  assert.equal(h.elements['empty-state-text'].textContent, '未连接');
  assert.equal(h.elements['empty-state'].hidden, false);
  assert.equal(h.elements.device.style.height, undefined);
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(1), frame_available: true }) });
  assert.equal(h.elements['empty-state'].hidden, true);
  assert.equal(h.elements.image.hidden, false);
  // A transient gap retains actual pixels; the placeholder must not replace them.
  h.app.ontoolresult({ structuredContent: preview({ frame_available: false }) });
  assert.equal(h.elements['empty-state'].hidden, true);
  assert.equal(h.elements.image.hidden, false);
});

test('empty screen explains connecting, offline, locked, authentication and paused states', async () => {
  const h = await harness();
  assert.equal(h.elements['empty-state'].dataset.state, 'connecting');
  assert.equal(h.elements['empty-state-text'].textContent, '正在连接');
  for (const [fields, state, label] of [
    [{ frame_available: false }, 'offline', '未连接'],
    [{ paused: true, pause_reason: 'device_locked' }, 'locked', '等待解锁'],
    [{ paused: true, pause_reason: 'authentication' }, 'authentication', '请完成认证'],
    [{ paused: true, pause_reason: 'unknown' }, 'paused', '预览已暂停'],
    [{ paused: true }, 'paused', '预览已暂停'],
  ]) {
    h.app.ontoolresult({ structuredContent: preview(fields) });
    assert.equal(h.elements['empty-state'].dataset.state, state);
    assert.equal(h.elements['empty-state-text'].textContent, label);
    assert.equal(h.elements['empty-state'].hidden, false);
    assert.equal(h.elements.image.hidden, true);
  }
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(1), frame_available: true }) });
  assert.equal(h.elements['empty-state'].hidden, true);
});

test('failed reconnect restores the authentication symbol and keeps phone controls disabled', async () => {
  let release;
  const h = await harness({ reply: params => params.name === 'screen_action'
    ? new Promise(resolve => { release = resolve; })
    : Promise.resolve({ structuredContent: preview() }) });
  h.app.ontoolresult({ structuredContent: preview({ paused: true, pause_reason: 'authentication' }) });
  h.elements['tool-refresh'].click();
  await flush();
  assert.equal(h.elements['empty-state'].dataset.state, 'connecting');
  release({ isError: true, structuredContent: { error: { code: 'pua_unreachable' } } });
  await flush();
  assert.equal(h.elements['empty-state'].dataset.state, 'authentication');
  assert.equal(h.elements['empty-state-text'].textContent, '请完成认证');
  assert.equal(h.elements['tool-home'].disabled, true);
  assert.equal(h.elements['tool-screenshot'].disabled, true);
});

test('first image decode failure hides the phone and explains the unavailable picture', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(1) }) });
  h.elements.image.onerror();
  assert.equal(h.elements.image.src, undefined);
  assert.equal(h.elements.image.hidden, true);
  assert.equal(h.elements.device.hidden, true);
  assert.equal(h.elements['empty-state-text'].textContent, '画面暂不可用');
  assert.equal(h.elements['empty-state'].hidden, false);
});

test('decode failure restores the last loaded image, while authentication pause erases its backup', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(6) }) });
  h.elements.image.onload();
  const previous = h.elements.image.src;
  h.app.ontoolresult({ structuredContent: preview({ frame: { ...frame(7), data: 'broken-fixture', width: 1800, height: 900 } }) });
  h.elements.image.onerror();
  assert.equal(h.elements.image.src, previous);
  assert.equal(h.elements.device.dataset.orientation, 'portrait');
  await h.tick();
  assert.equal(h.calls[0].arguments.after_seq, 0);
  h.app.ontoolresult({ structuredContent: preview({ paused: true }) });
  h.elements.image.onerror();
  assert.equal(h.elements.image.src, undefined);
  assert.equal(h.elements.screen.hidden, true);
  assert.equal(h.elements['empty-state'].hidden, false);
});

test('unavailable and paused previews poll slowly, and focus wakes recovery immediately', async () => {
  const h = await harness({ reply: async () => ({ structuredContent: preview({ frame_available: false }) }) });
  await h.tick();
  assert.equal([...h.timers.values()][0].delay, 1000);
  h.event('focus');
  assert.equal([...h.timers.values()][0].delay, 0);
  await h.tick();
  h.visibility(true);
  assert.equal(h.elements.app.dataset.pageVisible, 'false');
  assert.equal(h.timers.size, 0);
});

test('a frame requested before authentication pause cannot restore cleared pixels', async () => {
  let resolve;
  const h = await harness({ reply: () => new Promise(done => { resolve = done; }) });
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(4) }) });
  await h.tick();
  h.app.ontoolresult({ structuredContent: preview({ paused: true }) });
  resolve({ structuredContent: preview({ frame: frame(5), paused: false }) });
  await flush();
  assert.equal(h.elements.image.src, undefined);
  assert.equal(h.elements.screen.hidden, true);
  assert.equal(h.elements['empty-state'].hidden, false);
  await h.tick();
  resolve({ structuredContent: preview({ frame: frame(6), paused: false }) });
  await flush();
  assert.equal(h.elements.screen.hidden, false);
});

test('status pill names the phone model and follows the stream state', async () => {
  const h = await harness();
  assert.equal(h.elements.app.dataset.live, undefined);
  assert.equal(h.elements.model.textContent, '');
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(1), frame_available: true, device: { id: 'phone-1', model: 'iPhone 17 Pro Max' } }) });
  assert.equal(h.elements.model.textContent, 'iPhone 17 Pro Max');
  assert.equal(h.elements.app.dataset.live, 'live');
  assert.equal(h.elements['live-text'].textContent, '实时');
  h.app.ontoolresult({ structuredContent: preview({ frame_available: false, device: null }) });
  assert.equal(h.elements.app.dataset.live, 'offline');
  assert.equal(h.elements.model.textContent, 'iPhone 17 Pro Max');
  h.app.ontoolresult({ structuredContent: preview({ paused: true }) });
  assert.equal(h.elements.app.dataset.live, 'paused');
  assert.equal(h.elements['live-text'].textContent, '已暂停');
  assert.equal(h.elements['tool-home'].disabled, true);
  assert.equal(h.elements['tool-screenshot'].disabled, true);
  assert.equal(h.elements['tool-refresh'].disabled, false);
  h.app.ontoolresult({ structuredContent: preview({ paused: true, pause_reason: 'device_locked' }) });
  assert.equal(h.elements['live-text'].textContent, '等待解锁');
  assert.match(h.elements['live-text'].title, /刷新/);
  assert.equal(h.elements.image.src, undefined);
  h.app.ontoolresult({ structuredContent: preview({ paused: true, pause_reason: 'authentication' }) });
  assert.equal(h.elements['live-text'].textContent, '已暂停');
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(2), frame_available: true }) });
  assert.equal(h.elements.app.dataset.live, 'live');
  assert.equal(h.elements['tool-home'].disabled, false);
  assert.equal(h.elements['live-text'].title, '');
});

test('toolbar sends exactly one app-only action and reports its outcome', async () => {
  let release;
  const h = await harness({ reply: params => params.name === 'screen_action'
    ? new Promise(resolve => { release = resolve; })
    : Promise.resolve({ structuredContent: preview() }) });
  h.app.ontoolresult({ structuredContent: preview({ device: { id: 'phone-1', model: 'iPhone' } }) });
  h.elements['tool-home'].click();
  h.elements['tool-screenshot'].click();
  await flush();
  const actions = h.calls.filter(call => call.name === 'screen_action');
  assert.equal(JSON.stringify(actions), '[{"name":"screen_action","arguments":{"action":"home","device_id":"phone-1"}}]');
  assert.equal(h.requestOptions[h.calls.indexOf(actions[0])].timeout, 240000);
  assert.equal(h.elements['tool-home'].dataset.busy, 'true');
  assert.ok(['tool-refresh', 'tool-home', 'tool-screenshot'].every(id => h.elements[id].disabled));
  release({ structuredContent: { ok: true, action: 'home' } });
  await flush();
  assert.equal(h.elements.toast.textContent, '已回到主屏幕');
  assert.equal(h.elements.toast.hidden, false);
  assert.equal(h.elements.toast.dataset.tone, 'ok');
  assert.equal(h.elements['tool-home'].dataset.busy, undefined);
  assert.ok(['tool-refresh', 'tool-home', 'tool-screenshot'].every(id => !h.elements[id].disabled));
});

test('toolbar failures name the reason without changing the preview', async () => {
  const replies = [
    { isError: true, structuredContent: { error: { code: 'device_busy' } } },
    { isError: true, structuredContent: { error: { code: 'something_new' } } },
    { structuredContent: { ok: true, action: 'screenshot', copied: true } },
  ];
  const h = await harness({ reply: params => params.name === 'screen_action'
    ? (replies.length ? Promise.resolve(replies.shift()) : Promise.reject(new Error('lost')))
    : Promise.resolve({ structuredContent: preview() }) });
  h.app.ontoolresult({ structuredContent: preview({ frame: frame(4), frame_available: true, device: { id: 'phone-1', model: 'iPhone' } }) });
  for (const [expected, tone] of [['手机正在执行操作，请稍后再试', 'error'], ['操作未完成，请重试', 'error'],
    ['截图已复制到剪贴板', 'ok'], ['操作未完成，请重试', 'error']]) {
    h.elements['tool-screenshot'].click();
    await flush();
    assert.equal(h.elements.toast.textContent, expected);
    assert.equal(h.elements.toast.dataset.tone, tone);
  }
  assert.equal(h.elements.app.dataset.frameSeq, '4');
  assert.equal(h.elements.device.hidden, false);
});

test('refresh adopts the new stream and asks for a frame at once', async () => {
  const h = await harness({ reply: params => Promise.resolve(params.name === 'screen_action'
    ? { structuredContent: { ok: true, action: 'refresh', service_ready: true, ...preview({ stream_id: 'next', frame_available: false }) } }
    : { structuredContent: preview({ stream_id: 'first' }) }) });
  h.app.ontoolresult({ structuredContent: preview({ stream_id: 'first', frame: frame(9), frame_available: true }) });
  assert.equal(h.elements.app.dataset.frameSeq, '9');
  h.elements['tool-refresh'].click();
  await flush();
  assert.equal(h.elements.toast.textContent, '已刷新连接');
  assert.equal([...h.timers.values()].some(timer => timer.delay === 0), true);
  await h.tick();
  const polls = h.calls.filter(call => call.name === 'screen_frame');
  assert.equal(polls.at(-1).arguments.after_seq, 0);
  // The last pixels stay until the new stream delivers its first frame.
  assert.equal(h.elements.device.hidden, false);
});

test('refresh reports a real disconnected service instead of a success toast', async () => {
  const h = await harness({ reply: () => Promise.resolve({ structuredContent: { ok: true, service_ready: false, ...preview({ frame_available: false }) } }) });
  h.elements['tool-refresh'].click();
  await flush();
  assert.match(h.elements.toast.textContent, /未连接到手机/);
  assert.equal(h.elements.toast.dataset.tone, 'error');
  assert.equal(h.elements['empty-state-text'].textContent, '未连接');
  assert.equal(h.elements.device.hidden, true);
});

test('a poll from before user reconnect cannot put the recovered preview back in pause', async () => {
  let release;
  const h = await harness({ reply: params => params.name === 'screen_frame'
    ? new Promise(resolve => { release = resolve; })
    : Promise.resolve({ structuredContent: { ok: true, service_ready: true, ...preview({ stream_id: 'reconnected', frame_available: false }) } }) });
  h.app.ontoolresult({ structuredContent: preview({ paused: true }) });
  await h.tick();
  h.elements['tool-refresh'].click();
  await flush();
  release({ structuredContent: preview({ paused: true, pause_reason: 'unknown' }) });
  await flush();
  assert.equal(h.elements.app.dataset.live, 'offline');
  assert.equal(h.elements['empty-state-text'].textContent, '未连接');
  assert.equal(h.calls.filter(call => call.name === 'screen_action').length, 1);
});

test('host theme is applied and followed, and teardown releases the toolbar', async () => {
  const h = await harness({ context: { displayMode: 'fullscreen', availableDisplayModes: ['fullscreen'], theme: 'dark' } });
  assert.equal(h.document.documentElement.dataset.theme, 'dark');
  h.app.onhostcontextchanged({ theme: 'light' });
  assert.equal(h.document.documentElement.dataset.theme, 'light');
  h.app.onhostcontextchanged({ theme: 'sepia' });
  assert.equal(h.document.documentElement.dataset.theme, 'light');
  h.elements['tool-home'].click();
  await flush();
  await h.app.onteardown();
  assert.equal(h.elements.toast.hidden, true);
  assert.equal(h.elements['tool-home'].handlers.size, 0);
  const before = h.calls.length;
  h.elements['tool-home'].click();
  await flush();
  assert.equal(h.calls.length, before);
});

test('binds frame polling and toolbar actions to the selected StupidMirror device', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ device: { id: 'phone-a', model: 'My phone' },
    devices: [{ device_id: 'phone-a', name: 'My phone' }], frame: frame(1) }) });
  await h.tick();
  assert.equal(h.calls[0].arguments.device_id, 'phone-a');
  h.elements['tool-home'].click(); await flush();
  const action = h.calls.find(c => c.name === 'screen_action');
  assert.equal(action.arguments.device_id, 'phone-a');
  assert.equal(action.arguments.action, 'home');
});

test('device picker starts embedded preview and clears previous phone pixels', async () => {
  const h = await harness({ reply: async ({ name }) => name === 'show_screen'
    ? { structuredContent: preview({ device: { id: 'phone-b', model: 'Second phone' } }) }
    : { structuredContent: preview() } });
  h.app.ontoolresult({ structuredContent: preview({ device: { id: 'phone-a', model: 'First phone' }, frame: frame(12) }) });
  h.app.ontoolresult({ structuredContent: preview({ devices: [{ device_id: 'phone-b', name: 'Second phone', connection_state: 'connected' }] }) });
  h.elements['device-picker'].click();
  assert.equal(h.elements['device-menu'].hidden, false);
  h.elements['device-menu'].children[0].click(); await flush();
  assert.equal(h.elements['device-menu'].hidden, true);
  assert.equal(h.elements.image.src, undefined);
  assert.equal(h.calls[0].name, 'show_screen');
  assert.equal(h.calls[0].arguments.device_id, 'phone-b');
  assert.equal(h.calls.some(c => c.name === 'start_mirror'), false);
});

test('pause and resume toolbar uses the selected device and removes paused pixels', async () => {
  const h = await harness({ reply: async ({ arguments: args }) => ({ structuredContent: preview({
    device: { id: 'phone-a', model: 'Phone' }, paused: args.action === 'pause',
    frame: args.action === 'resume' ? frame(2) : null,
  }) }) });
  h.app.ontoolresult({ structuredContent: preview({ device: { id: 'phone-a', model: 'Phone' }, frame: frame(1) }) });
  h.elements['tool-pause'].click(); await flush();
  assert.equal(h.calls[0].arguments.action, 'pause');
  assert.equal(h.elements.image.src, undefined);
  h.elements['tool-pause'].click(); await flush();
  assert.equal(h.calls[1].arguments.action, 'resume');
  assert.equal(h.calls[1].arguments.device_id, 'phone-a');
  assert.match(h.elements.image.src, /^data:image\/png/);
});

test('shows wireless startup progress and backend failure details', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ frame_available: false, busy: true, message: '正在连接手机，画面就绪后会自动显示。' }) });
  assert.equal(h.elements.app.dataset.live, 'connecting');
  assert.equal(h.elements['empty-state-text'].textContent, '正在连接手机，画面就绪后会自动显示。');
  h.app.ontoolresult({ structuredContent: preview({ frame_available: false, message: '请在 iPhone 上信任此电脑。' }) });
  assert.equal(h.elements.app.dataset.live, 'offline');
  assert.equal(h.elements['empty-state-text'].textContent, '请在 iPhone 上信任此电脑。');
});


test('iPhone screen corners scale with the real image while no extra bezel changes its ratio', async () => {
  const h = await harness();
  h.app.ontoolresult({ structuredContent: preview({ device: { id: 'air', model: 'iPhone Air', platform: 'ios' }, frame: { ...frame(1), width: 506, height: 1100 } }) });
  const width = parseFloat(h.elements.device.style.width);
  const height = parseFloat(h.elements.device.style.height);
  assert.ok(Math.abs(width / height - 506 / 1100) < 1e-10);
  assert.ok(Math.abs(parseFloat(h.elements.device.style['--screen-radius']) - width * .14) < 1e-10);
});


const pointerEvent = (x, y, id=1) => ({clientX:x,clientY:y,pointerId:id,button:0,preventDefault(){}});
const pointerDispatch = (h, name, x, y) => h.elements.screen.handlers.get(name)(pointerEvent(x,y));
const readyPreview = () => preview({device:{id:'phone-a',model:'iPhone Air',platform:'ios'},frame:frame(1),frame_available:true});

test('viewing the screen does not send taps and pending control setup cannot queue a stale tap', async () => {
  let connect;
  const h = await harness({reply: params => params.arguments?.action === 'connect'
    ? new Promise(resolve=>{connect=resolve;}) : Promise.resolve({structuredContent:preview()})});
  h.app.ontoolresult({structuredContent:readyPreview()});
  pointerDispatch(h,'pointerdown',200,450);pointerDispatch(h,'pointerup',200,450);
  assert.equal(h.calls.length,0);
  h.elements['control-button'].click(); await flush();
  pointerDispatch(h,'pointerdown',200,450);pointerDispatch(h,'pointerup',200,450);
  assert.equal(h.calls.length,1);
  connect({structuredContent:{ok:true}});await flush();
  assert.equal(h.calls.length,1);
  pointerDispatch(h,'pointerdown',200,450);pointerDispatch(h,'pointerup',200,450);await flush();
  assert.equal(h.calls.length,2);
  assert.equal(JSON.stringify(h.calls[1]),JSON.stringify({name:'screen_action',arguments:{action:'tap',device_id:'phone-a',x:.25,y:.5}}));
});

test('manual swipes normalize against the picture and clamp the release point', async () => {
  const h = await harness();h.app.ontoolresult({structuredContent:readyPreview()});
  h.elements['control-button'].click();await flush();
  pointerDispatch(h,'pointerdown',300,650);pointerDispatch(h,'pointerup',800,-50);await flush();
  const action=h.calls.at(-1).arguments;
  assert.equal(action.action,'swipe');assert.equal(action.x,.5);assert.equal(action.y,.75);
  assert.equal(action.end_x,1);assert.equal(action.end_y,0);assert.equal(action.duration_ms,120);
  const before=h.calls.length;
  pointerDispatch(h,'pointerdown',300,450);h.elements.screen.handlers.get('pointercancel')();pointerDispatch(h,'pointerup',310,440);
  assert.equal(h.calls.length,before);
});

test('annotation freezes one frame and sends only the marked screenshot and user note without phone actions', async () => {
  const h=await harness();h.app.ontoolresult({structuredContent:readyPreview()});
  h.elements['annotate-button'].click();
  const frozen=h.elements.image.src;
  pointerDispatch(h,'pointerdown',200,250);pointerDispatch(h,'pointermove',400,650);pointerDispatch(h,'pointerup',400,650);
  h.elements['annotation-note'].value='检查这个区域，不要点击。';
  h.app.ontoolresult({structuredContent:preview({device:{id:'phone-b',model:'Different phone'},frame:frame(99),frame_available:true})});
  assert.equal(h.elements.image.src,frozen);assert.equal(h.calls.length,0);
  assert.equal(h.elements['annotation-count'].textContent,'已标注 1 处');
  h.elements['annotation-send'].click();await flush();
  assert.equal(h.sentMessages.length,1);
  const content=h.sentMessages[0].content;
  assert.equal(content[1].type,'image');assert.equal(content[1].mimeType,'image/png');
  assert.equal(content[0].text,'检查这个区域，不要点击。');
  assert.equal(content.length,2);
  assert.deepEqual(h.drawnRegions[0],[225,450,450,900]);
  assert.equal(h.calls.length,0);
});

test('a rejected annotation send preserves the frozen frame and never retries automatically', async () => {
  const h=await harness({messageReply:async()=>({isError:true})});h.app.ontoolresult({structuredContent:readyPreview()});
  h.elements['annotate-button'].click();
  pointerDispatch(h,'pointerdown',200,250);pointerDispatch(h,'pointerup',400,650);
  const frozen=h.elements.image.src;
  h.elements['annotation-send'].click();await flush();
  assert.equal(h.elements['annotation-editor'].hidden,false);assert.equal(h.elements.image.src,frozen);
  assert.match(h.elements['annotation-hint'].textContent,/已保留/);
  await h.tick();await flush();
  assert.equal(h.sentMessages.length,1);
});

test('a display rotation between pointer down and up does not send stale coordinates', async () => {
  const h=await harness();h.app.ontoolresult({structuredContent:readyPreview()});
  h.elements['control-button'].click();await flush();
  pointerDispatch(h,'pointerdown',300,450);
  h.app.ontoolresult({structuredContent:preview({device:{id:'phone-a',model:'iPhone Air',platform:'ios'},frame:{...frame(2),width:1800,height:900},frame_available:true})});
  pointerDispatch(h,'pointerup',300,450);await flush();
  assert.equal(h.calls.filter(c=>c.arguments?.action==='tap'||c.arguments?.action==='swipe').length,0);
  assert.match(h.elements.toast.textContent,/画面已变化/);
});
test('failed frame requests stop after three attempts and the visible retry reconnects with a short timeout',async()=>{
  let fail=true;
  const h=await harness({reply:async params=>{
    if(params.name==='screen_action'){fail=false;return {structuredContent:preview({frame_available:true})};}
    if(fail)throw new Error('App server request queue is full');
    return {structuredContent:preview({frame:frame(1),frame_available:true})};
  }});
  for(let i=0;i<3;i++)await h.tick();
  assert.equal(h.calls.length,3);assert.equal(h.timers.size,0);
  assert.equal(h.elements['empty-retry'].hidden,false);
  assert.equal(h.elements['empty-retry'].disabled,false);
  assert.match(h.elements['empty-state-text'].textContent,/queue is full/);
  h.elements['empty-retry'].click();await flush();
  const action=h.calls.findIndex(c=>c.name==='screen_action');
  assert.equal(h.requestOptions[action].timeout,10000);
  assert.equal(h.elements['empty-retry'].disabled,false);
  await h.tick();
  assert.equal(h.elements.image.hidden,false);assert.equal(h.elements.app.dataset.live,'live');
});
test('manual reconnect aborts the old poll and does not strand polling behind it',async()=>{
  let first=true;let aborted=false;
  const h=await harness({reply:(params,options)=>{
    if(params.name==='screen_frame'&&first){first=false;return new Promise((_,reject)=>options.signal.addEventListener('abort',()=>{aborted=true;reject(new Error('Cancelled'));}));}
    return Promise.resolve({structuredContent:preview({frame:frame(1),frame_available:true})});
  }});
  await h.tick();assert.equal(h.calls.length,1);
  h.elements['tool-refresh'].click();await flush();assert.equal(aborted,true);
  assert.equal(h.elements['tool-refresh'].disabled,false);
  await h.tick();assert.equal(h.calls.filter(c=>c.name==='screen_frame').length,2);
  assert.equal(h.elements.image.hidden,false);
});

test('a second annotation has fresh regions and can be sent after the first succeeds',async()=>{
  const h=await harness();h.app.ontoolresult({structuredContent:readyPreview()});
  for(const [index,label] of ['第一处','第二处'].entries()){
    h.elements['annotate-button'].click();
    pointerDispatch(h,'pointerdown',150+index*100,150);
    pointerDispatch(h,'pointerup',200+index*100,250);
    h.elements['annotation-note'].value=label;
    h.elements['annotation-send'].click();await flush();
    assert.equal(h.elements['annotation-editor'].hidden,true);
    assert.equal(h.elements['annotate-button'].disabled,false);
  }
  assert.equal(h.sentMessages.length,2);
  assert.match(h.sentMessages[0].content[0].text,/第一处/);
  assert.match(h.sentMessages[1].content[0].text,/第二处/);
  assert.doesNotMatch(h.sentMessages[1].content[0].text,/第一处/);
  assert.deepEqual(h.drawnRegions[2],[337.5,225,112.5,225]);
});

test('a host composer rejection after the first send is shown as not sent and preserves the second annotation',async()=>{
  let attempts=0;
  const h=await harness({messageReply:async()=>{
    if(++attempts===1)return {};
    throw Object.assign(new Error('MCP error -32601: MCP app messages require an available composer'),{code:-32601});
  }});
  h.app.ontoolresult({structuredContent:readyPreview()});
  for(const label of ['第一处','第二处']){
    h.elements['annotate-button'].click();
    pointerDispatch(h,'pointerdown',200,250);pointerDispatch(h,'pointerup',400,650);
    h.elements['annotation-note'].value=label;
    h.elements['annotation-send'].click();await flush();
  }
  assert.equal(h.elements['annotation-editor'].hidden,false);
  assert.equal(h.elements['annotation-note'].value,'第二处');
  assert.equal(h.elements['annotation-count'].textContent,'已标注 1 处');
  assert.match(h.elements['annotation-hint'].textContent,/标注未发送.*聊天发送入口不可用/);
  assert.doesNotMatch(h.elements['annotation-hint'].textContent,/未确认/);
  await h.tick();await flush();assert.equal(h.sentMessages.length,2);
});

test('a lost annotation acknowledgement remains uncertain and is never automatically replayed',async()=>{
  const h=await harness({messageReply:async()=>{throw new Error('MCP error -32001: Request timed out');}});
  h.app.ontoolresult({structuredContent:readyPreview()});h.elements['annotate-button'].click();
  pointerDispatch(h,'pointerdown',200,250);pointerDispatch(h,'pointerup',400,650);
  h.elements['annotation-send'].click();await flush();
  assert.match(h.elements['annotation-hint'].textContent,/发送未确认/);
  assert.match(h.elements['annotation-hint'].textContent,/Request timed out/);
  await h.tick();await flush();assert.equal(h.sentMessages.length,1);
});

const annotationRects = h => h.elements['annotation-overlay'].children
  .filter(node => node.class?.startsWith('annotation-region'))
  .map(node => ['x','y','width','height'].map(key => Number(node[key])));
const drawAnnotation = (h, from = [200,250], to = [400,650]) => {
  pointerDispatch(h,'pointerdown',...from); pointerDispatch(h,'pointermove',...to); pointerDispatch(h,'pointerup',...to);
};
const beginAnnotation = async (options) => {
  const h = await harness(options);
  h.app.ontoolresult({ structuredContent: readyPreview() }); h.elements['annotate-button'].click();
  return h;
};

test('dragging inside an existing region moves it instead of drawing another and undo restores geometry',async()=>{
  const h = await beginAnnotation(); drawAnnotation(h);
  pointerDispatch(h,'pointermove',300,450); assert.equal(h.elements.screen.style.cursor,'grab');
  pointerDispatch(h,'pointerdown',300,450); assert.equal(h.elements.screen.style.cursor,'grabbing');
  pointerDispatch(h,'pointermove',340,530);
  assert.equal(h.elements['annotation-send'].disabled,true);
  pointerDispatch(h,'pointerup',340,530);
  assert.deepEqual(annotationRects(h),[[315,630,450,900]]);
  assert.equal(h.elements['annotation-count'].textContent,'已标注 1 处');
  h.elements['annotation-undo'].click(); assert.deepEqual(annotationRects(h),[[225,450,450,900]]);
  h.elements['annotation-undo'].click(); assert.equal(annotationRects(h).length,0);
  assert.equal(h.calls.length,0);
});

test('all eight resize handles change only their intended edges and export the edited rectangle',async()=>{
  const cases = [
    ['nw',[200,250],[160,170],[135,270,540,1080]],
    ['n',[300,250],[300,170],[225,270,450,1080]],
    ['ne',[400,250],[440,170],[225,270,540,1080]],
    ['e',[400,450],[440,450],[225,450,540,900]],
    ['se',[400,650],[440,730],[225,450,540,1080]],
    ['s',[300,650],[300,730],[225,450,450,1080]],
    ['sw',[200,650],[160,730],[135,450,540,1080]],
    ['w',[200,450],[160,450],[135,450,540,900]],
  ];
  for (const [handle,from,to,expected] of cases) {
    const h = await beginAnnotation(); drawAnnotation(h);
    assert.equal(h.elements['annotation-overlay'].children.filter(node=>node.class==='annotation-handle').length,8);
    pointerDispatch(h,'pointermove',...from); assert.equal(h.elements.screen.style.cursor,`${handle}-resize`);
    drawAnnotation(h,from,to);
    assert.deepEqual(annotationRects(h).map(box=>box.map(Math.round)),[expected],handle);
    h.elements['annotation-send'].click(); await flush();
    assert.deepEqual(h.drawnRegions[0].map(Math.round),expected,handle);
    assert.equal(h.sentMessages[0].content[0].text,'请查看截图中的标注区域。');
    assert.equal(h.calls.length,0);
  }
});

test('moving and resizing stay inside the image and resizing cannot invert a rectangle',async()=>{
  const h = await beginAnnotation(); drawAnnotation(h);
  drawAnnotation(h,[300,450],[900,-100]);
  assert.deepEqual(annotationRects(h),[[450,0,450,900]]);
  drawAnnotation(h,[500,850],[900,1200]);
  // A drag starting at the image boundary has zero width, so it creates no region.
  assert.equal(annotationRects(h).length,1);
  drawAnnotation(h,[500,450],[900,1200]);
  assert.deepEqual(annotationRects(h),[[450,0,450,1800]]);
  drawAnnotation(h,[300,50],[900,1200]);
  const [x,y,width,height] = annotationRects(h)[0];
  assert.ok(width >= 18 - 1e-8 && height >= 18 - 1e-8);
  assert.ok(x >= 0 && y >= 0 && x+width <= 900 && y+height <= 1800);
});

test('pointer cancellation and lost capture restore the rectangle without adding an undo step',async()=>{
  for (const event of ['pointercancel','lostpointercapture']) {
    const h = await beginAnnotation(); drawAnnotation(h);
    pointerDispatch(h,'pointerdown',300,450); pointerDispatch(h,'pointermove',340,530);
    pointerDispatch(h,event,340,530); pointerDispatch(h,'pointerup',340,530);
    assert.deepEqual(annotationRects(h),[[225,450,450,900]]);
    assert.equal(h.elements.screen.capturedPointer,undefined);
    h.elements['annotation-undo'].click(); assert.equal(annotationRects(h).length,0);
  }
});

test('click selects without creating an undo step and deleting that selection is undoable',async()=>{
  const h = await beginAnnotation(); drawAnnotation(h,[140,130],[220,290]); drawAnnotation(h,[340,530],[420,690]);
  drawAnnotation(h,[180,210],[180,210]);
  h.elements['annotation-delete'].click();
  assert.deepEqual(annotationRects(h).map(box=>box.map(Math.round)),[[540,1080,180,360]]);
  h.elements['annotation-undo'].click(); assert.equal(annotationRects(h).length,2);
  h.elements['annotation-undo'].click(); assert.deepEqual(annotationRects(h).map(box=>box.map(Math.round)),[[90,180,180,360]]);
});

test('the eight-region limit still allows moving, resizing and deleting existing regions',async()=>{
  const h = await beginAnnotation();
  for(let i=0;i<8;i++) drawAnnotation(h,[130+(i%2)*180,90+Math.floor(i/2)*160],[210+(i%2)*180,170+Math.floor(i/2)*160]);
  drawAnnotation(h,[440,750],[480,810]);
  assert.equal(annotationRects(h).length,8);
  drawAnnotation(h,[170,130],[190,150]);
  assert.deepEqual(annotationRects(h)[0].map(Math.round),[113,135,180,180]);
  drawAnnotation(h,[230,190],[250,210]);
  assert.deepEqual(annotationRects(h)[0].map(Math.round),[113,135,225,225]);
  h.elements['annotation-delete'].click(); assert.equal(annotationRects(h).length,7);
});

test('hosts using image context receive the screenshot without redundant region metadata',async()=>{
  const h = await beginAnnotation({messageImage:false}); drawAnnotation(h);
  h.elements['annotation-send'].click(); await flush();
  assert.equal(h.contextUpdates.length,1);
  assert.deepEqual(Object.keys(h.contextUpdates[0]),['content']);
  assert.equal(h.contextUpdates[0].content[0].type,'image');
  assert.equal(h.sentMessages[0].content.length,1);
  assert.equal(h.sentMessages[0].content[0].text,'请查看截图中的标注区域。');
});

test('Command Enter sends once while Enter, IME composition, key repeat and empty selection do not',async()=>{
  let finish;
  const h = await beginAnnotation({messageReply:()=>new Promise(resolve=>{finish=resolve;})});
  const key = (fields={}) => h.elements['annotation-note'].handlers.get('keydown')({key:'Enter',preventDefault(){},...fields});
  key({metaKey:true}); await flush(); assert.equal(h.sentMessages.length,0);
  drawAnnotation(h); h.elements['annotation-note'].value='请调整这里的间距';
  key(); key({metaKey:true,isComposing:true}); key({metaKey:true,repeat:true});
  await flush(); assert.equal(h.sentMessages.length,0);
  key({metaKey:true}); key({metaKey:true}); await flush();
  assert.equal(h.sentMessages.length,1);
  assert.equal(h.sentMessages[0].content[0].text,'请调整这里的间距');
  assert.equal(h.elements['annotation-note'].disabled,true);
  finish({}); await flush(); assert.equal(h.elements['annotation-editor'].hidden,true);
});
