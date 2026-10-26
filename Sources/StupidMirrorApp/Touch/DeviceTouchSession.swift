import CoreGraphics
import Foundation

/// These errors deliberately do not ask the control layer to reconnect and
/// replay an action whose delivery to the device may already have succeeded.
enum TouchSessionError: Error, LocalizedError, Sendable {
    case unsupported
    case closed
    case invalidPoint
    case staleGeometry(expected: UInt64, received: UInt64)
    case busy(owner: String)
    case noActiveContact
    case gestureEnding
    case queueFull
    case cancelled
    case incompleteGesture
    case uncertain(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "Continuous touch is not available for this device."
        case .closed: "The touch session is closed."
        case .invalidPoint: "Touch coordinates must be finite values between zero and one."
        case let .staleGeometry(expected, received):
            "The touch geometry changed (expected \(expected), received \(received))."
        case .busy: "Another input operation is still in progress."
        case .noActiveContact: "There is no active contact for this input source."
        case .gestureEnding: "The previous contact is still being released."
        case .queueFull: "The touch input queue is full."
        case .cancelled: "The input operation was cancelled."
        case .incompleteGesture: "The input operation ended without releasing its contact."
        case let .uncertain(message): "Touch delivery is uncertain: \(message)"
        }
    }
}

/// Serializes native, plugin and automation input against one connected
/// transport. Ownership is reserved synchronously, before the first await.
@MainActor
final class DeviceTouchSession {
    var onChange: (() -> Void)?
    var onFailure: ((TouchSessionError) -> Void)?

    private(set) var geometryGeneration: UInt64 = 0
    private(set) var uncertain = false

    var hasBackend: Bool { backend != nil && !closing && !closed }
    var supportsNativeGestures: Bool { hasBackend && backend?.supportsNativeGestures == true }
    var name: String? { backend?.name }
    var activeSource: String? { reservation?.source ?? contacts.first?.source }
    var isIdle: Bool {
        !closing && !closed && reservation == nil && contacts.isEmpty && sendingContact == nil
            && pending.isEmpty && inFlight == nil && drainTask == nil
    }
    var idle: Bool { isIdle }

    private var backend: (any TouchInputBackend)?
    private let queueCapacity: Int
    private var pending: [PendingEvent] = []
    private var inFlight: PendingEvent?
    // The tail owns admission; sendingContact is the contact that has actually
    // entered send(). Queued taps must never change the latter's release point.
    private var contacts: [Contact] = []
    private var sendingContact: Contact?
    private var reservation: Reservation?
    private var drainTask: Task<Void, Never>?
    private var retiredBackends: [Task<Void, Never>] = []
    private var nextToken: UInt64 = 0
    private var lifecycle: UInt64 = 0
    private var closing = false
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var uncertaintyMessage = "The previous action could not be confirmed."

    init(backend: (any TouchInputBackend)? = nil, queueCapacity: Int = 64) {
        self.backend = backend
        // Reserve room for DOWN, the final coalesced MOVE, and UP/CANCEL.
        self.queueCapacity = max(3, queueCapacity)
    }

    /// Replacing an idle transport never clears uncertain delivery. Recovery
    /// from that state requires closing and constructing a new session.
    func installBackend(_ backend: any TouchInputBackend) throws {
        try requireOpen()
        try requireCertain()
        guard isIdle else { throw TouchSessionError.busy(owner: activeSource ?? "input transport") }
        if let previous = self.backend, previous !== backend {
            retiredBackends.append(Task { await previous.close() })
        }
        self.backend = backend
        onChange?()
    }

    /// Returns once the event is admitted. DOWN starts the drain immediately;
    /// only a MOVE that has not reached send() can be replaced by a newer MOVE.
    func enqueue(_ event: TouchEvent, source: String, geometryGeneration: UInt64) throws {
        do {
            _ = try admit(event, source: source, generation: geometryGeneration, flush: false)
        } catch TouchSessionError.queueFull {
            // Dropping one relative gesture increment and continuing would
            // corrupt the gesture. Release this source instead of resuming
            // from a later increment when the queue becomes available.
            if event.nativeInput != nil, contacts.first?.source == source {
                _ = cancelContacts(failure: .queueFull)
                onChange?()
            }
            throw TouchSessionError.queueFull
        }
    }

