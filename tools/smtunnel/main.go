// smtunnel is StupidMirror's device tunnel sidecar. It reaches an iPhone through
// usbmuxd (USB or, once "Wi-Fi connections" are enabled on the phone, the local
// network), starts Apple's CoreDeviceProxy service over lockdown, and carries
// the resulting CoreDevice tunnel in an in-process network stack. Over that
// tunnel it launches the WebDriverAgent runner through testmanagerd and
// publishes the runner's ports on 127.0.0.1. No root, no Xcode involvement.
//
// Every line on stdout is one JSON object with an "event" key.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/danielpaulus/go-ios/ios"
	"github.com/danielpaulus/go-ios/ios/appservice"
	"github.com/danielpaulus/go-ios/ios/imagemounter"
	"github.com/danielpaulus/go-ios/ios/installationproxy"
	"github.com/danielpaulus/go-ios/ios/testmanagerd"

	"github.com/LiuTianjie/StupidMirror/tools/smtunnel/internal/forward"
	"github.com/LiuTianjie/StupidMirror/tools/smtunnel/internal/utun"
)

const (
	exitUsage          = 2
	exitDeviceNotFound = 3
	exitTunnelFailed   = 4
	exitServiceMissing = 5
	exitRunnerFailed   = 6
	exitRunnerExited   = 7
	exitTunnelClosed   = 8
)

const (
	coreDeviceProxyService = "com.apple.internal.devicecompute.CoreDeviceProxy"
	testmanagerdService    = "com.apple.dt.testmanagerd.remote"
	wirelessLockdownDomain = "com.apple.mobile.wireless_lockdown"
	wifiConnectionsKey     = "EnableWifiConnections"
)

var version = "dev"

var stdout = json.NewEncoder(os.Stdout)

func emit(event string, fields map[string]any) {
	if fields == nil {
		fields = map[string]any{}
	}
	fields["event"] = event
	fields["t"] = time.Now().UTC().Format(time.RFC3339Nano)
	_ = stdout.Encode(fields)
}

func fail(code int, kind string, err error) {
	emit("error", map[string]any{"code": kind, "message": err.Error()})
	os.Exit(code)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "version":
		emit("version", map[string]any{"version": version})
	case "list":
		runList(os.Args[2:])
	case "info":
		runInfo(os.Args[2:])
	case "wifi":
		runWifi(os.Args[2:])
	case "serve":
		runServe(os.Args[2:])
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `usage:
  smtunnel version
  smtunnel list [--details]
  smtunnel info --udid <udid> [--runner <bundle id>]
  smtunnel wifi --udid <udid> [on|off]
  smtunnel serve --udid <udid> [--transport network|usb|auto]
                 [--runner <bundle id> [--xctest-config <name>] [--env KEY=VALUE]...]
                 [--tcp <device port>[:<local port>]]... [--udp <device port>[:<local port>]]...
                 [--status-port <device port>] [--mtu <bytes>] [--watch-stdin]`)
	os.Exit(exitUsage)
}

type flags struct {
	values map[string]string
	lists  map[string][]string
}

// booleanFlags never take a value, so a word that follows them is positional.
var booleanFlags = map[string]bool{"watch-stdin": true, "details": true}

func parseFlags(args []string, listKeys ...string) flags {
	f := flags{values: map[string]string{}, lists: map[string][]string{}}
	isList := map[string]bool{}
	for _, key := range listKeys {
		isList[key] = true
	}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if !strings.HasPrefix(arg, "--") {
			f.lists["_"] = append(f.lists["_"], arg)
			continue
		}
		key := strings.TrimPrefix(arg, "--")
		value := ""
		if eq := strings.IndexByte(key, '='); eq >= 0 {
			key, value = key[:eq], key[eq+1:]
		} else if !booleanFlags[key] && i+1 < len(args) && !strings.HasPrefix(args[i+1], "--") {
			i++
			value = args[i]
		}
		if isList[key] {
			f.lists[key] = append(f.lists[key], value)
		} else {
			f.values[key] = value
		}
	}
	return f
}

// --- list -------------------------------------------------------------------

