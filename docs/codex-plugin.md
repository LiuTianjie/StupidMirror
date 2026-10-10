# Codex plugin / Codex 插件

Available in StupidMirror 0.3.4 (bundled plugin 0.2.3).

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
- **标注:** freeze the current frame and draw up to eight numbered rectangles in
  empty space. Drag inside a box to move it, or use its edges and eight handles to
  resize. Delete the selected box or undo the last edit. The compact composer
  stays below the image and sends only the marked PNG and note to the current
  chat. Use Command-Enter or Control-Enter to send; plain Enter inserts a newline.
  Drawing sends no taps.
- **AI tools:** observe → act → observe. An annotation shows a frozen frame;
  always reobserve before acting if the page may have changed.

「操作」开启后才会向手机发送点击或拖动。「标注」会冻结当前画面，支持最多八个编号框。
空白处拖动新建，框内拖动移动，拖动边缘和角点缩放；支持删除选中框与撤销每次编辑。
输入栏位于画面下方，只把标注截图和说明发到当前聊天。⌘＋回车或 Ctrl＋回车发送，
普通回车换行；输入法选字期间不会误发送。标注期间不会误触手机。
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
- Annotation reports an unavailable composer: Codex rejected the message before
  submission. The image, regions and note remain in the panel. Return to the
  target chat and retry; if it still fails, reopen StupidMirror from that chat.
  A timeout instead means delivery is unconfirmed: check the chat before retrying.
- A manual MCP entry conflicts: the installer only migrates a matching local
  StupidMirror endpoint. Resolve other entries explicitly rather than overwriting them.

## Validation boundary / 验证范围

The release preparation verified tool/resource discovery through the Codex
app-server, widget and native tests, and a local MCP Apps SDK host with a real
iPhone at 1260 × 2736 and sampled 26–27 fps. This is a sample, not a performance
guarantee. On 2026-10-10, the installed 0.3.1 app / 0.2.1 plugin also passed
real Codex acceptance in a fresh chat: the iPhone panel rendered, two consecutive
annotated images and notes arrived, and authorized device navigation and text
input succeeded. The 0.3.2 changes add error classification and preservation;
widget tests cover those paths. This does not prove that reopening repairs a
host-owned composer binding in an older chat, or validate every manual gesture.

The 0.3.4 annotation changes passed local browser interaction checks at narrow,
wide and short viewport sizes, plus widget regression tests. These checks used
a local host fixture; they do not establish real Codex delivery for this version.
