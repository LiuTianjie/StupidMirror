@testable import StupidMirrorApp
@preconcurrency import AVFoundation
import XCTest

final class DeviceDiscoveryTests: XCTestCase {
    func testAudioCaptureRequiresBothExplicitPreferenceAndAuthorization() {
        XCTAssertFalse(DeviceGalleryStore.shouldCaptureAudio(
            playbackEnabled: false,
            authorizationStatus: .authorized
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldCaptureAudio(
            playbackEnabled: true,
            authorizationStatus: .notDetermined
        ))
        XCTAssertTrue(DeviceGalleryStore.shouldCaptureAudio(
            playbackEnabled: true,
            authorizationStatus: .authorized
        ))
    }

    func testDeviceInfoParserReadsOneProcessPayload() {
        let parsed = DeviceMetadataService.parseInfo(
            """
            DeviceName: Test iPhone
            ProductType: iPhone18,4
            ProductVersion: 26.1
            ValueWithColon: first:second
            malformed
            """
        )

        XCTAssertEqual(parsed["DeviceName"], "Test iPhone")
        XCTAssertEqual(parsed["ProductType"], "iPhone18,4")
        XCTAssertEqual(parsed["ProductVersion"], "26.1")
        XCTAssertEqual(parsed["ValueWithColon"], "first:second")
        XCTAssertNil(parsed["malformed"])
    }

    func testSingleMetadataCandidateDoesNotMatchUnrelatedCaptureDevice() {
        let metadata = DeviceMetadata(
            udid: "real-device-udid",
            name: "Nickname's iPhone",
            productType: "iPhone18,4",
            osVersion: "26.0"
        )

        let match = DeviceMetadataService.bestMatch(
            for: "Continuity Camera",
            modelID: "MacCamera",
            candidates: [metadata]
        )

        XCTAssertNil(match)
    }

    func testSessionLookupToleratesDuplicateIDsFromPreviousDiscovery() {
        let lookup = DeviceGalleryStore.latestValueByID(["stale", "fresh"]) { _ in "device-1" }

        XCTAssertEqual(lookup["device-1"], "fresh")
    }

    func testCoreDeviceParserReadsDynamicTunnelAndAllEndpointCandidates() throws {
        let data = try XCTUnwrap(
            """
            {
              "result": {
                "devices": [
                  {
                    "connectionProperties": {
                      "pairingState": "paired",
                      "transportType": "localNetwork",
                      "localHostnames": ["Test-iPhone.coredevice.local"],
                      "potentialHostnames": ["wireless-udid.coredevice.local"],
                      "tunnelIPAddress": "fd00::1234",
                      "tunnelState": "connected"
                    },
                    "deviceProperties": {
                      "bootState": "booted",
                      "name": "Test iPhone",
                      "osVersionNumber": "26.5"
                    },
                    "hardwareProperties": {
                      "deviceType": "iPhone",
                      "platform": "iOS",
                      "productType": "iPhone18,4",
                      "reality": "physical",
                      "udid": "wireless-udid"
                    }
                  },
                  {
                    "connectionProperties": {
                      "pairingState": "paired",
                      "potentialHostnames": ["Offline.coredevice.local"]
                    },
                    "deviceProperties": {"name": "Offline"},
                    "hardwareProperties": {
                      "deviceType": "iPhone",
                      "platform": "iOS",
                      "reality": "physical",
                      "udid": "offline-udid"
                    }
                  }
                ]
              }
            }
            """.data(using: .utf8)
        )

        XCTAssertEqual(
            CoreDeviceDiscoveryService.parseWirelessDevices(data),
            [
                WirelessDeviceMetadata(
                    udid: "wireless-udid",
                    name: "Test iPhone",
                    productType: "iPhone18,4",
                    osVersion: "26.5",
                    hostname: "Test-iPhone.coredevice.local",
                    hostnames: [
                        "Test-iPhone.coredevice.local",
                        "wireless-udid.coredevice.local"
                    ],
                    tunnelIPAddress: "fd00::1234",
                    tunnelState: "connected"
                )
            ]
        )

        let device = try XCTUnwrap(CoreDeviceDiscoveryService.parseWirelessDevices(data).first)
        XCTAssertTrue(device.isTunnelConnected)
        XCTAssertEqual(device.endpointURLs(port: 8100).map(\.absoluteString), [
            "http://[fd00::1234]:8100",
            "http://Test-iPhone.coredevice.local:8100",
            "http://wireless-udid.coredevice.local:8100"
        ])
    }

    func testWirelessTunnelMustBeConnectedBeforeItIsUsable() {
        let device = WirelessDeviceMetadata(
            udid: "device",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5",
            hostname: "device.coredevice.local",
            tunnelIPAddress: "198.18.0.1",
            tunnelState: "disconnected"
        )

        XCTAssertFalse(device.isTunnelConnected)
        XCTAssertEqual(device.endpointURLs(port: 9200).first?.absoluteString, "http://198.18.0.1:9200")
    }

    func testWirelessWDAKeepsAppleCoreDeviceHostnameForControlDiscovery() {
        XCTAssertEqual(
            WirelessWDAService.lanHostname(from: "Test-iPhone.coredevice.local"),
            "Test-iPhone.coredevice.local"
        )
    }

    func testWirelessWDAEndpointUsesReportedLANAddressForVideo() throws {
        let controlURL = try XCTUnwrap(URL(string: "http://[fd68:8f67:2e76::1]:8100"))
        let endpoint = WirelessWDAService.endpoint(
            baseURL: controlURL,
            statusJSON: [
                "value": [
                    "ready": true,
                    "ios": ["ip": "192.168.31.135"]
                ]
            ]
        )

        XCTAssertEqual(endpoint?.controlURL, controlURL)
        XCTAssertEqual(endpoint?.videoHost, "192.168.31.135")
    }

    func testWirelessWDADetectsLockedAndUnavailableDestinations() {
        XCTAssertTrue(WirelessWDAService.outputIndicatesLockedDevice(
            "Unlock iPhone Air to Continue. The device is locked."
        ))
        XCTAssertTrue(WirelessWDAService.outputIndicatesUnavailableDevice(
            "Device is busy (Connecting to iPhone Air)"
        ))
        XCTAssertFalse(WirelessWDAService.outputIndicatesLockedDevice("Testing started"))
        XCTAssertFalse(WirelessWDAService.outputIndicatesUnavailableDevice("Testing started"))
    }

    func testWirelessWDAUsesXCTestRunnerBundleIdentifier() {
        XCTAssertEqual(
            WirelessWDAService.runnerBundleIdentifier(for: "com.example.wda"),
            "com.example.wda.xctrunner"
        )
    }

    func testWirelessWDAReadsLaunchedProcessIdentifier() throws {
        let data = try XCTUnwrap(
            #"{"result":{"process":{"processIdentifier":59076}}}"#.data(using: .utf8)
        )
        XCTAssertEqual(
            WirelessWDAService.processIdentifier(fromDevicectlJSON: data),
            59_076
        )
        XCTAssertNil(WirelessWDAService.processIdentifier(fromDevicectlJSON: Data("{}".utf8)))
    }

}
