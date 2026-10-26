import CoreGraphics
import Foundation
import XCTest
@testable import StupidMirrorApp

@MainActor
final class DeviceTouchSessionTests: XCTestCase {
    func testAcceptanceSendAndFlushCompletionHaveSeparateBoundaries() async throws {
        let firstDown = TouchSessionTestGate("default DOWN reached send")
        let secondDown = TouchSessionTestGate("waitForSend DOWN reached send")
        let flushedMove = TouchSessionTestGate("waitForFlush MOVE reached send")
        let explicitFlush = TouchSessionTestGate("waitForFlush MOVE reached flush")
        let backend = ControlledTouchSessionBackend(
            sendGates: [1: firstDown, 3: secondDown, 4: flushedMove],
            flushGates: [2: explicitFlush]
        )
        let session = makeSession(backend)
        let generation = session.geometryGeneration
        let point = CGPoint(x: 0.2, y: 0.3)
        let destination = CGPoint(x: 0.4, y: 0.5)

        let accepted = expectation(description: "default acceptance returns while send is blocked")
        let accepting = Task {
            try await session.accept(event(.down, point), source: "native", geometryGeneration: generation)
            accepted.fulfill()
        }
        await waitFor([firstDown.entered, accepted])
        await firstDown.release()
        try await accepting.value
        try await session.accept(event(.up, point), source: "native", geometryGeneration: generation, waitForFlush: true)

        let sent = expectation(description: "waitForSend returns after send without a flush")
        var sendCompleted = false
        let sending = Task {
            try await session.accept(event(.down, point), source: "native", geometryGeneration: generation, waitForSend: true)
            sendCompleted = true
            sent.fulfill()
        }
        await waitFor([secondDown.entered])
        XCTAssertFalse(sendCompleted, "A caller starting its hold timer must wait for DOWN to finish sending.")
        await secondDown.release()
        await waitFor([sent])
        guard sendCompleted else {
            // A regression that waits for flush must not leave this test blocked.
            await backend.releaseAllGates()
            _ = try? await sending.value
            return
        }
        try await sending.value
        let afterSend = await backend.snapshot()
        XCTAssertEqual(afterSend, [
            .send(event(.down, point)), .send(event(.up, point)), .flush,
            .send(event(.down, point)),
        ], "Waiting for DOWN send must not add a transport round trip.")

        let flushed = expectation(description: "waitForFlush returns only after flush")
        var flushCompleted = false
        let flushing = Task {
            try await session.accept(event(.move, destination), source: "native", geometryGeneration: generation, waitForFlush: true)
            flushCompleted = true
            flushed.fulfill()
        }
        await waitFor([flushedMove.entered])
        XCTAssertFalse(flushCompleted)
        await flushedMove.release()
        await waitFor([explicitFlush.entered])
        XCTAssertFalse(flushCompleted, "Send completion alone must not satisfy waitForFlush.")
        await explicitFlush.release()
        await waitFor([flushed])
        try await flushing.value
        try await session.accept(event(.up, destination), source: "native", geometryGeneration: generation, waitForFlush: true)
        XCTAssertTrue(session.isIdle)
    }

    func testSameSourceClickQueuesWhilePreviousUpIsFlushingWithinThePendingBound() async throws {
        let firstFlush = TouchSessionTestGate("first UP reached flush")
        let backend = ControlledTouchSessionBackend(flushGates: [1: firstFlush])
        let session = makeSession(backend, queueCapacity: 3)
        let idle = expectIdle(session)
        let source = "native"
        let generation = session.geometryGeneration
        let first = CGPoint(x: 0.2, y: 0.3)
        let second = CGPoint(x: 0.7, y: 0.8)

        try session.enqueue(event(.down, first), source: source, geometryGeneration: generation)
        try session.enqueue(event(.up, first), source: source, geometryGeneration: generation)
        await waitFor([firstFlush.entered])

        // The in-flight UP is not part of the three pending slots. Both calls
        // must be accepted synchronously without waiting for its flush.
        try session.enqueue(event(.down, second), source: source, geometryGeneration: generation)
        try session.enqueue(event(.up, second), source: source, geometryGeneration: generation)
        XCTAssertThrowsError(try session.enqueue(event(.down, .zero), source: source, geometryGeneration: generation)) { error in
            guard let failure = error as? TouchSessionError, case .queueFull = failure else {
                return XCTFail("Expected queueFull, got \(error)")
            }
        }
        let whileBlocked = await backend.snapshot()
        XCTAssertEqual(whileBlocked, [.send(event(.down, first)), .send(event(.up, first)), .flush])
        XCTAssertEqual(session.activeSource, source)
        XCTAssertFalse(session.isIdle)

        await firstFlush.release()
        await waitFor([idle])

        let calls = await backend.snapshot()
        XCTAssertEqual(calls, [
            .send(event(.down, first)), .send(event(.up, first)), .flush,
            .send(event(.down, second)), .send(event(.up, second)), .flush,
        ])
        XCTAssertNil(session.activeSource)
        XCTAssertFalse(session.uncertain)
    }

