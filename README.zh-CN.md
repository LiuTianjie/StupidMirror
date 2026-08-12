# StupidMirror

[English](README.md) · **简体中文**

StupidMirror 是一款原生 macOS 菜单栏应用，可通过 USB，或完成一次 USB
准备后通过同一局域网，镜像并操作真实 iPhone。USB 画面来自 macOS 通过
CoreMediaIO / AVFoundation 暴露的 iPhone 屏幕源；无线画面由 Xcode 签名的
WebDriverAgent 在 iPhone 端以 H.264 编码，通过 SRT 传输，并在 Mac 端使用
VideoToolbox 解码。

[产品网站](https://liutianjie.github.io/StupidMirror/) ·
[下载 StupidMirror v0.2.11](https://github.com/LiuTianjie/StupidMirror/releases/download/v0.2.11/StupidMirror-v0.2.11-macos.zip) ·
[商业授权](COMMERCIAL-LICENSE.md)

> 项目仍处于实验阶段。由于 macOS 将 iPhone 屏幕暴露为 AVFoundation
> 捕获源，USB 镜像需要相机权限，但 StupidMirror 并不会因此调用 Mac 摄像头。

## 主要功能

- 通过 CoreMediaIO / AVFoundation 自动发现并镜像 USB iPhone。
- 完成一次 USB 准备后，通过 Apple `devicectl` 与局域网无线镜像。
- iPhone 端全分辨率 H.264、SRT 传输、Mac 端 VideoToolbox 解码。
- 菜单栏设备面板、实时缩略图、诊断、设置与独立镜像窗口。
- 可选的 Appium / XCUITest 真机控制：点击、滑动、长按、文本输入、剪贴板、
  Home、App 切换以及按 Bundle ID 启停 App。
- 发布包内置 Mac 侧 Appium / XCUITest 运行时，无需另装 Node 环境。
- 内置只监听本机的 MCP Server，可直接接入 Codex 或 Claude Code。
- 本地 Apple Vision OCR、按需 iOS Accessibility、可见的 AI 操作与高亮标记。
- 免费镜像一台设备；激活后支持多设备并行镜像与 iPhone 控制。
- 应用界面和产品网站均支持英文与简体中文。

## 系统要求

- macOS 15 或更高版本。
- 信任当前 Mac 的 iPhone；首次无线配置需要 USB。
- USB 镜像需要相机权限；播放 iPhone 音频时需要可选的麦克风权限。
- 真机控制需要 iPhone 开启开发者模式 / UI Automation，并允许当前 Mac
  使用有效 Apple Development 身份签名 WebDriverAgentRunner。

## 快速开始

直接下载已签名和 Apple 公证的版本：

[下载 StupidMirror v0.2.11](https://github.com/LiuTianjie/StupidMirror/releases/download/v0.2.11/StupidMirror-v0.2.11-macos.zip)

从源码运行：

```sh
make run
```

构建但不启动：

```sh
make build
```

生成本地 `.app`：

```sh
make app
open dist/StupidMirror.app
```

## 连接 Codex 或 Claude Code

1. 打开 StupidMirror，进入 **设置 → MCP**，启用本地 MCP Server。
2. 在内置连接向导中选择 **Codex** 或 **Claude Code**。
3. 复制应用生成的配置或命令，其中已经包含本机
   `http://127.0.0.1:<port>/mcp` 地址、Bearer 认证，以及首次准备 WDA 所需的
   240 秒工具超时。
4. 将配置加入对应客户端，必要时重启客户端，然后让它调用 `list_devices`。

生成的 Bearer Token 需要保密。服务只绑定 `127.0.0.1`；在应用中轮换 Token
后，旧客户端凭据会立即失效。

### MCP 能做什么

- 设备与会话：发现设备、开始/停止镜像、连接/断开控制、读取状态与诊断。
- 观察与定位：读取最新镜像帧、本地 Vision OCR、按需 Accessibility、语义化
  元素查找、等待与断言。
- 可见引导：在 Mac 镜像上编号高亮所有可点击目标，或高亮指定目标，不向
  iPhone 发送任何输入。
- 真机操作：点击、双击、长按、滑动、滚动、输入、清空/替换文本、按键、
  App 切换，以及按 Bundle ID 启停 App。

推荐的 Agent 操作顺序：

1. 调用 `list_devices`，按需执行 `start_mirror` 与 `connect_control`。
2. 使用 `observe_screen` 获取最新帧；日常导航优先启用本地 OCR，只有明确需要
   深层结构时才请求 Accessibility。
3. 使用 `tap_text` 一次提交最多 16 个候选文案。StupidMirror 先在 45 FPS
   最新镜像帧上做一次本地 OCR；像素中没有目标时，再为全部候选共享一次 WDA
   UI Tree 快照。
4. 使用 `tap_element` 时携带 observation UUID，可拒绝已经过期的元素 ID。
5. 文本输入优先使用 `replace_text` 或 `clear_text`，它们直接操作当前原生输入
   元素并校验结果，不依赖 iOS 选择菜单或坐标猜测。

`highlight_clickable_elements` 会把当前所有可见、启用且可点击的目标编号显示在
Mac 镜像上；`highlight_elements` 可高亮指定元素；`clear_highlights` 可提前清除。
这些高亮不会点击 iPhone，也不会被写进视频流。

## 隐私

StupidMirror 在本机运行，不会主动上传镜像画面、缩略图、设备信息或控制事件。
OCR 使用 macOS Vision 按需在本地完成；AI 操作标记只渲染在 Mac 界面中。
应用不内置模型，也不要求模型 API Key。

激活服务只会向 Supabase 许可证接口发送随机安装 ID、用户输入的激活码、应用
版本和返回的回执，不包含镜像帧、缩略图、iPhone 标识或控制输入。详见
[PRIVACY.md](PRIVACY.md)。

## 开发与文档

```sh
swift build
swift test
make app
```

- [MVP 架构](docs/mvp-architecture.md)
- [研究记录](docs/research.md)
- [安全策略](SECURITY.md)
- [贡献指南](CONTRIBUTING.md)
- [更新日志](CHANGELOG.md)
- [发布流程](RELEASING.md)
- [许可证激活与本地生成器](LICENSING.md)

## 许可证

StupidMirror 以 [PolyForm Noncommercial License 1.0.0](LICENSE) 提供源码。
个人学习、研究、实验、兴趣项目及其他非商业用途可在该许可证范围内免费使用；
商业用途需要项目所有者单独书面授权，详见[商业授权说明](COMMERCIAL-LICENSE.md)。

这不是 MIT 或 OSI 认可的开源许可证。第三方组件仍遵循各自许可证，详见
[NOTICE](NOTICE)。
