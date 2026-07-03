# Probes

这些脚本用于第一阶段技术验证。默认只检查环境和输出诊断信息，不自动安装全局依赖，也不启动长时间运行的服务。

## Commands

```sh
bash tools/probes/device-discovery.sh
swift tools/probes/avfoundation-cmio-discovery.swift --seconds 12
swift tools/probes/avfoundation-frame-capture.swift --output artifacts/avfoundation-frame.png
bash tools/probes/pymobiledevice3-screen-probe.sh
bash tools/probes/wda-readiness.sh
python3 tools/probes/appium-control-smoke.py --help
```

## Optional flows

Start the `pymobiledevice3 screen-mirror` server if the fork is installed:

```sh
bash tools/probes/pymobiledevice3-screen-probe.sh --serve
```

Capture one frame from the first AVFoundation `.muxed` iPhone source:

```sh
swift tools/probes/avfoundation-frame-capture.swift --output artifacts/avfoundation-frame.png
```

Try an Appium session once Appium, the XCUITest driver, WDA signing, and device preparation are done:

```sh
python3 tools/probes/appium-control-smoke.py --udid <device-udid> --bundle-id com.apple.Preferences --screenshot artifacts/settings.png
```
