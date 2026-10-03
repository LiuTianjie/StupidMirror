<p align="center">
  <img src="docs/assets/app-icon.webp" alt="StupidMirror" width="96" />
</p>

<h1 align="center">StupidMirror</h1>

<p align="center">
  <strong>把手机带到 Mac，把真机交给 Agent。</strong><br />
  原生 iOS / Android 镜像、真机控制，以及面向 AI Agent 的本地 MCP Server。
</p>

<p align="center">
  <a href="Package.swift"><img src="https://img.shields.io/badge/macOS-15%2B-343b48?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 15 及以上" /></a>
  <a href="https://github.com/LiuTianjie/StupidMirror/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/LiuTianjie/StupidMirror/ci.yml?style=flat-square&amp;label=build" alt="构建状态" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-PolyForm%20Noncommercial-64748b?style=flat-square" alt="PolyForm Noncommercial 许可证" /></a>
</p>

<p align="center">
  <a href="https://github.com/LiuTianjie/StupidMirror/releases/latest">下载</a> ·
  <a href="https://liutianjie.github.io/StupidMirror/">官网</a> ·
  <a href="#连接-ai-agent">MCP 接入</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <img src="docs/assets/dashboard.webp" alt="StupidMirror macOS 界面：已连接的 iPhone、实时镜像与真机控制入口" width="820" />
</p>

StupidMirror 将真实的移动设备接入原生 macOS 工作台。通过 USB 或 Wi-Fi 查看 iPhone，通过 ADB 镜像 Android，再按需连接控制，在 Mac 上操作手机。

同一个工作台也可以通过 **MCP** 交给 AI Agent：观察当前画面，用本地 OCR 或原生无障碍信息定位目标，执行操作，再检查结果。整个过程都能在 Mac 镜像窗口中看到。

