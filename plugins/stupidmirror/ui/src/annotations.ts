import type { App } from '@modelcontextprotocol/ext-apps';
export type Point = { x: number; y: number };
export type Region = Point & { width: number; height: number };
type FrozenFrame = { source: string; width: number; height: number };
type Handle = 'nw' | 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w';
type Hit = { index: number; handle?: Handle };
type Gesture = { origin: Point; before: Region[]; target?: Hit };
const handles: Handle[] = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];
const clamp = (value: number, min: number, max: number) => Math.max(min, Math.min(max, value));
const handlePoint = (region: Region, handle: Handle): Point => ({
  x: region.x + region.width * (handle.includes('w') ? 0 : handle.includes('e') ? 1 : .5),
  y: region.y + region.height * (handle.includes('n') ? 0 : handle.includes('s') ? 1 : .5),
});
const copyRegions = (regions: Region[]) => regions.map(region => ({ ...region }));
export const regionBetween = (a: Point, b: Point): Region => ({
  x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y),
});
export function createAnnotations(app: App, callbacks: {
  freeze: (source: string) => void; resume: () => void; changed: () => void; notify: (text: string, error?: boolean) => void;
}) {
  const overlay = document.getElementById('annotation-overlay')! as unknown as SVGSVGElement;
  const screen = document.getElementById('screen')!;
  const editor = document.getElementById('annotation-editor')!;
  const note = document.getElementById('annotation-note')! as HTMLTextAreaElement;
  const count = document.getElementById('annotation-count')!;
  const undo = document.getElementById('annotation-undo')! as HTMLButtonElement;
  const remove = document.getElementById('annotation-delete')! as HTMLButtonElement;
  const cancel = document.getElementById('annotation-cancel')! as HTMLButtonElement;
  const send = document.getElementById('annotation-send')! as HTMLButtonElement;
  const hint = document.getElementById('annotation-hint')!;
  let frozen: FrozenFrame | undefined;
  let regions: Region[] = [];
  let gesture: Gesture | undefined;
  let selected: number | undefined;
  let history: { regions: Region[]; selected?: number }[] = [];
  let selectionBefore: number | undefined;
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
      rect.setAttribute('class', `annotation-region${index === selected ? ' is-selected' : ''}`);
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
    if (selected !== undefined && regions[selected] && !sending) {
      // Keep the controls the same on-screen size at every preview scale.
      const bounds = screen.getBoundingClientRect();
      const width = 7 * frozen.width / Math.max(1, bounds.width);
      const height = 7 * frozen.height / Math.max(1, bounds.height);
      for (const handle of handles) {
        const point = handlePoint(regions[selected], handle);
        const rect = document.createElementNS(ns, 'rect');
        for (const [key, value] of Object.entries({ x: point.x * frozen.width - width / 2, y: point.y * frozen.height - height / 2, width, height, rx: width / 7 })) rect.setAttribute(key, String(value));
        rect.setAttribute('class', 'annotation-handle');
        rect.setAttribute('data-handle', handle);
        overlay.appendChild(rect);
      }
    }
    count.textContent = regions.length ? `已标注 ${regions.length} 处` : '拖动框选要讨论的区域';
    undo.disabled = sending || !!gesture || !history.length;
    remove.disabled = sending || !!gesture || selected === undefined;
    send.disabled = sending || !!gesture || !regions.length;
    cancel.disabled = sending;
    note.disabled = sending;
  }
  function begin(source: CanvasImageSource, size: {width:number;height:number}) {
    if (sending) return;
    const canvas = document.createElement('canvas'); canvas.width = size.width; canvas.height = size.height;
    const context = canvas.getContext('2d');
    if (!context || !canvas.width || !canvas.height) throw new Error('当前没有可标注的画面');
    context.drawImage(source, 0, 0, canvas.width, canvas.height);
    frozen = { source: canvas.toDataURL('image/png'), ...size };
    regions = []; history = []; selected = undefined; gesture = draft = undefined; note.value = ''; resizeNote();
    callbacks.freeze(frozen.source); editor.hidden = false; overlay.removeAttribute('hidden');
    hint.textContent = '空白处框选 · 框内拖动 · 边角缩放'; render(); callbacks.changed();
  }
  function end() {
    if (sending) return;
    frozen = undefined; regions = []; history = []; selected = undefined; gesture = draft = undefined;
    screen.style.cursor = '';
    overlay.replaceChildren(); editor.hidden = true; overlay.setAttribute('hidden', '');
    callbacks.resume(); callbacks.changed();
  }
  function hitTest(point: Point): Hit | undefined {
    const bounds = screen.getBoundingClientRect();
    const dx = 6 / Math.max(1, bounds.width), dy = 6 / Math.max(1, bounds.height);
    if (selected !== undefined && regions[selected]) {
      // Visible handles have priority over overlapping rectangles.
      const handle = handles.filter(handle => {
        const position = handlePoint(regions[selected!], handle);
        return Math.abs(point.x - position.x) <= dx && Math.abs(point.y - position.y) <= dy;
      }).sort((a, b) => {
        const p = handlePoint(regions[selected!], a), q = handlePoint(regions[selected!], b);
        return Math.hypot((point.x - p.x) / dx, (point.y - p.y) / dy) - Math.hypot((point.x - q.x) / dx, (point.y - q.y) / dy);
      })[0];
      if (handle) return { index: selected, handle };
    }
    for (let index = regions.length - 1; index >= 0; index--) {
      const region = regions[index];
      const right = region.x + region.width, bottom = region.y + region.height;
      if (point.x < region.x - dx || point.x > right + dx || point.y < region.y - dy || point.y > bottom + dy) continue;
      const horizontal = Math.abs(point.x - region.x) <= dx ? 'w' : Math.abs(point.x - right) <= dx ? 'e' : '';
      const vertical = Math.abs(point.y - region.y) <= dy ? 'n' : Math.abs(point.y - bottom) <= dy ? 's' : '';
      return { index, handle: (vertical + horizontal || undefined) as Handle | undefined };
    }
  }
  function pointerHover(point: Point) {
    if (!frozen) return;
    const hit = gesture?.target ?? hitTest(point);
    screen.style.cursor = sending ? 'wait' : gesture && !gesture.target ? 'crosshair' : hit?.handle ? `${hit.handle}-resize` : hit ? (gesture ? 'grabbing' : 'grab') : regions.length < 8 ? 'crosshair' : 'default';
  }
  function pointerDown(point: Point) {
    if (!frozen || sending) return;
    const target = hitTest(point);
    selectionBefore = selected;
    selected = target?.index;
    if (!target && regions.length >= 8) {
      callbacks.notify('最多标注 8 处，可移动、缩放或删除已有框'); render(); return;
    }
    gesture = { origin: point, before: copyRegions(regions), target }; draft = undefined;
    pointerHover(point); render();
  }
  function pointerMove(point: Point) {
    if (!gesture || !frozen) return;
    const { origin, target, before } = gesture;
    if (!target) draft = regionBetween(origin, point);
    else {
      const region = before[target.index], dx = point.x - origin.x, dy = point.y - origin.y;
      if (!dx && !dy) regions[target.index] = { ...region };
      else if (!target.handle) regions[target.index] = { ...region, x: clamp(region.x + dx, 0, 1 - region.width), y: clamp(region.y + dy, 0, 1 - region.height) };
      else {
        const bounds = screen.getBoundingClientRect();
        const minWidth = Math.min(region.width, 8 / Math.max(1, bounds.width));
        const minHeight = Math.min(region.height, 8 / Math.max(1, bounds.height));
        let left = region.x, top = region.y, right = left + region.width, bottom = top + region.height;
        if (target.handle.includes('w')) left = clamp(left + dx, 0, right - minWidth);
        if (target.handle.includes('e')) right = clamp(right + dx, left + minWidth, 1);
        if (target.handle.includes('n')) top = clamp(top + dy, 0, bottom - minHeight);
        if (target.handle.includes('s')) bottom = clamp(bottom + dy, top + minHeight, 1);
        regions[target.index] = { x: left, y: top, width: right - left, height: bottom - top };
      }
    }
    render();
  }
  function pointerUp(point: Point) {
    if (!gesture || !frozen) return;
    pointerMove(point);
    const before = gesture.before;
    const bounds = screen.getBoundingClientRect();
    if (draft && draft.width * bounds.width >= 8 && draft.height * bounds.height >= 8) { regions.push(draft); selected = regions.length - 1; }
    if (JSON.stringify(before) !== JSON.stringify(regions)) history.push({ regions: before, selected: selectionBefore });
    gesture = draft = undefined; pointerHover(point); render();
  }
  function pointerCancel() {
    if (gesture) { regions = gesture.before; selected = selectionBefore; }
    gesture = draft = undefined; screen.style.cursor = ''; render();
  }
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
    if (!frozen || !regions.length || sending || gesture) return;
    const frame = frozen;
    const capturedRegions = regions.map(region => ({ ...region }));
    draft = undefined;
    const caps = app.getHostCapabilities();
    if (!caps?.message || (!caps.message.image && !caps.updateModelContext?.image)) {
      callbacks.notify('当前宿主不支持发送截图标注，请在 Codex 插件面板打开。', true); return;
    }
    sending = true; render(); callbacks.changed(); hint.textContent = '正在发送截图和标注…';
    let messageRequested = false;
    try {
      const data = await annotatedImage(frame, capturedRegions);
      const text = note.value.trim() || '请查看截图中的标注区域。';
      const image = { type: 'image' as const, mimeType: 'image/png', data };
      if (!caps.message.image) await app.updateModelContext({ content: [image] });
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
  const undoClick = () => {
    if (sending || gesture) return;
    const previous = history.pop();
    if (previous) { regions = previous.regions; selected = previous.selected; render(); }
  };
  const deleteClick = () => {
    if (sending || gesture || selected === undefined) return;
    history.push({ regions: copyRegions(regions), selected });
    regions.splice(selected, 1); selected = undefined; render();
  };
  function resizeNote() { note.style.height = 'auto'; note.style.height = `${Math.min(72, Math.max(32, note.scrollHeight))}px`; }
  function noteKeyDown(event: KeyboardEvent) {
    if (event.key !== 'Enter' || (!event.metaKey && !event.ctrlKey) || event.isComposing) return;
    event.preventDefault();
    if (!event.repeat) void submit();
  }
  undo.addEventListener('click', undoClick); remove.addEventListener('click', deleteClick);
  cancel.addEventListener('click', end); send.addEventListener('click', submit); note.addEventListener('input', resizeNote);
  note.addEventListener('keydown', noteKeyDown);
  return { begin, end, pointerDown, pointerMove, pointerUp, pointerCancel, pointerHover, render,
    get active() { return !!frozen; }, get busy() { return sending; },
    dispose() { undo.removeEventListener('click',undoClick);remove.removeEventListener('click',deleteClick);cancel.removeEventListener('click',end);send.removeEventListener('click',submit);note.removeEventListener('input',resizeNote);note.removeEventListener('keydown',noteKeyDown); }
  };
}
