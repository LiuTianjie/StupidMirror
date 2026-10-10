/*!
MIT License

Copyright (c) 2026 ZHONG XIN

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
import { App } from '@modelcontextprotocol/ext-apps';
import { createVideo } from './video';
import { createAnnotations, type Point as NormalizedPoint } from './annotations';

type Size = { width: number; height: number };
type Point = { x: number; y: number };
type Frame = Size & { seq: number; data: string; mimeType: string };
type Gesture = {
  id: number;
  kind: 'tap' | 'drag';
  at: number;
  point?: Point;
  from?: Point;
  to?: Point;
  duration_ms?: number;
  viewport?: Size;
};
type Preview = {
  server_time: number;
  stream_id?: string;
  frame: Frame | null;
  frame_available?: boolean;
  viewport: Size | null;
  busy: boolean;
  paused: boolean;
  pause_reason?: 'device_locked' | 'authentication' | 'unknown' | null;
  events: Gesture[];
  device?: { id?: string; model?: string; platform?: string } | null;
  devices?: { device_id: string; name: string; platform?: string; connection_state: string }[];
  message?: string;
};
type LiveState = 'connecting' | 'live' | 'paused' | 'offline';
type EmptyState = 'connecting' | 'offline' | 'locked' | 'authentication' | 'paused' | 'unavailable';
type ToolName = 'refresh' | 'home' | 'screenshot' | 'pause';
type CursorEffect = { node: HTMLElement; animation?: Animation; timer?: ReturnType<typeof setTimeout> };

const root = document.getElementById('app')!;
const device = document.getElementById('device')!;
const screen = document.getElementById('screen')!;
const image = document.getElementById('image')! as HTMLImageElement;
const video = document.getElementById('video')! as HTMLVideoElement;
const controlButton = document.getElementById('control-button')! as HTMLButtonElement;
const annotateButton = document.getElementById('annotate-button')! as HTMLButtonElement;
const controlLabel = document.getElementById('control-label')!;
let controlMode = false;
let pointer: { id:number; start:NormalizedPoint; x:number; y:number; started:number; deviceId?:string; width?:number; height?:number } | undefined;
const emptyState = document.getElementById('empty-state')!;
const emptyText = document.getElementById('empty-state-text')!;
const emptyHint = document.getElementById('empty-hint')!;
const retryButton = document.getElementById('empty-retry')! as HTMLButtonElement;
const cursor = document.getElementById('cursor')!;
const stage = document.getElementById('stage')!;
const model = document.getElementById('model')!;
const picker = document.getElementById('device-picker')! as HTMLButtonElement;
const deviceMenu = document.getElementById('device-menu')!;
const deviceSwitcher = document.getElementById('device-switcher')!;
const pauseLabel = document.getElementById('pause-label')!;
let deviceOptions: HTMLButtonElement[] = [];
let platform: string | undefined;
let selectedDeviceId: string | undefined;
let deviceListKey = '';
let previewPaused = false;
const liveText = document.getElementById('live-text')!;
const toast = document.getElementById('toast')!;
const tools: Record<ToolName, HTMLButtonElement> = {
  refresh: document.getElementById('tool-refresh') as HTMLButtonElement,
  home: document.getElementById('tool-home') as HTMLButtonElement,
  screenshot: document.getElementById('tool-screenshot') as HTMLButtonElement,
  pause: document.getElementById('tool-pause') as HTMLButtonElement,
};
const app = new App(
  { name: 'StupidMirror', version: '0.2.3' },
  { availableDisplayModes: ['fullscreen'] },
  { autoResize: false },
);
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
let ready = false;
let disposed = false;
let inFlight = false;
let frameSeq = 0;
let frameGeneration = 0;
let streamId: string | undefined;
let eventId = 0;
let dimensions: Size | undefined;
let viewport: Size | undefined;
let timer: ReturnType<typeof setTimeout> | undefined;
let failures = 0;
let pollBlocked = false;
let pollRequest: AbortController | undefined;
const cursorEffects = new Set<CursorEffect>();
let requestedFullscreen = false;
let connecting: Promise<void> | undefined;
let suspended = false;
let lastGoodFrame: { source: string; size: Size } | undefined;
let acting = false;
let toastTimer: ReturnType<typeof setTimeout> | undefined;
const FRAME_INTERVAL = 250;
const VIDEO_STATE_INTERVAL = 1000;
const REQUEST_TIMEOUT = 3000;
// A screenshot or Home may queue behind the phone operation already running.
const ACTION_TIMEOUT = 240000;
const LIVE_TEXT: Record<LiveState, string> = { connecting: '连接中', live: '实时', paused: '已暂停', offline: '未连接' };
const EMPTY_TEXT: Record<EmptyState, string> = {
  connecting: '正在连接', offline: '未连接', locked: '等待解锁',
  authentication: '请完成认证', paused: '预览已暂停', unavailable: '画面暂不可用',
};
const DONE: Record<ToolName, string> = { refresh: '已刷新连接', home: '已回到主屏幕', screenshot: '截图已复制到剪贴板', pause: '预览状态已更新' };
const FAILED: Record<string, string> = {
  device_busy: '手机正在执行操作，请稍后再试',
  preview_paused: '认证接管期间已暂停',
  clipboard_unavailable: '截图未能写入剪贴板',
  pua_unreachable: '未连接到手机',
};

const validSize = (value: unknown): value is Size => {
  const size = value as Size | undefined;
  return !!size && Number.isFinite(size.width) && Number.isFinite(size.height)
    && size.width > 0 && size.height > 0;
};
const validPoint = (value: unknown): value is Point => {
  const point = value as Point | undefined;
  return !!point && Number.isFinite(point.x) && Number.isFinite(point.y);
};

const liveVideo = createVideo(app, video, {
  ready: size => {
    if (annotations.active || previewPaused || disposed) return;
    if (!dimensions || dimensions.width !== size.width || dimensions.height !== size.height) { dimensions = size; fitFrame(); }
    image.hidden = true; video.hidden = false; device.hidden = screen.hidden = false; emptyState.hidden = true;
    root.dataset.transport = 'webrtc'; setLive('live'); syncTools();
  },
  stopped: (reason, retrying) => {
    root.dataset.transport = 'webrtc-error';
    if (!annotations.active) {
      clearFrame();
      pollBlocked = !retrying;
      setLive('offline'); showConnectionError(reason, retrying);
      schedule(1000);
    }
  },
  fps: value => { root.dataset.videoFps = String(value); if (dimensions) liveText.title = `${dimensions.width} × ${dimensions.height} · ${value} fps`; },
});
const annotations = createAnnotations(app, {
  freeze: source => { frameGeneration++; controlMode = false; image.src = source; image.hidden = false; video.hidden = true; root.dataset.annotation = 'true'; },
  resume: () => {
    root.dataset.annotation = 'false';
    if (liveVideo.active) { image.hidden = true; video.hidden = false; }
    else { frameSeq = 0; schedule(0); }
  },
  changed: () => syncTools(), notify,
});

function syncTools() {
  const paused = root.dataset.live === 'paused';
  tools.refresh.disabled = acting || annotations.active;
  retryButton.disabled = tools.refresh.disabled;
  picker.disabled = acting || annotations.active;
  tools.pause.disabled = acting || annotations.active || !selectedDeviceId;
  tools.pause.title = tools.pause.ariaLabel = previewPaused ? '继续预览' : '暂停预览';
  tools.pause.dataset.paused = String(previewPaused);
  pauseLabel.textContent = previewPaused ? '继续' : '暂停';
  // While the user authenticates on the phone nothing is captured or sent from here.
  tools.home.disabled = tools.screenshot.disabled = acting || annotations.active || paused || !selectedDeviceId;
  controlButton.disabled = acting || annotations.active || paused || !selectedDeviceId || !dimensions || root.dataset.live !== 'live';
  annotateButton.disabled = acting || paused || !selectedDeviceId || !dimensions || annotations.busy || (!annotations.active && root.dataset.live !== 'live');
  controlButton.setAttribute('aria-pressed', String(controlMode));
  annotateButton.setAttribute('aria-pressed', String(annotations.active));
  root.dataset.control = String(controlMode);
  if (annotations.active) liveText.textContent = '画面已冻结';
  else if (root.dataset.live === 'live') liveText.textContent = LIVE_TEXT.live;
}

function showEmpty(state: EmptyState) {
  emptyState.dataset.state = state;
  emptyText.textContent = EMPTY_TEXT[state];
  emptyHint.textContent = '保持手机已连接并解锁';
  retryButton.hidden = !['offline', 'unavailable'].includes(state);
}

function showConnectionError(reason: string, retrying = false) {
  if (!image.src && !liveVideo.active) { emptyState.hidden = false; device.hidden = screen.hidden = true; }
  if (previewPaused) {
    showEmpty(emptyState.dataset.state === 'locked' ? 'locked' : 'authentication');
    emptyHint.textContent = reason; retryButton.hidden = false; return;
  }
  showEmpty('unavailable');
  emptyText.textContent = reason;
  emptyHint.textContent = retrying ? '正在自动重新连接…' : '点击重试，重新建立预览连接';
  retryButton.hidden = false;
}

function setLive(state: LiveState) {
  if (!image.src) showEmpty(state === 'paused' ? 'paused' : state === 'offline' ? 'offline' : 'connecting');
  if (root.dataset.live === state) return;
  root.dataset.live = state;
  if (state !== 'live') controlMode = false;
  liveText.textContent = LIVE_TEXT[state];
  liveText.title = '';
  syncTools();
}

function notify(text: string, failed = false) {
  toast.textContent = text;
  toast.dataset.tone = failed ? 'error' : 'ok';
  toast.hidden = false;
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { toastTimer = undefined; toast.hidden = true; }, 1800);
}

function applyTheme(theme: unknown) {
  if (theme === 'light' || theme === 'dark') document.documentElement.dataset.theme = theme;
}

function finishCursor(effect: CursorEffect) {
  if (!cursorEffects.delete(effect)) return;
  effect.animation?.cancel();
  if (effect.timer) clearTimeout(effect.timer);
  effect.node.hidden = true;
  if (effect.node !== cursor) effect.node.remove();
}

function hideCursor() {
  for (const effect of cursorEffects) finishCursor(effect);
}

function clearFrame(resetOperating = true) {
  const hadDimensions = !!dimensions;
  liveVideo.close(); controlMode = false; pointer = undefined;
  frameGeneration++;
  hideCursor();
  image.removeAttribute('src');
  image.hidden = true;
  emptyState.hidden = false;
  device.hidden = screen.hidden = true;
  dimensions = undefined;
  lastGoodFrame = undefined;
  frameSeq = 0;
  root.dataset.frameSeq = '0';
  root.dataset.busy = 'false';
  if (resetOperating) root.dataset.operating = 'false';
  if (!disposed && hadDimensions) fitFrame();
}

function retainFrame() {
  hideCursor();
  root.dataset.busy = 'false';
}

const visible = () => !disposed && !suspended && !document.hidden;

function fitFrame() {
  const size = dimensions ?? viewport;
  if (!size) return;
  const width = stage.clientWidth;
  const height = stage.clientHeight;
  const scale = Math.min(width / size.width, height / size.height);
  const displayWidth = Math.max(0, size.width * scale);
  const displayHeight = Math.max(0, size.height * scale);
  device.style.width = `${displayWidth}px`;
  device.style.height = `${displayHeight}px`;
  // Match StupidMirror's continuous phone-screen clip. No added chassis,
  // side buttons or camera cutouts: these belong to the captured device.
  const cornerRatio = platform === 'ios' ? .14 : platform === 'android' ? .06 : .035;
  device.style.setProperty('--screen-radius', `${Math.min(displayWidth, displayHeight) * cornerRatio}px`);
  device.dataset.orientation = size.width > size.height ? 'landscape' : 'portrait';
  if (annotations.active) annotations.render();
}

function setDeviceMenu(open: boolean, focus = false) {
  deviceMenu.hidden = !open;
  picker.setAttribute('aria-expanded', String(open));
  if (open && focus) (deviceOptions.find(option => option.getAttribute('aria-selected') === 'true') ?? deviceOptions[0])?.focus();
}

function syncDeviceSelection() {
  for (const option of deviceOptions) option.setAttribute('aria-selected', String(option.dataset.deviceId === selectedDeviceId));
}

function renderDevices(devices: NonNullable<Preview['devices']>) {
  deviceOptions = devices.map(d => {
    const option = document.createElement('button');
    option.type = 'button'; option.dataset.deviceId = d.device_id;
    option.setAttribute('role', 'option');
    const icon = document.createElement('span'); icon.className = 'device-option-icon'; icon.setAttribute('aria-hidden', 'true');
    const copy = document.createElement('span'); copy.className = 'device-option-copy';
    const name = document.createElement('span'); name.className = 'device-option-name'; name.textContent = d.name;
    const detail = document.createElement('span'); detail.className = 'device-option-detail';
    detail.textContent = `${d.platform === 'android' ? 'Android' : 'iPhone'} · ${d.connection_state === 'connected' ? '已连接' : '等待连接'}`;
    copy.appendChild(name); copy.appendChild(detail);
    const check = document.createElement('span'); check.className = 'device-option-check'; check.setAttribute('aria-hidden', 'true');
    option.appendChild(icon); option.appendChild(copy); option.appendChild(check);
    option.addEventListener('click', () => {
      setDeviceMenu(false); picker.focus(); model.textContent = d.name;
      void selectDevice(d.device_id);
    });
    return option;
  });
  deviceMenu.replaceChildren(...deviceOptions);
  syncDeviceSelection();
}

function pickerClick() { setDeviceMenu(deviceMenu.hidden); }
function pickerKeydown(event: KeyboardEvent) {
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); setDeviceMenu(true, true); }
}
function menuKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape') { event.preventDefault(); setDeviceMenu(false); picker.focus(); }
  if (event.key === 'Tab') setDeviceMenu(false);
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    const index = deviceOptions.indexOf(document.activeElement as HTMLButtonElement);
    deviceOptions[(index + (event.key === 'ArrowDown' ? 1 : -1) + deviceOptions.length) % deviceOptions.length]?.focus();
  }
}
function outsidePointer(event: PointerEvent) {
  if (!deviceSwitcher.contains(event.target as Node)) setDeviceMenu(false);
}

function pointStyle(point: Point, size: Size) {
  return {
    left: `${Math.max(0, Math.min(1, point.x / size.width)) * 100}%`,
    top: `${Math.max(0, Math.min(1, point.y / size.height)) * 100}%`,
  };
}

function showGesture(gesture: Gesture) {
  if (screen.hidden || image.hidden) return;
  const size = validSize(gesture.viewport) ? gesture.viewport : viewport;
  if (!size) return;
  if (dimensions && Math.abs((size.width / size.height) / (dimensions.width / dimensions.height) - 1) > .08) return;
  const point = gesture.kind === 'tap' ? gesture.point : gesture.from;
  if (!validPoint(point)) return;
  if (gesture.kind === 'drag' && !validPoint(gesture.to)) return;
  // Keep each indication readable even when several real actions arrive together.
  // Overlapping effects have independent lifetimes, so a new tap cannot erase one.
  const marker = cursor.hidden ? cursor : cursor.cloneNode(false) as HTMLElement;
  if (marker !== cursor) {
    marker.removeAttribute('id');
    screen.appendChild(marker);
  }
  Object.assign(marker.style, pointStyle(point, size));
  marker.hidden = false;
  const effect: CursorEffect = { node: marker };
  cursorEffects.add(effect);
  const movement = Math.max(600, Math.min(1000, gesture.duration_ms || 650));
  const duration = gesture.kind === 'drag' ? movement + 1000 : 1600;
  if (reducedMotion.matches) {
    if (gesture.kind === 'drag') Object.assign(marker.style, pointStyle(gesture.to!, size));
    effect.timer = setTimeout(() => finishCursor(effect), duration);
    return;
  }
  const delta = gesture.kind === 'drag'
    ? `translate(${(gesture.to!.x - point.x) / size.width * screen.clientWidth}px, ${(gesture.to!.y - point.y) / size.height * screen.clientHeight}px)`
    : '';
  const frames: Keyframe[] = gesture.kind === 'drag'
    ? [
      { transform: 'translate(0, 0) scale(.96)', opacity: 0 },
      { transform: 'translate(0, 0) scale(1)', opacity: 1, offset: 80 / duration },
      { transform: 'translate(0, 0) scale(.92)', opacity: 1, offset: 200 / duration, easing: 'cubic-bezier(.3,0,.2,1)' },
      { transform: `${delta} scale(.92)`, opacity: 1, offset: (movement + 200) / duration },
      { transform: `${delta} scale(1.06)`, opacity: 1, offset: (movement + 380) / duration },
      { transform: `${delta} scale(1)`, opacity: 1, offset: (duration - 350) / duration },
      { transform: `${delta} scale(1)`, opacity: 1, offset: (duration - 200) / duration },
      { transform: `${delta} scale(.98)`, opacity: 0 },
    ]
    : [
      { transform: 'scale(.96)', opacity: 0 },
      { transform: 'scale(1)', opacity: 1, offset: .06 },
      { transform: 'scale(.9)', opacity: 1, offset: .16 },
      { transform: 'scale(1.06)', opacity: 1, offset: .28 },
      { transform: 'scale(1)', opacity: 1, offset: .4 },
      { transform: 'scale(1)', opacity: 1, offset: .875 },
      { transform: 'scale(.98)', opacity: 0 },
    ];
  effect.animation = marker.animate(frames, { duration, easing: 'linear' });
  effect.animation.onfinish = () => finishCursor(effect);
}

function consume(value: unknown) {
  if (annotations.active) return;
  if (disposed || !value || typeof value !== 'object') return;
  const preview = value as Partial<Preview>;
  if (Array.isArray(preview.devices)) {
    const key = JSON.stringify(preview.devices.map(d => [d.device_id, d.name, d.platform, d.connection_state]));
    if (key !== deviceListKey) {
      deviceListKey = key;
      renderDevices(preview.devices);
    }
  }
  if (preview.device?.id && preview.device.id !== selectedDeviceId) {
    clearFrame(); liveVideo.retry(); selectedDeviceId = preview.device.id;
    syncDeviceSelection();
  }
  if (preview.device?.platform && preview.device.platform !== platform) {
    platform = preview.device.platform;
    fitFrame();
  }
  if (typeof preview.paused === 'boolean') {
    previewPaused = preview.paused; syncTools();
  }
  if (typeof preview.stream_id === 'string' && preview.stream_id !== streamId) {
    streamId = preview.stream_id;
    // Sequence numbers restart with the server, but keep the last pixels until
    // its replacement is ready. Authentication pause remains an explicit erase.
    frameSeq = 0;
    eventId = 0;
    root.dataset.operating = 'false';
    retainFrame();
  }
  if (typeof preview.device?.model === 'string' && preview.device.model) model.textContent = preview.device.model;
  if (validSize(preview.viewport) && (viewport?.width !== preview.viewport.width || viewport?.height !== preview.viewport.height)) {
    viewport = preview.viewport;
    if (!dimensions) fitFrame();
  }
  if (preview.paused === true) {
    clearFrame();
    setLive('paused');
    liveText.textContent = preview.pause_reason === 'device_locked' ? '等待解锁' : LIVE_TEXT.paused;
    liveText.title = preview.pause_reason === 'device_locked'
      ? '解锁 iPhone 后继续任务，或点击刷新恢复预览'
      : '预览已暂停；完成手机认证后继续任务或点击刷新恢复画面';
    showEmpty(preview.pause_reason === 'device_locked' ? 'locked'
      : preview.pause_reason === 'authentication' ? 'authentication' : 'paused');
    return;
  }
  if (!preview.paused && selectedDeviceId && preview.frame_available && visible()) void liveVideo.connect(selectedDeviceId);
  if (preview.frame_available === false) {
    retainFrame();
    setLive(preview.busy ? 'connecting' : 'offline');
    if (preview.message) {
      showEmpty(preview.busy ? 'connecting' : 'unavailable');
      emptyText.textContent = preview.message;
    }
  } else if (preview.frame_available === true || preview.frame) {
    if (liveVideo.active || image.src || preview.frame) setLive('live');
    else if (root.dataset.transport !== 'webrtc-error') setLive('connecting');
  }
  const frame = preview.frame;
  if (frame && validSize(frame) && Number.isInteger(frame.seq) && frame.seq > frameSeq
      && !liveVideo.active && typeof frame.data === 'string' && frame.data.length > 0
      && ['image/jpeg', 'image/png', 'image/webp'].includes(frame.mimeType)) {
    frameSeq = frame.seq;
    root.dataset.frameSeq = String(frame.seq);
    if (!dimensions || dimensions.width !== frame.width || dimensions.height !== frame.height) {
      dimensions = { width: frame.width, height: frame.height };
      fitFrame();
    }
    image.src = `data:${frame.mimeType};base64,${frame.data}`;
    image.hidden = false;
    emptyState.hidden = true;
    device.hidden = false;
    screen.hidden = false;
  }
  syncTools();
  if (typeof preview.busy === 'boolean') root.dataset.busy = String(preview.busy);
  // Keep the edge light on between tools and while the model plans its next action.
  if (preview.busy === true) root.dataset.operating = 'true';
  if (Array.isArray(preview.events)) {
    for (const gesture of preview.events) {
      if (!Number.isInteger(gesture.id) || gesture.id <= eventId) continue;
      eventId = gesture.id;
      const age = (preview.server_time || Date.now()) - gesture.at;
      if (Number.isFinite(age) && age >= -1000 && age <= 2500
          && (gesture.kind === 'tap' || gesture.kind === 'drag')) {
        root.dataset.operating = 'true';
        showGesture(gesture);
      }
    }
  }
}

function schedule(delay: number) {
  if (!visible() || timer || pollBlocked) return;
  timer = setTimeout(() => {
    timer = undefined;
    void poll();
  }, delay);
}

async function poll() {
  if (!visible() || inFlight || pollBlocked) return;
  inFlight = true;
  const started = performance.now();
  let nextDelay = FRAME_INTERVAL;
  const controller = new AbortController(); pollRequest = controller;
  try {
    if (!ready) await connect();
    if (!visible()) return;
    const generation = frameGeneration;
    const result = await app.callServerTool({
      name: 'screen_frame',
      arguments: { after_seq: frameSeq, ...(liveVideo.available ? { include_frame: false } : {}), ...(selectedDeviceId ? { device_id: selectedDeviceId } : {}) },
    }, { timeout: REQUEST_TIMEOUT, signal: controller.signal });
    if (!visible() || generation !== frameGeneration) return;
    if (result.isError) throw new Error((result.structuredContent as {error?:{message?:string}})?.error?.message ?? '预览服务不可用');
    consume(result.structuredContent);
    failures = 0;
    const preview = result.structuredContent as Partial<Preview> | undefined;
    nextDelay = liveVideo.active || liveVideo.pending || annotations.active ? VIDEO_STATE_INTERVAL : preview?.paused || preview?.frame_available === false
      ? 1000 : Math.max(0, FRAME_INTERVAL - (performance.now() - started));
  } catch (error) {
    if (controller.signal.aborted) return;
    failures += 1;
    pollBlocked = failures >= 3;
    nextDelay = Math.min(2000, 500 * failures);
    if (!liveVideo.active) {
      retainFrame();
      if (root.dataset.live !== 'paused') {
        setLive('offline');
        showConnectionError(error instanceof Error ? error.message : '预览连接失败', !pollBlocked);
      }
    } else if (pollBlocked) {
      liveText.textContent = '状态连接中断';
      liveText.title = error instanceof Error ? error.message : '点击刷新重新连接';
    }
  } finally {
    if (pollRequest === controller) pollRequest = undefined;
    inFlight = false;
    schedule(nextDelay);
  }
}

async function act(name: ToolName) {
  if (acting || disposed || tools[name].disabled) return;
  if (name === 'refresh') {
    pollRequest?.abort();
    failures = 0; pollBlocked = true;
    liveVideo.retry(); root.dataset.transport = 'connecting';
    frameGeneration++; // Ignore a poll from before this reconnect click.
    if (!image.src) { clearFrame(); if (!previewPaused) setLive('connecting'); showEmpty('connecting'); }
  }
  acting = true;
  tools[name].dataset.busy = 'true';
  syncTools();
  try {
    if (!ready) await connect();
    const result = await app.callServerTool({
      name: 'screen_action',
      arguments: { action: name === 'pause' ? (previewPaused ? 'resume' : 'pause') : name, ...(selectedDeviceId ? { device_id: selectedDeviceId } : {}) },
    }, { timeout: name === 'refresh' ? 10000 : ACTION_TIMEOUT });
    const data = result.structuredContent as (Partial<Preview> & { service_ready?: boolean; error?: { code?: string; message?: string } }) | undefined;
    if (result.isError || data?.error) {
      if (name === 'refresh') { pollBlocked = true; if (!previewPaused) setLive('offline'); showConnectionError(data?.error?.message ?? '预览连接失败'); }
      notify(data?.error?.message ?? FAILED[data?.error?.code ?? ''] ?? '操作未完成，请重试', true);
    } else {
      // A refresh answers with the new stream identity; take the next frame at once.
      if (name === 'refresh') pollBlocked = false;
      consume(data);
      notify(name === 'refresh' && data?.service_ready === false ? '未连接到手机，请确认连接后重试' : DONE[name], name === 'refresh' && data?.service_ready === false);
      if (timer) clearTimeout(timer);
      timer = undefined;
      schedule(0);
    }
  } catch (error) {
    if (name === 'refresh') {
      pollBlocked = true; if (!previewPaused) setLive('offline');
      showConnectionError(error instanceof Error ? error.message : '预览连接失败');
    }
    notify('操作未完成，请重试', true);
  } finally {
    acting = false;
    delete tools[name].dataset.busy;
    syncTools();
  }
}
const retryPreview = () => { void act('refresh'); };
retryButton.addEventListener('click', retryPreview);
picker.addEventListener('click', pickerClick);
picker.addEventListener('keydown', pickerKeydown);
deviceMenu.addEventListener('keydown', menuKeydown);
document.addEventListener('pointerdown', outsidePointer);
async function selectDevice(id: string) {
  if (!id || acting) return;
  pollRequest?.abort(); failures = 0; pollBlocked = false; liveVideo.retry();
  selectedDeviceId = id; viewport = undefined; streamId = undefined; platform = undefined;
  syncDeviceSelection();
  clearFrame(); setLive('connecting');
  acting = true; picker.disabled = true; syncTools();
  try {
    if (!ready) await connect();
    const result = await app.callServerTool({ name: 'show_screen', arguments: { device_id: id } }, { timeout: ACTION_TIMEOUT });
    if (result.isError) throw new Error('Could not start preview');
    consume(result.structuredContent);
  } catch { showEmpty('unavailable'); notify('预览未启动，请检查手机连接后刷新', true); }
  finally { acting = false; picker.disabled = false; syncTools(); schedule(0); }
}
const toolHandlers = (Object.keys(tools) as ToolName[]).map(name => {
  const handler = () => { void act(name); };
  tools[name].addEventListener('click', handler);
  return [name, handler] as const;
});

function visibilityChanged() {
  root.dataset.pageVisible = String(visible());
  if (!visible()) {
    liveVideo.close();
    if (timer) clearTimeout(timer);
    timer = undefined;
    retainFrame();
  } else {
    if (timer) clearTimeout(timer);
    timer = undefined;
    schedule(0);
  }
}

async function toggleControl() {
  if (controlButton.disabled) return;
  if (controlMode) { controlMode = false; syncTools(); return; }
  acting = true; controlLabel.textContent = '连接中'; syncTools();
  try {
    const result = await app.callServerTool({ name:'screen_action', arguments:{ action:'connect', device_id:selectedDeviceId } }, {timeout:ACTION_TIMEOUT});
    if (result.isError) throw new Error((result.structuredContent as {error?:{message?:string}})?.error?.message ?? '控制连接未完成');
    controlMode = true; notify('可直接点按或拖动手机画面');
  } catch (error) { notify(error instanceof Error ? error.message : '控制连接未完成', true); }
  finally { acting = false; controlLabel.textContent = '操作'; syncTools(); }
}
function toggleAnnotations() {
  if (annotateButton.disabled) return;
  if (annotations.active) { annotations.end(); return; }
  if (!dimensions || !selectedDeviceId) return;
  try { annotations.begin(liveVideo.active ? video : image, dimensions); }
  catch { notify('当前没有可标注的画面，请等待连接', true); }
}
function normalizedPoint(event: PointerEvent): NormalizedPoint {
  const rect = screen.getBoundingClientRect();
  return { x:Math.max(0,Math.min(1,(event.clientX-rect.left)/rect.width)), y:Math.max(0,Math.min(1,(event.clientY-rect.top)/rect.height)) };
}
function pointerDown(event: PointerEvent) {
  if ((!annotations.active && root.dataset.live !== 'live') || event.button !== 0 || acting || previewPaused || pointer || (!controlMode && !annotations.active)) return;
  event.preventDefault(); const point = normalizedPoint(event);
  pointer = {id:event.pointerId,start:point,x:event.clientX,y:event.clientY,started:performance.now(),deviceId:selectedDeviceId,width:dimensions?.width,height:dimensions?.height};
  screen.setPointerCapture(event.pointerId);
  if (annotations.active) annotations.pointerDown(point);
}
function pointerMove(event: PointerEvent) {
  if (!annotations.active || (pointer && pointer.id !== event.pointerId)) return;
  const point = normalizedPoint(event);
  if (pointer) annotations.pointerMove(point);
  else annotations.pointerHover(point);
}
function pointerCancel() {
  const id = pointer?.id; pointer = undefined;
  if (id !== undefined && screen.hasPointerCapture(id)) screen.releasePointerCapture(id);
  annotations.pointerCancel();
}
function lostPointerCapture(event: PointerEvent) { if (pointer?.id === event.pointerId) pointerCancel(); }
function pointerUp(event: PointerEvent) {
  if (!pointer || pointer.id !== event.pointerId) return;
  const start = pointer; pointer = undefined;
  if (screen.hasPointerCapture(event.pointerId)) screen.releasePointerCapture(event.pointerId);
  const end = normalizedPoint(event);
  if (annotations.active) { annotations.pointerUp(end); return; }
  if (!controlMode || acting) return;
  if (start.deviceId !== selectedDeviceId || start.width !== dimensions?.width || start.height !== dimensions?.height) {
    notify('画面已变化，请重新操作', true); return;
  }
  const isTap = Math.hypot(event.clientX-start.x,event.clientY-start.y) < 6;
  const arguments_ = {action:isTap?'tap':'swipe',device_id:selectedDeviceId,x:start.start.x,y:start.start.y,
    ...(isTap?{}:{end_x:end.x,end_y:end.y,duration_ms:Math.round(Math.max(120,Math.min(1500,performance.now()-start.started)))})};
  acting = true; syncTools();
  void app.callServerTool({name:'screen_action',arguments:arguments_},{timeout:15000}).then(result => {
    if (result.isError) notify((result.structuredContent as {error?:{message?:string}})?.error?.message ?? '操作未完成，请先查看当前画面',true);
  }).catch(() => notify('操作结果未确认，请先查看画面，避免重复点击',true)).finally(() => {acting=false;syncTools();});
}
const pointerHandlers = [['pointerdown',pointerDown],['pointermove',pointerMove],['pointerup',pointerUp],['pointercancel',pointerCancel],['lostpointercapture',lostPointerCapture]] as const;
for (const [name,handler] of pointerHandlers) screen.addEventListener(name,handler);
controlButton.addEventListener('click',toggleControl); annotateButton.addEventListener('click',toggleAnnotations);

const resizeObserver = new ResizeObserver(fitFrame);
resizeObserver.observe(stage);
image.onload = () => {
  if (dimensions && image.src) lastGoodFrame = { source: image.src, size: dimensions };
};
image.onerror = () => {
  if (disposed || root.dataset.live === 'paused' || !image.src) return;
  if (lastGoodFrame && image.src !== lastGoodFrame.source) {
    image.src = lastGoodFrame.source;
    dimensions = lastGoodFrame.size;
    fitFrame();
  } else if (!lastGoodFrame) {
    clearFrame();
    setLive('offline');
    showEmpty('unavailable');
  }
  frameSeq = 0; // Request a replacement without blanking the last decoded frame.
  retainFrame();
};
function documentVisibilityChanged() {
  if (!document.hidden) suspended = false;
  visibilityChanged();
}
document.addEventListener('visibilitychange', documentVisibilityChanged);

function pageHide() {
  // WebViews may suspend a document without putting it in the browser cache.
  // A real navigation destroys this JS context; only host teardown is terminal.
  suspended = true;
  visibilityChanged();
}
function pageShow() { suspended = false; visibilityChanged(); }
function focusChanged() { if (!document.hidden) pageShow(); }

function dispose() {
  if (disposed) return;
  disposed = true;
  ready = false;
  root.dataset.pageVisible = 'false';
  if (timer) clearTimeout(timer);
  timer = undefined;
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = undefined;
  toast.hidden = true;
  for (const [name, handler] of toolHandlers) tools[name].removeEventListener('click', handler);
  clearFrame();
  resizeObserver.disconnect();
  liveVideo.close(); annotations.dispose();
  controlButton.removeEventListener('click', toggleControl);
  annotateButton.removeEventListener('click', toggleAnnotations);
  for (const [name, handler] of pointerHandlers) screen.removeEventListener(name, handler);
  pollRequest?.abort();
  retryButton.removeEventListener('click', retryPreview);
  picker.removeEventListener('click', pickerClick);
  picker.removeEventListener('keydown', pickerKeydown);
  deviceMenu.removeEventListener('keydown', menuKeydown);
  document.removeEventListener('pointerdown', outsidePointer);
  document.removeEventListener('visibilitychange', documentVisibilityChanged);
  window.removeEventListener('pagehide', pageHide);
  window.removeEventListener('pageshow', pageShow);
  window.removeEventListener('focus', focusChanged);
}

app.ontoolresult = (result) => {
  if (!result.isError) consume(result.structuredContent);
  schedule(0);
};
app.onhostcontextchanged = (context) => { applyTheme(context?.theme); };
app.onteardown = async () => { dispose(); return {}; };
app.onclose = () => {
  ready = false;
  retainFrame();
  schedule(1000);
};
window.addEventListener('pagehide', pageHide);
window.addEventListener('pageshow', pageShow);
window.addEventListener('focus', focusChanged);

function connect() {
  if (!connecting) connecting = initialize().finally(() => { connecting = undefined; });
  return connecting;
}

async function initialize() {
  await app.connect(undefined, { timeout: REQUEST_TIMEOUT });
  if (disposed) { await app.close(); return; }
  ready = true;
  const context = app.getHostContext();
  applyTheme(context?.theme);
  if (!requestedFullscreen && context?.displayMode !== 'fullscreen'
      && context?.availableDisplayModes?.includes('fullscreen')) {
    requestedFullscreen = true;
    try { await app.requestDisplayMode({ mode: 'fullscreen' }, { timeout: REQUEST_TIMEOUT }); } catch { /* Keep the preview in the host's supported view. */ }
  }
}

root.dataset.pageVisible = String(visible());
device.hidden = screen.hidden = true;
image.hidden = true;
emptyState.hidden = false;
showEmpty('connecting');
fitFrame();
syncTools();
try { await connect(); } catch { retainFrame(); setLive('offline'); }
schedule(ready ? 0 : 1000);
