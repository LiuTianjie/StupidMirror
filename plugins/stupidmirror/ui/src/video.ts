import type { App } from '@modelcontextprotocol/ext-apps';
import { createTouchSender, type TouchMessage } from './touch';

type Size = { width: number; height: number };
type Answer = { type?: RTCSdpType; sdp?: string; peer_id?: string; error?: { message?: string } };
export function createVideo(app: App, video: HTMLVideoElement, callbacks: {
  ready: (size: Size) => void; stopped: (reason: string, retrying: boolean) => void; fps: (value: number) => void;
  touchStopped?: (reason: string) => void;
}) {
  let connection: RTCPeerConnection | undefined;
  let peerId: string | undefined;
  let target: string | undefined;
  let generation = 0;
  let active = false;
  let pending = false;
  let retryAfter = 0;
  let failures = 0;
  let request: AbortController | undefined;
  let firstFrameTimer: ReturnType<typeof setTimeout> | undefined;
  let disconnectTimer: ReturnType<typeof setTimeout> | undefined;
  let frameCallback: number | undefined;
  let fpsStarted = 0, rendered = 0;
  const available = typeof RTCPeerConnection !== 'undefined';
  const touch = createTouchSender(reason => callbacks.touchStopped?.(reason));

  function finishPeer(id: string) {
    void app.callServerTool({ name: 'screen_signal', arguments: { action: 'close', peer_id: id } }, { timeout: 3000 }).catch(() => {});
  }
  function close() {
    touch.close();
    generation++;
    request?.abort(); request = undefined;
    clearTimeout(firstFrameTimer); firstFrameTimer = undefined;
    clearTimeout(disconnectTimer); disconnectTimer = undefined;
    if (frameCallback !== undefined) video.cancelVideoFrameCallback?.(frameCallback);
    frameCallback = undefined;
    const old = connection; connection = undefined;
    old?.close();
    if (peerId) finishPeer(peerId);
    peerId = target = undefined; active = pending = false;
    video.onloadeddata = null; video.srcObject = null; video.hidden = true;
  }
  function retry() { close(); failures = 0; retryAfter = 0; }
  function fail(reason: string) {
    close(); failures++;
    retryAfter = performance.now() + Math.min(3000, failures * 1000);
    callbacks.stopped(reason, failures < 3);
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
    if (!available || pending || failures >= 3 || (target === deviceId && connection) || performance.now() < retryAfter) return;
    close(); target = deviceId; pending = true;
    const ownGeneration = generation;
    let stage = '视频初始化';
    try {
      const peer = new RTCPeerConnection({ iceServers: [] });
      connection = peer;
      const controller = new AbortController(); request = controller;
      peer.addTransceiver('video', { direction: 'recvonly' });
      touch.attach(peer.createDataChannel('stupidmirror-touch', { ordered: true }));
      peer.ontrack = event => {
        if (generation !== ownGeneration) return;
        video.srcObject = event.streams[0] ?? new MediaStream([event.track]);
        void video.play().catch(error => { if (generation === ownGeneration) fail(`视频播放失败：${error.message}`); });
      };
      video.onloadeddata = () => {
        if (generation !== ownGeneration || !video.videoWidth) return;
        clearTimeout(firstFrameTimer); firstFrameTimer = undefined;
        active = true; pending = false; retryAfter = 0; failures = 0;
        callbacks.ready({ width: video.videoWidth, height: video.videoHeight });
        fpsStarted = performance.now(); rendered = 0;
        if (frameCallback !== undefined) video.cancelVideoFrameCallback?.(frameCallback);
        frameCallback = video.requestVideoFrameCallback?.(countFrame);
      };
      peer.onconnectionstatechange = () => {
        if (generation !== ownGeneration) return;
        clearTimeout(disconnectTimer); disconnectTimer = undefined;
        if (peer.connectionState === 'failed') fail('本机视频连接失败');
        // ICE can briefly disconnect when a panel or network interface changes.
        // Give the existing connection time to recover before replacing it.
        else if (peer.connectionState === 'disconnected') disconnectTimer = setTimeout(() => {
          if (generation === ownGeneration && peer.connectionState === 'disconnected') fail('本机视频连接已断开');
        }, 3000);
      };
      stage = '本机连接协商';
      await peer.setLocalDescription(await peer.createOffer());
      await new Promise<void>((resolve, reject) => {
        if (peer.iceGatheringState === 'complete') { resolve(); return; }
        const timer = setTimeout(() => { cleanup(); reject(new Error('ICE gathering timed out')); }, 6000);
        const changed = () => { if (peer.iceGatheringState === 'complete') { cleanup(); resolve(); } };
        const aborted = () => { cleanup(); reject(new Error('Cancelled')); };
        const cleanup = () => { clearTimeout(timer); peer.removeEventListener('icegatheringstatechange', changed); controller.signal.removeEventListener('abort', aborted); };
        peer.addEventListener('icegatheringstatechange', changed);
        controller.signal.addEventListener('abort', aborted, { once: true });
      });
      if (generation !== ownGeneration) return;
      stage = '视频信令';
      const result = await app.callServerTool({ name: 'screen_signal', arguments: { action: 'offer', device_id: deviceId, sdp: peer.localDescription!.sdp } }, { timeout: 15000, signal: controller.signal });
      const answer = result.structuredContent as Answer;
      if (generation !== ownGeneration) { if (answer?.peer_id) finishPeer(answer.peer_id); return; }
      if (result.isError || !answer?.sdp || !answer.peer_id) throw new Error(answer?.error?.message ?? 'Video connection failed');
      peerId = answer.peer_id;
      await peer.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
      // Signaling/ICE success is not proof that a frame was decoded.
      firstFrameTimer = setTimeout(() => {
        if (generation === ownGeneration && !active) fail(`视频首帧超时（${peer.connectionState}）`);
      }, 8000);
    } catch (error) {
      if (generation === ownGeneration) fail(`${stage}失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return { available, connect, close, retry, sendTouch: (message: TouchMessage) => touch.send(message),
    get touchReady() { return touch.ready; }, get active() { return active; }, get pending() { return pending; } };
}
