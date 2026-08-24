@testable import StupidMirrorApp
@preconcurrency import AVFoundation
import XCTest

final class DeviceDiscoveryTests: XCTestCase {
    func testCameraPermissionRemainsReachableWhenAndroidIsConnected() {
        XCTAssertEqual(
            DeviceGalleryStore.cameraPermissionPresentation(
                authorizationStatus: .notDetermined,
                hasCameraIndependentConnectedDevice: true
            ),
            .banner
        )
        XCTAssertEqual(
            DeviceGalleryStore.cameraPermissionPresentation(
                authorizationStatus: .denied,
                hasCameraIndependentConnectedDevice: true
            ),
            .banner
        )
    }

    func testCameraPermissionUsesFullPageWithoutAnotherUsableDevice() {
        XCTAssertEqual(
            DeviceGalleryStore.cameraPermissionPresentation(
                authorizationStatus: .notDetermined,
                hasCameraIndependentConnectedDevice: false
            ),
            .fullPage
        )
        XCTAssertEqual(
            DeviceGalleryStore.cameraPermissionPresentation(
                authorizationStatus: .authorized,
                hasCameraIndependentConnectedDevice: true
            ),
            .hidden
        )
    }

    func testAudioCaptureRequiresPreferenceAndPermission() {
        XCTAssertFalse(DeviceGalleryStore.shouldCaptureAudio(
            playbackEnabled: false,
            authorizationStatus: .authorized
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldCaptureAudio(
            playbackEnabled: true,
            authorizationStatus: .denied
        ))
        XCTAssertTrue(DeviceGalleryStore.shouldCaptureAudio(
            playbackEnabled: true,
            authorizationStatus: .authorized
        ))
    }

    func testWirelessModeDefersUSBWhenTheTunnelIsConnected() {
        XCTAssertTrue(DeviceGalleryStore.shouldDeferUSBForWireless(
            wirelessModeEnabled: true,
            usbUDID: "UDID-1",
            wirelessConnectedUDIDs: ["UDID-1"]
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldDeferUSBForWireless(
            wirelessModeEnabled: true,
            usbUDID: "UDID-1",
            wirelessConnectedUDIDs: ["UDID-2"]
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldDeferUSBForWireless(
            wirelessModeEnabled: false,
            usbUDID: "UDID-1",
            wirelessConnectedUDIDs: ["UDID-1"]
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldDeferUSBForWireless(
            wirelessModeEnabled: true,
            usbUDID: nil,
            wirelessConnectedUDIDs: ["UDID-1"]
        ))
    }

    func testFailedWirelessDiscoveryPreservesWirelessSessionsOnly() {
        XCTAssertTrue(DeviceGalleryStore.shouldPreserveIOSSessionWhenWirelessDiscoveryFails(
            transport: .wireless,
            platform: .iOS,
            isAndroid: false
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldPreserveIOSSessionWhenWirelessDiscoveryFails(
            transport: .usb,
            platform: .iOS,
            isAndroid: false
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldPreserveIOSSessionWhenWirelessDiscoveryFails(
            transport: .wireless,
            platform: .android,
            isAndroid: true
        ))
    }

    func testUSBThumbnailCaptureYieldsToALiveMirror() {
        XCTAssertFalse(DeviceGalleryStore.shouldStartUSBThumbnailCapture(
            liveMirrorDesired: true,
            mirrorState: .stopped
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldStartUSBThumbnailCapture(
            liveMirrorDesired: false,
            mirrorState: .starting
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldStartUSBThumbnailCapture(
            liveMirrorDesired: false,
            mirrorState: .running
        ))
        XCTAssertTrue(DeviceGalleryStore.shouldStartUSBThumbnailCapture(
            liveMirrorDesired: false,
            mirrorState: .stopped
        ))
    }

    func testIOSUSBAudioStaysOnPhoneUnlessMacPlaybackIsAuthorized() {
        XCTAssertFalse(IOSUSBAudioRouting.shouldEnableMuxedAudioPorts(
            playbackEnabled: false,
            authorizationStatus: .authorized
        ))
        XCTAssertFalse(IOSUSBAudioRouting.shouldEnableMuxedAudioPorts(
            playbackEnabled: true,
            authorizationStatus: .notDetermined
        ))
        XCTAssertFalse(IOSUSBAudioRouting.shouldEnableMuxedAudioPorts(
            playbackEnabled: true,
            authorizationStatus: .denied
        ))
        XCTAssertTrue(IOSUSBAudioRouting.shouldEnableMuxedAudioPorts(
            playbackEnabled: true,
            authorizationStatus: .authorized
        ))
    }

    func testAndroidAudioDuplicationRequiresAndroid13() {
        XCTAssertFalse(AndroidScrcpyStream.shouldDuplicateDeviceAudio(sdkVersion: nil))
        XCTAssertFalse(AndroidScrcpyStream.shouldDuplicateDeviceAudio(sdkVersion: 32))
        XCTAssertTrue(AndroidScrcpyStream.shouldDuplicateDeviceAudio(sdkVersion: 33))
        XCTAssertTrue(AndroidScrcpyStream.shouldDuplicateDeviceAudio(sdkVersion: 36))
    }

    func testAndroidServerKeepsDeviceSpeakerUnlessMacPlaybackIsOn() {
        XCTAssertEqual(
            AndroidScrcpyStream.serverAudioArguments(
                audioEnabled: false,
                duplicateDeviceAudio: true
            ),
            ["audio=false"]
        )
        XCTAssertEqual(
            AndroidScrcpyStream.serverAudioArguments(
                audioEnabled: true,
                duplicateDeviceAudio: false
            ),
            ["audio=true", "audio_codec=raw"]
        )
        XCTAssertEqual(
            AndroidScrcpyStream.serverAudioArguments(
                audioEnabled: true,
                duplicateDeviceAudio: true
            ),
            ["audio=true", "audio_codec=raw", "audio_source=playback", "audio_dup=true"]
        )
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

    func testUSBIdentityPrefersMetadataThenCacheThenExistingUDID() {
        let metadata = DeviceMetadata(
            udid: "metadata-udid",
            name: "Phone",
            productType: "iPhone18,4",
            osVersion: "26.5"
        )
        XCTAssertEqual(
            AVFoundationMirrorBackend.resolvedUDID(
                captureUniqueID: "capture-1",
                metadataMatch: metadata,
                cachedUDID: "cached-udid",
                existingUDID: "existing-udid"
            ),
            "metadata-udid"
        )
        XCTAssertEqual(
            AVFoundationMirrorBackend.resolvedUDID(
                captureUniqueID: "capture-1",
                metadataMatch: nil,
                cachedUDID: "cached-udid",
                existingUDID: "existing-udid"
            ),
            "cached-udid"
        )
        XCTAssertEqual(
            AVFoundationMirrorBackend.resolvedUDID(
                captureUniqueID: "capture-1",
                metadataMatch: nil,
                cachedUDID: nil,
                existingUDID: "existing-udid"
            ),
            "existing-udid"
        )
        XCTAssertNil(
            AVFoundationMirrorBackend.resolvedUDID(
                captureUniqueID: "capture-1",
                metadataMatch: nil,
                cachedUDID: nil,
                existingUDID: nil
            )
        )
    }

    func testSoleUSBCaptureBindsTheOnlyMetadataRecord() {
        let metadata = DeviceMetadata(
            udid: "only-udid",
            name: "Nickname",
            productType: "iPhone18,4",
            osVersion: "26.5"
        )
        XCTAssertEqual(
            AVFoundationMirrorBackend.preferSoleMetadataMatch(
                captureCount: 1,
                metadata: [metadata]
            )?.udid,
            "only-udid"
        )
        XCTAssertNil(
            AVFoundationMirrorBackend.preferSoleMetadataMatch(
                captureCount: 2,
                metadata: [metadata]
            )
        )
    }

    func testWirelessDiscoveryFailureIsDistinctFromAnEmptyDeviceList() {
        XCTAssertNotEqual(
            WirelessDiscoveryOutcome.unavailable,
            WirelessDiscoveryOutcome.available([])
        )
        XCTAssertEqual(
            WirelessDiscoveryOutcome.available([]),
            WirelessDiscoveryOutcome.available([])
        )
    }

    func testDisconnectedSessionsAreKeptForTheRetentionWindow() {
        let now = Date()
        XCTAssertTrue(
            DeviceGalleryStore.shouldKeepDisconnectedSession(
                previouslyConnected: true,
                disconnectedAt: now,
                now: now,
                retention: 30
            )
        )
        XCTAssertTrue(
            DeviceGalleryStore.shouldKeepDisconnectedSession(
                previouslyConnected: false,
                disconnectedAt: now.addingTimeInterval(-10),
                now: now,
                retention: 30
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldKeepDisconnectedSession(
                previouslyConnected: false,
                disconnectedAt: now.addingTimeInterval(-31),
                now: now,
                retention: 30
            )
        )
    }

    func testWirelessStreamRetryUsesTheFailureWindowNotTheOriginalStartTime() {
        let now = Date()
        XCTAssertTrue(
            MirrorCaptureSession.shouldRetryWirelessFailure(
                lastFailureAt: now.addingTimeInterval(-10),
                now: now,
                window: 120
            )
        )
        XCTAssertFalse(
            MirrorCaptureSession.shouldRetryWirelessFailure(
                lastFailureAt: now.addingTimeInterval(-121),
                now: now,
                window: 120
            )
        )
        XCTAssertTrue(
            MirrorCaptureSession.shouldRetryWirelessFailure(
                lastFailureAt: nil,
                now: now,
                window: 120
            )
        )
    }

    @MainActor
    func testSessionMatchesDiscoveryByUDIDAndLastUSBCaptureID() {
        let identity = DeviceIdentity(
            id: "unique-capture",
            udid: nil,
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5",
            connectionState: .disconnected,
            trustState: .trusted
        )
        var session = DeviceSession(
            device: identity,
            wirelessDevice: WirelessDeviceMetadata(
                udid: "later-udid",
                name: "iPhone",
                productType: "iPhone18,4",
                osVersion: "26.5",
                hostname: "iphone.coredevice.local"
            )
        )
        session.id = "unique-capture"
        session.lastUSBCaptureUniqueID = "capture-unique"

        XCTAssertTrue(session.matchesDiscovery(id: "unique-capture", udid: nil, captureUniqueID: "capture-unique"))
        XCTAssertFalse(session.matchesDiscovery(id: "other", udid: "later-udid", captureUniqueID: nil))

        session.device = DeviceIdentity(
            id: "later-udid",
            udid: "later-udid",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5",
            connectionState: .connected,
            trustState: .trusted
        )
        session.id = "later-udid"
        XCTAssertTrue(session.matchesDiscovery(id: "later-udid", udid: "later-udid", captureUniqueID: "capture-unique"))
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

    func testUSBControlDoesNotResolveRetainedWirelessTransport() {
        XCTAssertFalse(DeviceGalleryStore.shouldResolveWirelessControl(for: .usb))
        XCTAssertTrue(DeviceGalleryStore.shouldResolveWirelessControl(for: .wireless))
    }

    @MainActor
    func testWirelessSessionCanAcceptDynamicEndpointRefreshWithoutReplacingOwners() {
        let original = WirelessDeviceMetadata(
            udid: "device",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5",
            hostname: "device.coredevice.local",
            tunnelIPAddress: "fd00::1",
            tunnelState: "connected"
        )
        let refreshed = WirelessDeviceMetadata(
            udid: "device",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5",
            hostname: "device.coredevice.local",
            tunnelIPAddress: "fd00::2",
            tunnelState: "connected"
        )
        let identity = DeviceIdentity(
            id: "device",
            udid: "device",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5",
            connectionState: .connected,
            trustState: .trusted
        )
        var session = DeviceSession(device: identity, wirelessDevice: original)
        let mirrorOwner = session.mirrorSession
        let controlOwner = session.controlSession
        let wdaOwner = session.wirelessWDA

        XCTAssertTrue(DeviceGalleryStore.canReuseWirelessSession(session, for: refreshed))
        session.wirelessDevice = refreshed

        XCTAssertTrue(session.mirrorSession === mirrorOwner)
        XCTAssertTrue(session.controlSession === controlOwner)
        XCTAssertTrue(session.wirelessWDA === wdaOwner)
        XCTAssertEqual(session.wirelessDevice?.tunnelIPAddress, "fd00::2")
    }

    @MainActor
    func testAdoptWirelessKeepsControlAndWDAOwners() {
        let original = WirelessDeviceMetadata(
            udid: "device",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5",
            hostname: "device.coredevice.local",
            tunnelIPAddress: "fd00::1",
            tunnelState: "disconnected"
        )
        let connected = WirelessDeviceMetadata(
            udid: "device",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5",
            hostname: "device.coredevice.local",
            tunnelIPAddress: "fd00::1",
            tunnelState: "connected"
        )
        var session = DeviceSession(
            device: DeviceIdentity(
                id: "device",
                udid: "device",
                name: "iPhone",
                productType: "iPhone18,4",
                osVersion: "26.5",
                connectionState: .disconnected,
                trustState: .trusted
            ),
            wirelessDevice: original
        )
        let mirrorOwner = session.mirrorSession
        let controlOwner = session.controlSession
        let wdaOwner = session.wirelessWDA

        session.adoptWireless(
            identity: DeviceIdentity(
                id: "device",
                udid: "device",
                name: "iPhone",
                productType: "iPhone18,4",
                osVersion: "26.5",
                connectionState: .connected,
                trustState: .trusted
            ),
            wirelessDevice: connected
        )

        XCTAssertEqual(session.transport, .wireless)
        XCTAssertTrue(session.mirrorSession === mirrorOwner)
        XCTAssertTrue(session.controlSession === controlOwner)
        XCTAssertTrue(session.wirelessWDA === wdaOwner)
        XCTAssertEqual(session.device.connectionState, .connected)
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

    func testWirelessWDAControlURLFormatsIPv6Hosts() throws {
        XCTAssertEqual(
            WirelessWDAService.controlURL(host: "192.168.31.135")?.absoluteString,
            "http://192.168.31.135:8100"
        )
        XCTAssertEqual(
            WirelessWDAService.controlURL(host: "fd00::1234")?.absoluteString,
            "http://[fd00::1234]:8100"
        )
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
