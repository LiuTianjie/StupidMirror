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
import type { TouchPhase } from './touch';
import { createAnnotations, type Point as NormalizedPoint } from './annotations';
import { validMesh, type ScreenMesh } from './mesh';
import { createDuoPreview, validDuoPose, type DuoPose, type DuoAsset } from './duo';
import { createStandaloneHost, isStandaloneViewer, ViewerLinkError } from './standalone';

type Size = { width: number; height: number };
type Point = { x: number; y: number };
type Frame = Size & { seq: number; data: string; mimeType: string };
type Posture = 'closed' | 'partially_open' | 'open';
type Shell = Size & {
  id: string;
  screen_x: number; screen_y: number; screen_width: number; screen_height: number;
  artwork?: string; mask?: string;
  mesh?: ScreenMesh; duo?: DuoPose; model?: DuoAsset; posture_icons?: Partial<Record<Posture | 'rotate',string>>;
};
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
  device?: { id?: string; model?: string; platform?: string; form_factor?: string; active_screen?: string; posture?: Posture; hinge_angle?: number; can_set_posture?: boolean; changing_posture?: boolean } | null;
  shell?: Shell | null;
  devices?: { device_id: string; name: string; platform?: string; connection_state: string; supports_continuous_touch?: boolean; supports_native_gestures?: boolean; touch_generation?: number }[];
  message?: string;
};
type LiveState = 'connecting' | 'live' | 'paused' | 'offline';
type EmptyState = 'connecting' | 'offline' | 'locked' | 'authentication' | 'paused' | 'unavailable';
type ToolName = 'refresh' | 'home' | 'screenshot' | 'pause';
type CursorEffect = { node: HTMLElement; animation?: Animation; timer?: ReturnType<typeof setTimeout> };