func runList(args []string) {
	f := parseFlags(args)
	_, details := f.values["details"]
	list, err := ios.ListDevices()
	if err != nil {
		fail(exitDeviceNotFound, "usbmuxd_unavailable", err)
	}
	devices := make([]map[string]any, 0, len(list.DeviceList))
	if !details {
		for _, device := range list.DeviceList {
			devices = append(devices, map[string]any{
				"udid":           device.Properties.SerialNumber,
				"connectionType": device.Properties.ConnectionType,
				"deviceId":       device.DeviceID,
			})
		}
		emit("devices", map[string]any{"devices": devices})
		return
	}
	// One row per phone, naming every transport usbmuxd offers for it, plus
	// the lockdown identity read over the preferred (USB first) entry.
	byUDID := map[string][]ios.DeviceEntry{}
	order := []string{}
	for _, device := range list.DeviceList {
		udid := device.Properties.SerialNumber
		if _, seen := byUDID[udid]; !seen {
			order = append(order, udid)
		}
		byUDID[udid] = append(byUDID[udid], device)
	}
	for _, udid := range order {
		entries := byUDID[udid]
		preferred := entries[0]
		types := make([]string, 0, len(entries))
		for _, entry := range entries {
			types = append(types, entry.Properties.ConnectionType)
			if entry.Properties.ConnectionType == "USB" {
				preferred = entry
			}
		}
		row := map[string]any{"udid": udid, "connectionTypes": types}
		if values, err := ios.GetValues(preferred); err == nil {
			row["name"] = values.Value.DeviceName
			row["productType"] = values.Value.ProductType
			row["productVersion"] = values.Value.ProductVersion
			row["deviceClass"] = values.Value.DeviceClass
		} else {
			row["error"] = err.Error()
		}
		devices = append(devices, row)
	}
	emit("devices", map[string]any{"devices": devices})
}

// --- info -------------------------------------------------------------------

const developerModeDomain = "com.apple.security.mac.amfi"

// runInfo reports everything the setup guide needs to decide what is still
// missing on a phone: identity, Developer Mode, the Wi-Fi connections switch,
// whether the runner is installed, and whether a developer image is mounted.
func runInfo(args []string) {
	f := parseFlags(args)
	udid := f.values["udid"]
	if udid == "" {
		usage()
	}
	device, err := pickDevice(udid, "USB")
	if err != nil {
		device, err = pickDevice(udid, "")
		if err != nil {
			fail(exitDeviceNotFound, "device_not_found", err)
		}
	}
	report := map[string]any{
		"udid":           udid,
		"connectionType": device.Properties.ConnectionType,
	}
	if list, err := ios.ListDevices(); err == nil {
		types := []string{}
		for _, entry := range list.DeviceList {
			if entry.Properties.SerialNumber == udid {
				types = append(types, entry.Properties.ConnectionType)
			}
		}
		report["connectionTypes"] = types
	}
	values, err := ios.GetValues(device)
	if err != nil {
		fail(exitDeviceNotFound, "lockdown_failed", err)
	}
	report["name"] = values.Value.DeviceName
	report["productType"] = values.Value.ProductType
	report["productVersion"] = values.Value.ProductVersion
	report["passwordProtected"] = values.Value.PasswordProtected

	if lockdown, err := ios.ConnectLockdownWithSession(device); err == nil {
		if value, err := lockdown.GetValueForDomain(wifiConnectionsKey, wirelessLockdownDomain); err == nil {
			if enabled, ok := value.(bool); ok {
				report["enableWifiConnections"] = enabled
			}
		}
		if value, err := lockdown.GetValueForDomain("DeveloperModeStatus", developerModeDomain); err == nil {
			if enabled, ok := value.(bool); ok {
				report["developerMode"] = enabled
			}
		}
		lockdown.Close()
	}

	if runner := f.values["runner"]; runner != "" {
		report["runnerBundleId"] = runner
		if proxy, err := installationproxy.New(device); err == nil {
			if apps, err := proxy.BrowseUserApps(); err == nil {
				installed := false
				for _, app := range apps {
					if app.CFBundleIdentifier() == runner {
						installed = true
						report["runnerVersion"] = app.CFBundleShortVersionString()
						break
					}
				}
				report["runnerInstalled"] = installed
			}
			proxy.Close()
		}
	}

	if mounter, err := imagemounter.NewImageMounter(device); err == nil {
		if images, err := mounter.ListImages(); err == nil {
			report["developerImageMounted"] = len(images) > 0
		}
		mounter.Close()
	}
	emit("info", report)
}

// --- wifi -------------------------------------------------------------------

