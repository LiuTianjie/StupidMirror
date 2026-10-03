import CoreGraphics
import Foundation
import XCTest
@testable import StupidMirrorApp

/// A scripted backend that records what the session asks of it.
final class RecordingControlBackend: ControlBackend, @unchecked Sendable {
    enum Call: Equatable {
        case tap(CGPoint)
        case drag(CGPoint, CGPoint, Int)
        case type(String)
        case press(DeviceButton)
        case ping
        case close
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var failNext: Error?
    let screenSize: DeviceScreenSize

    init(screenSize: DeviceScreenSize = DeviceScreenSize(width: 400, height: 800)) {
        self.screenSize = screenSize
    }

    var calls: [Call] { lock.withLock { recorded } }

    /// Thrown by every call until cleared.
    var failEvery: Error?

    private func record(_ call: Call) throws {
        lock.withLock { recorded.append(call) }
        if let error = lock.withLock({ let e = failNext ?? failEvery; failNext = nil; return e }) {
            throw error
        }
    }

    func tap(_ point: CGPoint) async throws { try record(.tap(point)) }
    func doubleTap(_ point: CGPoint) async throws { try record(.tap(point)) }
    func longPress(_ point: CGPoint, durationSeconds: Double) async throws { try record(.tap(point)) }
    func drag(from start: CGPoint, to end: CGPoint, durationMS: Int) async throws { try record(.drag(start, end, durationMS)) }
    func typeText(_ text: String) async throws { try record(.type(text)) }
    func clearActiveText() async throws -> ControlTextEditResult { ControlTextEditResult(strategy: "test", value: "", verified: true) }
    func replaceActiveText(_ text: String) async throws -> ControlTextEditResult { ControlTextEditResult(strategy: "test", value: text, verified: true) }
    func press(_ button: DeviceButton) async throws { try record(.press(button)) }
    func screenshotPNG() async throws -> Data { Data() }
    func uiTree() async throws -> String { "<AppiumAUT/>" }
    func findTextElements(query: String, maximumMatches: Int) async throws -> [NativeElementMatch] { [] }
    func click(elementReference: String) async throws {}
    func click(semantic element: ScreenElement) async throws -> Bool { false }
    func activateApp(_ identifier: String) async throws {}
    func terminateApp(_ identifier: String) async throws -> Bool { true }
    func ping() async throws -> DeviceScreenSize {
        try record(.ping)
        return screenSize
    }
    func close() async { try? record(.close) }
}

@MainActor
final class DeviceControlSessionTests: XCTestCase {
    private func identity() -> DeviceIdentity {
        DeviceIdentity(
            id: "test",
            udid: "00008150-TEST",
            name: "Test iPhone",
            productType: "iPhone18,4",
            osVersion: "27.0",
            connectionState: .connected,
            trustState: .trusted
        )
    }

    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testInteractiveGesturesAreConvertedToDevicePointsInOrder() async {
        let backend = RecordingControlBackend()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(backend, keepAliveInterval: .seconds(60))
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.screenSize, backend.screenSize)

        session.enqueue(.tap(CGPoint(x: 0.5, y: 0.25)))
        session.enqueue(.swipe(from: CGPoint(x: 0.1, y: 0.9), to: CGPoint(x: 0.1, y: 0.1), durationMS: 200))
        session.enqueue(.press(.home))
        await settle()

        XCTAssertEqual(backend.calls, [
            .tap(CGPoint(x: 200, y: 200)),
            .drag(CGPoint(x: 40, y: 720), CGPoint(x: 40, y: 80), 200),
            .press(.home)
        ])
    }

    func testFlickUsesAFullScreenTrajectory() async {
        let backend = RecordingControlBackend()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(backend, keepAliveInterval: .seconds(60))

        session.enqueue(.flick(.up))
        await settle()

        guard case let .drag(start, end, duration)? = backend.calls.first else {
            return XCTFail("expected a drag, got \(backend.calls)")
        }
        XCTAssertEqual(start.x, 200)
        XCTAssertGreaterThan(start.y, end.y)
        XCTAssertEqual(duration, 120)
    }

