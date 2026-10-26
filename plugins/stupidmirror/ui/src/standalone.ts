import type { App } from '@modelcontextprotocol/ext-apps';

// The app serves this same widget at /viewer for hosts that cannot render MCP
// Apps (Claude Code's Browser pane). There it talks to the app over plain
// fetch instead of a host bridge. Only the subset of App the widget uses is
// provided; host-only features such as sending annotations are absent.

type ToolResult = { content?: unknown[]; structuredContent?: unknown; isError?: boolean };
type ToolCall = { name: string; arguments?: Record<string, unknown> };
type CallOptions = { timeout?: number; signal?: AbortSignal };
type Saved = { session: string; device_id?: string };

const SESSION_KEY = 'stupidmirror.viewer';
const HEADER = 'X-StupidMirror-Viewer';
const INITIAL_TIMEOUT = 240000;

/** The link cannot be repaired from this page; only a new link from the agent can. */
export class ViewerLinkError extends Error {}

export function isStandaloneViewer() {
  return !!globalThis.document?.querySelector?.('meta[name="stupidmirror-viewer"]');
}

async function post(path: string, body: unknown, headers: Record<string, string>, options: CallOptions = {}) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  options.signal?.addEventListener('abort', abort, { once: true });
  const timer = options.timeout ? setTimeout(abort, options.timeout) : undefined;
  try {
    return await fetch(path, {
      method: 'POST', headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify(body), signal: controller.signal, cache: 'no-store', credentials: 'omit',
    });
  } catch (error) {
    if (controller.signal.aborted && !options.signal?.aborted) throw new Error('请求超时');
    throw error;
  } finally {
    clearTimeout(timer);
    options.signal?.removeEventListener('abort', abort);
  }
}

function load(): Saved | undefined {
  try {
    const saved = JSON.parse(sessionStorage.getItem(SESSION_KEY) ?? 'null') as Saved | null;
    return typeof saved?.session === 'string' ? saved : undefined;
  } catch { return undefined; }
}

export function createStandaloneHost(): App {
  let saved: Saved | undefined;
  let opened = false;
  const host = {
    ontoolresult: undefined as ((result: ToolResult) => void) | undefined,
    onhostcontextchanged: undefined as unknown,
    onteardown: undefined as unknown,
    onclose: undefined as unknown,
    async connect() {
      if (saved) return;
      const ticket = new URLSearchParams(location.hash.slice(1)).get('ticket');
      if (ticket) {
        // Drop the single-use ticket from the address bar and history first.
        history.replaceState(null, '', location.pathname + location.search);
        const response = await post('/viewer/api/session', { ticket }, {}, { timeout: 5000 });
        if (response.status === 401) throw new ViewerLinkError('这个查看链接已使用或已过期');
        if (!response.ok) throw new Error(`查看器连接失败（${response.status}）`);
        saved = await response.json() as Saved;
        // Survives reloads of this tab only; closing the tab ends access.
        sessionStorage.setItem(SESSION_KEY, JSON.stringify(saved));
      } else {
        saved = load();
        if (!saved) throw new ViewerLinkError('请通过 Claude 提供的链接打开手机画面');
      }
      if (!opened) {
        opened = true;
        // Hosts deliver show_screen's result to the panel; do the same here.
        const args = saved.device_id ? { device_id: saved.device_id } : {};
        void host.callServerTool({ name: 'show_screen', arguments: args }, { timeout: INITIAL_TIMEOUT })
          .then(result => host.ontoolresult?.(result)).catch(() => {});
      }
    },
    async close() {},
    getHostContext() { return {}; },
    getHostCapabilities() { return {}; },
    async requestDisplayMode() { return { mode: 'inline' }; },
    async updateModelContext(): Promise<never> { throw new Error('没有可接收标注的聊天'); },
    async sendMessage(): Promise<never> { throw new Error('没有可接收标注的聊天'); },
    async callServerTool(params: ToolCall, options?: CallOptions): Promise<ToolResult> {
      if (!saved) throw new ViewerLinkError('请通过 Claude 提供的链接打开手机画面');
      const response = await post('/viewer/api/call', params, { [HEADER]: saved.session }, options);
      if (response.status === 401) {
        saved = undefined;
        sessionStorage.removeItem(SESSION_KEY);
        throw new ViewerLinkError('查看会话已结束');
      }
      if (!response.ok) {
        const body = await response.json().catch(() => undefined) as { error?: { message?: string } } | undefined;
        throw new Error(body?.error?.message ?? `请求失败（${response.status}）`);
      }
      return await response.json() as ToolResult;
    },
  };
  return host as unknown as App;
}