func runWifi(args []string) {
	f := parseFlags(args)
	udid := f.values["udid"]
	if udid == "" {
		usage()
	}
	device, err := pickDevice(udid, "USB")
	if err != nil {
		// Reading the flag works over any transport; setting it is only
		// meaningful while the phone is on USB, but try whatever is there.
		device, err = pickDevice(udid, "")
		if err != nil {
			fail(exitDeviceNotFound, "device_not_found", err)
		}
	}
	lockdown, err := ios.ConnectLockdownWithSession(device)
	if err != nil {
		fail(exitDeviceNotFound, "lockdown_failed", err)
	}
	defer lockdown.Close()
	if positional := f.lists["_"]; len(positional) == 1 {
		want := positional[0] == "on"
		if positional[0] != "on" && positional[0] != "off" {
			usage()
		}
		if err := lockdown.SetValueForDomain(wifiConnectionsKey, wirelessLockdownDomain, want); err != nil {
			fail(exitDeviceNotFound, "set_failed", err)
		}
	}
	current, err := lockdown.GetValueForDomain(wifiConnectionsKey, wirelessLockdownDomain)
	if err != nil {
		fail(exitDeviceNotFound, "get_failed", err)
	}
	enabled, _ := current.(bool)
	emit("wifi", map[string]any{
		"udid":                  udid,
		"connectionType":        device.Properties.ConnectionType,
		"enableWifiConnections": enabled,
	})
}

// --- serve ------------------------------------------------------------------

type portMapping struct {
	devicePort int
	localPort  int
}

func parsePortMappings(specs []string) ([]portMapping, error) {
	mappings := make([]portMapping, 0, len(specs))
	for _, spec := range specs {
		devicePart, localPart, hasLocal := strings.Cut(spec, ":")
		devicePort, err := strconv.Atoi(devicePart)
		if err != nil || devicePort <= 0 || devicePort > 65535 {
			return nil, fmt.Errorf("invalid device port %q", spec)
		}
		localPort := 0
		if hasLocal {
			localPort, err = strconv.Atoi(localPart)
			if err != nil || localPort < 0 || localPort > 65535 {
				return nil, fmt.Errorf("invalid local port %q", spec)
			}
		}
		mappings = append(mappings, portMapping{devicePort: devicePort, localPort: localPort})
	}
	return mappings, nil
}

