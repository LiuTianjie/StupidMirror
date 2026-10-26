import CoreGraphics
import Foundation
import XCTest
@testable import StupidMirrorApp

@MainActor
final class HIDControlBackendTests: XCTestCase {
    private let oldSize = DeviceScreenSize(width: 400, height: 800)
    private let newSize = DeviceScreenSize(width: 800, height: 400)

    func testLatePreflightPingPreservesNewGeometryAndRetriesTheSizeRead() async throws {
        let gate = HIDGeometryTestGate("the old preflight size read is suspended")
        let auxiliary = GeometryControlBackend(
            screenSize: oldSize, pingReplies: [oldSize, newSize], pingGates: [1: gate]
        )
        let provider = GeometrySizeProvider(oldSize)
        let backend = try await connect(auxiliary: auxiliary, provider: provider)
        _ = try await backend.uiTree()

        // Mark the current size dirty, causing the next auxiliary operation
        // to read it before requesting a hierarchy.
        backend.screenGeometryDidChange()
        backend.touch.invalidateGeometry()
        let reading = Task { try await backend.uiTree() }
        await waitFor(gate)

        changeGeometry(of: backend, provider: provider)
        await gate.release()
        do {
            _ = try await reading.value
            XCTFail("A hierarchy request prepared against obsolete geometry must be cancelled")
        } catch {
            XCTAssertFalse(DeviceControlSession.isSessionLoss(error))
        }

        XCTAssertEqual(backend.screenSize, newSize, "The old ping must not overwrite the newer provider size")
        XCTAssertFalse(backend.touch.uncertain)
        XCTAssertEqual(auxiliary.treeCount, 1, "The stale preflight must not continue into the operation")
        _ = try await backend.uiTree()
        XCTAssertEqual(auxiliary.pingCount, 2, "A stale response must leave geometry dirty for the next operation")
        XCTAssertEqual(auxiliary.treeCount, 2)
        XCTAssertEqual(backend.screenSize, newSize)
    }

    func testLateIdlePingPreservesNewGeometryAndTheAuxiliaryConnection() async throws {
        let gate = HIDGeometryTestGate("the old idle size read is suspended")
        let auxiliary = GeometryControlBackend(
            screenSize: oldSize, pingReplies: [oldSize, newSize], pingGates: [1: gate]
        )
        let provider = GeometrySizeProvider(oldSize)
        let backend = try await connect(auxiliary: auxiliary, provider: provider)
        _ = try await backend.uiTree()

        let reading = Task { try await backend.ping() }
        await waitFor(gate)
        changeGeometry(of: backend, provider: provider)
        await gate.release()
        _ = try? await reading.value

        XCTAssertEqual(backend.screenSize, newSize, "An idle probe must not restore the preceding orientation")
        XCTAssertFalse(backend.touch.uncertain)
        XCTAssertEqual(auxiliary.closeCount, 0, "A geometry change is not an auxiliary transport failure")
        _ = try await backend.uiTree()
        XCTAssertEqual(auxiliary.pingCount, 2, "The next operation must refresh the still-dirty auxiliary geometry")
        XCTAssertEqual(backend.screenSize, newSize)
    }

    func testLateOperationCompletionCannotRestoreItsOldScreenSize() async throws {
        let gate = HIDGeometryTestGate("the old hierarchy operation is suspended")
        let auxiliary = GeometryControlBackend(
            screenSize: oldSize, pingReplies: [newSize], treeGates: [2: gate]
        )
        let provider = GeometrySizeProvider(oldSize)
        let backend = try await connect(auxiliary: auxiliary, provider: provider)
        _ = try await backend.uiTree()

        let reading = Task { try await backend.uiTree() }
        await waitFor(gate)
        changeGeometry(of: backend, provider: provider)
        await gate.release()
        do {
            _ = try await reading.value
            XCTFail("The operation's cancelled reservation must remain cancelled")
        } catch {
            XCTAssertFalse(DeviceControlSession.isSessionLoss(error))
        }

        XCTAssertEqual(backend.screenSize, newSize, "Returning from an old operation must not copy its stale cached size")
        XCTAssertFalse(backend.touch.uncertain)
        XCTAssertEqual(auxiliary.pingCount, 0)
        _ = try await backend.uiTree()
        XCTAssertEqual(auxiliary.pingCount, 1)
        XCTAssertEqual(auxiliary.treeCount, 3)
        XCTAssertEqual(backend.screenSize, newSize)
    }