    /// Normally confirms queue acceptance only. waitForSend waits for send()
    /// without adding a flush; waitForFlush also awaits an explicit backend.flush().
    /// This is transport completion, never proof of UIKit execution.
    /// UP/CANCEL always flush before releasing the contact, with either mode.
    func accept(
        _ event: TouchEvent,
        source: String,
        geometryGeneration: UInt64,
        waitForFlush: Bool = false,
        waitForSend: Bool = false
    ) async throws {
        try Task.checkCancellation()
        let entry = try admit(event, source: source, generation: geometryGeneration, flush: waitForFlush)
        if waitForFlush || waitForSend { try await wait(for: entry) }
    }

    /// Cancels only this source unless explicitly forced. An opaque exclusive
    /// body retains ownership until it actually returns; cancellation prevents
    /// it from admitting further touches, but does not claim to undo its work.
    func cancel(source: String? = nil, force: Bool = false) async throws {
        try requireOpen()
        try requireCancellationOwner(source: source, force: force)
        reservation?.cancelled = true
        let terminal = cancelContacts()
        onChange?()
        if let terminal { try await wait(for: terminal) }
    }

    /// Synchronous invalidation rejects old UI frames immediately, even while
    /// a previous send is suspended. Internal cancellation bypasses geometry
    /// validation so that the old contact can still be released.
    func invalidateGeometry() {
        geometryGeneration &+= 1
        guard !closing && !closed else { return }
        reservation?.cancelled = true
        _ = cancelContacts()
        onChange?()
    }

    /// The composite controller calls this after an irreversible WDA action
    /// fails. It must not call it for a failed read-only operation.
    func markUncertain(_ message: String) {
        guard !closing && !closed else { return }
        setUncertain(message)
    }

    /// Rechecks ownership after asynchronous preparation and immediately
    /// before an exclusive body sends an irreversible device action.
    func checkExclusive(source: String) throws {
        try requireOpen()
        try requireCertain()
        try Task.checkCancellation()
        guard let reservation else { throw TouchSessionError.cancelled }
        guard reservation.source == source else { throw TouchSessionError.busy(owner: reservation.source) }
        if reservation.cancelled { throw TouchSessionError.cancelled }
    }

    /// Holds the same owner across the idle check and the health flush. A
    /// failed probe can therefore close safely before any new DOWN is admitted.
    /// No touch was sent, so its error is not an uncertain action delivery.
    func probeIfIdle() async throws -> Bool {
        guard hasBackend && !uncertain && isIdle, let transport = backend else { return false }
        let operation = Reservation(token: token(), source: "touch-health:\(UUID().uuidString)", waitsForBodyOnClose: false)
        reservation = operation
        onChange?()
        do {
            try await transport.flush()
            try requireOpen()
            let healthy = !uncertain
            finishReservation(operation)
            return healthy
        } catch {
            // The reservation remains held until close seals admission. This
            // special reservation has no opaque body for close to wait upon.
            await close()
            operation.finish()
            throw error
        }
    }

    /// Reserves the same owner used by live touch for an entire semantic or
    /// fallback action. A same-source body may issue multiple touch gestures;
    /// releasing each contact does not release the outer reservation.
    /// Close the session outside this body: close waits for the body to finish.
    func runExclusive<T: Sendable>(
        source: String,
        body: @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try requireOpen()
        try requireCertain()
        try Task.checkCancellation()
        guard isIdle else { throw TouchSessionError.busy(owner: activeSource ?? "input transport") }
        let operation = Reservation(token: token(), source: source)
        reservation = operation
        onChange?()
        var attemptedCleanup = false
        do {
            let value = try await body()
            try requireOpen()
            try requireCertain()
            while let tail = contacts.last {
                if let terminal = tail.terminal {
                    try await wait(for: terminal)
                } else {
                    attemptedCleanup = true
                    if let terminal = cancelContacts() { try await wait(for: terminal) }
                    throw TouchSessionError.incompleteGesture
                }
            }
            try requireOpen()
            try requireCertain()
            if operation.cancelled { throw TouchSessionError.cancelled }
            try Task.checkCancellation()
            finishReservation(operation)
            return value
        } catch {
            // Cleanup can run after task cancellation. We must keep the owner
            // while the release is in flight, and never clear uncertainty.
            if !attemptedCleanup && !closing && !closed {
                if let terminal = cancelContacts(allowNewRelease: sendingContact?.cleanupAttempted != true) {
                    try? await wait(for: terminal)
                }
            }
            finishReservation(operation)
            throw error
        }
    }