func runServe(args []string) {
	f := parseFlags(args, "env", "tcp", "udp")
	udid := f.values["udid"]
	if udid == "" {
		usage()
	}
	transport := f.values["transport"]
	if transport == "" {
		transport = "auto"
	}
	want := ""
	switch transport {
	case "network":
		want = "Network"
	case "usb":
		want = "USB"
	case "auto":
	default:
		usage()
	}
	tcpMappings, err := parsePortMappings(f.lists["tcp"])
	if err != nil {
		fail(exitUsage, "bad_arguments", err)
	}
	udpMappings, err := parsePortMappings(f.lists["udp"])
	if err != nil {
		fail(exitUsage, "bad_arguments", err)
	}
	statusPort := 0
	if raw := f.values["status-port"]; raw != "" {
		statusPort, err = strconv.Atoi(raw)
		if err != nil {
			fail(exitUsage, "bad_arguments", fmt.Errorf("invalid --status-port %q", raw))
		}
	}
	requestedMTU := utun.DefaultRequestedMTU
	if raw := f.values["mtu"]; raw != "" {
		requestedMTU, err = strconv.Atoi(raw)
		if err != nil {
			fail(exitUsage, "bad_arguments", fmt.Errorf("invalid --mtu %q", raw))
		}
	}
	runnerBundle := f.values["runner"]
	xctestConfig := f.values["xctest-config"]
	if xctestConfig == "" {
		xctestConfig = "WebDriverAgentRunner.xctest"
	}
	env := map[string]any{}
	for _, pair := range f.lists["env"] {
		key, value, ok := strings.Cut(pair, "=")
		if !ok || key == "" {
			fail(exitUsage, "bad_arguments", fmt.Errorf("invalid --env %q", pair))
		}
		env[key] = value
	}

	// Shut down on SIGTERM/SIGINT, and also when stdin closes: the parent app
	// holds our stdin, so its death ends the session even without a signal.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-signals
		emit("shutdown", map[string]any{"reason": "signal"})
		cancel()
	}()
	if _, watchStdin := f.values["watch-stdin"]; watchStdin {
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			emit("shutdown", map[string]any{"reason": "stdin_closed"})
			cancel()
		}()
	}

	device, err := pickDevice(udid, want)
	if err != nil {
		fail(exitDeviceNotFound, "device_not_found", err)
	}
	emit("device", map[string]any{
		"udid":           device.Properties.SerialNumber,
		"connectionType": device.Properties.ConnectionType,
	})

	tunnel, err := openTunnel(device, requestedMTU)
	if err != nil {
		fail(exitTunnelFailed, "tunnel_failed", err)
	}
	defer tunnel.Close()

	relay, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		fail(exitTunnelFailed, "relay_failed", err)
	}
	defer relay.Close()
	go tunnel.ServeRelay(relay)
	relayPort := relay.Addr().(*net.TCPAddr).Port

	device.UserspaceTUN = true
	device.UserspaceTUNHost = "127.0.0.1"
	device.UserspaceTUNPort = relayPort
	rsdService, err := ios.NewWithAddrPortDevice(tunnel.DeviceIP.String(), tunnel.RSDPort(), device)
	if err != nil {
		fail(exitTunnelFailed, "rsd_failed", err)
	}
	rsd, err := rsdService.Handshake()
	rsdService.Close()
	if err != nil {
		fail(exitTunnelFailed, "rsd_failed", err)
	}
	device.Address = tunnel.DeviceIP.String()
	device.Rsd = rsd
	emit("tunnel", map[string]any{
		"address":   tunnel.DeviceIP.String(),
		"rsdPort":   tunnel.RSDPort(),
		"mtu":       tunnel.Parameters.ClientParameters.MTU,
		"relayPort": relayPort,
	})

	if runnerBundle != "" && rsd.GetPort(testmanagerdService) == 0 {
		fail(exitServiceMissing, "developer_image_missing",
			fmt.Errorf("%s is not offered by the device; the developer disk image is not mounted", testmanagerdService))
	}

	for _, mapping := range tcpMappings {
		published, closeForward, err := forward.TCP(tunnel, mapping.devicePort, mapping.localPort)
		if err != nil {
			fail(exitTunnelFailed, "forward_failed", err)
		}
		defer closeForward()
		emit("forward", map[string]any{"proto": published.Protocol, "devicePort": published.DevicePort, "localPort": published.LocalPort})
	}
	for _, mapping := range udpMappings {
		published, closeForward, err := forward.UDP(tunnel, mapping.devicePort, mapping.localPort)
		if err != nil {
			fail(exitTunnelFailed, "forward_failed", err)
		}
		defer closeForward()
		emit("forward", map[string]any{"proto": published.Protocol, "devicePort": published.DevicePort, "localPort": published.LocalPort})
	}

	runnerDone := make(chan error, 1)
	if runnerBundle != "" {
		if statusPort != 0 {
			stopStaleRunner(ctx, tunnel, device, runnerBundle, statusPort)
		}
		emit("runner", map[string]any{"state": "launching", "bundleId": runnerBundle})
		go func() {
			_, err := testmanagerd.RunTestWithConfig(ctx, testmanagerd.TestConfig{
				BundleId:           runnerBundle,
				TestRunnerBundleId: runnerBundle,
				XctestConfigName:   xctestConfig,
				Env:                env,
				Device:             device,
				Listener:           testmanagerd.NewTestListener(io.Discard, io.Discard, os.TempDir()),
			})
			runnerDone <- err
		}()
		if statusPort != 0 {
			if err := waitForStatus(ctx, tunnel, statusPort, runnerDone, 90*time.Second); err != nil {
				if ctx.Err() != nil {
					os.Exit(0)
				}
				fail(exitRunnerFailed, runnerFailureCode(err), err)
			}
			emit("ready", map[string]any{"statusPort": statusPort})
		} else {
			emit("ready", nil)
		}
	} else {
		emit("ready", nil)
	}

	select {
	case <-ctx.Done():
		emit("stopped", nil)
	case err := <-runnerDone:
		if ctx.Err() != nil {
			emit("stopped", nil)
			return
		}
		if err == nil {
			err = errors.New("the runner ended its test session")
		}
		emit("runner", map[string]any{"state": "exited", "message": err.Error()})
		os.Exit(exitRunnerExited)
	case <-tunnel.Done():
		if ctx.Err() != nil {
			emit("stopped", nil)
			return
		}
		message := "tunnel closed"
		if err := tunnel.Err(); err != nil {
			message = err.Error()
		}
		emit("error", map[string]any{"code": "tunnel_closed", "message": message})
		os.Exit(exitTunnelClosed)
	}
	// Give the runner kill (triggered by ctx cancel) a moment to land.
	select {
	case <-runnerDone:
	case <-time.After(5 * time.Second):
	}
}