    func testSendFailureCancelsOnceAndDropsLaterContactsWithoutReplay() async throws {
        try await assertFailureDropsLaterContacts(at: .send)
    }

    func testFlushFailureCancelsOnceAndDropsLaterContactsWithoutReplay() async throws {
        try await assertFailureDropsLaterContacts(at: .flush)
    }

    func testOtherSourcesRemainExcludedUntilTheLastQueuedContactFlushes() async throws {
        let firstFlush = TouchSessionTestGate("first contact reached flush")
        let lastFlush = TouchSessionTestGate("last contact reached flush")
        let backend = ControlledTouchSessionBackend(flushGates: [1: firstFlush, 2: lastFlush])
        let session = makeSession(backend)
        let idle = expectIdle(session)
        let generation = session.geometryGeneration
        let first = CGPoint(x: 0.1, y: 0.2)
        let second = CGPoint(x: 0.8, y: 0.9)

        try session.enqueue(event(.down, first), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.up, first), source: "native", geometryGeneration: generation)
        await waitFor([firstFlush.entered])
        try session.enqueue(event(.down, second), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.up, second), source: "native", geometryGeneration: generation)
        assertOtherSourceIsBusy(session, generation: generation)

        await firstFlush.release()
        await waitFor([lastFlush.entered])
        XCTAssertEqual(session.activeSource, "native")
        XCTAssertFalse(session.isIdle)
        assertOtherSourceIsBusy(session, generation: generation)

        await lastFlush.release()
        await waitFor([idle])
        XCTAssertNil(session.activeSource)

        // A different source becomes admissible only after that final flush.
        try session.enqueue(event(.down, first), source: "plugin", geometryGeneration: generation)
        try await session.accept(event(.up, first), source: "plugin", geometryGeneration: generation, waitForFlush: true)
        let calls = await backend.snapshot()
        XCTAssertEqual(calls, [
            .send(event(.down, first)), .send(event(.up, first)), .flush,
            .send(event(.down, second)), .send(event(.up, second)), .flush,
            .send(event(.down, first)), .send(event(.up, first)), .flush,
        ])
    }

    func testUpAddsItsFinalMoveWithoutCoalescingAcrossContacts() async throws {
        let firstSend = TouchSessionTestGate("first DOWN reached send")
        let backend = ControlledTouchSessionBackend(sendGates: [1: firstSend])
        let session = makeSession(backend)
        let idle = expectIdle(session)
        let generation = session.geometryGeneration
        let firstStart = CGPoint(x: 0.1, y: 0.1)
        let firstEnd = CGPoint(x: 0.3, y: 0.4)
        let secondStart = CGPoint(x: 0.6, y: 0.6)
        let secondEnd = CGPoint(x: 0.9, y: 0.8)

        try session.enqueue(event(.down, firstStart), source: "native", geometryGeneration: generation)
        await waitFor([firstSend.entered])
        // No MOVE was supplied for the first contact: UP must synthesize it.
        try session.enqueue(event(.up, firstEnd), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.down, secondStart), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.move, CGPoint(x: 0.7, y: 0.7)), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.move, CGPoint(x: 0.8, y: 0.75)), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.up, secondEnd), source: "native", geometryGeneration: generation)

        await firstSend.release()
        await waitFor([idle])
        let calls = await backend.snapshot()
        XCTAssertEqual(calls, [
            .send(event(.down, firstStart)), .send(event(.move, firstEnd)), .send(event(.up, firstEnd)), .flush,
            .send(event(.down, secondStart)), .send(event(.move, secondEnd)), .send(event(.up, secondEnd)), .flush,
        ])
    }

    func testUnsupportedNativeGestureDoesNotReserveDirectTouchOwnership() async throws {
        let backend = ControlledTouchSessionBackend()
        let session = makeSession(backend)
        let generation = session.geometryGeneration
        let point = CGPoint(x: 0.2, y: 0.3)

        XCTAssertThrowsError(try session.enqueue(nativeEvent(.down, point, marker: 1), source: "native", geometryGeneration: generation)) { error in
            guard let failure = error as? TouchSessionError, case .unsupported = failure else {
                return XCTFail("Expected unsupported native gestures, got \(error)")
            }
        }
        XCTAssertTrue(session.isIdle)
        XCTAssertNil(session.activeSource)
        let beforeDirectTouch = await backend.snapshot()
        XCTAssertTrue(beforeDirectTouch.isEmpty)

        try session.enqueue(event(.down, point), source: "plugin", geometryGeneration: generation)
        try await session.accept(event(.up, point), source: "plugin", geometryGeneration: generation, waitForFlush: true)
        let calls = await backend.snapshot()
        XCTAssertEqual(calls, [.send(event(.down, point)), .send(event(.up, point)), .flush])
        XCTAssertTrue(session.isIdle)
    }

    func testNativeRelativeMovesRetainEveryIncrementWithoutSynthesizingDirectMoves() async throws {
        let firstSend = TouchSessionTestGate("native DOWN reached send")
        let backend = ControlledTouchSessionBackend(supportsNativeGestures: true, sendGates: [1: firstSend])
        let session = makeSession(backend)
        let idle = expectIdle(session)
        let generation = session.geometryGeneration
        let point = CGPoint(x: 0.2, y: 0.3)
        let down = nativeEvent(.down, point, marker: 1)
        let moves = (2...4).map { nativeEvent(.move, point, marker: UInt8($0)) }
        let up = nativeEvent(.up, CGPoint(x: 0.8, y: 0.9), marker: 5)

        try session.enqueue(down, source: "native", geometryGeneration: generation)
        await waitFor([firstSend.entered])
        for move in moves { try session.enqueue(move, source: "native", geometryGeneration: generation) }
        try session.enqueue(up, source: "native", geometryGeneration: generation)

        await firstSend.release()
        await waitFor([idle])
        let calls = await backend.snapshot()
        let expected = ([down] + moves + [up]).map { ControlledTouchSessionBackend.Call.send($0) } + [.flush]
        XCTAssertEqual(calls, expected, "Native reports contain relative increments: replacing one or synthesizing a direct MOVE changes the gesture.")
        XCTAssertNil(session.activeSource)
        XCTAssertFalse(session.uncertain)
    }

    func testFullNativeQueueCancelsInsteadOfResumingAfterLostRelativeIncrement() async throws {
        let firstSend = TouchSessionTestGate("native DOWN blocked while increments fill the queue")
        let backend = ControlledTouchSessionBackend(supportsNativeGestures: true, sendGates: [1: firstSend])
        let session = makeSession(backend, queueCapacity: 3)
        let idle = expectIdle(session)
        let generation = session.geometryGeneration
        let point = CGPoint(x: 0.2, y: 0.3)
        let down = nativeEvent(.down, point, marker: 1)

        try session.enqueue(down, source: "native", geometryGeneration: generation)
        await waitFor([firstSend.entered])
        for marker in UInt8(2)...UInt8(4) {
            try session.enqueue(nativeEvent(.move, point, marker: marker), source: "native", geometryGeneration: generation)
        }
        XCTAssertThrowsError(try session.enqueue(nativeEvent(.move, point, marker: 5), source: "native", geometryGeneration: generation)) { error in
            guard let failure = error as? TouchSessionError, case .queueFull = failure else {
                return XCTFail("Expected bounded native input to report queueFull, got \(error)")
            }
        }
        XCTAssertThrowsError(try session.enqueue(nativeEvent(.move, point, marker: 6), source: "native", geometryGeneration: generation)) { error in
            guard let failure = error as? TouchSessionError, case .gestureEnding = failure else {
                return XCTFail("Expected the incomplete native gesture to be ending, got \(error)")
            }
        }

        await firstSend.release()
        await waitFor([idle])
        let calls = await backend.snapshot()
        XCTAssertEqual(calls, [.send(down), .send(event(.cancel, point)), .flush],
                       "The first dropped increment must discard the remaining relative movement and release the gesture.")
        XCTAssertThrowsError(try session.enqueue(nativeEvent(.move, point, marker: 7), source: "native", geometryGeneration: generation)) { error in
            guard let failure = error as? TouchSessionError, case .noActiveContact = failure else {
                return XCTFail("Expected cleanup to prevent resuming the old gesture, got \(error)")
            }
        }
        XCTAssertTrue(session.isIdle)
        XCTAssertFalse(session.uncertain)
    }

    func testDirectAndNativeEventsCannotMixWithinAContact() async throws {
        let backend = ControlledTouchSessionBackend(supportsNativeGestures: true)
        let session = makeSession(backend)
        let generation = session.geometryGeneration
        let point = CGPoint(x: 0.2, y: 0.3)
        var expected: [ControlledTouchSessionBackend.Call] = []

        for startsNative in [true, false] {
            let down = startsNative ? nativeEvent(.down, point, marker: 1) : event(.down, point)
            let up = startsNative ? nativeEvent(.up, point, marker: 2) : event(.up, point)
            try session.enqueue(down, source: "native", geometryGeneration: generation)
            for phase in [TouchPhase.move, .up] {
                let mixed = startsNative ? event(phase, point) : nativeEvent(phase, point, marker: 3)
                XCTAssertThrowsError(try session.enqueue(mixed, source: "native", geometryGeneration: generation)) { error in
                    guard let failure = error as? TouchSessionError, case .invalidPoint = failure else {
                        return XCTFail("Expected a mixed contact to be rejected, got \(error)")
                    }
                }
            }
            try await session.accept(up, source: "native", geometryGeneration: generation, waitForFlush: true)
            expected += [.send(down), .send(up), .flush]
            XCTAssertTrue(session.isIdle, "Rejected mixed input must leave the original contact releasable.")
        }

        let calls = await backend.snapshot()
        XCTAssertEqual(calls, expected)
        XCTAssertFalse(session.uncertain)
    }

    func testNativeCancellationDropsUnsentIncrementsAndOwnsInputUntilCleanupFlushes() async throws {
        let firstSend = TouchSessionTestGate("native DOWN reached send")
        let cancelFlush = TouchSessionTestGate("native cleanup reached flush")
        let backend = ControlledTouchSessionBackend(
            supportsNativeGestures: true, sendGates: [1: firstSend], flushGates: [1: cancelFlush]
        )
        let session = makeSession(backend)
        let idle = expectIdle(session)
        let generation = session.geometryGeneration
        let point = CGPoint(x: 0.2, y: 0.3)
        let laterPoint = CGPoint(x: 0.8, y: 0.9)
        let down = nativeEvent(.down, point, marker: 1)

        try session.enqueue(down, source: "native", geometryGeneration: generation)
        await waitFor([firstSend.entered])
        try session.enqueue(nativeEvent(.move, laterPoint, marker: 2), source: "native", geometryGeneration: generation)
        try session.enqueue(nativeEvent(.move, laterPoint, marker: 3), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.cancel, laterPoint), source: "native", geometryGeneration: generation)
        await firstSend.release()
        await waitFor([cancelFlush.entered])

        let cleanupCalls = await backend.snapshot()
        XCTAssertEqual(cleanupCalls, [.send(down), .send(event(.cancel, point)), .flush],
                       "Cleanup uses the last sent point and lets the backend release its cached native gesture state.")
        assertOtherSourceIsBusy(session, generation: generation)
        XCTAssertFalse(session.isIdle)
        await cancelFlush.release()
        await waitFor([idle])
        XCTAssertNil(session.activeSource)

        try session.enqueue(event(.down, laterPoint), source: "plugin", geometryGeneration: generation)
        try await session.accept(event(.up, laterPoint), source: "plugin", geometryGeneration: generation, waitForFlush: true)
        let calls = await backend.snapshot()
        XCTAssertEqual(calls, cleanupCalls + [.send(event(.down, laterPoint)), .send(event(.up, laterPoint)), .flush])
    }

    func testDirectClickInterruptingNativeMomentumWaitsForCancellationFlush() async throws {
        let cancelFlush = TouchSessionTestGate("momentum cancellation reached flush")
        let backend = ControlledTouchSessionBackend(supportsNativeGestures: true, flushGates: [1: cancelFlush])
        let session = makeSession(backend)
        let idle = expectIdle(session)
        let generation = session.geometryGeneration
        let point = CGPoint(x: 0.2, y: 0.3)
        let clickPoint = CGPoint(x: 0.8, y: 0.9)
        let down = nativeEvent(.down, point, marker: 1)

        try await session.accept(down, source: "native", geometryGeneration: generation, waitForSend: true)
        try session.enqueue(event(.cancel, point), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.down, clickPoint), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.up, clickPoint), source: "native", geometryGeneration: generation)
        await waitFor([cancelFlush.entered])

        let whileBlocked = await backend.snapshot()
        XCTAssertEqual(whileBlocked, [.send(down), .send(event(.cancel, point)), .flush])
        assertOtherSourceIsBusy(session, generation: generation)
        await cancelFlush.release()
        await waitFor([idle])
        let calls = await backend.snapshot()
        XCTAssertEqual(calls, whileBlocked + [.send(event(.down, clickPoint)), .send(event(.up, clickPoint)), .flush])
        XCTAssertFalse(session.uncertain)
        XCTAssertNil(session.activeSource)
    }

    func testFailedNativeCancellationSendDropsInterruptingDirectClick() async throws {
        try await assertFailedNativeCancellationDropsDirectClick(at: .send)
    }

    func testFailedNativeCancellationFlushDropsInterruptingDirectClick() async throws {
        try await assertFailedNativeCancellationDropsDirectClick(at: .flush)
    }

    private enum FailingStep {
        case send
        case flush
    }

    private func assertFailedNativeCancellationDropsDirectClick(at step: FailingStep) async throws {
        let failingCall = TouchSessionTestGate("native cancellation failure reached transport")
        let backend: ControlledTouchSessionBackend
        switch step {
        case .send:
            backend = ControlledTouchSessionBackend(
                supportsNativeGestures: true, sendGates: [2: failingCall], failingSends: [2]
            )
        case .flush:
            backend = ControlledTouchSessionBackend(
                supportsNativeGestures: true, flushGates: [1: failingCall], failingFlushes: [1]
            )
        }
        let session = makeSession(backend)
        let failed = expectation(description: "failed cancellation marks delivery uncertain")
        session.onFailure = { _ in failed.fulfill() }
        let generation = session.geometryGeneration
        let point = CGPoint(x: 0.2, y: 0.3)
        let clickPoint = CGPoint(x: 0.8, y: 0.9)
        let down = nativeEvent(.down, point, marker: 1)

        try await session.accept(down, source: "native", geometryGeneration: generation, waitForSend: true)
        try session.enqueue(event(.cancel, point), source: "native", geometryGeneration: generation)
        await waitFor([failingCall.entered])
        try session.enqueue(event(.down, clickPoint), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.up, clickPoint), source: "native", geometryGeneration: generation)
        await failingCall.release()
        await waitFor([failed])

        let calls = await backend.snapshot()
        XCTAssertEqual(calls, [.send(down), .send(event(.cancel, point)), .flush],
                       "An uncertain native release must discard the interrupting click without replaying cleanup.")
        XCTAssertTrue(session.uncertain)
        XCTAssertThrowsError(try session.enqueue(event(.down, clickPoint), source: "native", geometryGeneration: generation)) { error in
            guard let failure = error as? TouchSessionError, case .uncertain = failure else {
                return XCTFail("Expected failed cleanup to prohibit another DOWN, got \(error)")
            }
        }
        let afterRejectedDown = await backend.snapshot()
        XCTAssertEqual(afterRejectedDown, calls)
    }

    private func assertFailureDropsLaterContacts(at step: FailingStep) async throws {
        let failingCall = TouchSessionTestGate("failing transport call entered")
        let backend: ControlledTouchSessionBackend
        switch step {
        case .send:
            backend = ControlledTouchSessionBackend(sendGates: [1: failingCall], failingSends: [1])
        case .flush:
            backend = ControlledTouchSessionBackend(flushGates: [1: failingCall], failingFlushes: [1])
        }
        let session = makeSession(backend)
        let idle = expectIdle(session)
        let generation = session.geometryGeneration
        let first = CGPoint(x: 0.2, y: 0.3)
        let later = CGPoint(x: 0.8, y: 0.9)

        try session.enqueue(event(.down, first), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.up, first), source: "native", geometryGeneration: generation)
        await waitFor([failingCall.entered])
        try session.enqueue(event(.down, later), source: "native", geometryGeneration: generation)
        try session.enqueue(event(.up, later), source: "native", geometryGeneration: generation)

        await failingCall.release()
        await waitFor([idle])

        let calls = await backend.snapshot()
        var expected: [ControlledTouchSessionBackend.Call] = [.send(event(.down, first))]
        if case .flush = step { expected += [.send(event(.up, first)), .flush] }
        expected += [.send(event(.cancel, first)), .flush]
        XCTAssertEqual(calls, expected, "Only the affected contact may receive one best-effort release")
        XCTAssertTrue(session.uncertain)
        XCTAssertNil(session.activeSource)
        XCTAssertThrowsError(try session.enqueue(event(.down, later), source: "native", geometryGeneration: generation)) { error in
            guard let failure = error as? TouchSessionError, case .uncertain = failure else {
                return XCTFail("Expected uncertain delivery to prohibit another DOWN, got \(error)")
            }
        }
        let afterRejectedDown = await backend.snapshot()
        XCTAssertEqual(afterRejectedDown, calls, "Rejected input must not be sent or replayed")
    }

    private func assertOtherSourceIsBusy(_ session: DeviceTouchSession, generation: UInt64) {
        XCTAssertThrowsError(try session.enqueue(event(.down, .zero), source: "plugin", geometryGeneration: generation)) { error in
            guard let failure = error as? TouchSessionError, case let .busy(owner) = failure else {
                return XCTFail("Expected the active source to keep ownership, got \(error)")
            }
            XCTAssertEqual(owner, "native")
        }
    }

    private func makeSession(_ backend: ControlledTouchSessionBackend, queueCapacity: Int = 64) -> DeviceTouchSession {
        let session = DeviceTouchSession(backend: backend, queueCapacity: queueCapacity)
        addTeardownBlock {
            await backend.releaseAllGates()
            await session.close()
        }
        return session
    }

    private func expectIdle(_ session: DeviceTouchSession) -> XCTestExpectation {
        let idle = expectation(description: "all accepted contacts have finished flushing")
        var fulfilled = false
        session.onChange = { [weak session] in
            guard let session, session.isIdle && !fulfilled else { return }
            fulfilled = true
            idle.fulfill()
        }
        return idle
    }

    private func waitFor(_ expectations: [XCTestExpectation]) async {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 5)
        XCTAssertEqual(result, .completed)
    }

    private func event(_ phase: TouchPhase, _ point: CGPoint) -> TouchEvent {
        TouchEvent(phase: phase, point: point)
    }

    private func nativeEvent(_ phase: TouchPhase, _ point: CGPoint, marker: UInt8) -> TouchEvent {
        TouchEvent(phase: phase, point: point, nativeInput: HIDNativeInput(
            reports: [HIDInputReport(serviceID: 0x501, data: Data([marker]))],
            cancellationReports: [HIDInputReport(serviceID: 0x501, data: Data([0]))]
        ))
    }
}

