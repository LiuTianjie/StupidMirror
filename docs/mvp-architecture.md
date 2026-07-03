# StupidMirror MVP 架构草案

## 产品边界

MVP 先服务内测/自用场景：

- 插上或信任设备后，Mac app 能自动发现设备。
- 设备画廊支持快速切换设备。
- 多设备连接时，可以同时展示多个镜像卡片。
- 控制能力作为增强能力：设备准备完成后才启用点击、滑动、键盘输入等操作。

暂不承诺：

- 普通用户零配置控制 iPhone。
- 普通用户零配置全局触控控制。
- 与 Apple iPhone Mirroring 完全一样的锁屏远程会话。

## 控制代理边界

单纯镜像不能依赖 iOS App。镜像主路径应该始终是：

- 用户在 Mac 上安装 StupidMirror。
- 连接或信任 iPhone。
- Mac app 自动发现并展示镜像。

控制能力走 Mac 管理的控制代理：用户明确点击安装/连接后，Mac app 启动
内置 Appium/XCUITest runtime，并安装或启动 WebDriverAgentRunner。普通用户只
看画面时，不应该被要求安装 iOS app，也不应该被自动安装控制代理。

同时要保持事实边界：普通 iOS app 不能对系统全局注入触摸事件。真正的控制
能力仍然需要 WDA/Appium/XCUITest 或其他具备系统级输入能力的通道。

## 核心模块

### DeviceIdentity

描述一个真实设备的稳定身份和连接状态。

```swift
struct DeviceIdentity: Identifiable, Hashable {
    let id: String
    let udid: String
    let name: String
    let productType: String
    let osVersion: String
    var connectionState: DeviceConnectionState
    var trustState: DeviceTrustState
}
```

### MirrorBackend

屏幕流后端协议。默认主路径是 AVFoundation；后续可以评估 pymobiledevice3 或 WDA MJPEG 等备选后端。

```swift
protocol MirrorBackend {
    var name: String { get }

    func discoverDevices() async throws -> [DeviceIdentity]
    func startStream(for device: DeviceIdentity) async throws -> MirrorStream
    func stopStream(for device: DeviceIdentity) async
}
```

### ControlBackend

控制通道协议。第一优先级是 WDA/Appium，后续再考虑直接 WDA HTTP。

```swift
protocol ControlBackend {
    var name: String { get }

    func prepareDevice(_ device: DeviceIdentity) async throws -> ControlSession
    func tap(_ point: CGPoint, in session: ControlSession) async throws
    func swipe(from start: CGPoint, to end: CGPoint, in session: ControlSession) async throws
    func longPress(_ point: CGPoint, duration: TimeInterval, in session: ControlSession) async throws
    func typeText(_ text: String, in session: ControlSession) async throws
    func home(in session: ControlSession) async throws
    func appSwitcher(in session: ControlSession) async throws
}
```

### DeviceSession

把一个物理设备、一个画面流和可选控制通道绑定到 UI。

```swift
struct DeviceSession: Identifiable {
    let id: String
    let device: DeviceIdentity
    var mirrorState: MirrorState
    var controlState: ControlState
}
```

## 运行时流程

1. App 启动后启动设备发现服务。
2. 发现设备后进入画廊列表。
3. 每个设备卡片先尝试启动最佳屏幕流后端。
4. 如果控制后端准备完成，卡片进入可交互模式。
5. 鼠标事件从 SwiftUI 坐标映射到设备屏幕坐标，再交给 `ControlBackend`。
6. 后端失败时，UI 显示明确的下一步：授权、信任设备、启用 Developer Mode、启动 Appium/WDA 等。

## UI 草案

- 主窗口默认就是设备画廊，不做营销首页。
- 顶部工具栏提供刷新设备、布局切换、全局停止流、打开诊断。
- 设备卡片固定比例展示画面，避免卡片因状态文案变化而跳动。
- 支持三种画廊布局：
  - 单设备聚焦
  - 双设备并排
  - 多设备网格
- 每张卡片显示最少状态：设备名、系统版本、画面后端、控制状态。

## Phase 2 实现顺序

1. 默认 `MirrorBackend` 先采用 CoreMediaIO + AVFoundation。
2. 搭 SwiftUI shell 和设备画廊。
3. 接入设备发现服务。
4. 接入默认屏幕流。
5. 接入 Mac 管理的 WDA/Appium 控制代理安装/启动流程。
6. 做多设备稳定性和错误恢复。
