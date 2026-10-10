import type { App } from '@modelcontextprotocol/ext-apps';

type Size = { width: number; height: number };
type Answer = { type?: RTCSdpType; sdp?: string; peer_id?: string; error?: { message?: string } };
export function createVideo(app: App, video: HTMLVideoElement, callbacks: {
  ready: (size: Size) => void; stopped: () => void; fps: (value: number) => void;
}) {
  let connection: RTCPeerConnection | undefined;
  let peerId: string | undefined;
  let target: string | undefined;
  let generation = 0;
  let active = false;
  let pending = false;
  let retryAfter = 0;
  let frameCallback: number | undefined;
  let fpsStarted = 0, rendered = 0;
  const available = typeof RTCPeerConnection !== 'undefined';

  function finishPeer(id: string) {
    void app.callServerTool({ name: 'screen_signal', arguments: { action: 'close', peer_id: id } }, { timeout: 3000 }).catch(() => {});
  }
  function close() {
    generation++;
    if (frameCallback !== undefined) video.cancelVideoFrameCallback?.(frameCallback);
    frameCallback = undefined;
    const old = connection; connection = undefined;
    old?.close();
    if (peerId) finishPeer(peerId);
    peerId = target = undefined; active = pending = false;
    video.srcObject = null; video.hidden = true;
  }
  function countFrame(now: number) {
    if (!active) return;
    rendered++;
    if (now - fpsStarted >= 1000) {
      callbacks.fps(Math.round(rendered * 1000 / (now - fpsStarted)));
      fpsStarted = now; rendered = 0;
    }
    const size = { width: video.videoWidth, height: video.videoHeight };
    if (size.width && size.height) callbacks.ready(size);
    frameCallback = video.requestVideoFrameCallback?.(countFrame);
  }
  async function connect(deviceId: string) {
    if (!available || pending || (target === deviceId && connection) || performance.now() < retryAfter) return;
    close(); target = deviceId; pending = true;
    const ownGeneration = generation;
    const peer = new RTCPeerConnection({ iceServers: [] });
    connection = peer;
    peer.addTransceiver('video', { direction: 'recvonly' });
    peer.ontrack = event => {
      if (generation !== ownGeneration) return;
      video.srcObject = event.streams[0] ?? new MediaStream([event.track]);
      void video.play().catch(() => {});
    };
    video.onloadeddata = () => {
      if (generation !== ownGeneration || !video.videoWidth) return;
      active = true; pending = false; retryAfter = 0;
      callbacks.ready({ width: video.videoWidth, height: video.videoHeight });
      fpsStarted = performance.now(); rendered = 0;
      if (frameCallback !== undefined) video.cancelVideoFrameCallback?.(frameCallback);
      frameCallback = video.requestVideoFrameCallback?.(countFrame);
    };
    peer.onconnectionstatechange = () => {
      if (generation !== ownGeneration) return;
      if (['failed', 'disconnected', 'closed'].includes(peer.connectionState)) {
        close(); retryAfter = performance.now() + 3000; callbacks.stopped();
      }
    };
    try {
      await peer.setLocalDescription(await peer.createOffer());
      await new Promise<void>((resolve, reject) => {
        if (peer.iceGatheringState === 'complete') { resolve(); return; }
        const timer = setTimeout(() => { cleanup(); reject(new Error('ICE gathering timed out')); }, 6000);
        const changed = () => { if (peer.iceGatheringState === 'complete') { cleanup(); resolve(); } };
        const cleanup = () => { clearTimeout(timer); peer.removeEventListener('icegatheringstatechange', changed); };
        peer.addEventListener('icegatheringstatechange', changed);
      });
      if (generation !== ownGeneration) return;
      const result = await app.callServerTool({ name: 'screen_signal', arguments: { action: 'offer', device_id: deviceId, sdp: peer.localDescription!.sdp } }, { timeout: 15000 });
      const answer = result.structuredContent as Answer;
      if (generation !== ownGeneration) { if (answer?.peer_id) finishPeer(answer.peer_id); return; }
      if (result.isError || !answer?.sdp || !answer.peer_id) throw new Error(answer?.error?.message ?? 'Video connection failed');
      peerId = answer.peer_id;
      await peer.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
      // A completed signaling exchange is not proof that a frame was decoded.
      setTimeout(() => {
        if (generation === ownGeneration && !active) { close(); retryAfter = performance.now() + 5000; callbacks.stopped(); }
      }, 8000);
    } catch {
      if (generation === ownGeneration) { close(); retryAfter = performance.now() + 5000; callbacks.stopped(); }
    }
  }
  return { available, connect, close, get active() { return active; }, get pending() { return pending; } };
}
