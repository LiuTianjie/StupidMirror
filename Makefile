.PHONY: build app run release-local bump-version setup-appium run-appium probe-devices probe-avfoundation probe-avfoundation-frame probe-pymobiledevice3 probe-wda

build:
	swift build

app:
	bash scripts/build-app.sh

release-local:
	@if [ -n "$(TAG)" ]; then \
		bash scripts/build-and-upload-release.sh "$(TAG)"; \
	else \
		bash scripts/build-and-upload-release.sh; \
	fi

bump-version:
	@if [ -n "$(BUMP)" ]; then \
		bash scripts/bump-version.sh "$(BUMP)"; \
	else \
		bash scripts/bump-version.sh; \
	fi

run:
	swift run StupidMirrorApp

setup-appium:
	bash scripts/setup-appium.sh

run-appium:
	bash scripts/run-appium.sh

probe-devices:
	bash tools/probes/device-discovery.sh

probe-avfoundation:
	swift tools/probes/avfoundation-cmio-discovery.swift --seconds 12

probe-avfoundation-frame:
	swift tools/probes/avfoundation-frame-capture.swift --output artifacts/avfoundation-frame.png

probe-pymobiledevice3:
	bash tools/probes/pymobiledevice3-screen-probe.sh

probe-wda:
	bash tools/probes/wda-readiness.sh