    func testALostSessionReconnectsThroughTheConnectorWithoutReplaying() async {
        let dead = RecordingControlBackend()
        let replacement = RecordingControlBackend()
        let connectorCalls = Counter()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(dead, keepAliveInterval: .seconds(60)) { _ in
            await connectorCalls.increment()
            return replacement
        }

        dead.failNext = ControlBackendError.sessionLost("gone")
        session.enqueue(.tap(CGPoint(x: 0.5, y: 0.5)))
        await settle()

        let count = await connectorCalls.value
        XCTAssertEqual(count, 1, "the connector should rebuild the backend exactly once")
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(dead.calls.contains(.close))
        XCTAssertFalse(replacement.calls.contains { if case .tap = $0 { return true }; return false },
                       "taps are not idempotent and must not be replayed")
    }

    func testARejectedRequestKeepsTheSession() async throws {
        let backend = RecordingControlBackend()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(backend, keepAliveInterval: .seconds(60))

        backend.failNext = ControlBackendError.rejected("no such element")
        do {
            try await session.tap(normalizedX: 0.5, normalizedY: 0.5)
            XCTFail("expected the rejection to surface")
        } catch {
            XCTAssertFalse(DeviceControlSession.isSessionLoss(error))
        }
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(session.statusMessage, "no such element")
    }

    func testDisconnectClosesTheBackendAndDropsPendingInput() async {
        let backend = RecordingControlBackend()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(backend, keepAliveInterval: .seconds(60))

        session.disconnect()
        session.enqueue(.tap(CGPoint(x: 0.5, y: 0.5)))
        await settle()

        XCTAssertFalse(session.isReady)
        XCTAssertEqual(session.state, .unavailable)
        XCTAssertEqual(backend.calls, [.close])
    }

    func testKeepAlivePingsAndNoticesADeadAgent() async {
        let backend = RecordingControlBackend()
        let replacement = RecordingControlBackend()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(backend, keepAliveInterval: .milliseconds(40)) { _ in replacement }

        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(backend.calls.contains(.ping))

        backend.failNext = ControlBackendError.sessionLost("agent exited")
        try? await Task.sleep(for: .milliseconds(200))
        await settle()
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(backend.calls.contains(.close))
    }

    func testASingleTimeoutKeepsTheSession() async {
        let backend = RecordingControlBackend()
        let replacement = RecordingControlBackend()
        let connectorCalls = Counter()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(backend, keepAliveInterval: .seconds(60)) { _ in
            await connectorCalls.increment()
            return replacement
        }

        backend.failNext = URLError(.timedOut)
        session.enqueue(.tap(CGPoint(x: 0.5, y: 0.5)))
        await settle()

        let count = await connectorCalls.value
        XCTAssertEqual(count, 0, "one slow request must not relaunch the agent")
        XCTAssertTrue(session.isReady)
        XCTAssertFalse(backend.calls.contains(.close))
    }

    func testRepeatedKeepAliveTimeoutsRebuildTheSession() async {
        let backend = RecordingControlBackend()
        let replacement = RecordingControlBackend()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(backend, keepAliveInterval: .milliseconds(30)) { _ in replacement }

        backend.failEvery = URLError(.timedOut)
        try? await Task.sleep(for: .milliseconds(250))
        await settle()

        XCTAssertTrue(backend.calls.contains(.close))
        XCTAssertTrue(session.isReady)
    }

    func testAgentExitRebuildsImmediately() async {
        let backend = RecordingControlBackend()
        let replacement = RecordingControlBackend()
        let connectorCalls = Counter()
        let session = DeviceControlSession(device: identity())
        session.adoptForTesting(backend, keepAliveInterval: .seconds(60)) { _ in
            await connectorCalls.increment()
            return replacement
        }

        session.agentDidExit()
        await settle()

        let count = await connectorCalls.value
        XCTAssertEqual(count, 1)
        XCTAssertTrue(backend.calls.contains(.close))
        XCTAssertTrue(session.isReady)
    }

    func testFailureWordingMapsKnownDeviceStates() {
        XCTAssertEqual(ControlFailure.messageKey(for: IOSAgentError.setupRequired), "agent.error.setupRequired")
        XCTAssertEqual(
            ControlFailure.messageKey(for: ControlBackendError.rejected("Unlock iPhone Air to Continue")),
            "control.error.unlockDevice"
        )
        XCTAssertEqual(
            ControlFailure.messageKey(for: ControlBackendError.rejected("xcodebuild failed: no provisioning profile")),
            "control.error.signing"
        )
        XCTAssertEqual(ControlFailure.messageKey(for: ControlServiceUnavailableError()), "control.error.appiumUnavailable")
    }
}

actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
