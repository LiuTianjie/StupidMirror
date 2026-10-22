@testable import StupidMirrorApp
import XCTest

final class SimulatorSupportTests: XCTestCase {
    func testBootedIOSSimulatorsAreListedAndOtherRuntimesSkipped() throws {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
            {"udid":"A","name":"iPhone 17","state":"Booted","isAvailable":true,
             "deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17"},
            {"udid":"B","name":"iPhone Air","state":"Shutdown","isAvailable":true}
          ],
          "com.apple.CoreSimulator.SimRuntime.watchOS-27-0":[
            {"udid":"C","name":"Apple Watch","state":"Booted","isAvailable":true}
          ]
        }}
        """
        let devices = try XCTUnwrap(SimulatorDiscoveryService.parseBootedDevices(Data(json.utf8)))
        XCTAssertEqual(devices, [SimulatorDevice(udid: "A", name: "iPhone 17", productType: "iPhone 17", osVersion: "27.0")])
        XCTAssertEqual(devices[0].identity.id, "simulator:A")
        XCTAssertEqual(devices[0].identity.platform, .iOS)
        // Unreadable output is unknown, not "nothing booted".
        XCTAssertNil(SimulatorDiscoveryService.parseBootedDevices(Data("not json".utf8)))
    }

    func testRuntimeVersionsAndDeviceTypesAreReadable() {
        XCTAssertEqual(SimulatorDiscoveryService.iOSVersion(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"), "26.5")
        XCTAssertNil(SimulatorDiscoveryService.iOSVersion(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.tvOS-26-5"))
        XCTAssertEqual(
            SimulatorDiscoveryService.productType(deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"),
            "iPad Pro 13 inch M5 12GB"
        )
        XCTAssertEqual(SimulatorDiscoveryService.productType(deviceTypeIdentifier: nil), "iOS Simulator")
    }

    func testRunnerListensOnLoopbackWithItsH264StreamOff() {
        let environment = SimulatorAgentService.launchEnvironment(controlPort: 1234, mjpegPort: 5678)
        XCTAssertEqual(environment["TEST_RUNNER_USE_IP"], "127.0.0.1")
        XCTAssertEqual(environment["TEST_RUNNER_USE_PORT"], "1234")
        XCTAssertEqual(environment["TEST_RUNNER_MJPEG_SERVER_PORT"], "5678")
        XCTAssertEqual(environment["TEST_RUNNER_STUPIDMIRROR_H264_PORT"], "0")
    }

    func testMJPEGPartsAreSplitAcrossChunks() {
        func part(_ body: [UInt8]) -> Data {
            Data("--BoundaryString\r\nContent-type: image/jpg\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
                + Data(body) + Data("\r\n\r\n".utf8)
        }
        let first: [UInt8] = [0xFF, 0xD8, 0x0D, 0x0A, 0x0D, 0x0A, 0xFF, 0xD9]
        let second: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]
        // The raw TCP stream starts with WDA's HTTP response header.
        let http = Data("HTTP/1.0 200 OK\r\nServer: WDA MJPEG Server\r\nContent-Type: multipart/x-mixed-replace; boundary=--BoundaryString\r\n\r\n".utf8)
        let stream = http + part(first) + part(second)
        var parser = MJPEGPartParser()
        var frames: [Data] = []
        var offset = 0
        for size in [5, 40, 3, 17, 1_000] where offset < stream.count {
            let end = min(stream.count, offset + size)
            frames += parser.append(stream.subdata(in: offset..<end))
            offset = end
        }
        XCTAssertEqual(frames, [Data(first), Data(second)])
    }

    func testContentLengthHeaderIsCaseInsensitive() {
        XCTAssertEqual(MJPEGPartParser.contentLength("--b\r\ncontent-LENGTH: 42"), 42)
        XCTAssertNil(MJPEGPartParser.contentLength("--b\r\nContent-Type: image/jpeg"))
    }

    func testBuildFailureNamesTheRealError() {
        let output = """
        warning: something harmless
        ld: building for 'iOS-simulator', but linking in object file built for 'iOS'
        clang: error: linker command failed with exit code 1 (use -v to see invocation)
        ** TEST BUILD FAILED **
        """
        XCTAssertEqual(
            SimulatorAgentService.lastErrorLine(output),
            "ld: building for 'iOS-simulator', but linking in object file built for 'iOS'"
        )
        XCTAssertEqual(
            SimulatorAgentService.lastErrorLine("a.m:3: error: unknown type\nclang: error: linker command failed"),
            "a.m:3: error: unknown type"
        )
    }
}