const root = document.getElementById('app')!;
const device = document.getElementById('device')!;
const shellArtwork = document.getElementById('shell-artwork')! as HTMLImageElement;
const meshCanvas = document.getElementById('mesh-screen')! as HTMLCanvasElement;
const duoPreview = createDuoPreview(meshCanvas);
const screen = document.getElementById('screen')!;
const image = document.getElementById('image')! as HTMLImageElement;
const video = document.getElementById('video')! as HTMLVideoElement;
const controlButton = document.getElementById('control-button')! as HTMLButtonElement;
const annotateButton = document.getElementById('annotate-button')! as HTMLButtonElement;
const controlLabel = document.getElementById('control-label')!;
let controlMode = false;
let supportsContinuousTouch = false;
let supportsNativeGestures = false;
let touchGeneration: number | undefined;
let nextGesture = 0;
let pointer: { id:number; target:HTMLElement; start:NormalizedPoint; x:number; y:number; started:number; deviceId?:string; width?:number; height?:number; shellId?:string; geometry:string; generation?:number; gestureID:string; seq:number; continuous:boolean; last:NormalizedPoint; moved:boolean } | undefined;
let wheelGesture: { point:NormalizedPoint; geometry:string; generation:number; gestureID:string; seq:number } | undefined;
let wheelIdle: ReturnType<typeof setTimeout> | undefined;
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
const postureDivider = document.getElementById('posture-divider')!;
const rotateButton = document.getElementById('tool-rotate')! as HTMLButtonElement;
const postureButtons: Record<Posture, HTMLButtonElement> = {
  closed: document.getElementById('tool-posture-closed') as HTMLButtonElement,
  partially_open: document.getElementById('tool-posture-partially-open') as HTMLButtonElement,
  open: document.getElementById('tool-posture-open') as HTMLButtonElement,
};
let currentPosture: Posture | undefined;
let canSetPosture = false;
let changingPosture = false;
let shell: Shell | undefined;
const shellCache = new Map<string, Shell>();
const app = isStandaloneViewer() ? createStandaloneHost() : new App(
  { name: 'StupidMirror', version: '0.2.7' },
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
    if (!dimensions || dimensions.width !== size.width || dimensions.height !== size.height) { cancelForGeometryChange(); dimensions = size; fitFrame(); }
    image.hidden = true; video.hidden = false; device.hidden = screen.hidden = false; emptyState.hidden = true;
    root.dataset.transport = 'webrtc'; setLive('live'); syncTools();
    duoPreview.draw(video);
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
  touchStopped: reason => { const wasControlling = controlMode || !!pointer; pointerCancel(); controlMode = false; syncTools(); if (wasControlling) notify(reason, true); },
  fps: value => { root.dataset.videoFps = String(value); if (dimensions) liveText.title = `${dimensions.width} × ${dimensions.height} · ${value} fps`; },
});
const annotations = createAnnotations(app, {
  freeze: source => { pointerCancel(); frameGeneration++; controlMode = false; image.src = source; image.hidden = false; video.hidden = true; root.dataset.annotation = 'true'; },
  resume: () => {
    root.dataset.annotation = 'false';
    if (liveVideo.active) { image.hidden = true; video.hidden = false; }
    else { frameSeq = 0; schedule(0); }
  },
  changed: () => { syncTools(); fitFrame(); }, notify,
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
  syncPosturePicker();
}

function showEmpty(state: EmptyState) {
  emptyState.dataset.state = state;
  emptyText.textContent = EMPTY_TEXT[state];
  emptyHint.textContent = '保持手机已连接并解锁';
  retryButton.hidden = !['offline', 'unavailable'].includes(state);
}

function showConnectionError(reason: string, retrying = false) {
  if (!image.src && !liveVideo.active) { emptyState.hidden = false; device.hidden = screen.hidden = !shell; }
  if (previewPaused) {
    showEmpty(emptyState.dataset.state === 'locked' ? 'locked' : 'authentication');
    emptyHint.textContent = reason; retryButton.hidden = false; return;
  }
  showEmpty('unavailable');
  emptyText.textContent = reason;
  emptyHint.textContent = retrying ? '正在自动重新连接…' : '点击重试，重新建立预览连接';
  retryButton.hidden = false;
}

// Only a new link from the agent repairs this, so offer no retry.
function showViewerLinkError(error: ViewerLinkError) {
  pollBlocked = true;
  retainFrame(); setLive('offline');
  emptyState.hidden = false; device.hidden = screen.hidden = true;
  showEmpty('unavailable');
  emptyText.textContent = error.message;
  emptyHint.textContent = '请让 Claude 重新打开手机画面（open_viewer），再点击新链接';
  retryButton.hidden = true;
}

function setLive(state: LiveState) {
  if (!image.src) showEmpty(state === 'paused' ? 'paused' : state === 'offline' ? 'offline' : 'connecting');
  if (root.dataset.live === state) return;
  root.dataset.live = state;
  if (state !== 'live') { pointerCancel(); controlMode = false; }
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
  pointerCancel();
  duoPreview.clear();
  liveVideo.close(); controlMode = false;
  frameGeneration++;
  hideCursor();
  image.removeAttribute('src');
  image.hidden = true;
  emptyState.hidden = false;
  device.hidden = screen.hidden = !shell;
  dimensions = undefined;
  lastGoodFrame = undefined;
  frameSeq = 0;
  root.dataset.frameSeq = '0';
  root.dataset.busy = 'false';
  if (resetOperating) root.dataset.operating = 'false';
  if (!disposed) fitFrame();
}

function retainFrame() {
  hideCursor();
  root.dataset.busy = 'false';
}

const visible = () => !disposed && !suspended && !document.hidden;

function fitFrame() {
  if ((pointer && pointer.geometry !== gestureGeometry()) || (wheelGesture && wheelGesture.geometry !== gestureGeometry())) cancelForGeometryChange();
  if (shell?.duo && !annotations.active) {
    const width = stage.clientWidth, height = stage.clientHeight;
    const ready = duoPreview.configure(shell.duo, shell.model, width, height);
    // Until the model arrives, keep the status visible rather than briefly
    // presenting this known foldable as a bare rectangular screenshot.
    device.hidden = !ready;
    screen.style.visibility = 'hidden';
    shellArtwork.hidden = true;
    if (ready) {
      // Keep one canvas mounted while the camera follows the hinge. A new
      // framebuffer must not replace or resize the model during a transition.
      device.style.width = width + 'px';
      device.style.height = height + 'px';
      device.dataset.duo = 'true';
      device.dataset.mesh = 'true';
      device.dataset.shellId = shell.id;
      duoPreview.draw(liveVideo.active ? video : image);
    }
    return;
  }
  const size = dimensions ?? viewport ?? (shell ? {width: shell.screen_width, height: shell.screen_height} : undefined);
  if (!size) return;
  // Hardware identity does not disappear while its video is starting or
  // rotating. object-fit: contain preserves the full frame inside its shell.
  const fittedShell = shell && !shell.duo && !(annotations.active && shell.mesh) ? shell : undefined;
  const body = fittedShell ?? size;
  const width = stage.clientWidth;
  const height = stage.clientHeight;
  const scale = Math.min(width / body.width, height / body.height);
  const displayWidth = Math.max(0, body.width * scale);
  const displayHeight = Math.max(0, body.height * scale);
  device.style.width = `${displayWidth}px`;
  device.style.height = `${displayHeight}px`;
  duoPreview.configure();
  screen.style.visibility = '';
  device.dataset.duo = 'false';
  screen.style.left = `${(fittedShell?.screen_x ?? 0) * scale}px`;
  screen.style.top = `${(fittedShell?.screen_y ?? 0) * scale}px`;
  screen.style.width = `${(fittedShell?.screen_width ?? size.width) * scale}px`;
  screen.style.height = `${(fittedShell?.screen_height ?? size.height) * scale}px`;
  shellArtwork.hidden = !fittedShell?.artwork;
  const mask = fittedShell?.mask ? `url("data:image/png;base64,${fittedShell.mask}")` : 'none';
  screen.style.maskImage = mask;
  screen.style.setProperty('-webkit-mask-image', mask);
  device.dataset.orientation = size.width > size.height ? 'landscape' : 'portrait';
  device.dataset.shellId = fittedShell?.id ?? '';
  device.dataset.mesh = 'false';
  duoPreview.draw(liveVideo.active && !annotations.active ? video : image);
  if (annotations.active) annotations.render();
}

function consumeShell(value: Shell | null | undefined) {
  if (!value || !validSize(value) || typeof value.id !== 'string'
      || !validSize({ width: value.screen_width, height: value.screen_height })
      || !Number.isFinite(value.screen_x) || !Number.isFinite(value.screen_y)
      || value.screen_x < 0 || value.screen_y < 0
      || value.screen_x + value.screen_width > value.width + 1
      || value.screen_y + value.screen_height > value.height + 1) return;
  if (value.mesh && !validMesh(value.mesh)) return;
  if (value.duo && !validDuoPose(value.duo)) return;
  const previousID = shell?.id;
  if ((pointer || wheelGesture) && previousID !== value.id) cancelForGeometryChange();
  shell = { ...shellCache.get(value.id), ...value };
  if (shell.artwork || shell.posture_icons || shell.model) {
    shellCache.set(shell.id, shell);
    if (shellCache.size > 12) shellCache.delete(shellCache.keys().next().value!);
  }
  if (shell.artwork && !shell.duo) {
    const source = `data:image/png;base64,${shell.artwork}`;
    if (shellArtwork.src !== source) {
      shellArtwork.src = source;
      if (previousID && previousID !== shell.id && !reducedMotion.matches) {
        shellArtwork.animate([{opacity:0.35},{opacity:1}], {duration:240,easing:'ease-in-out'});
      }
    }
  } else {
    shellArtwork.removeAttribute('src');
  }
  for (const posture of Object.keys(postureButtons) as Posture[]) {
    const icon = shell.posture_icons?.[posture];
    postureButtons[posture].dataset.realIcon = String(!!icon);
    if (icon) postureButtons[posture].style.setProperty('--posture-icon', `url("data:image/png;base64,${icon}")`);
  }
  const rotateIcon = shell.posture_icons?.rotate;
  rotateButton.dataset.realIcon = String(!!rotateIcon);
  if (rotateIcon) rotateButton.style.setProperty('--posture-icon', `url("data:image/png;base64,${rotateIcon}")`);
  device.hidden = screen.hidden = false;
  fitFrame();
}

function resetDeviceAppearance() {
  shell = undefined; currentPosture = undefined; canSetPosture = false; changingPosture = false;
  device.hidden = screen.hidden = true;
  shellArtwork.removeAttribute('src'); shellArtwork.hidden = true;
  duoPreview.clear(); screen.style.visibility = '';
  screen.style.maskImage = 'none'; screen.style.setProperty('-webkit-mask-image', 'none');
  syncPosturePicker();
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
    viewport = undefined; platform = undefined; resetDeviceAppearance();
    syncDeviceSelection();
  }
  if (Array.isArray(preview.devices)) {
    const selected = preview.devices.find(item => item.device_id === selectedDeviceId);
    const generation = selected?.touch_generation;
    const supported = selected?.supports_continuous_touch === true;
    const nativeGestures = selected?.supports_native_gestures === true;
    if ((pointer || wheelGesture) && (generation !== touchGeneration || supported !== supportsContinuousTouch || nativeGestures !== supportsNativeGestures)) cancelForGeometryChange();
    supportsContinuousTouch = supported;
    supportsNativeGestures = nativeGestures;
    touchGeneration = Number.isSafeInteger(generation) ? generation : undefined;
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
  if (preview.device) {
    if ((pointer || wheelGesture) && preview.device.changing_posture === true) cancelForGeometryChange();
    currentPosture = preview.device.posture ?? undefined;
    canSetPosture = preview.device.can_set_posture === true;
    changingPosture = preview.device.changing_posture === true;
    syncPosturePicker();
  }
  consumeShell(preview.shell);
  if (validSize(preview.viewport) && (viewport?.width !== preview.viewport.width || viewport?.height !== preview.viewport.height)) {
    cancelForGeometryChange();
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
      arguments: { after_seq: frameSeq, ...(shell && (shell.artwork || shell.posture_icons) ? { shell_id: shell.id } : {}), model_id: duoPreview.modelID ?? '', ...(liveVideo.available ? { include_frame: false } : {}), ...(selectedDeviceId ? { device_id: selectedDeviceId } : {}) },
    }, { timeout: REQUEST_TIMEOUT, signal: controller.signal });
    if (!visible() || generation !== frameGeneration) return;
    if (result.isError) throw new Error((result.structuredContent as {error?:{message?:string}})?.error?.message ?? '预览服务不可用');
    consume(result.structuredContent);
    failures = 0;
    const preview = result.structuredContent as Partial<Preview> | undefined;
    const stateInterval = canSetPosture && !annotations.active ? FRAME_INTERVAL : VIDEO_STATE_INTERVAL;
    nextDelay = liveVideo.active || liveVideo.pending || annotations.active ? stateInterval : preview?.paused || preview?.frame_available === false
      ? 1000 : Math.max(0, FRAME_INTERVAL - (performance.now() - started));
  } catch (error) {
    if (controller.signal.aborted) return;
    if (error instanceof ViewerLinkError) { showViewerLinkError(error); return; }
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
  pointerCancel();
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
  resetDeviceAppearance();
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

function syncPosturePicker() {
  postureDivider.hidden = !canSetPosture;
  rotateButton.hidden = !canSetPosture;
  rotateButton.disabled = acting || changingPosture || annotations.active || previewPaused || !canSetPosture || !selectedDeviceId;
  for (const [posture, button] of Object.entries(postureButtons)) {
    button.hidden = !canSetPosture;
    button.setAttribute('aria-pressed', String(currentPosture === posture));
    button.disabled = acting || changingPosture || annotations.active || previewPaused
      || !canSetPosture || !selectedDeviceId;
  }
}

async function setPosture(target: Posture | 'rotate') {
  if (disposed || (target === 'rotate' ? rotateButton : postureButtons[target]).disabled) return;
  pointerCancel();
  acting = true;
  if (target !== 'rotate') duoPreview.beginPosture({closed:0,partially_open:130,open:180}[target]);
  syncTools();
  try {
    if (!ready) await connect();
    const result = await app.callServerTool({
      name: 'screen_action',
      arguments: { action: target, device_id: selectedDeviceId },
    }, { timeout: ACTION_TIMEOUT });
    const data = result.structuredContent as (Partial<Preview> & { error?: { message?: string } }) | undefined;
    if (result.isError || data?.error) {
      notify(data?.error?.message ?? '调整姿态失败，请重试', true);
    } else {
      consume(data);
      if (timer) clearTimeout(timer);
      timer = undefined;
      schedule(0);
    }
  } catch {
    notify('调整姿态失败，请重试', true);
  } finally {
    duoPreview.finishPosture();
    acting = false;
    syncTools();
  }
}
for (const posture of Object.keys(postureButtons) as Posture[]) {
  postureButtons[posture].addEventListener('click', () => { void setPosture(posture); });
}
const rotateDevice = () => { void setPosture('rotate'); };
rotateButton.addEventListener('click', rotateDevice);

function visibilityChanged() {
  root.dataset.pageVisible = String(visible());
  if (!visible()) {
    pointerCancel();
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
  if (controlMode) { pointerCancel(); controlMode = false; syncTools(); return; }
  acting = true; controlLabel.textContent = '连接中'; syncTools();
  try {
    const result = await app.callServerTool({ name:'screen_action', arguments:{ action:'connect', device_id:selectedDeviceId } }, {timeout:ACTION_TIMEOUT});
    if (result.isError) throw new Error((result.structuredContent as {error?:{message?:string}})?.error?.message ?? '控制连接未完成');
    consume(result.structuredContent);
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
function normalizedPoint(event: Pick<MouseEvent, 'clientX' | 'clientY'>, clamped = false): NormalizedPoint | undefined {
  if (duoPreview.active) {
    const rect = device.getBoundingClientRect();
    return duoPreview.point({x:(event.clientX-rect.left)/rect.width,y:(event.clientY-rect.top)/rect.height}, clamped);
  }
  const rect = screen.getBoundingClientRect();
  return { x:Math.max(0,Math.min(1,(event.clientX-rect.left)/rect.width)), y:Math.max(0,Math.min(1,(event.clientY-rect.top)/rect.height)) };
}
function gestureGeometry() {
  return [selectedDeviceId, touchGeneration, dimensions?.width, dimensions?.height,
    viewport?.width, viewport?.height, shell?.id, currentPosture, stage.clientWidth, stage.clientHeight].join(':');
}
function sendPointer(phase: TouchPhase, point: NormalizedPoint, captured = pointer): boolean {
  if (!captured?.continuous) return false;
  return liveVideo.sendTouch({ type:'touch', phase, gesture_id:captured.gestureID, seq:captured.seq++,
    x:point.x, y:point.y, geometry_id:String(captured.generation) });
}
function pointerDown(event: PointerEvent) {
  if ((!annotations.active && root.dataset.live !== 'live') || event.button !== 0 || acting || duoPreview.transitioning || previewPaused || pointer || (!controlMode && !annotations.active)) return;
  const point = normalizedPoint(event); if (!point) return;
  finishWheel(false);
  event.preventDefault();
  const target = duoPreview.active ? meshCanvas : screen;
  const continuous = !annotations.active && supportsContinuousTouch && touchGeneration !== undefined && liveVideo.touchReady;
  pointer = {id:event.pointerId,target,start:point,last:point,moved:false,x:event.clientX,y:event.clientY,started:performance.now(),deviceId:selectedDeviceId,width:dimensions?.width,height:dimensions?.height,shellId:shell?.id,
    geometry:gestureGeometry(),generation:touchGeneration,gestureID:`${Date.now().toString(36)}-${++nextGesture}`,seq:0,continuous};
  target.setPointerCapture(event.pointerId);
  if (annotations.active) annotations.pointerDown(point);
  else if (continuous && !sendPointer('down', point)) pointerCancel();
}
function pointerMove(event: PointerEvent) {
  if (pointer && pointer.id !== event.pointerId) return;
  if (!pointer && !annotations.active) return;
  if (pointer && pointer.geometry !== gestureGeometry()) { cancelForGeometryChange(); return; }
  const point = normalizedPoint(event, !!pointer); if (!point) return;
  if (annotations.active) {
    if (pointer) annotations.pointerMove(point); else annotations.pointerHover(point);
    return;
  }
  if (!pointer) return;
  pointer.last = point;
  pointer.moved ||= Math.hypot(event.clientX-pointer.x,event.clientY-pointer.y) >= 6;
  if (pointer.continuous && !sendPointer('move', point)) pointerCancel();
}
function cancelForGeometryChange() {
  if (!pointer && !wheelGesture) return;
  pointerCancel();
  notify('画面已变化，已取消当前手势，请重新操作', true);
}
function pointerCancel() {
  finishWheel(true);
  const captured = pointer; pointer = undefined;
  if (captured?.continuous) sendPointer('cancel', captured.last, captured);
  if (captured?.target.hasPointerCapture(captured.id)) captured.target.releasePointerCapture(captured.id);
  annotations.pointerCancel();
}

function finishWheel(cancelled: boolean) {
  clearTimeout(wheelIdle); wheelIdle = undefined;
  const captured = wheelGesture; wheelGesture = undefined;
  if (!captured) return;
  // A browser wheel has no BEGIN/END phase. This ends only shared local input
  // ownership; the server emits no synthetic finger or system gesture report.
  liveVideo.sendTouch({type:'touch',phase:cancelled?'cancel':'up',gesture_id:captured.gestureID,seq:captured.seq++,
    x:captured.point.x,y:captured.point.y,geometry_id:String(captured.generation),scroll:{delta_x:0,delta_y:0}});
}

function wheel(event: WheelEvent) {
  // DOM does not expose AppKit's phase, momentum or accelerated CG children.
  // Pixel deltas are forwarded individually; do not guess line/page metrics
  // or reinterpret the browser's Ctrl-wheel zoom as a native pinch.
  if (event.ctrlKey || event.deltaMode !== 0 || !controlMode || annotations.active || acting || pointer
      || duoPreview.transitioning || previewPaused || root.dataset.live !== 'live'
      || !supportsNativeGestures || touchGeneration === undefined || !liveVideo.touchReady) return;
  if (![event.deltaX,event.deltaY].every(value=>Number.isFinite(value) && Math.abs(value)<=1_000_000)
      || (event.deltaX === 0 && event.deltaY === 0)) return;
  if (wheelGesture && wheelGesture.geometry !== gestureGeometry()) { cancelForGeometryChange(); return; }
  const point = normalizedPoint(event); if (!point) return;
  event.preventDefault();
  const starting = !wheelGesture;
  wheelGesture ??= {point,geometry:gestureGeometry(),generation:touchGeneration,
    gestureID:`${Date.now().toString(36)}-${++nextGesture}`,seq:0};
  const captured = wheelGesture;
  // DOM deltas describe positive content scrolling right/down; the system
  // wheel report uses the opposite source-axis direction.
  const accepted = liveVideo.sendTouch({type:'touch',phase:starting?'down':'move',gesture_id:captured.gestureID,seq:captured.seq++,
    x:captured.point.x,y:captured.point.y,geometry_id:String(captured.generation),
    scroll:{delta_x:-event.deltaX,delta_y:-event.deltaY}});
  if (!accepted) { finishWheel(true); return; }
  clearTimeout(wheelIdle);
  wheelIdle = setTimeout(()=>finishWheel(false),150);
}
function lostPointerCapture(event: PointerEvent) { if (pointer?.id === event.pointerId) pointerCancel(); }
function pointerUp(event: PointerEvent) {
  if (!pointer || pointer.id !== event.pointerId) return;
  if (pointer.geometry !== gestureGeometry()) { cancelForGeometryChange(); return; }
  if (!annotations.active && (!controlMode || acting)) { pointerCancel(); return; }
  const start = pointer; pointer = undefined;
  if (start.target.hasPointerCapture(event.pointerId)) start.target.releasePointerCapture(event.pointerId);
  const end = normalizedPoint(event, true) ?? start.last;
  if (annotations.active) { annotations.pointerUp(end); return; }
  if (start.continuous) { sendPointer('up', end, start); return; }
  // Compatibility is chosen before down. Never replay a partially sent stream.
  const held = performance.now()-start.started;
  const stationary = !start.moved && Math.hypot(event.clientX-start.x,event.clientY-start.y) < 6;
  const action = stationary ? (held >= 500 ? 'long_press' : 'tap') : 'swipe';
  const arguments_ = {action,device_id:start.deviceId,x:start.start.x,y:start.start.y,
    ...(action==='tap'?{}:{duration_ms:Math.round(Math.max(120,Math.min(5000,held)))}),
    ...(action==='swipe'?{end_x:end.x,end_y:end.y}:{})};
  acting = true; syncTools();
  void app.callServerTool({name:'screen_action',arguments:arguments_},{timeout:15000}).then(result => {
    if (result.isError) notify((result.structuredContent as {error?:{message?:string}})?.error?.message ?? '操作未完成，请先查看当前画面',true);
  }).catch(() => notify('操作结果未确认，请先查看画面，避免重复点击',true)).finally(() => {acting=false;syncTools();});
}
const pointerHandlers = [['pointerdown',pointerDown],['pointermove',pointerMove],['pointerup',pointerUp],['pointercancel',pointerCancel],['lostpointercapture',lostPointerCapture]] as const;
for (const [name,handler] of pointerHandlers) screen.addEventListener(name,handler);
for (const [name,handler] of pointerHandlers) meshCanvas.addEventListener(name,handler);
screen.addEventListener('wheel',wheel,{passive:false});
meshCanvas.addEventListener('wheel',wheel,{passive:false});
controlButton.addEventListener('click',toggleControl); annotateButton.addEventListener('click',toggleAnnotations);

const resizeObserver = new ResizeObserver(fitFrame);
resizeObserver.observe(stage);
image.onload = () => {
  if (dimensions && image.src) lastGoodFrame = { source: image.src, size: dimensions };
  duoPreview.draw(image);
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
window.addEventListener('blur', pointerCancel);

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
  pointerCancel(); liveVideo.close(); annotations.dispose();
  controlButton.removeEventListener('click', toggleControl);
  annotateButton.removeEventListener('click', toggleAnnotations);
  for (const [name, handler] of pointerHandlers) screen.removeEventListener(name, handler);
  for (const [name, handler] of pointerHandlers) meshCanvas.removeEventListener(name, handler);
  screen.removeEventListener('wheel',wheel);
  meshCanvas.removeEventListener('wheel',wheel);
  duoPreview.dispose();
  rotateButton.removeEventListener('click', rotateDevice);
  pollRequest?.abort();
  retryButton.removeEventListener('click', retryPreview);
  picker.removeEventListener('click', pickerClick);
  picker.removeEventListener('keydown', pickerKeydown);
  deviceMenu.removeEventListener('keydown', menuKeydown);
  document.removeEventListener('pointerdown', outsidePointer);
  document.removeEventListener('visibilitychange', documentVisibilityChanged);
  window.removeEventListener('blur', pointerCancel);
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
  // Annotations are sent into the host's chat; a plain page has none.
  annotateButton.hidden = !app.getHostCapabilities()?.message;
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
try { await connect(); } catch (error) {
  if (error instanceof ViewerLinkError) showViewerLinkError(error);
  else { retainFrame(); setLive('offline'); }
}
schedule(ready ? 0 : 1000);
