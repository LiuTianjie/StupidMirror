<p align="center">
  <img src="docs/assets/app-icon.webp" alt="StupidMirror" width="96" />
</p>

<h1 align="center">StupidMirror</h1>

<p align="center">
  <strong>把手机带到 Mac，把真机交给 Agent。</strong><br />
  把真实的 iPhone / Android 屏幕带进 Codex，让 AI Agent 看屏幕、操作手机、验证结果。
</p>

<p align="center">
  <a href="#支持-codex"><img src="https://img.shields.io/badge/Codex-supported-10a37f?style=flat-square" alt="支持 Codex" /></a>
  <a href="Package.swift"><img src="https://img.shields.io/badge/macOS-15%2B-343b48?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 15 及以上" /></a>
  <a href="https://github.com/LiuTianjie/StupidMirror/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/LiuTianjie/StupidMirror/ci.yml?style=flat-square&amp;label=build" alt="构建状态" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-64748b?style=flat-square" alt="PolyForm Noncommercial 许可证" /></a>
</p>

<p align="center">
  <a href="https://github.com/LiuTianjie/StupidMirror/releases/latest">下载</a> ·
  <a href="https://stupidmirror.itool.tech/">官网</a> ·
  <a href="#支持-codex">Codex 支持</a> ·
  <a href="#连接-ai-agent">MCP 接入</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <img src="docs/assets/dashboard.webp" alt="StupidMirror macOS 界面：已连接的 iPhone、实时镜像与真机控制入口" width="820" />
</p>

StupidMirror 将真实的移动设备接入原生 macOS 工作台。通过 USB 或 Wi-Fi 查看 iPhone，通过 ADB 镜像 Android，再按需连接控制，在 Mac 上操作手机。

同一个工作台也可以通过 **MCP** 交给 AI Agent：观察当前画面，用本地 OCR 或原生无障碍信息定位目标，执行操作，再检查结果。通过内置插件，可直接在 Codex 中查看手机实时画面，也可以使用原生 Mac 镜像窗口。

