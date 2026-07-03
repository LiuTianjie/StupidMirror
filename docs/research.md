# StupidMirror 第一阶段调研

## 当前结论

第一阶段先按“自己/内测工具”推进。目标不是马上做普通用户零配置应用，而是用真实设备验证三件事：

1. Mac 是否能稳定发现 USB 连接的 iPhone。
2. 是否能拿到实时屏幕画面，而不是只拿到 Continuity Camera/相机画面。
3. 是否能通过 Mac 侧点击、滑动、输入来控制真机。

当前本机基线：

- macOS 26.3
- Xcode 26.2
- Swift 6.2.3
- `libimobiledevice` 可用
- 已连接设备：`iPhone Air`，iOS `26.4.2`
- Appium 当前未安装

已验证的早期观察：

- `idevice_id` 可以看到真机 UDID。
- `ideviceinfo` 可以读到设备名、型号和系统版本。
- `xcrun xctrace list devices` 可以看到在线设备和离线设备。
- CoreMediaIO 开关 `kCMIOHardwarePropertyAllowScreenCaptureDevices` 设置成功。
- AVFoundation 初始枚举到 iPhone 相机和麦克风；经过 warmup 和连接通知后，可以枚举到 `.muxed` 的 `iPhone Air` 源。
- `tools/probes/avfoundation-frame-capture.swift` 已成功从 `.muxed` 源抓取 PNG，尺寸为 `1260 x 2736`。

这意味着 AVFoundation 路线已通过第一帧验证，Phase 2 可以优先把它作为默认镜像后端，再继续验证连续帧率、延迟和多设备并发。

## 路线评估

| 能力 | 路线 | 当前状态 | 说明 |
| --- | --- | --- | --- |
| 设备发现 | `idevice_id` / `ideviceinfo` / `xcrun xctrace` | 可行 | 适合做 Phase 1 的真实设备清单与状态核对。 |
| 屏幕采集 | CoreMediaIO + AVFoundation | 可行 | CMIO 开关可设置，warmup 后能发现 `.muxed` iPhone 源，并已成功抓取 `1260 x 2736` PNG 帧。 |
| 屏幕采集 | `pymobiledevice3 screen-mirror` 分支 | 可行但需要设置 | 上游讨论显示有 USB-only 镜像分支；需要安装 fork 并验证 macOS TCC 权限。 |
| 屏幕采集 | WebDriverAgent MJPEG | 可行但需要设置 | 依赖 WDA/Appium 或直接 WDA；帧率和画质可调，适合与控制链路共用。 |
| 屏幕采集 | ReplayKit iOS helper | 非当前主线 | 会让镜像依赖 iOS App/扩展，暂不作为普通镜像路径。 |
| 输入控制 | WebDriverAgent/Appium/XCUITest | 可行但需要设置 | 需要信任设备、Developer Mode、Enable UI Automation、WDA 签名/安装。 |
| 输入控制 | 直接调用 WDA HTTP | 待验证 | 如果 Appium 太重，后续可把 WDA 作为受管 runner，Mac app 直接发 HTTP。 |
| 输入控制 | iOS helper | 受限 | iOS helper 不能自然获得全局系统触控注入能力，只能作为补充。 |

## 推荐验证顺序

1. 跑 `tools/probes/device-discovery.sh`，固定设备发现输出格式。
2. 跑 `tools/probes/avfoundation-cmio-discovery.swift`，确认 AVFoundation 是否能出现 `.muxed` 屏幕源。
3. 跑 `tools/probes/avfoundation-frame-capture.swift --output artifacts/avfoundation-frame.png`，验证真实帧输出；当前本机已验证成功。
4. 跑 `tools/probes/pymobiledevice3-screen-probe.sh`，如果未安装则按脚本提示安装 `screen-mirror` fork 后再验证。
5. 跑 `tools/probes/wda-readiness.sh`，确认 WDA/Appium 前置条件。
6. Appium/WDA 就绪后，用 `tools/probes/appium-control-smoke.py` 做点击、滑动和截图冒烟。

## 权限与风险

- AVFoundation/CMIO 路线可能需要给启动进程的终端应用授予 Camera 和 Screen Recording 权限。
- WDA/Appium 路线需要真机启用 Developer Mode 和 Enable UI Automation，并处理签名/Provisioning Profile。
- Apple 官方 iPhone Mirroring 仍然有同 Apple Account、附近、锁屏、单设备等约束；本项目不能假设可复用其私有控制通道。
- 普通用户零配置控制 iPhone 暂不作为第一阶段目标。

## 参考资料

- Apple iPhone Mirroring: https://support.apple.com/en-us/120421
- QuickTime 连接设备录制: https://support.apple.com/en-au/guide/quicktime-player/qtp356b55534/10.5/mac/13.0
- pymobiledevice3: https://github.com/doronz88/pymobiledevice3
- pymobiledevice3 screen-mirror 讨论: https://github.com/doronz88/pymobiledevice3/discussions/1668
- Appium 真机准备: https://appium.github.io/appium-xcuitest-driver/11.11/getting-started/device-setup/
- Appium MJPEG 流: https://appium.github.io/appium-xcuitest-driver/11.11/guides/mjpeg/
- Appium iOS 输入事件: https://appium.github.io/appium-xcuitest-driver/11.11/guides/input-events/
