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
session_commands_path="${APPIUM_WDA_SESSION_COMMANDS:-${wda_root}/WebDriverAgentLib/Commands/FBSessionCommands.m}"
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
  # Guard on the consent probe, not the older service patch: machines patched
  # by a previous release already have the service block and must still get the
  # consent probe added.
  if grep -q 'STUPIDMIRROR_LOCAL_NETWORK_CONSENT' "$runner_source_path"; then
    echo "WDA local-network consent patch already installed."
    return
  fi
  if grep -q 'STUPIDMIRROR_LOCAL_NETWORK_SERVICE' "$runner_source_path"; then
    echo "Upgrading older WDA local-network patch to include the consent probe."
    local pristine
    pristine="$(dirname "$runner_source_path")/UITestingUITests.m.stupidmirror-orig"
    if [ -f "$pristine" ]; then
      cat "$pristine" > "$runner_source_path"
    else
      echo "No pristine runner source to restore; reinstall the XCUITest driver if this patch fails." >&2
    fi
  else
    cp "$runner_source_path" "$(dirname "$runner_source_path")/UITestingUITests.m.stupidmirror-orig"
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
      print "  [self stupidMirrorRequestLocalNetworkConsent];"
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
    /^#pragma mark - FBWebServerDelegate$/ {
      print "// STUPIDMIRROR_LOCAL_NETWORK_CONSENT"
      print "// iOS only presents the Local Network consent alert after a process"
      print "// actually attempts local-network access. WDA never does: it just"
      print "// listens and waits for the Mac to dial in. Without a prompt the grant"
      print "// is never made, and every inbound SYN to the WDA HTTP/MJPEG ports is"
      print "// silently dropped while a non-listening port on the same device still"
      print "// answers with RST. Publishing a Bonjour service is not enough either."
      print "//"
      print "// So make one deliberate outbound attempt. It is expected to fail"
      print "// (errno 65 / NSURLErrorNotConnectedToInternet are how the system"
      print "// disguises a denial), and failing is fine: the attempt is what causes"
      print "// iOS to ask the user. Once granted, the decision is keyed to the"
      print "// runner bundle id and persists across relaunches and reinstalls, so"
      print "// later sessions pay nothing for this."
      print "//"
      print "// STUPIDMIRROR_CONSENT_HOST is set by the Mac to its own LAN address"
      print "// during first-time USB setup. The port is intentionally one nothing"
      print "// listens on, so this never disturbs a real service."
      print "- (void)stupidMirrorRequestLocalNetworkConsent"
      print "{"
      print "  NSString *host = NSProcessInfo.processInfo.environment[@\"STUPIDMIRROR_CONSENT_HOST\"];"
      print "  if (host.length == 0) { return; }"
      print "  NSString *portValue = NSProcessInfo.processInfo.environment[@\"STUPIDMIRROR_CONSENT_PORT\"];"
      print "  int port = portValue.length > 0 ? portValue.intValue : 47811;"
      print "  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{"
      print "    int fd = socket(AF_INET, SOCK_STREAM, 0);"
      print "    if (fd < 0) { return; }"
      print "    struct sockaddr_in addr;"
      print "    memset(&addr, 0, sizeof(addr));"
      print "    addr.sin_family = AF_INET;"
      print "    addr.sin_port = htons((uint16_t)port);"
      print "    if (inet_pton(AF_INET, host.UTF8String, &addr.sin_addr) == 1) {"
      print "      struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };"
      print "      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));"
      print "      int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));"
      print "      [FBLogger logFmt:@\"StupidMirror local-network consent probe rc=%d errno=%d\", rc, rc == 0 ? 0 : errno];"
      print "    }"
      print "    close(fd);"
      print "  });"
      print "}"
      print ""
      print
      next
    }
    { print }
  ' "$runner_source_path" > "$tmp_path"

  cat "$tmp_path" > "$runner_source_path"
  rm -f "$tmp_path"

  # The probe needs BSD socket headers and FBLogger, which the stock runner
  # source does not import.
  local header_tmp
  header_tmp="$(mktemp)"
  awk '
    /^#import <XCTest\/XCTest.h>$/ {
      print
      print ""
      print "// STUPIDMIRROR_LOCAL_NETWORK_CONSENT headers"
      print "#import <arpa/inet.h>"
      print "#import <netinet/in.h>"
      print "#import <sys/socket.h>"
      print "#import <unistd.h>"
      print "#import <WebDriverAgentLib/FBLogger.h>"
      next
    }
    { print }
  ' "$runner_source_path" > "$header_tmp"
  cat "$header_tmp" > "$runner_source_path"
  rm -f "$header_tmp"

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

patch_srt_status() {
  if [ ! -f "$session_commands_path" ]; then
    echo "WDA session commands source not found. Install the Appium XCUITest driver first." >&2
    return
  fi
  if grep -q 'STUPIDMIRROR_SRT_STATUS' "$session_commands_path"; then
    echo "WDA SRT status patch already installed."
    return
  fi

  local tmp_path
  tmp_path="$(mktemp)"
  awk '
    /#import "XCUIApplicationProcessDelay.h"/ {
      print
      print "// STUPIDMIRROR_SRT_STATUS"
      print "extern volatile int SMStupidMirrorSRTStartupState;"
      print "extern char SMStupidMirrorSRTStartupError[512];"
      next
    }
    /@"device": \[self.class deviceNameByUserInterfaceIdiom:/ {
      print "      @\"stupidMirrorSRT\" : @{"
      print "        @\"startupState\" : @(SMStupidMirrorSRTStartupState),"
      print "        @\"startupError\" : [NSString stringWithUTF8String:SMStupidMirrorSRTStartupError] ?: @\"\""
      print "      },"
      print
      next
    }
    { print }
  ' "$session_commands_path" > "$tmp_path"

  cat "$tmp_path" > "$session_commands_path"
  rm -f "$tmp_path"
  echo "Installed WDA SRT status patch: $session_commands_path"
}

patch_icon_script
patch_local_network_service
patch_h264_stream
patch_srt_status
