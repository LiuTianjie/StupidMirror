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
}