func pickDevice(udid, want string) (ios.DeviceEntry, error) {
	list, err := ios.ListDevices()
	if err != nil {
		return ios.DeviceEntry{}, fmt.Errorf("usbmuxd: %w", err)
	}
	// "auto" (want == "") prefers the local-network entry: a phone that is
	// also on USB will keep working when the cable comes out.
	var fallback *ios.DeviceEntry
	for i := range list.DeviceList {
		device := list.DeviceList[i]
		if device.Properties.SerialNumber != udid {
			continue
		}
		if device.Properties.ConnectionType == want || (want == "" && device.Properties.ConnectionType == "Network") {
			return device, nil
		}
		if fallback == nil {
			fallback = &list.DeviceList[i]
		}
	}
	if want == "" {
		if fallback != nil {
			return *fallback, nil
		}
		return ios.DeviceEntry{}, fmt.Errorf("device %s is not connected", udid)
	}
	if fallback != nil {
		return ios.DeviceEntry{}, fmt.Errorf("device %s is only reachable over %s, not %s", udid, fallback.Properties.ConnectionType, want)
	}
	return ios.DeviceEntry{}, fmt.Errorf("device %s is not connected over %s", udid, want)
}

func openTunnel(device ios.DeviceEntry, requestedMTU int) (*utun.Tunnel, error) {
	conn, err := ios.ConnectToService(device, coreDeviceProxyService)
	if err != nil {
		return nil, fmt.Errorf("start %s: %w", coreDeviceProxyService, err)
	}
	tunnel, err := utun.Open(conn, requestedMTU)
	if err != nil {
		return nil, fmt.Errorf("tunnel handshake: %w", err)
	}
	return tunnel, nil
}

func statusClient(tunnel *utun.Tunnel) *http.Client {
	return &http.Client{
		Timeout: 4 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, address string) (net.Conn, error) {
				_, portText, err := net.SplitHostPort(address)
				if err != nil {
					return nil, err
				}
				port, err := strconv.Atoi(portText)
				if err != nil {
					return nil, err
				}
				return tunnel.DialTCP(ctx, port)
			},
			DisableKeepAlives: true,
		},
	}
}

func statusAnswers(ctx context.Context, client *http.Client, port int) bool {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, fmt.Sprintf("http://tunnel:%d/status", port), nil)
	if err != nil {
		return false
	}
	response, err := client.Do(request)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, response.Body)
	return response.StatusCode == http.StatusOK
}

// stopStaleRunner kills a runner left over from an earlier session. testmanagerd
// refuses to pair a new test session while the old runner process is alive,
// and that old runner has no IDE connection left to keep it useful.
func stopStaleRunner(ctx context.Context, tunnel *utun.Tunnel, device ios.DeviceEntry, bundle string, statusPort int) {
	client := statusClient(tunnel)
	if !statusAnswers(ctx, client, statusPort) {
		return
	}
	emit("runner", map[string]any{"state": "stale", "bundleId": bundle})
	apps, err := appservice.New(device)
	if err != nil {
		return
	}
	defer apps.Close()
	processes, err := apps.ListProcesses()
	if err != nil {
		return
	}
	for _, process := range processes {
		if strings.HasSuffix(process.Path, "/WebDriverAgentRunner-Runner") {
			_ = apps.KillProcess(process.Pid)
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && statusAnswers(ctx, client, statusPort) {
		time.Sleep(250 * time.Millisecond)
	}
}

// runnerFailureCode names why the runner never served its status endpoint.
// iOS asks for the passcode before the first automation session after a
// reboot (or once the previous approval expired); XCTest gives up after a
// minute without it and reports the automation-mode timeout.
func runnerFailureCode(err error) string {
	if strings.Contains(strings.ToLower(err.Error()), "enabling automation mode") {
		return "automation_not_approved"
	}
	return "runner_not_ready"
}

// slowRunnerNotice is when a launch counts as slow enough that the phone is
// probably waiting for the user (an automation approval prompt, a locked
// screen). Healthy launches answer within a few seconds over USB and Wi-Fi.
const slowRunnerNotice = 10 * time.Second

func waitForStatus(ctx context.Context, tunnel *utun.Tunnel, port int, runnerDone <-chan error, timeout time.Duration) error {
	client := statusClient(tunnel)
	started := time.Now()
	deadline := started.Add(timeout)
	announcedSlow := false
	for time.Now().Before(deadline) {
		if !announcedSlow && time.Since(started) >= slowRunnerNotice {
			announcedSlow = true
			emit("runner", map[string]any{"state": "waiting_for_device"})
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-runnerDone:
			if err == nil {
				err = errors.New("the runner exited before serving its status endpoint")
			}
			return err
		case <-time.After(500 * time.Millisecond):
		}
		if statusAnswers(ctx, client, port) {
			return nil
		}
	}
	return fmt.Errorf("the runner did not answer on port %d within %s", port, timeout)
}
