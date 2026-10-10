# Codex plugin / Codex 插件

Available in StupidMirror 0.3.1 (bundled plugin 0.2.1).

## Connect / 连接

1. Move StupidMirror to Applications and open it. Connect and unlock the phone.
2. For iPhone control or wireless video, complete **Set Up This iPhone** over USB.
   USB video alone needs trust and Camera permission. Android needs authorized ADB.
3. In **Settings → MCP Automation**, click **Connect Codex**. No separate Python,
   Node.js, repository checkout, or token copy is needed for the installed app.
4. Open a new Codex chat, select StupidMirror, and ask: “Show my phone inside Codex
   without tapping anything.” The panel opens through `show_screen`.

将应用放入「应用程序」，连接并解锁手机；首次 iPhone 控制或无线镜像先完成 USB
设置向导。在「设置 → MCP 自动化」点击「连接 Codex」，新建聊天并选中 StupidMirror，
发送：「在 Codex 里显示我的手机，先不要点击。」无需额外安装 Python / Node.js 或复制令牌。

## View, operate, annotate / 查看、操作、标注

- **View:** choose a device; pause/resume, refresh, return Home, or copy a screenshot.
  Home is a real device action and may require control setup.
- **操作:** explicitly enable control, then click to tap or drag to swipe. Device
  setup must finish first. This mode currently supports taps and drags; native
  mirror keyboard, long-press and multi-touch features remain separate.
- **标注:** freeze the current frame, draw up to eight numbered rectangles, add a
  note, and send it to the current chat. The payload includes a PNG, device ID,
  time, image dimensions, and normalized/pixel regions. Drawing sends no taps.
- **AI tools:** observe → act → observe. Annotation coordinates belong to an older
  frozen frame; always reobserve before acting if the page may have changed.

「操作」开启后才会向手机发送点击或拖动。「标注」会冻结当前画面，支持最多八个编号框、
撤销和文字说明；点击发送后，截图及设备、时间、坐标进入当前聊天。标注期间不会误触手机。
发送失败保留草稿，不会自动重复提交；回到实时画面可继续查看手机。

## Video and privacy / 视频与隐私

Hardware H.264 travels over encrypted local WebRTC. There is no cloud relay or
STUN/TURN service. Hosts unable to establish video fall back to native-resolution
PNG snapshots, which are less smooth. No separate native mirror window opens
unless requested. Image-message delivery depends on the host's MCP Apps features.

WebRTC 只在本机传输；AI 请求的截图及主动发送的标注仍会交给 AI 客户端，受该客户端的数据
设置约束。不要将连接凭据文件放入聊天或分享给他人。详见 [Privacy](../PRIVACY.md)。

## Troubleshooting / 排障

- No tools: reconnect the plugin and select it in a new Codex chat. After an
  app update, use **Connect Codex / Update or reinstall plugin** again.
- Initialization fails with `-32603` and “data isn’t in the correct format”: older
  builds reject object-valued experimental client capabilities. Update to StupidMirror 0.3.1 or later
  and reconnect the plugin; restarting Codex does not fix this decoding error.
  The compatibility fix covers both the plugin's stdio helper and direct Streamable
  HTTP connections, while preserving authentication and normal tool traffic.
- No device: unlock it, check cable/trust or ADB authorization, and refresh.
- No video: grant the app Camera permission for USB iPhone; complete the iPhone
  setup guide for wireless video. Keep the phone connected and awake.
- Cannot operate: wait for control setup, verify Developer Mode and the signed
  runner, then re-enable 操作. Viewing and control readiness are independent.
- Annotation unavailable: the host must support image user messages or image
  model-context updates plus text messages. Keep the draft and use a supported host.
- A manual MCP entry conflicts: the installer only migrates a matching local
  StupidMirror endpoint. Resolve other entries explicitly rather than overwriting them.

## Validation boundary / 验证范围

The release preparation verified tool/resource discovery through the Codex
app-server, widget and native tests, and a local MCP Apps SDK host with a real
iPhone at 1260 × 2736 and sampled 26–27 fps. This is a sample, not a performance
guarantee. Formal Codex-panel rendering, annotation arrival in a real chat, and
end-to-end manual gestures still require host/device acceptance before publication.
