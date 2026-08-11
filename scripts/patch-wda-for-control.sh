#!/usr/bin/env bash
set -euo pipefail

default_wda_root="$HOME/.appium/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent"
if [ -n "${APPIUM_HOME:-}" ]; then
  default_wda_root="${APPIUM_HOME}/node_modules/appium-xcuitest-driver/node_modules/appium-webdriveragent"
fi
wda_root="${APPIUM_WDA_ROOT:-$default_wda_root}"
icon_script_path="${APPIUM_WDA_ICON_SCRIPT:-${wda_root}/Scripts/embed-runner-icon.sh}"
runner_source_path="${APPIUM_WDA_RUNNER_SOURCE:-${wda_root}/WebDriverAgentRunner/UITestingUITests.m}"
mjpeg_source_path="${APPIUM_WDA_MJPEG_SOURCE:-${wda_root}/WebDriverAgentLib/Utilities/FBMjpegServer.m}"
h264_include_source="${repo_root:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/wda/FBStupidMirrorH264Server.inc"
h264_include_path="${wda_root}/WebDriverAgentLib/Utilities/FBStupidMirrorH264Server.inc"

patch_icon_script() {
  if [ ! -f "$icon_script_path" ]; then
    echo "WDA icon embed script not found. Install the Appium XCUITest driver first." >&2
    return
  fi
  if grep -q 'STUPIDMIRROR_SKIP_WDA_ICON_EMBED' "$icon_script_path"; then
    echo "WDA icon embed skip guard already installed."
    return
  fi

  local tmp_path
  tmp_path="$(mktemp)"
  {
    read -r first_line
    printf '%s\n' "$first_line"
    cat <<'GUARD'

if [ "${STUPIDMIRROR_SKIP_WDA_ICON_EMBED:-}" = "1" ]; then
    echo "warning: skipping WDA runner icon embed for StupidMirror control setup"
    exit 0
fi
GUARD
    cat
  } < "$icon_script_path" > "$tmp_path"

  cat "$tmp_path" > "$icon_script_path"
  rm -f "$tmp_path"
  chmod +x "$icon_script_path"
  echo "Installed WDA icon embed skip guard: $icon_script_path"
}

patch_local_network_service() {
  if [ ! -f "$runner_source_path" ]; then
    echo "WDA runner source not found. Install the Appium XCUITest driver first." >&2
    return
  fi
  if grep -q 'STUPIDMIRROR_LOCAL_NETWORK_SERVICE' "$runner_source_path"; then
    echo "WDA local-network service patch already installed."
    return
  fi

  local tmp_path
  tmp_path="$(mktemp)"
  awk '
    /@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>/ {
      print
      print "// STUPIDMIRROR_LOCAL_NETWORK_SERVICE"
      print "@property (nonatomic, strong) NSNetServiceBrowser *stupidMirrorLocalNetworkBrowser;"
      print "@property (nonatomic, strong) NSNetService *stupidMirrorLocalNetworkService;"
      next
    }
    /^- \(void\)testRunner$/ {
      in_test_runner = 1
      print
      next
    }
    in_test_runner && /^\{$/ {
      print
      print "  self.stupidMirrorLocalNetworkBrowser = [[NSNetServiceBrowser alloc] init];"
      print "  [self.stupidMirrorLocalNetworkBrowser searchForServicesOfType:@\"_stupidmirror._tcp.\" inDomain:@\"local.\"];"
      print "  NSInteger stupidMirrorPort = [NSProcessInfo.processInfo.environment[@\"USE_PORT\"] integerValue];"
      print "  if (stupidMirrorPort <= 0) { stupidMirrorPort = 8100; }"
      print "  self.stupidMirrorLocalNetworkService = [[NSNetService alloc]"
      print "    initWithDomain:@\"local.\""
      print "    type:@\"_stupidmirror._tcp.\""
      print "    name:@\"StupidMirror WebDriverAgent\""
      print "    port:(int)stupidMirrorPort];"
      print "  [self.stupidMirrorLocalNetworkService publish];"
      in_test_runner = 0
      next
    }
    { print }
  ' "$runner_source_path" > "$tmp_path"

  cat "$tmp_path" > "$runner_source_path"
  rm -f "$tmp_path"
  echo "Installed WDA local-network service patch: $runner_source_path"
}

patch_h264_stream() {
  if [ ! -f "$mjpeg_source_path" ] || [ ! -f "$h264_include_source" ]; then
    echo "WDA H.264 patch inputs are unavailable." >&2
    return
  fi
  cp "$h264_include_source" "$h264_include_path"
  if grep -q 'STUPIDMIRROR_H264_STREAM' "$mjpeg_source_path"; then
    echo "WDA H.264 stream patch already installed."
    return
  fi

  local tmp_path
  tmp_path="$(mktemp)"
  awk '
    /#import "XCUIScreen.h"/ {
      print
      print "// STUPIDMIRROR_H264_STREAM"
      print "#include \"FBStupidMirrorH264Server.inc\""
      next
    }
    /@property \(nonatomic, readonly\) long long mainScreenID;/ {
      print
      print "@property (nonatomic, strong) FBStupidMirrorH264Server *stupidMirrorH264Server;"
      next
    }
    /_mainScreenID = \[XCUIScreen.mainScreen displayID\];/ {
      print
      print "    NSString *h264PortValue = NSProcessInfo.processInfo.environment[@\"STUPIDMIRROR_H264_PORT\"];"
      print "    NSInteger h264Port = h264PortValue.length > 0 ? h264PortValue.integerValue : 9200;"
      print "    if (h264Port > 0 && h264Port <= UINT16_MAX) {"
      print "      _stupidMirrorH264Server = [[FBStupidMirrorH264Server alloc] initWithPort:(uint16_t)h264Port];"
      print "    }"
      next
    }
    /- \(void\)stopStreaming/ {
      in_stop = 1
      print
      next
    }
    in_stop && /^\{$/ {
      print
      print "  [self.stupidMirrorH264Server stop];"
      print "  self.stupidMirrorH264Server = nil;"
      in_stop = 0
      next
    }
    { print }
  ' "$mjpeg_source_path" > "$tmp_path"

  cat "$tmp_path" > "$mjpeg_source_path"
  rm -f "$tmp_path"
  echo "Installed WDA H.264 stream patch: $mjpeg_source_path"
}

patch_icon_script
patch_local_network_service
patch_h264_stream