/// Arrival is observable separately from release, so the test controls exactly
/// which transport operation is suspended without sleeping or polling.
private actor TouchSessionTestGate {
    nonisolated let entered: XCTestExpectation
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ description: String) {
        entered = XCTestExpectation(description: description)
    }

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

private actor ControlledTouchSessionBackend: TouchInputBackend {
    enum Call: Equatable, Sendable {
        case send(TouchEvent)
        case flush
        case close
    }

    private enum InjectedFailure: Error {
        case send
        case flush
        case closed
    }

    nonisolated let name = "controlled-touch-backend"
    nonisolated let supportsNativeGestures: Bool
    private let sendGates: [Int: TouchSessionTestGate]
    private let flushGates: [Int: TouchSessionTestGate]
    private let failingSends: Set<Int>
    private let failingFlushes: Set<Int>
    private var calls: [Call] = []
    private var sendCount = 0
    private var flushCount = 0
    private var closed = false

    init(
        supportsNativeGestures: Bool = false,
        sendGates: [Int: TouchSessionTestGate] = [:],
        flushGates: [Int: TouchSessionTestGate] = [:],
        failingSends: Set<Int> = [],
        failingFlushes: Set<Int> = []
    ) {
        self.supportsNativeGestures = supportsNativeGestures
        self.sendGates = sendGates
        self.flushGates = flushGates
        self.failingSends = failingSends
        self.failingFlushes = failingFlushes
    }

    func send(_ event: TouchEvent) async throws {
        sendCount += 1
        let ordinal = sendCount
        calls.append(.send(event))
        if let gate = sendGates[ordinal] { await gate.pause() }
        if closed { throw InjectedFailure.closed }
        if failingSends.contains(ordinal) { throw InjectedFailure.send }
    }

    func flush() async throws {
        flushCount += 1
        let ordinal = flushCount
        calls.append(.flush)
        if let gate = flushGates[ordinal] { await gate.pause() }
        if closed { throw InjectedFailure.closed }
        if failingFlushes.contains(ordinal) { throw InjectedFailure.flush }
    }

    func snapshot() -> [Call] { calls }

    func releaseAllGates() async {
        for gate in sendGates.values { await gate.release() }
        for gate in flushGates.values { await gate.release() }
    }

    func close() async {
        closed = true
        calls.append(.close)
        await releaseAllGates()
    }
}