    /// Closes admission before awaiting the transport, and resolves even an
    /// in-flight event's waiters once. A late send completion cannot revive it.
    func close() async {
        if closed { return }
        if closing {
            await withCheckedContinuation { closeWaiters.append($0) }
            return
        }
        closing = true
        lifecycle &+= 1
        let failure = TouchSessionError.closed
        pending.forEach { $0.finish(.failure(failure)) }
        pending.removeAll()
        inFlight?.finish(.failure(failure))
        inFlight = nil
        contacts.removeAll()
        sendingContact = nil
        let activeReservation = reservation
        activeReservation?.cancelled = true
        let draining = drainTask
        draining?.cancel()
        drainTask = nil
        let transport = backend
        backend = nil
        let retired = retiredBackends
        retiredBackends.removeAll()
        onChange?()
        await transport?.close()
        // Closing the backend must unblock its I/O; Task.cancel alone does not
        // ensure an old send cannot arrive after a replacement session starts.
        await draining?.value
        if let activeReservation, activeReservation.waitsForBodyOnClose {
            await activeReservation.waitForCompletion()
        }
        for task in retired { await task.value }
        reservation = nil
        closed = true
        closing = false
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
        onChange?()
    }

    private func admit(_ event: TouchEvent, source: String, generation: UInt64, flush: Bool) throws -> PendingEvent {
        try requireOpen()
        guard generation == geometryGeneration else {
            throw TouchSessionError.staleGeometry(expected: geometryGeneration, received: generation)
        }
        guard event.isValid else { throw TouchSessionError.invalidPoint }
        guard backend != nil else { throw TouchSessionError.unsupported }
        if event.nativeInput != nil, !supportsNativeGestures { throw TouchSessionError.unsupported }
        let releasing = event.phase == .up || event.phase == .cancel
        if !releasing { try requireCertain() }
        if let reservation {
            guard reservation.source == source else { throw TouchSessionError.busy(owner: reservation.source) }
            if reservation.cancelled && !releasing { throw TouchSessionError.cancelled }
        }
        if let owner = contacts.first?.source, owner != source { throw TouchSessionError.busy(owner: owner) }
        if event.phase == .down {
            if let tail = contacts.last {
                guard let terminal = tail.terminal else { throw TouchSessionError.busy(owner: tail.source) }
                // A normal UP may be followed immediately by another click.
                // A click may interrupt native momentum. Queue its DOWN
                // behind that source's gesture cleanup; drain will flush the
                // CANCEL first and discard this new contact if cleanup fails.
                let interruptsNativeGesture = tail.isNativeInput && event.nativeInput == nil
                    && terminal.event.phase == .cancel
                guard terminal.event.phase == .up || interruptsNativeGesture else {
                    throw TouchSessionError.gestureEnding
                }
            }
            // A new contact must fit its DOWN, final MOVE, and UP even if
            // earlier contacts have not begun draining yet.
            guard pending.count + 3 <= queueCapacity else { throw TouchSessionError.queueFull }
            contacts.append(Contact(token: token(), source: source, point: event.point,
                                    isNativeInput: event.nativeInput != nil))
        }
        guard let tail = contacts.last else { throw TouchSessionError.noActiveContact }
        if event.phase == .cancel {
            guard let terminal = cancelContacts() else { throw TouchSessionError.noActiveContact }
            return terminal
        }
        guard tail.isNativeInput == (event.nativeInput != nil) else { throw TouchSessionError.invalidPoint }
        guard tail.terminal == nil else { throw TouchSessionError.gestureEnding }
        // Once delivery is uncertain, only release is allowed; do not turn
        // that release into an additional movement on the device.
        if event.phase == .up && !tail.isNativeInput && !uncertain && tail.admittedPoint != event.point {
            let finalMove = TouchEvent(phase: .move, point: event.point)
            if let last = pending.last,
               last.contactToken == tail.token, last.event.phase == .move {
                guard pending.count < queueCapacity else { throw TouchSessionError.queueFull }
                // Keep this MOVE's flush request and all of its waiters.
                last.event = finalMove
            } else {
                guard pending.count + 2 <= queueCapacity else { throw TouchSessionError.queueFull }
                pending.append(PendingEvent(event: finalMove, contactToken: tail.token, flush: false))
            }
        }
        tail.admittedPoint = event.point
        if event.phase == .move, event.nativeInput == nil, let last = pending.last,
           last.event.nativeInput == nil,
           last.contactToken == tail.token, last.event.phase == .move {
            last.event = event
            last.flush = last.flush || flush
            return last
        }
        guard pending.count < queueCapacity else { throw TouchSessionError.queueFull }
        let entry = PendingEvent(event: event, contactToken: tail.token, flush: flush)
        pending.append(entry)
        if event.phase == .up { tail.terminal = entry }
        startDrain()
        if event.phase != .move { onChange?() }
        return entry
    }

