import Foundation
import XCTest
@testable import StupidMirrorApp

/// The sidecar speaks JSON lines; these pin the contract the Swift side reads.
final class DeviceTunnelSidecarEventTests: XCTestCase {
    func testParsesAForwardEvent() throws {
        let event = try XCTUnwrap(DeviceTunnelEvent.parse(
            #"{"devicePort":8100,"event":"forward","localPort":54321,"proto":"tcp","t":"2026-10-02T16:53:35Z"}"#
        ))
        XCTAssertEqual(event.name, "forward")
        XCTAssertEqual(event.int("devicePort"), 8_100)
        XCTAssertEqual(event.int("localPort"), 54_321)
        XCTAssertEqual(event.string("proto"), "tcp")
    }

    func testIgnoresGoIOSLogLinesAndPartialOutput() {
        XCTAssertNil(DeviceTunnelEvent.parse(
            "2026/10/02 09:43:37 INFO userspace tunnel negotiated module=go-ios/tunnel"
        ))
        XCTAssertNil(DeviceTunnelEvent.parse(#"{"devicePort":8100,"ev"#))
        XCTAssertNil(DeviceTunnelEvent.parse(#"{"noEvent":true}"#))
        XCTAssertNil(DeviceTunnelEvent.parse(""))
    }

    func testReadsDeviceListsAndWifiFlags() throws {
        let devices = try XCTUnwrap(DeviceTunnelEvent.parse(
            #"{"event":"devices","devices":[{"udid":"A","connectionType":"Network","deviceId":16},{"udid":"A","connectionType":"USB","deviceId":15}]}"#
        ))
        XCTAssertEqual(devices.array("devices").count, 2)
        XCTAssertEqual(devices.array("devices").first?["connectionType"] as? String, "Network")

        let wifi = try XCTUnwrap(DeviceTunnelEvent.parse(
            #"{"event":"wifi","udid":"A","connectionType":"USB","enableWifiConnections":true}"#
        ))
        XCTAssertEqual(wifi.bool("enableWifiConnections"), true)
    }

    func testMapsSidecarErrorCodes() {
        XCTAssertEqual(
            DeviceTunnelSidecarError.from(code: "device_not_found", message: "device X is not connected"),
            .deviceNotFound("device X is not connected")
        )
        XCTAssertEqual(
            DeviceTunnelSidecarError.from(code: "developer_image_missing", message: "no testmanagerd"),
            .developerImageMissing("no testmanagerd")
        )
        XCTAssertEqual(
            DeviceTunnelSidecarError.from(code: "runner_not_ready", message: "no /status"),
            .runnerNotReady("no /status")
        )
        XCTAssertEqual(
            DeviceTunnelSidecarError.from(code: "tunnel_closed", message: "EOF"),
            .tunnelClosed("EOF")
        )
        XCTAssertEqual(
            DeviceTunnelSidecarError.from(code: "rsd_failed", message: "handshake"),
            .tunnelFailed("handshake")
        )
    }

    func testBuildsServeArgumentsForTheWirelessAgent() {
        let configuration = IOSAgentService.sidecarConfiguration(
            udid: "00008150-TEST",
            transport: .auto,
            bundleID: "com.stupidmirror.wda.abc"
        )
        let arguments = DeviceTunnelSidecar.arguments(for: configuration)

        XCTAssertEqual(arguments.prefix(5), ["serve", "--udid", "00008150-TEST", "--transport", "auto"])
        XCTAssertTrue(arguments.contains("--watch-stdin"))
        XCTAssertTrue(arguments.contains("com.stupidmirror.wda.abc.xctrunner"))
        XCTAssertTrue(arguments.contains("USE_PORT=8100"))
        XCTAssertTrue(arguments.contains("STUPIDMIRROR_H264_PORT=9200"))
        XCTAssertTrue(arguments.contains("WDA_PRODUCT_BUNDLE_IDENTIFIER=com.stupidmirror.wda.abc.xctrunner"))
        XCTAssertEqual(arguments.filter { $0 == "--tcp" }.count, 2)
        XCTAssertEqual(arguments.filter { $0 == "--udp" }.count, 1)
        XCTAssertEqual(arguments.suffix(2), ["--status-port", "8100"])
    }

    func testEndpointsBecomeLoopbackControlAndVideoAddresses() throws {
        let endpoints = DeviceTunnelEndpoints(
            udid: "00008150-TEST",
            connectionType: "Network",
            tunnelAddress: "fd82:a74c:d7b8::1",
            tcpPorts: [8_100: 18_100, 9_100: 19_100],
            udpPorts: [9_200: 19_200]
        )
        let endpoint = try XCTUnwrap(IOSAgentService.endpoint(for: endpoints))
        XCTAssertEqual(endpoint.controlURL.absoluteString, "http://127.0.0.1:18100")
        XCTAssertEqual(endpoint.videoHost, "127.0.0.1")
        XCTAssertEqual(endpoint.videoPort, 19_200)

        let withoutVideo = DeviceTunnelEndpoints(
            udid: "00008150-TEST",
            connectionType: "USB",
            tunnelAddress: "fd82::1",
            tcpPorts: [8_100: 18_100],
            udpPorts: [:]
        )
        XCTAssertNil(IOSAgentService.endpoint(for: withoutVideo))
    }

    func testSidecarFailuresAreNamedForTheUser() {
        XCTAssertEqual(
            IOSAgentService.agentError(from: .deviceNotFound("device X is only reachable over USB, not Network")),
            .wifiConnectionsUnavailable
        )
        XCTAssertEqual(
            IOSAgentService.agentError(from: .deviceNotFound("device X is not connected")),
            .deviceUnavailable
        )
        XCTAssertEqual(
            IOSAgentService.agentError(from: .developerImageMissing("no testmanagerd")),
            .developerImageMissing
        )
        XCTAssertEqual(
            IOSAgentService.agentError(from: .runnerNotReady("the runner did not answer on port 8100 within 1m30s")),
            .timedOut
        )
        XCTAssertEqual(
            IOSAgentService.agentError(from: .runnerExited("could not find app with bundle id com.x.xctrunner")),
            .setupRequired
        )
        XCTAssertEqual(
            IOSAgentService.agentError(from: .tunnelClosed("read: connection reset")),
            .launchFailed
        )
        XCTAssertEqual(IOSAgentService.agentError(from: .missingSidecar), .missingRuntime)
        // Asked for USB but the cable is out: that is not a Wi-Fi problem.
        XCTAssertEqual(
            IOSAgentService.agentError(from: .deviceNotFound("device X is only reachable over Network, not USB")),
            .deviceUnavailable
        )
        XCTAssertEqual(
            DeviceTunnelSidecarError.from(
                code: "automation_not_approved",
                message: "Timed out while enabling automation mode."
            ),
            .automationNotApproved("Timed out while enabling automation mode.")
        )
        XCTAssertEqual(
            IOSAgentService.agentError(from: .automationNotApproved("Timed out while enabling automation mode.")),
            .automationNotApproved
        )
    }
}