**无需登录，即可镜像和控制一台设备。** 输入 SM- 激活码后可同时连接多台设备，无需登录。源码采用 PolyForm Noncommercial 许可证，商业用途需要单独授权，详见[许可证说明](#许可证)。

## 支持 Codex

**StupidMirror 内置 Codex 插件，让 Codex 直接观察和操作真实的 iPhone / Android，并把手机实时画面显示在聊天中的插件面板里。** 你可以让它检查移动端界面、走一遍 App 流程、复现问题，并在连接的真机上验证修改结果。

- **在 Codex 里看手机。** 通过本机 WebRTC 显示实时画面，支持切换设备、暂停/继续和复制截图。
- **用自然语言操作并验证。** 让 Codex 通过 MCP 读取页面、定位控件、点击、滑动和输入，再观察手机上的实际结果。
- **框出问题，交给 Codex。** 冻结当前画面、框选区域并附上说明，在支持图片消息的宿主中发送标注截图；也可以开启手动操作，直接点按或拖动预览画面。

安装 StupidMirror 并完成[设备准备](#从一台设备开始)后，点击 **设置 → MCP 自动化 → 接入 Codex**，再在 Codex 新建聊天、选择 **StupidMirror** 插件，发送：

> 用 StupidMirror 在 Codex 中显示我的手机屏幕，并读取当前页面，先不要点击。

应用会通过 Codex 桌面端内置的 CLI 安装随附插件，无需克隆仓库、额外安装 Python / Node.js 或复制 Token。完整步骤见 [Codex 接入说明](#codex-插件从应用内一键接入)，操作方式与排障见 [Codex 插件指南](docs/codex-plugin.md)。

## 核心能力

- **原生设备工作台。** 使用 SwiftUI 与 AppKit 构建，提供菜单栏入口、设备面板、实时缩略图与独立镜像窗口。
- **真机与模拟器。** USB iPhone 使用 AVFoundation；无线 iPhone 通过局域网传输 H.264；Android 使用固定版本的 scrcpy server 传输画面与声音；本机启动的 iOS 模拟器和 Android 模拟器同样可用。
- **按需连接真机控制。** iPhone 直接连接 WDA，Android 通过 Appium / UiAutomator2，实现点击、滑动、输入、按键和 App 启停。打开 USB 或 Android 镜像不会自动建立控制会话。
- **Agent 可以观察操作对象。** 实时帧、Apple Vision OCR、按需无障碍树、语义定位、等待与断言都围绕同一台真机工作。
- **自动化过程可见。** Agent 的点击、滑动路径和目标高亮显示在 Mac 镜像上，不改变手机画面，也不写入编码后的视频。
- **接入已有 AI 客户端。** 内置 Codex 与 Claude Code 配置向导；StupidMirror 本身无需模型 API Key，也不内置模型。

## 从一台设备开始

从 [GitHub Releases](https://github.com/LiuTianjie/StupidMirror/releases/latest) 下载 macOS 应用，移入 Applications 后打开。StupidMirror 以菜单栏工具的形式运行，窗口打开时也会显示在 Dock 中。从 0.3.7 起应用会自行检查签名更新（菜单栏或设置中的“检查更新…”）；“开机时自动启动”位于设置 > 启动与更新。

| 连接方式 | 准备工作 | 画面与声音 |
| --- | --- | --- |
| **iPhone · USB** | 信任当前 Mac；按提示授予相机权限 | AVFoundation 捕获；可选将设备声音播放到 Mac |
| **iPhone · Wi-Fi** | 通过 USB 完成一次“设置这台 iPhone”（会在手机上开启 Wi‑Fi 连接）；两端保持同一局域网 | H.264 / SRT 经 CoreDevice 隧道传输，VideoToolbox 解码；暂不支持无线音频 |
| **Android · ADB** | Android 11+；Mac 安装 Android SDK Platform-Tools；开启 USB 调试并授权当前 Mac | scrcpy 提供 H.264 画面与可选设备音频 |
| **iOS 模拟器** | 安装 Xcode；启动模拟器 | 首次为模拟器构建屏幕代理（无需签名）并传输画面；所有端口只监听本机 |
| **Android 模拟器** | 同 Android · ADB；启动模拟器 | 同 Android · ADB；按 AVD 名称显示 |

模拟器启动后会自动出现在设备列表中，与真机一样计入同时使用的设备数。模拟器不会被自动镜像，正在跑 UI 测试的模拟器在你主动打开之前不受影响。

**需要 macOS 15 或更高版本。** 兼容性受系统版本、信任状态和自动化运行时影响，项目仍处于实验阶段。

### USB 连接 iPhone

1. 连接并解锁 iPhone，接受“信任此电脑”。
2. 打开 StupidMirror，通过应用中的权限按钮授予相机访问权限。
3. 选择发现的设备并打开镜像。

macOS 将 iPhone 屏幕暴露为 AVFoundation 捕获源，因此需要相机权限；这个权限用于读取手机屏幕，并非调用 Mac 摄像头。默认关闭**在 Mac 上播放设备声音**，声音保留在 iPhone。开启后，USB 设备音频会转到 Mac，并需要额外授予麦克风权限。

### Wi-Fi 连接 iPhone

保持 USB 连接，打开**设置这台 iPhone**。向导会检查设备和 Apple Development 签名身份，构建并安装屏幕 Runner，试启动一次，然后在手机上开启 Wi‑Fi 连接（与 Xcode 的“通过网络连接”是同一个开关），之后再拔线。

后续会话由内置的 `smtunnel` 侧车连接手机：它在局域网上用进程内网络协议栈建立 Apple 的 CoreDevice 隧道，并通过 testmanagerd 启动 Runner，不依赖 Xcode 的启动器，不需要管理员密码、本地网络授权或在手机上点任何东西。无线镜像无需相机权限或 ReplayKit Broadcast Extension，但需要这个签名后的设备端 Runner 和手机上的开发者模式；准备无线画面不会自动连接控制。

应用也按同一路径发现手机：只要 usbmuxd 在局域网上列出这台 iPhone，它就显示为已连接，可直接在应用里或通过 MCP 开始镜像。无线镜像或控制进行中插上数据线，当前会话会继续走 Wi‑Fi。

### 连接 Android

安装 `adb`，开启 USB 调试，连接设备并在手机上授权当前 Mac，然后选择发现的设备开始镜像。画面与音频独立运行，不依赖可选的 Appium 控制连接。

## 真机控制

点击**连接控制**开始操作。

| 平台 | 控制后端 | 首次连接 |
| --- | --- | --- |
| iOS | 经 `smtunnel` 隧道直连 WebDriverAgent（USB 与 Wi‑Fi 同一条路径） | 在 iPhone 设置向导中用 USB 准备一次：信任 Mac、开启开发者模式、用 Apple Development 身份签名并安装屏幕代理 |
| Android | Appium + UiAutomator2（发布包内置 Node / Appium 运行时） | 按需安装 Appium settings / server 辅助 APK |

镜像上的手势会尽量还原鼠标的动作：慢速拖动按记录的路径与节奏回放，快速拨动保留起点、方向和速度，由手机自然惯性滑动；按住不动是长按（右键也是），双击是双击，鼠标滚轮和触控板都能滚动，触控板捏合与旋转对应手机上的捏合与旋转，返回是系统的边缘滑动。iPhone 上的触控通过代理中的 StupidMirror 专用接口直接交给 XCTest 事件合成，省去 WebDriverAgent 每次查询前台 App 的开销；0.4.0 之前准备过的手机会自动退回原有接口，用 USB 连接后在 iPhone 设置中点一次“重新准备”即可启用。XCTest 只能在鼠标抬起后整体回放一个手势，所以按住期间“手指跟随”目前做不到。“诊断”里可以看到每台设备最近手势的往返耗时。界面默认跟随系统浅色/深色，也可以在“设置 → 界面”或菜单栏中固定。高级设置允许为 Android 配置自定义 Appium 地址，默认是 `http://127.0.0.1:4723`。

## 连接 AI Agent

### Codex 插件：从应用内一键接入

1. 将包含 Codex 插件的新构建安装到 Applications，打开 StupidMirror。首次使用 iPhone，先通过 USB 连接并完成应用内的 **iPhone 连接引导**；Android 需开启 USB 调试并授权此 Mac。
2. 打开 **设置 → MCP 自动化**，点击 **接入 Codex**。应用会启用本地 MCP、安装随 App 附带的插件，并复用 Codex / ChatGPT 桌面端内置的 CLI；无需克隆仓库、安装 Python / Node.js 或复制 Token。
3. 在 Codex 新建聊天，选择 **StupidMirror** 插件，发送：

   > 用 StupidMirror 在 Codex 中显示我的手机屏幕，并读取当前页面，先不要点击。

4. Codex 会按需在后台启动 StupidMirror。实时手机画面通过本机 WebRTC 直接显示在 Codex 插件面板内，支持选择设备、刷新、暂停/继续、返回主屏幕和复制截图；不会自动打开原生镜像窗口。保持手机已连接并解锁。

**直接操作和标注：** 点击预览工具栏的 **操作**，控制连接就绪后可点按、拖动手机画面；AI 仍可通过 MCP 点击、滑动、输入和读取页面。点击 **标注** 会冻结当前画面：空白处拖动框选，框内拖动移动，拖动边缘或角点缩放，支持删除和撤销。细输入栏位于画面下方，只发送标注截图和说明；**⌘＋回车**（或 **Ctrl＋回车**）发送，普通回车换行。标注模式不会把拖动发送给手机。

视频在本机通过加密 WebRTC 传输，不使用云端中转。宿主没有 WebRTC API 时使用原分辨率 PNG；WebRTC 连接失败会显示原因和重试按钮，不会悄悄改用截图轮询；正式聊天的标注发送取决于宿主的图片消息能力。

安装失败时页面会显示原因，可处理后重试。工具未加载时，重新连接插件或新建聊天。StupidMirror 0.3.1 修复了扩展能力字段导致的 `-32603` 初始化错误；旧版遇到此错误时，重启 Codex 无法解决。嵌入面板统一显示为 **StupidMirror**。**插件安装成功、设备已发现、真机可操作是三个不同状态**：依次用 `list_devices`、`observe_screen` 和一次授权操作后的观察确认。

更新 App 后再次点击 **更新或重新安装插件**（重新打开设置时显示 **接入 Codex**）即可刷新安装副本。支持插件的 Codex CLI 也可使用 `bash scripts/install-codex-plugin.sh` 安装；开发者先运行 `bash scripts/build-app.sh` 并安装生成的 App。

插件复用同一个设备引擎，不单独启动 WDA。端口和 Token 轮换自动读取；应用启用 MCP 时将连接信息写入当前用户的 `~/Library/Application Support/StupidMirror/MCP/connection.json`（目录 `0700`、文件 `0600`），停止服务时移除。该文件不包含在插件包中，也不应被上传或粘贴到聊天。

如果已有手动配置的 `stupidmirror` MCP，安装器仅在其 URL 与当前应用端点一致时迁移这一条配置，并在本机保留私有恢复副本；其他配置保持不变。不匹配的同名连接会显示提示，避免覆盖。

### 手动 MCP 接入 / Claude Code

展开 **高级连接设置 · 其他 AI 客户端**：

1. 打开**设置 → MCP**，启用本地 MCP Server。
2. 在连接向导中选择 **Codex** 或 **Claude Code**。
3. 将生成的配置或命令复制到客户端，其中包含地址、Bearer 认证和准备超时。
4. 保持 StupidMirror 打开，让 Agent 调用 `list_devices`。

服务仅监听 `http://127.0.0.1:<port>/mcp`，轮换 Bearer Token 会使旧凭据失效。首次控制准备可能耗时较长，因此向导设置了 240 秒的工具超时。

可以从这样的指令开始：

> 列出已连接设备，开始镜像我的 iPhone，并高亮当前可点击的元素，先不要点击。

### 观察 → 操作 → 验证

| 阶段 | 工具 | 行为 |
| --- | --- | --- |
| 连接 | `list_devices`、`show_screen`、`connect_control` | 发现目标，准备所需会话 |
| 观察 | `observe_screen`、`find_any_element` | 读取实时帧，使用本地 OCR，按需获取无障碍信息 |
| 操作 | `tap_text`、`tap_element`、`replace_text`、`swipe` | 操作已观察到的目标，或执行明确的手势 |
| 验证 | `wait_for`、`assert_screen`、`observe_screen` | 检查操作后的状态 |
| 引导 | `highlight_clickable_elements`、`highlight_elements`、`clear_highlights` | 只在 Mac 镜像上标记目标，不发送输入 |
| 应用 | `list_apps`、`install_app`、`uninstall_app`、`open_url`、`activate_app`、`terminate_app` | 安装构建产物（.app/.ipa/.apk）、打开深链接、启动或结束 App |
| 录屏 | `start_recording`、`stop_recording` | 把实时镜像保存为 `~/Movies/StupidMirror` 下的 .mp4（最长 10 分钟） |

<details>
<summary>面向 Agent 开发者的定位与文本输入细节</summary>

- 存在多台设备时，明确传入 `device_id`。
- `tap_text` 一次接受最多 16 个候选文案，默认先做一次本地 OCR，必要时再共享一次原生 UI 层级快照。`find_any_element` 只查找，不点击。
- `observe_screen` 默认返回图片和精简 OCR，不读取原生层级。视觉任务或需求不明确时保留图片，明确只读文字时传 `include_image=false`；`find_element`、`find_any_element` 也默认精简。保留元素 ID 和观察 ID，可直接交给 `tap_element`；`center: [x, y]` 是四舍五入后的归一化位置提示，实际点击仍使用内部原始精度坐标。
- 这三个工具可传 `response_format="full"` 获取原有完整元数据、边界和层级格式。该参数不改变图片或无障碍查询开关：视觉判断保留默认的 `include_image=true`；读取开关值、选中状态等原生语义用 `include_accessibility=true, include_ocr=false`。
- 遇到图标、画布或自定义控件，使用 `include_image: true` 获取截图，观察后再选择目标坐标。
- 向 `tap_element` 传入 observation UUID，可在界面变化后拒绝过期元素 ID。
- iOS 无障碍快照可能影响已聚焦的输入框。聚焦后直接调用 `replace_text` 或 `clear_text`；追加内容使用 `type_text`。替换和清空都会校验最终的原生值。
- Vision OCR 提供 `fast` / `accurate` 模式，默认识别中英文，按需执行，不进入采集或编码热路径。
- 输入工具在 MCP 元数据中标记为可能具有破坏性，因为实际效果取决于手机当前打开的 App。

完整参数以[工具定义](Sources/StupidMirrorApp/StupidMirrorMCPTools.swift)为准。

</details>

## 架构与隐私

```text
iPhone USB → AVFoundation ─┐
iPhone LAN → H.264 / SRT ──┼→ 采集 → 原生镜像 / Vision OCR
Android → ADB / scrcpy ────┘    └→ H.264 → 本机 WebRTC → Codex 面板
Codex → 内置 stdio 桥接 → 本机鉴权 MCP → 观察 / 操作
iOS 操作 → smtunnel / WDA；Android 操作 → Appium / UiAutomator2
```

采集、播放和 OCR 均在本地完成。StupidMirror 不会自行将镜像内容上传到模型服务商。**外部 AI 客户端可以通过 MCP 获取截图和工具结果**；后续如何处理这些信息，取决于该客户端的账号、模型服务商和数据设置。

账号登录与许可证校验会访问配置的 Supabase 服务，许可请求包含账号和激活信息，不包含镜像帧或控制输入。详见[隐私政策](PRIVACY.md)与[安全策略](SECURITY.md)。

## 从源码构建

需要 macOS 15+、Swift 6 工具链和 Go（版本见 sidecar 的 `go.mod`）；插件界面开发另需 Node.js 22+：

```bash
git clone https://github.com/LiuTianjie/StupidMirror.git
cd StupidMirror
make run
```

```bash
swift build --build-system native # 编译
swift test --build-system native  # 运行测试
make app           # 生成 dist/StupidMirror.app
open dist/StupidMirror.app
```

使用宿主机 Appium 时，可运行 `make setup-appium` 与 `make run-appium`。源码运行与打包后的应用具有不同的 macOS 权限身份，应为实际运行的进程授权。

[探针工具](tools/probes/README.md)可检查设备发现、捕获与 WDA 就绪状态。`make probe-avfoundation-frame` 会将一帧画面保存在 Git 忽略的 `artifacts/` 目录中。

## 贡献与文档

反馈设备问题时，请提供 macOS / 手机系统版本、连接方式、复现步骤和脱敏诊断。涉及捕获或控制的改动应附上真机验证结果；Swift 构建通过并不能证明设备兼容性。

| 文档 | 内容 |
| --- | --- |
| [贡献指南](CONTRIBUTING.md) | 开发环境与 Pull Request 要求 |
| [架构笔记](docs/mvp-architecture.md) | 初始设计与实现背景 |
| [研究记录](docs/research.md) | 屏幕捕获与设备接入研究 |
| [发布流程](RELEASING.md) | 签名、公证、固定应用身份与产物上传 |
| [更新日志](CHANGELOG.md) | 版本历史 |
| [账号许可](LICENSING.md) | 激活、账号迁移与许可服务实现 |

## Codex 插件完整指南

参见 [Codex 插件指南](docs/codex-plugin.md)：内嵌视频、直接操作、标注、隐私和排障。插件开发需 Node.js 22+，原生打包需 Go；提交前运行 `npm ci --prefix plugins/stupidmirror/ui`、`npm run build --prefix plugins/stupidmirror/ui` 和 `npm test --prefix plugins/stupidmirror/ui`，将生成的内嵌 HTML 一并提交。

## 许可证

StupidMirror 以 **source-available（源码可用）** 形式采用 [PolyForm Noncommercial License 1.0.0](LICENSE) 发布，允许许可证约定的非商业用途，不属于 OSI 认可的开源许可证。商业用途需要单独书面授权，详见[商业授权说明](COMMERCIAL-LICENSE.md)。

当前应用在未激活时允许一个镜像会话和一个控制会话。需要同时连接多台设备时，直接输入[官方商店](https://wzyp.cn/item/exords)提供的 `SM-` 激活码即可，无需登录。账号登录仅用于按需恢复已有账号许可或绑定这台 Mac 的许可；不接受 iTool `IT-` 码。功能激活与商业授权是两件独立的事。

第三方组件仍遵循各自许可证，详见 [NOTICE](NOTICE)。
