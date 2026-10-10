import type { App } from '@modelcontextprotocol/ext-apps';
export type Point = { x: number; y: number };
export type Region = Point & { width: number; height: number };
type FrozenFrame = { source: string; width: number; height: number; deviceId: string; deviceName: string; capturedAt: string };
export const regionBetween = (a: Point, b: Point): Region => ({
  x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y),
});
export function createAnnotations(app: App, callbacks: {
  freeze: (source: string) => void; resume: () => void; changed: () => void; notify: (text: string, error?: boolean) => void;
}) {
  const overlay = document.getElementById('annotation-overlay')! as unknown as SVGSVGElement;
  const editor = document.getElementById('annotation-editor')!;
  const note = document.getElementById('annotation-note')! as HTMLTextAreaElement;
  const count = document.getElementById('annotation-count')!;
  const undo = document.getElementById('annotation-undo')! as HTMLButtonElement;
  const cancel = document.getElementById('annotation-cancel')! as HTMLButtonElement;
  const send = document.getElementById('annotation-send')! as HTMLButtonElement;
  const hint = document.getElementById('annotation-hint')!;
  let frozen: FrozenFrame | undefined;
  let regions: Region[] = [];
  let origin: Point | undefined;
  let draft: Region | undefined;
  let sending = false;
  const ns = 'http://www.w3.org/2000/svg';
  function render() {
    overlay.replaceChildren();
    if (!frozen) return;
    overlay.setAttribute('viewBox', `0 0 ${frozen.width} ${frozen.height}`);
    const all = [...regions, ...(draft ? [draft] : [])];
    all.forEach((region, index) => {
      const x = region.x * frozen!.width, y = region.y * frozen!.height;
      const rect = document.createElementNS(ns, 'rect');
      for (const [key, value] of Object.entries({ x, y, width: region.width * frozen!.width, height: region.height * frozen!.height })) rect.setAttribute(key, String(value));
      rect.setAttribute('class', 'annotation-region');
      overlay.appendChild(rect);
      const size = Math.max(25, frozen!.width * .033);
      const badge = document.createElementNS(ns, 'circle');
      badge.setAttribute('cx', String(x + size / 2)); badge.setAttribute('cy', String(y + size / 2));
      badge.setAttribute('r', String(size / 2)); badge.setAttribute('class', 'annotation-number-bg');
      overlay.appendChild(badge);
      const text = document.createElementNS(ns, 'text');
      text.setAttribute('x', String(x + size / 2)); text.setAttribute('y', String(y + size * .54));
      text.setAttribute('font-size', String(size * .62)); text.setAttribute('class', 'annotation-number');
      text.textContent = String(index + 1); overlay.appendChild(text);
    });
    count.textContent = regions.length ? `已标注 ${regions.length} 处` : '拖动框选要讨论的区域';
    undo.disabled = sending || !regions.length;
    send.disabled = sending || !regions.length;
    cancel.disabled = sending;
    note.disabled = sending;
  }
  function begin(source: CanvasImageSource, size: {width:number;height:number}, deviceId: string, deviceName: string) {
    if (sending) return;
    const canvas = document.createElement('canvas'); canvas.width = size.width; canvas.height = size.height;
    const context = canvas.getContext('2d');
    if (!context || !canvas.width || !canvas.height) throw new Error('当前没有可标注的画面');
    context.drawImage(source, 0, 0, canvas.width, canvas.height);
    frozen = { source: canvas.toDataURL('image/png'), ...size, deviceId, deviceName, capturedAt: new Date().toISOString() };
    regions = []; origin = draft = undefined; note.value = '';
    callbacks.freeze(frozen.source); editor.hidden = false; overlay.removeAttribute('hidden');
    hint.textContent = '画面已冻结，框选不会操作手机'; render(); callbacks.changed();
  }
  function end() {
    if (sending) return;
    frozen = undefined; regions = []; origin = draft = undefined;
    overlay.replaceChildren(); editor.hidden = true; overlay.setAttribute('hidden', '');
    callbacks.resume(); callbacks.changed();
  }
  function pointerDown(point: Point) { if (frozen && !sending && regions.length < 8) { origin = point; draft = undefined; } }
  function pointerMove(point: Point) { if (origin) { draft = regionBetween(origin, point); render(); } }
  function pointerUp(point: Point) {
    if (!origin || !frozen) return;
    const region = regionBetween(origin, point); origin = draft = undefined;
    if (region.width * frozen.width >= 8 && region.height * frozen.height >= 8) regions.push(region);
    render();
  }
  function pointerCancel() { origin = draft = undefined; render(); }
  async function annotatedImage(frame: FrozenFrame, capturedRegions: Region[]) {
    const image = new Image(); image.src = frame.source; await image.decode();
    const canvas = document.createElement('canvas'); canvas.width = frame.width; canvas.height = frame.height;
    const context = canvas.getContext('2d')!; context.drawImage(image, 0, 0);
    const size = Math.max(25, frame.width * .033);
    for (const [index, region] of capturedRegions.entries()) {
      const x = region.x * frame.width, y = region.y * frame.height, w = region.width * frame.width, h = region.height * frame.height;
      context.strokeStyle = '#ffffff'; context.lineWidth = Math.max(5, frame.width / 150); context.strokeRect(x, y, w, h);
      context.strokeStyle = '#db701d'; context.lineWidth = Math.max(3, frame.width / 300); context.strokeRect(x, y, w, h);
      context.fillStyle = '#db701d'; context.beginPath(); context.arc(x + size/2, y + size/2, size/2, 0, Math.PI*2); context.fill();
      context.fillStyle = '#ffffff'; context.font = `600 ${size*.62}px -apple-system, sans-serif`;
      context.textAlign = 'center'; context.textBaseline = 'middle'; context.fillText(String(index+1), x+size/2, y+size*.54);
    }
    return canvas.toDataURL('image/png').split(',')[1];
  }
  async function submit() {
    if (!frozen || !regions.length || sending) return;
    const frame = frozen;
    const capturedRegions = regions.map(region => ({ ...region }));
    origin = draft = undefined;
    const caps = app.getHostCapabilities();
    if (!caps?.message || (!caps.message.image && !caps.updateModelContext?.image)) {
      callbacks.notify('当前宿主不支持发送截图标注，请在 Codex 插件面板打开。', true); return;
    }
    sending = true; render(); callbacks.changed(); hint.textContent = '正在发送截图和标注…';
    let messageRequested = false;
    try {
      const data = await annotatedImage(frame, capturedRegions);
      const boxes = capturedRegions.map((region, index) => ({ number: index+1, normalized: region,
        pixels: { x: Math.round(region.x*frame.width), y: Math.round(region.y*frame.height), width: Math.round(region.width*frame.width), height: Math.round(region.height*frame.height) } }));
      const text = `${note.value.trim() || '请查看这些标注区域。'}\n\nStupidMirror 截图标注\n设备：${frame.deviceName}（device_id: ${frame.deviceId}）\n冻结时间：${frame.capturedAt}\n原图尺寸：${frame.width} × ${frame.height}\n标注区域：${JSON.stringify(boxes)}\n这是冻结截图；若需要操作手机，请先重新观察当前画面，确认目标仍对应，不要直接重放旧坐标。`;
      const image = { type: 'image' as const, mimeType: 'image/png', data };
      if (!caps.message.image) await app.updateModelContext({ content: [image], structuredContent: { device_id: frame.deviceId, captured_at: frame.capturedAt, regions: boxes } });
      messageRequested = true;
      const result = await app.sendMessage({ role: 'user', content: [{ type: 'text', text }, ...(caps.message.image ? [image] : [])] });
      if (result.isError) {
        hint.textContent = '标注未发送：Codex 拒绝接收消息。截图、区域和说明已保留。';
        callbacks.notify('Codex 未接收标注，内容已保留', true);
        return;
      }
      sending = false; end(); callbacks.notify('标注已发送给 Codex');
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      if (/available composer|composer is unavailable|app messages are disabled for this view|composer was closed/i.test(reason)) {
        // The host rejects these requests before submitting the message. This
        // differs from a lost acknowledgement, and retrying the same detached
        // app view cannot repair its host-owned conversation binding.
        hint.textContent = '标注未发送：Codex 的聊天发送入口不可用。截图、区域和说明已保留；请回到目标聊天后再试。若仍失败，请从该聊天重新打开 StupidMirror 面板。';
        callbacks.notify('聊天发送入口不可用，标注尚未发送', true);
      } else if (!messageRequested) {
        hint.textContent = `标注未发送：${reason.slice(0, 240)}。内容已保留。`;
        callbacks.notify('标注准备失败，内容已保留', true);
      } else {
        // A timed-out host message may have been accepted; never retry it automatically.
        hint.textContent = `发送未确认，标注已保留。请先查看聊天，再决定是否重试。错误：${reason.slice(0, 240)}`;
        callbacks.notify('发送未确认，请查看聊天。标注已保留。', true);
      }
    } finally { sending = false; render(); callbacks.changed(); }
  }
  const undoClick = () => { if (!sending) { regions.pop(); render(); } };
  undo.addEventListener('click', undoClick); cancel.addEventListener('click', end); send.addEventListener('click', submit);
  return { begin, end, pointerDown, pointerMove, pointerUp, pointerCancel,
    get active() { return !!frozen; }, get busy() { return sending; },
    dispose() { undo.removeEventListener('click',undoClick);cancel.removeEventListener('click',end);send.removeEventListener('click',submit); }
  };
}
