# Codex plugin / Codex 插件

Available in StupidMirror 0.6.0 (bundled plugin 0.2.7).

## Connect / 连接

1. Move StupidMirror to Applications and open it. Connect and unlock the phone.
2. For iPhone video over either USB or Wi-Fi, complete **Set Up This iPhone** over
   USB to prepare the signed screen agent. Video does not need Camera or Microphone
   permission. System touch on iOS 27+ needs Xcode, trust and Developer Mode;
   accessibility automation and compatibility control use the screen agent.
   Android needs authorized ADB.
3. In **Settings → MCP Automation**, click **Connect Codex**. No separate Python,
   Node.js, repository checkout, or token copy is needed for the installed app.
4. Open a new Codex chat, select StupidMirror, and ask: “Show my phone inside Codex
   without tapping anything.” The panel opens through `show_screen`.

将应用放入「应用程序」，连接并解锁手机。iOS 27 及以上版本的系统触控需要 Xcode、
信任配对和开发者模式。USB 和 Wi-Fi 画面都需先通过 USB 设置向导准备签名的屏幕组件，
画面本身不需要摄像头或麦克风权限；无障碍自动化与兼容控制也使用该组件。
在「设置 → MCP 自动化」点击「连接 Codex」，新建聊天并选中 StupidMirror，
发送：「在 Codex 里显示我的手机，先不要点击。」无需额外安装 Python / Node.js 或复制令牌。

## View, operate, annotate / 查看、操作、标注

- **View:** choose a device; pause/resume, refresh, return Home, or copy a screenshot.
  Home is a real device action and may require control setup.
- **操作:** explicitly enable control, then click, hold the left mouse button or
  drag. Right-click does not substitute for a long press. On iOS 27+
  over USB or Wi-Fi and supported iOS Simulators, the panel uses the same
  continuous single-finger touch backend as the native mirror: DOWN, MOVE and UP are
  sent as you act, including long presses and edge gestures. When system touch
  is unavailable, taps and swipes use compatibility control.
- **Trackpad gestures:** the native mirror streams scrolling, magnification and
  rotation events through the system gesture service when available, preserving
  gesture phases and scroll momentum. The browser panel shares the input backend,
  but DOM wheel events provide only fallback scroll increments; they do not carry
  the native trackpad event stream. On iOS, programmatic pinch and rotate requests with
  an explicit center still use WDA so that their target position is preserved.
- **Simulators:** booted iOS Simulators appear in the device picker. Duo's posture
  controls change the actual simulator hinge, and the panel follows its active
  screen. Xcode and a compatible simulator runtime are required.
- **标注:** freeze the current frame and draw up to eight numbered rectangles in
  empty space. Drag inside a box to move it, or use its edges and eight handles to
  resize. Delete the selected box or undo the last edit. The compact composer
  stays below the image and sends only the marked PNG and note to the current
  chat. Use Command-Enter or Control-Enter to send; plain Enter inserts a newline.
  Drawing sends no taps.
- **AI tools:** observe → act → observe. An annotation shows a frozen frame;
  always reobserve before acting if the page may have changed.

「操作」开启后才会向手机发送触控。在支持的 iOS 真机和模拟器上，按下、移动、抬起会
实时发送，长按、拖拽和边缘手势与原生镜像共用同一后端；长按需按住鼠标左键，右键不再
映射为长按。系统触控不可用时，点击与滑动走兼容控制。原生窗口的触控板滚动、缩放和
旋转会在系统手势服务可用时逐事件发送，并保留手势相位与滚动惯性。浏览器面板共用输入
后端，但 DOM 滚轮事件只能提供降级滚动增量，不能等同于完整的原生触控板事件。
iOS 上程序化指定中心点的缩放、旋转仍通过 WDA 执行，以保留目标位置。
Duo 姿态控件会调整模拟器的实际铰链角度，面板跟随当前亮屏。
「标注」会冻结当前画面，支持最多八个编号框。
空白处拖动新建，框内拖动移动，拖动边缘和角点缩放；支持删除选中框与撤销每次编辑。
输入栏位于画面下方，只把标注截图和说明发到当前聊天。⌘＋回车或 Ctrl＋回车发送，
普通回车换行；输入法选字期间不会误发送。标注期间不会误触手机。
发送失败保留草稿，不会自动重复提交；回到实时画面可继续查看手机。
发送请求最多等待十分钟，以便 Codex 在忙碌时排队接收；等待期间请勿重复提交。

## Compact observations / 精简观察

Screen observation includes an image and compact OCR by default. Element IDs,
text, normalized center hints and available native control state remain usable;
raw bounds and hierarchy are available with `response_format="full"`. Use
`include_image=false` for clearly text-only reads. The skill prefers direct
`tap_text`, targeted lookup and specific verification before a full-screen read.

默认观察仍带图片，OCR 和文字查找返回精简信息，保留可操作的元素 ID、文字、归一化中心
位置提示及可用的原生控件状态。`response_format="full"` 可获取完整边界和层级；明确
只读文字时可传 `include_image=false`。Skill 优先直接点击文字、定位单个目标和验证特定结果。

## Video and privacy / 视频与隐私

Both USB and Wi-Fi iPhone video use the signed screen agent's H.264/SRT stream.
On USB, choose **Phone** audio to leave sound on the iPhone, or **Mac** audio to
play it on this computer. Mac audio requires Camera and Microphone permissions
for the USB audio source; video itself requires neither. Wireless audio is not
available.

Hardware H.264 travels over encrypted local WebRTC. There is no cloud relay or
STUN/TURN service. Hosts unable to establish video fall back to native-resolution
PNG snapshots, which are less smooth. No separate native mirror window opens
unless requested. Image-message delivery depends on the host's MCP Apps features.

USB 和 Wi-Fi 的 iPhone 画面统一使用签名屏幕组件的 H.264/SRT 视频流。USB 连接时可选
「手机」声音，让声音保留在 iPhone 上；或选「Mac」在电脑播放。Mac 声音通道需要摄像头
和麦克风权限，以访问 USB 音频源；视频本身不需要这两项权限。无线方式暂不支持声音。

Codex 面板通过仅在本机传输的 WebRTC 接收画面；AI 请求的截图及主动发送的标注仍会交给 AI 客户端，受该客户端的数据
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
- No video: complete the iPhone setup guide for both USB and Wi-Fi video, and
  keep the phone connected and awake. Camera permission is not required for video.
- No USB audio on Mac: select Mac audio and grant Camera and Microphone permissions,
  or choose Phone audio to keep playback on the device.
- Cannot operate: wait for control setup, verify Xcode, trust and Developer Mode
  for system touch, or the signed runner for compatibility control, then re-enable
  操作. Viewing and control readiness are independent.
- Annotation unavailable: the host must support image user messages or image
  model-context updates plus text messages. Keep the draft and use a supported host.
- Annotation reports an unavailable composer: Codex rejected the message before
  submission. The image, regions and note remain in the panel. If the first
  annotation created a chat, open that chat and ask Codex to call `show_screen`
  again, then continue in the new panel. The original panel may still be bound
  to the pre-chat composer; waiting for the response to finish does not repair
  that binding. The plugin cannot rebind a host-owned conversation. The same
  recovery applies to “The widget conversation is not ready yet.”
  A timeout instead means delivery is unconfirmed: check the chat before retrying.
- Codex can queue messages when the panel has a valid chat/composer binding.
  The widget allows ten minutes for the host to acknowledge a send. This avoids
  the SDK's default one-minute timeout during a long reply, but does not repair
  an unavailable composer or guarantee delivery. No automatic replay is used.
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