    /// Discards all future contacts. Only the contact that entered send() may
    /// need releasing, using its last attempted point rather than the tail's.
    /// A release already in flight (or a queued CANCEL) keeps its waiters.
    private func cancelContacts(
        failure: TouchSessionError = .cancelled,
        allowNewRelease: Bool = true
    ) -> PendingEvent? {
        guard let first = contacts.first, backend != nil else { return nil }
        guard let active = sendingContact else {
            pending.forEach { $0.finish(.failure(failure)) }
            pending.removeAll()
            contacts.removeAll()
            // No DOWN entered send(), so no remote release should be emitted.
            let completed = PendingEvent(
                event: TouchEvent(phase: .cancel, point: first.admittedPoint),
                contactToken: first.token,
                flush: false
            )
            completed.finish(.success(()))
            return completed
        }
        let retainedTerminal = active.terminal.flatMap { terminal -> PendingEvent? in
            if terminal === inFlight { return terminal }
            if terminal.event.phase == .cancel && pending.contains(where: { $0 === terminal }) { return terminal }
            return nil
        }
        let discarded = pending.filter { $0 !== retainedTerminal }
        pending.removeAll { $0 !== retainedTerminal }
        discarded.forEach { $0.finish(.failure(failure)) }
        contacts = [active]
        active.terminal = retainedTerminal
        if let retainedTerminal {
            startDrain()
            return retainedTerminal
        }
        guard allowNewRelease else { return nil }
        let entry = PendingEvent(
            event: TouchEvent(phase: .cancel, point: active.sentPoint),
            contactToken: active.token,
            flush: true
        )
        active.cleanupAttempted = true
        active.terminal = entry
        pending.append(entry)
        startDrain()
        return entry
    }