**无需登录，即可镜像和控制一台设备。** 账号激活后可同时连接多台设备。源码采用 PolyForm Noncommercial 许可证，商业用途需要单独授权，详见[许可证说明](#许可证)。

## 核心能力

- **原生设备工作台。** 使用 SwiftUI 与 AppKit 构建，提供菜单栏入口、设备面板、实时缩略图与独立镜像窗口。
- **三条画面接入路径。** USB iPhone 使用 AVFoundation；无线 iPhone 通过局域网传输 H.264；Android 使用固定版本的 scrcpy server 传输画面与声音。
- **按需连接真机控制。** 通过 Appium 点击、滑动、输入、按键、切换和启停 App。打开 USB 或 Android 镜像不会自动建立控制会话。
- **Agent 可以观察操作对象。** 实时帧、Apple Vision OCR、按需无障碍树、语义定位、等待与断言都围绕同一台真机工作。
- **自动化过程可见。** Agent 的点击、滑动路径和目标高亮显示在 Mac 镜像上，不改变手机画面，也不写入编码后的视频。
- **接入已有 AI 客户端。** 内置 Codex 与 Claude Code 配置向导；StupidMirror 本身无需模型 API Key，也不内置模型。

## 从一台设备开始

从 [GitHub Releases](https://github.com/LiuTianjie/StupidMirror/releases/latest) 下载 macOS 应用，移入 Applications 后打开。StupidMirror 以菜单栏工具的形式运行。

| 连接方式 | 准备工作 | 画面与声音 |
| --- | --- | --- |
| **iPhone · USB** | 信任当前 Mac；按提示授予相机权限 | AVFoundation 捕获；可选将设备声音播放到 Mac |
| **iPhone · Wi-Fi** | 通过 USB 完成一次“设置这台 iPhone”（会在手机上开启 Wi‑Fi 连接）；两端保持同一局域网 | H.264 / SRT 经 CoreDevice 隧道传输，VideoToolbox 解码；暂不支持无线音频 |
| **Android · ADB** | Android 11+；Mac 安装 Android SDK Platform-Tools；开启 USB 调试并授权当前 Mac | scrcpy 提供 H.264 画面与可选设备音频 |

**需要 macOS 15 或更高版本。** 兼容性受系统版本、信任状态和自动化运行时影响，项目仍处于实验阶段。

### USB 连接 iPhone

1. 连接并解锁 iPhone，接受“信任此电脑”。
2. 打开 StupidMirror，通过应用中的权限按钮授予相机访问权限。
3. 选择发现的设备并打开镜像。

macOS 将 iPhone 屏幕暴露为 AVFoundation 捕获源，因此需要相机权限；这个权限用于读取手机屏幕，并非调用 Mac 摄像头。默认关闭**在 Mac 上播放设备声音**，声音保留在 iPhone。开启后，USB 设备音频会转到 Mac，并需要额外授予麦克风权限。

### Wi-Fi 连接 iPhone

保持 USB 连接，打开**设置这台 iPhone**。向导会检查设备和 Apple Development 签名身份，构建并安装屏幕 Runner，试启动一次，然后在手机上开启 Wi‑Fi 连接（与 Xcode 的“通过网络连接”是同一个开关），之后再拔线。

后续会话由内置的 `smtunnel` 侧车连接手机：它在局域网上用进程内网络协议栈建立 Apple 的 CoreDevice 隧道，并通过 testmanagerd 启动 Runner，不依赖 Xcode 的启动器，不需要管理员密码、本地网络授权或在手机上点任何东西。无线镜像无需相机权限或 ReplayKit Broadcast Extension，但需要这个签名后的设备端 Runner 和手机上的开发者模式；准备无线画面不会自动连接控制。

### 连接 Android

安装 `adb`，开启 USB 调试，连接设备并在手机上授权当前 Mac，然后选择发现的设备开始镜像。画面与音频独立运行，不依赖可选的 Appium 控制连接。

## 真机控制

点击**连接控制**开始操作。

| 平台 | 控制后端 | 首次连接 |
| --- | --- | --- |
| iOS | 经 `smtunnel` 隧道直连 WebDriverAgent（USB 与 Wi‑Fi 同一条路径） | 在 iPhone 设置向导中用 USB 准备一次：信任 Mac、开启开发者模式、用 Apple Development 身份签名并安装屏幕代理 |
| Android | Appium + UiAutomator2（发布包内置 Node / Appium 运行时） | 按需安装 Appium settings / server 辅助 APK |

镜像上的手势会尽量还原鼠标的动作：慢速拖动按记录的路径与节奏回放，按住不动是长按（右键也是），双击是双击，触控板捏合与旋转对应手机上的捏合与旋转，返回是系统的边缘滑动。XCTest 只能在鼠标抬起后整体回放一个手势，所以按住期间“手指跟随”目前做不到。高级设置允许为 Android 配置自定义 Appium 地址，默认是 `http://127.0.0.1:4723`。

## 连接 AI Agent

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
| 连接 | `list_devices`、`start_mirror`、`connect_control` | 发现目标，准备所需会话 |
| 观察 | `observe_screen`、`find_any_element` | 读取实时帧，使用本地 OCR，按需获取无障碍信息 |
| 操作 | `tap_text`、`tap_element`、`replace_text`、`swipe` | 操作已观察到的目标，或执行明确的手势 |
| 验证 | `wait_for`、`assert_screen`、`observe_screen` | 检查操作后的状态 |
| 引导 | `highlight_clickable_elements`、`highlight_elements`、`clear_highlights` | 只在 Mac 镜像上标记目标，不发送输入 |

<details>
<summary>面向 Agent 开发者的定位与文本输入细节</summary>

- 存在多台设备时，明确传入 `device_id`。
- `tap_text` 一次接受最多 16 个候选文案，默认先做一次本地 OCR，必要时再共享一次原生 UI 层级快照。`find_any_element` 只查找，不点击。
- `observe_screen` 默认不抓取无障碍树。通过 `include_ocr` 启用本地文字识别，只在明确需要检查层级时使用 `include_accessibility`。
- 遇到图标、画布或自定义控件，使用 `include_image: true` 获取截图，观察后再选择目标坐标。
- 向 `tap_element` 传入 observation UUID，可在界面变化后拒绝过期元素 ID。
- iOS 无障碍快照可能影响已聚焦的输入框。聚焦后直接调用 `replace_text` 或 `clear_text`；追加内容使用 `type_text`。替换和清空都会校验最终的原生值。
- Vision OCR 提供 `fast` / `accurate` 模式，默认识别中英文，按需执行，不进入采集或编码热路径。
- 输入工具在 MCP 元数据中标记为可能具有破坏性，因为实际效果取决于手机当前打开的 App。

完整参数以[工具定义](Sources/StupidMirrorApp/StupidMirrorMCPTools.swift)为准。

</details>

## 架构与隐私

```text
iPhone USB ── AVFoundation ──────────────┐
iPhone LAN ── H.264 / SRT ───────────────┼── Native macOS mirror
Android    ── ADB / scrcpy ──────────────┘        │
                                                  ├── Vision OCR / observations
AI client  ── localhost MCP ── device actions ────┘
                                  │
                         Appium: XCUITest / UiAutomator2
                                  │
                              Real device
```

采集、播放和 OCR 均在本地完成。StupidMirror 不会自行将镜像内容上传到模型服务商。**外部 AI 客户端可以通过 MCP 获取截图和工具结果**；后续如何处理这些信息，取决于该客户端的账号、模型服务商和数据设置。

账号登录与许可证校验会访问配置的 Supabase 服务，许可请求包含账号和激活信息，不包含镜像帧或控制输入。详见[隐私政策](PRIVACY.md)与[安全策略](SECURITY.md)。

## 从源码构建

需要 macOS 15+ 与 Swift 6 工具链：

```bash
git clone https://github.com/LiuTianjie/StupidMirror.git
cd StupidMirror
make run
```

```bash
swift build        # 编译
swift test         # 运行测试
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

## 许可证

StupidMirror 以 **source-available（源码可用）** 形式采用 [PolyForm Noncommercial License 1.0.0](LICENSE) 发布，允许许可证约定的非商业用途，不属于 OSI 认可的开源许可证。商业用途需要单独书面授权，详见[商业授权说明](COMMERCIAL-LICENSE.md)。

当前应用在未激活时允许一个镜像会话和一个控制会话。需要同时连接多台设备时，可使用 Google、GitHub 或邮箱登录，并兑换[官方商店](https://wzyp.cn/item/exords)提供的 `SM-` 激活码；不接受 iTool `IT-` 码。功能激活与商业授权是两件独立的事。

第三方组件仍遵循各自许可证，详见 [NOTICE](NOTICE)。
