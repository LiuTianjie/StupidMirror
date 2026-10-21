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

    func testUSBWaitsWhileAWirelessSessionForThePhoneIsInUse() {
        XCTAssertTrue(DeviceGalleryStore.shouldDeferUSBForWireless(
            wirelessModeEnabled: true,
            usbUDID: "UDID-1",
            activeWirelessUDIDs: ["UDID-1"]
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldDeferUSBForWireless(
            wirelessModeEnabled: true,
            usbUDID: "UDID-1",
            activeWirelessUDIDs: ["UDID-2"]
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldDeferUSBForWireless(
            wirelessModeEnabled: false,
            usbUDID: "UDID-1",
            activeWirelessUDIDs: ["UDID-1"]
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldDeferUSBForWireless(
            wirelessModeEnabled: true,
            usbUDID: nil,
            activeWirelessUDIDs: ["UDID-1"]
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

    func testWirelessDiscoveryListsEveryPhoneUsbmuxdReachesOverTheNetwork() {
        let cache = WirelessDiscoveryService.IdentityCache()
        cache.remember(DeviceMetadata(
            udid: "both",
            name: "iPhone Air",
            productType: "iPhone18,4",
            osVersion: "27.0"
        ))
        let devices = WirelessDiscoveryService.wirelessDevices(
            from: [
                DeviceTunnelDeviceEntry(udid: "usb-only", connectionTypes: ["USB"]),
                DeviceTunnelDeviceEntry(udid: "both", connectionTypes: ["USB", "Network"]),
                DeviceTunnelDeviceEntry(udid: "wifi-only", connectionTypes: ["Network"]),
                DeviceTunnelDeviceEntry(udid: "both", connectionTypes: ["Network"])
            ],
            cache: cache
        )

        XCTAssertEqual(devices, [
            WirelessDeviceMetadata(
                udid: "both",
                name: "iPhone Air",
                productType: "iPhone18,4",
                osVersion: "27.0",
                isAlsoOnUSB: true
            ),
            WirelessDeviceMetadata(
                udid: "wifi-only",
                name: "iPhone",
                productType: "iOS Device",
                osVersion: "",
                hasIdentity: false
            )
        ])
    }

    func testWirelessDiscoveryLearnsIdentityFromDetailedListing() {
        let detailed = DeviceTunnelSidecar.parseDeviceList([
            ["udid": "A", "connectionTypes": ["Network"], "name": "Test iPhone", "productType": "iPhone18,4", "productVersion": "27.0"],
            ["udid": "B", "connectionTypes": ["Network"], "error": "lockdown did not answer within 3s"]
        ])

        XCTAssertEqual(
            detailed.compactMap(WirelessDiscoveryService.identityMetadata(from:)),
            [DeviceMetadata(udid: "A", name: "Test iPhone", productType: "iPhone18,4", osVersion: "27.0")]
        )
    }

    func testCoreDeviceParserProvidesWiredMetadataWithoutLibimobiledevice() throws {
        let data = try XCTUnwrap(
            """
            {
              "result": {
                "devices": [
                  {
                    "connectionProperties": {
                      "pairingState": "paired",
                      "transportType": "wired",
                      "tunnelState": "disconnected"
                    },
                    "deviceProperties": {
                      "name": "iPhone Air",
                      "osVersionNumber": "27.0"
                    },
                    "hardwareProperties": {
                      "deviceType": "iPhone",
                      "platform": "iOS",
                      "productType": "iPhone18,4",
                      "reality": "physical",
                      "udid": "wired-udid"
                    }
                  },
                  {
                    "connectionProperties": {
                      "pairingState": "paired",
                      "transportType": "localNetwork"
                    },
                    "deviceProperties": {"name": "Wireless iPhone"},
                    "hardwareProperties": {
                      "deviceType": "iPhone",
                      "platform": "iOS",
                      "reality": "physical",
                      "udid": "wireless-udid"
                    }
                  }
                ]
              }
            }
            """.data(using: .utf8)
        )

        XCTAssertEqual(
            CoreDeviceDiscoveryService.parseUSBDevices(data),
            [
                DeviceMetadata(
                    udid: "wired-udid",
                    name: "iPhone Air",
                    productType: "iPhone18,4",
                    osVersion: "27.0"
                )
            ]
        )
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
                osVersion: "26.5"
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

    func testLiveWirelessSessionSurvivesAMissedDiscoveryPoll() {
        XCTAssertTrue(DeviceGalleryStore.shouldKeepLiveWirelessSession(
            isIOSWireless: true,
            connectionState: .connected,
            tunnelRunning: true
        ))
        // Without a tunnel, a phone missing from usbmuxd is really gone.
        XCTAssertFalse(DeviceGalleryStore.shouldKeepLiveWirelessSession(
            isIOSWireless: true,
            connectionState: .connected,
            tunnelRunning: false
        ))
        // USB sessions follow the capture device, not the tunnel.
        XCTAssertFalse(DeviceGalleryStore.shouldKeepLiveWirelessSession(
            isIOSWireless: false,
            connectionState: .connected,
            tunnelRunning: true
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldKeepLiveWirelessSession(
            isIOSWireless: true,
            connectionState: .disconnected,
            tunnelRunning: true
        ))
    }

    @MainActor
    func testWirelessSessionCanAcceptRefreshedDiscoveryWithoutReplacingOwners() {
        // The first poll had no identity yet; a later one read it.
        let original = WirelessDeviceMetadata(
            udid: "device",
            name: "iPhone",
            productType: "iOS Device",
            osVersion: "",
            hasIdentity: false
        )
        let refreshed = WirelessDeviceMetadata(
            udid: "device",
            name: "Test iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5"
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
        let wdaOwner = session.iosAgent

        XCTAssertTrue(DeviceGalleryStore.canReuseWirelessSession(session, for: refreshed))
        session.wirelessDevice = refreshed

        XCTAssertTrue(session.mirrorSession === mirrorOwner)
        XCTAssertTrue(session.controlSession === controlOwner)
        XCTAssertTrue(session.iosAgent === wdaOwner)
        XCTAssertEqual(session.wirelessDevice?.name, "Test iPhone")
        XCTAssertEqual(session.mirrorSession.wirelessDeviceUDID, "device")
    }

    @MainActor
    func testAdoptWirelessKeepsControlAndWDAOwners() {
        let original = WirelessDeviceMetadata(
            udid: "device",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5"
        )
        let connected = WirelessDeviceMetadata(
            udid: "device",
            name: "iPhone",
            productType: "iPhone18,4",
            osVersion: "26.5"
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
        let wdaOwner = session.iosAgent

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
        XCTAssertTrue(session.iosAgent === wdaOwner)
        XCTAssertEqual(session.device.connectionState, .connected)
    }

    func testWirelessWDADetectsLockedAndUnavailableDestinations() {
        XCTAssertTrue(IOSAgentService.outputIndicatesLockedDevice(
            "Unlock iPhone Air to Continue. The device is locked."
        ))
        XCTAssertFalse(IOSAgentService.outputIndicatesLockedDevice("Testing started"))
    }

    func testWirelessWDAUsesXCTestRunnerBundleIdentifier() {
        XCTAssertEqual(
            IOSAgentService.runnerBundleIdentifier(for: "com.example.wda"),
            "com.example.wda.xctrunner"
        )
    }

    func testWirelessWDAInstallationFailuresAreRecognised() {
        XCTAssertTrue(IOSAgentService.outputIndicatesMissingInstallation(
            "RunTestWithConfig: could not find app with bundle id com.x.xctrunner"
        ))
        XCTAssertTrue(IOSAgentService.outputIndicatesMissingInstallation(
            "The application com.x.xctrunner is not installed on this device."
        ))
        XCTAssertFalse(IOSAgentService.outputIndicatesMissingInstallation(
            "the runner did not answer on port 8100 within 1m30s"
        ))
    }

    func testUSBRetargetTriggersWhenCMIOPublishesNewCaptureDeviceInstanceWithSameUniqueID() {
        XCTAssertFalse(
            DeviceSession.needsUSBRetarget(
                currentTransport: .usb,
                currentUniqueID: "00008150-001614E40200401C",
                newUniqueID: "00008150-001614E40200401C",
                sameCaptureDeviceInstance: true
            )
        )
        // After a brief USB blip or Configuration 6 <-> 7 reset, CoreMediaIO
        // destroys the old AVCaptureDALDevice and publishes a new instance with
        // the same uniqueID. It must retarget so the dead CMIOGraph is torn down.
        XCTAssertTrue(
            DeviceSession.needsUSBRetarget(
                currentTransport: .usb,
                currentUniqueID: "00008150-001614E40200401C",
                newUniqueID: "00008150-001614E40200401C",
                sameCaptureDeviceInstance: false
            )
        )
        XCTAssertTrue(
            DeviceSession.needsUSBRetarget(
                currentTransport: .wireless,
                currentUniqueID: nil,
                newUniqueID: "00008150-001614E40200401C",
                sameCaptureDeviceInstance: false
            )
        )
    }

    func testShouldResumeAfterAdoptionResumesStoppedMirrorOrReplacedCaptureDevice() {
        XCTAssertTrue(
            DeviceGalleryStore.shouldResumeAfterAdoption(
                wanted: true,
                previousConnectionState: .disconnected,
                previousTransport: .usb,
                newTransport: .usb,
                mirrorState: .stopped,
                captureDeviceChanged: false
            )
        )
        XCTAssertTrue(
            DeviceGalleryStore.shouldResumeAfterAdoption(
                wanted: true,
                previousConnectionState: .connected,
                previousTransport: .usb,
                newTransport: .usb,
                mirrorState: .running,
                captureDeviceChanged: true
            )
        )
        XCTAssertTrue(
            DeviceGalleryStore.shouldResumeAfterAdoption(
                wanted: true,
                previousConnectionState: .connected,
                previousTransport: .usb,
                newTransport: .usb,
                mirrorState: .stopped,
                captureDeviceChanged: false
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldResumeAfterAdoption(
                wanted: true,
                previousConnectionState: .connected,
                previousTransport: .usb,
                newTransport: .usb,
                mirrorState: .running,
                captureDeviceChanged: false
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldResumeAfterAdoption(
                wanted: false,
                previousConnectionState: .disconnected,
                previousTransport: .usb,
                newTransport: .usb,
                mirrorState: .stopped,
                captureDeviceChanged: true
            )
        )
    }

    func testUSBThumbnailCaptureIsSuppressedDuringControlOrTunnelOrBackground() {
        XCTAssertTrue(
            DeviceGalleryStore.shouldStartUSBThumbnailCapture(
                liveMirrorDesired: false,
                mirrorState: .stopped
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldStartUSBThumbnailCapture(
                liveMirrorDesired: false,
                mirrorState: .stopped,
                controlActive: true
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldStartUSBThumbnailCapture(
                liveMirrorDesired: false,
                mirrorState: .stopped,
                tunnelRunning: true
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldStartUSBThumbnailCapture(
                liveMirrorDesired: false,
                mirrorState: .stopped,
                preparingIPhone: true
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldStartUSBThumbnailCapture(
                liveMirrorDesired: false,
                mirrorState: .stopped,
                isBackgroundProcess: true
            )
        )
    }

    func testControlResumeAndRetryPolicySurvivesTransientUSBResets() {
        XCTAssertTrue(DeviceGalleryStore.shouldRetryControlConnection(IOSAgentError.deviceUnavailable))
        XCTAssertTrue(DeviceGalleryStore.shouldRetryControlConnection(IOSAgentError.launchFailed))
        XCTAssertTrue(DeviceGalleryStore.shouldRetryControlConnection(IOSAgentError.timedOut))
        XCTAssertTrue(DeviceGalleryStore.shouldRetryControlConnection(ControlBackendError.sessionLost("EOF")))
        XCTAssertFalse(DeviceGalleryStore.shouldRetryControlConnection(IOSAgentError.setupRequired))
        XCTAssertFalse(DeviceGalleryStore.shouldRetryControlConnection(IOSAgentError.developerModeDisabled))
        XCTAssertFalse(DeviceGalleryStore.shouldRetryControlConnection(ControlBackendError.rejected("bad element")))

        XCTAssertTrue(DeviceGalleryStore.shouldKeepDesiredControlAfterFailure(
            messageKey: IOSAgentError.deviceUnavailable.copyKey
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldKeepDesiredControlAfterFailure(
            messageKey: IOSAgentError.setupRequired.copyKey
        ))
        XCTAssertFalse(DeviceGalleryStore.shouldKeepDesiredControlAfterFailure(
            messageKey: IOSAgentError.deviceLocked.copyKey
        ))

        XCTAssertTrue(
            DeviceGalleryStore.shouldResumeControl(
                wanted: true,
                connectionState: .connected,
                controlState: .failed("agent.error.deviceUnavailable")
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldResumeControl(
                wanted: true,
                connectionState: .connected,
                controlState: .ready
            )
        )
        XCTAssertFalse(
            DeviceGalleryStore.shouldResumeControl(
                wanted: true,
                connectionState: .disconnected,
                controlState: .failed("agent.error.deviceUnavailable")
            )
        )
    }
}