    private func startDrain() {
        guard drainTask == nil && !pending.isEmpty && !closing && !closed else { return }
        let epoch = lifecycle
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.drain(epoch: epoch)
        }
    }

    private func drain(epoch: UInt64) async {
        while lifecycle == epoch && !closing && !closed && !pending.isEmpty {
            let entry = pending.removeFirst()
            inFlight = entry
            guard let transport = backend else {
                entry.finish(.failure(TouchSessionError.unsupported))
                inFlight = nil
                continue
            }
            guard let active = contacts.first, active.token == entry.contactToken else {
                entry.finish(.failure(TouchSessionError.cancelled))
                inFlight = nil
                continue
            }
            if entry.event.phase == .down { sendingContact = active }
            guard sendingContact?.token == active.token else {
                entry.finish(.failure(TouchSessionError.cancelled))
                inFlight = nil
                continue
            }
            active.sentPoint = entry.event.point
            // Every error from this point is uncertain, even if send throws
            // before returning: the remote peer may already have received it.
            var deliveryError: Error?
            do { try await transport.send(entry.event) }
            catch { deliveryError = error }
            guard lifecycle == epoch && !closing && !closed else { return }
            // A release can have reached the transport before send threw.
            // Draining it is still useful, but cannot erase that uncertainty.
            if entry.isTerminal || (entry.flush && deliveryError == nil) {
                do { try await transport.flush() }
                catch { if deliveryError == nil { deliveryError = error } }
            }
            guard lifecycle == epoch && !closing && !closed else { return }
            if let deliveryError {
                inFlight = nil
                if active.terminal === entry { active.terminal = nil }
                let failure = setUncertain(deliveryError.localizedDescription, failedPhase: entry.event.phase)
                entry.finish(.failure(failure))
            } else {
                if entry.isTerminal {
                    contacts.removeAll { $0.token == entry.contactToken }
                    if sendingContact?.token == entry.contactToken { sendingContact = nil }
                }
                inFlight = nil
                entry.finish(.success(()))
            }
        }
        guard lifecycle == epoch else { return }
        drainTask = nil
        onChange?()
    }

    @discardableResult
    private func setUncertain(_ message: String, failedPhase: TouchPhase? = nil) -> TouchSessionError {
        uncertain = true
        uncertaintyMessage = message
        let failure = TouchSessionError.uncertain(message)
        if let active = sendingContact {
            // A failed CANCEL is already the best-effort cleanup attempt.
            // Otherwise make one automatic release, including when the UI
            // never gets another mouse-up. Its failure must not start a loop.
            if failedPhase == .cancel { active.cleanupAttempted = true }
            _ = cancelContacts(failure: failure, allowNewRelease: !active.cleanupAttempted)
        } else {
            _ = cancelContacts(failure: failure, allowNewRelease: false)
        }
        onChange?()
        onFailure?(failure)
        return failure
    }

    private func wait(for entry: PendingEvent) async throws {
        try await withCheckedThrowingContinuation { continuation in
            if let result = entry.result { continuation.resume(with: result) }
            else { entry.waiters.append(continuation) }
        }
    }

    private func requireOpen() throws {
        if closing || closed { throw TouchSessionError.closed }
    }

    private func requireCertain() throws {
        if uncertain { throw TouchSessionError.uncertain(uncertaintyMessage) }
    }

    private func requireCancellationOwner(source: String?, force: Bool) throws {
        if let owner = activeSource, !force && source != owner { throw TouchSessionError.busy(owner: owner) }
    }

    private func finishReservation(_ operation: Reservation) {
        if reservation?.token == operation.token {
            reservation = nil
            operation.finish()
            onChange?()
        } else {
            operation.finish()
        }
    }

    private func token() -> UInt64 {
        nextToken &+= 1
        return nextToken
    }

    private final class Contact {
        let token: UInt64
        let source: String
        let isNativeInput: Bool
        var admittedPoint: CGPoint
        var sentPoint: CGPoint
        var terminal: PendingEvent?
        var cleanupAttempted = false

        init(token: UInt64, source: String, point: CGPoint, isNativeInput: Bool) {
            self.token = token
            self.source = source
            self.isNativeInput = isNativeInput
            self.admittedPoint = point
            self.sentPoint = point
        }
    }

    @MainActor
    private final class Reservation {
        let token: UInt64
        let source: String
        let waitsForBodyOnClose: Bool
        var cancelled = false
        private var completed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(token: UInt64, source: String, waitsForBodyOnClose: Bool = true) {
            self.token = token
            self.source = source
            self.waitsForBodyOnClose = waitsForBodyOnClose
        }

        func waitForCompletion() async {
            if completed { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish() {
            guard !completed else { return }
            completed = true
            let completions = waiters
            waiters.removeAll()
            completions.forEach { $0.resume() }
        }
    }

    @MainActor
    private final class PendingEvent {
        var event: TouchEvent
        let contactToken: UInt64
        var flush: Bool
        var waiters: [CheckedContinuation<Void, Error>] = []
        private(set) var result: Result<Void, Error>?
        var isTerminal: Bool { event.phase == .up || event.phase == .cancel }

        init(event: TouchEvent, contactToken: UInt64, flush: Bool) {
            self.event = event
            self.contactToken = contactToken
            self.flush = flush
        }

        func finish(_ result: Result<Void, Error>) {
            guard self.result == nil else { return }
            self.result = result
            let completions = waiters
            waiters.removeAll()
            completions.forEach { $0.resume(with: result) }
        }
    }
}
