export type TouchPhase = 'down' | 'move' | 'up' | 'cancel';
export type TouchMessage = {
  type: 'touch'; phase: TouchPhase; gesture_id: string; seq: number;
  x: number; y: number; geometry_id?: string;
  // Semantic browser wheel input, never raw HID bytes or a service identifier.
  scroll?: { delta_x: number; delta_y: number };
};

// Bound pressure before SCTP as well as in the helper. Once down is sent this
// gesture belongs to this channel; a failed stream must never be replayed.
export function createTouchSender(failed: (message: string) => void) {
  let channel: RTCDataChannel | undefined;
  let ready = false;
  let queue: TouchMessage[] = [];
  let timer: ReturnType<typeof setTimeout> | undefined;
  const highWater = 16 * 1024;

  function clear() { queue = []; clearTimeout(timer); timer = undefined; }
  function disconnect(message?: string) {
    const old = channel; channel = undefined; ready = false; clear();
    if (old) { old.onopen = old.onclose = old.onerror = old.onmessage = old.onbufferedamountlow = null; old.close(); }
    if (message) failed(message);
  }
  function flush() {
    if (!ready || channel?.readyState !== 'open') return;
    try {
      while (queue.length && channel.bufferedAmount <= highWater) channel.send(JSON.stringify(queue.shift()!));
    } catch { disconnect('触控连接已断开，请重新操作'); return; }
    if (!queue.length) { clearTimeout(timer); timer = undefined; }
    else if (!timer) timer = setTimeout(() => disconnect('触控连接拥塞，已释放当前手势'), 1500);
  }
  function attach(value: RTCDataChannel) {
    disconnect(); channel = value;
    value.bufferedAmountLowThreshold = highWater / 2;
    value.onbufferedamountlow = flush;
    value.onclose = () => { if (channel === value) disconnect('触控连接已断开'); };
    value.onerror = () => { if (channel === value) disconnect('触控连接失败'); };
    value.onmessage = event => {
      if (channel !== value || typeof event.data !== 'string' || event.data.length > 4096) return;
      try {
        const status = JSON.parse(event.data);
        if (status.type === 'status') ready = status.ready === true;
        if (status.type === 'ack' && status.accepted === false) disconnect(typeof status.error === 'string' ? status.error : '触控被拒绝，请重新连接');
      } catch { disconnect('触控连接返回无效响应'); }
    };
  }
  function send(message: TouchMessage): boolean {
    if (!ready || channel?.readyState !== 'open') {
      if (channel) disconnect('触控连接已断开，请重新操作');
      return false;
    }
    const last = queue.at(-1);
    if (!message.scroll && !last?.scroll && message.phase === 'move' && last?.phase === 'move' && last.gesture_id === message.gesture_id) queue[queue.length - 1] = message;
    else queue.push(message);
    if (queue.length > 32) { disconnect('触控连接拥塞，已释放当前手势'); return false; }
    flush();
    return channel !== undefined;
  }
  return { attach, send, close: () => disconnect(), get ready() { return ready && channel?.readyState === 'open'; } };
}