    private func connect(auxiliary: GeometryControlBackend, provider: GeometrySizeProvider) async throws -> HIDControlBackend {
        let touch = GeometryTouchBackend()
        let backend = try await HIDControlBackend.connect(
            screenSize: provider.size,
            sizeProvider: { provider.size },
            touchConnector: { touch },
            auxiliaryConnector: { _ in auxiliary },
            report: { _, _ in }
        )
        addTeardownBlock {
            await auxiliary.releaseAllGates()
            await backend.close()
        }
        return backend
    }

    private func changeGeometry(of backend: HIDControlBackend, provider: GeometrySizeProvider) {
        provider.size = newSize
        backend.screenGeometryDidChange()
        backend.touch.invalidateGeometry()
        XCTAssertEqual(backend.screenSize, newSize)
    }

    private func waitFor(_ gate: HIDGeometryTestGate) async {
        let result = await XCTWaiter.fulfillment(of: [gate.entered], timeout: 5)
        XCTAssertEqual(result, .completed)
    }
}

@MainActor
private final class GeometrySizeProvider {
    var size: DeviceScreenSize
    init(_ size: DeviceScreenSize) { self.size = size }
}

private actor HIDGeometryTestGate {
    nonisolated let entered: XCTestExpectation
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ description: String) { entered = XCTestExpectation(description: description) }

    func pause() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor GeometryTouchBackend: TouchInputBackend {
    nonisolated let name = "geometry-test-touch"
    func send(_ event: TouchEvent) async throws {}
    func flush() async throws {}
    func close() async {}
}

/// A delayed ping intentionally updates its own cache with the old response,
/// matching WDAControlBackend. The composite must reject that stale writeback.
private final class GeometryControlBackend: ControlBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedSize: DeviceScreenSize
    private var pings = 0
    private var trees = 0
    private var closes = 0
    private let pingReplies: [DeviceScreenSize]
    private let pingGates: [Int: HIDGeometryTestGate]
    private let treeGates: [Int: HIDGeometryTestGate]

    init(
        screenSize: DeviceScreenSize,
        pingReplies: [DeviceScreenSize],
        pingGates: [Int: HIDGeometryTestGate] = [:],
        treeGates: [Int: HIDGeometryTestGate] = [:]
    ) {
        self.cachedSize = screenSize
        self.pingReplies = pingReplies
        self.pingGates = pingGates
        self.treeGates = treeGates
    }

    var screenSize: DeviceScreenSize { lock.withLock { cachedSize } }
    var pingCount: Int { lock.withLock { pings } }
    var treeCount: Int { lock.withLock { trees } }
    var closeCount: Int { lock.withLock { closes } }

    func ping() async throws -> DeviceScreenSize {
        let (ordinal, reply) = lock.withLock { () -> (Int, DeviceScreenSize) in
            pings += 1
            return (pings, pingReplies.indices.contains(pings - 1) ? pingReplies[pings - 1] : cachedSize)
        }
        if let gate = pingGates[ordinal] { await gate.pause() }
        lock.withLock { cachedSize = reply }
        return reply
    }

    func uiTree() async throws -> String {
        let ordinal = lock.withLock { trees += 1; return trees }
        if let gate = treeGates[ordinal] { await gate.pause() }
        return "<AppiumAUT/>"
    }

    func releaseAllGates() async {
        for gate in pingGates.values { await gate.release() }
        for gate in treeGates.values { await gate.release() }
    }

    func close() async { lock.withLock { closes += 1 } }
    func tap(_ point: CGPoint) async throws {}
    func doubleTap(_ point: CGPoint) async throws {}
    func longPress(_ point: CGPoint, durationSeconds: Double) async throws {}
    func drag(from start: CGPoint, to end: CGPoint, durationMS: Int) async throws {}
    func typeText(_ text: String) async throws {}
    func clearActiveText() async throws -> ControlTextEditResult { ControlTextEditResult(strategy: "test", value: "", verified: true) }
    func replaceActiveText(_ text: String) async throws -> ControlTextEditResult { ControlTextEditResult(strategy: "test", value: text, verified: true) }
    func press(_ button: DeviceButton) async throws {}
    func screenshotPNG() async throws -> Data { Data() }
    func findTextElements(query: String, maximumMatches: Int) async throws -> [NativeElementMatch] { [] }
    func click(elementReference: String) async throws {}
    func click(semantic element: ScreenElement) async throws -> Bool { false }
    func activateApp(_ identifier: String) async throws {}
    func terminateApp(_ identifier: String) async throws -> Bool { true }
}
