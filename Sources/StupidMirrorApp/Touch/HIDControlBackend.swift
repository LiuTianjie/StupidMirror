import CoreGraphics
import Foundation

/// Keeps synchronous ControlBackend geometry available outside the main actor.
private final class ControlScreenSizeStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DeviceScreenSize

    init(_ size: DeviceScreenSize) { stored = size }
    var value: DeviceScreenSize {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Coordinate input uses a system HID connection. WDA is created only for a
/// capability that needs it, or when HID could not connect before any input.
/// Both paths share one owner, including the entire duration of WDA replay.
@MainActor
final class HIDControlBackend: ControlBackend {
    typealias TouchConnector = @Sendable () async throws -> any TouchInputBackend
    typealias SizeProvider = @MainActor @Sendable () -> DeviceScreenSize?

    let touch: DeviceTouchSession
    nonisolated private let sizeStorage: ControlScreenSizeStorage
    private let touchConnector: TouchConnector
    private let auxiliaryConnector: DeviceControlSession.Connector
    private let sizeProvider: SizeProvider
    private var auxiliary: (any ControlBackend)?
    private var auxiliaryTask: Task<any ControlBackend, Error>?
    private var auxiliaryGeneration: UInt64 = 0
    private var auxiliaryGeometryDirty = false
    private var recoveryAfter = ContinuousClock.now
    private var closed = false

    nonisolated var screenSize: DeviceScreenSize { sizeStorage.value }

    private init(
        screenSize: DeviceScreenSize,
        sizeProvider: @escaping SizeProvider,
        touchConnector: @escaping TouchConnector,
        auxiliaryConnector: @escaping DeviceControlSession.Connector
    ) {
        self.sizeStorage = ControlScreenSizeStorage(screenSize)
        self.sizeProvider = sizeProvider
        self.touchConnector = touchConnector
        self.auxiliaryConnector = auxiliaryConnector
        self.touch = DeviceTouchSession()
    }

    static func connect(
        screenSize: DeviceScreenSize,
        sizeProvider: @escaping SizeProvider,
        touchConnector: @escaping TouchConnector,
        auxiliaryConnector: @escaping DeviceControlSession.Connector,
        report: @escaping DeviceControlSession.ProgressReporter
    ) async throws -> HIDControlBackend {
        let result = HIDControlBackend(
            screenSize: screenSize, sizeProvider: sizeProvider,
            touchConnector: touchConnector, auxiliaryConnector: auxiliaryConnector
        )
        await report(.connectingAgent, "Connecting system touch")
        do {
            let backend = try await touchConnector()
            do {
                try Task.checkCancellation()
                try result.touch.installBackend(backend)
            }
            catch { await backend.close(); throw error }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // No touch has been attempted. Choosing compatibility here is
            // safe; an error after sending input never reaches this branch.
            try Task.checkCancellation()
            let geometry = result.touch.geometryGeneration
            result.auxiliary = try await auxiliaryConnector(report)
            result.storeAuxiliarySize(result.auxiliary!.screenSize, generation: geometry)
            result.recoveryAfter = .now + .seconds(30)
        }
        await report(.finishing, nil)
        return result
    }

    private func getAuxiliary() async throws -> any ControlBackend {
        guard !closed else { throw ControlBackendError.rejected("Device control is closed.") }
        if let auxiliary { return auxiliary }
        if let auxiliaryTask { return try await auxiliaryTask.value }
        let attempt = auxiliaryGeneration
        let geometry = touch.geometryGeneration
        let connector = auxiliaryConnector
        let task = Task { try await connector { _, _ in } }
        auxiliaryTask = task
        do {
            let backend = try await task.value
            guard !closed, auxiliaryGeneration == attempt else {
                await backend.close()
                throw CancellationError()
            }
            auxiliary = backend
            auxiliaryTask = nil
            storeAuxiliarySize(backend.screenSize, generation: geometry)
            return backend
        } catch {
            if auxiliaryGeneration == attempt { auxiliaryTask = nil }
            throw error
        }
    }

    /// Runner/tunnel failures affect the auxiliary connection, never HID.
    func auxiliaryDidExit() {
        auxiliaryGeneration &+= 1
        auxiliaryTask?.cancel()
        auxiliaryTask = nil
        let previous = auxiliary
        auxiliary = nil
        if let previous { Task { await previous.close() } }
    }

    func screenGeometryDidChange() {
        auxiliaryGeometryDirty = true
        if let size = sizeProvider() { sizeStorage.value = size }
    }

    /// An awaited WDA response may describe a display that has since rotated
    /// or changed panels. A stale response must neither replace the current
    /// size nor clear the need to refresh WDA's own coordinate space.
    @discardableResult
    private func storeAuxiliarySize(
        _ size: DeviceScreenSize, generation: UInt64, clearsDirty: Bool = false
    ) -> Bool {
        guard !closed, generation == touch.geometryGeneration else {
            auxiliaryGeometryDirty = true
            return false
        }
        sizeStorage.value = size
        if clearsDirty { auxiliaryGeometryDirty = false }
        return true
    }

    private func withAuxiliary<T: Sendable>(
        changesDevice: Bool = false,
        _ operation: @escaping @Sendable (any ControlBackend) async throws -> T
    ) async throws -> T {
        let source = "auxiliary:\(UUID().uuidString)"
        return try await touch.runExclusive(source: source) { [self] in
            let geometry = touch.geometryGeneration
            let neededConnection = auxiliary == nil
            let started = ContinuousClock.now
            let backend: any ControlBackend
            do {
                backend = try await getAuxiliary()
                try touch.checkExclusive(source: source)
                if auxiliaryGeometryDirty {
                    let size = try await backend.ping()
                    guard storeAuxiliarySize(size, generation: geometry, clearsDirty: true) else {
                        throw TouchSessionError.cancelled
                    }
                }
            }
            catch {
                if DeviceControlSession.isSessionLoss(error) { auxiliaryDidExit() }
                // A healthy HID path must not be torn down by failed signing
                // or a failed lazy WDA connection.
                throw ControlBackendError.rejected(error.localizedDescription)
            }
            if changesDevice, neededConnection, started.duration(to: .now) > .seconds(2) {
                throw ControlBackendError.rejected("Control preparation finished. Repeat the action on the current screen.")
            }
            try Task.checkCancellation()
            try touch.checkExclusive(source: source)
            guard geometry == touch.geometryGeneration else {
                throw ControlBackendError.rejected("The screen changed while preparing control. Repeat the action on the current screen.")
            }
            do {
                let result = try await operation(backend)
                storeAuxiliarySize(backend.screenSize, generation: geometry)
                return result
            } catch {
                if DeviceControlSession.isSessionLoss(error) { auxiliaryDidExit() }
                if changesDevice {
                    touch.markUncertain("A device action did not finish reliably. Disconnect and reconnect control before sending more input.")
                }
                // Never rebuild/replay the whole control path after an
                // auxiliary action whose effect may already have occurred.
                throw ControlBackendError.rejected(error.localizedDescription)
            }
        }
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let size = screenSize
        return CGPoint(x: min(max(point.x / max(size.width, 0.001), 0), 1),
                       y: min(max(point.y / max(size.height, 0.001), 0), 1))
    }

    private func gesture(
        _ operation: @escaping @MainActor @Sendable (String, UInt64) async throws -> Void
    ) async throws {
        let owner = "gesture:\(UUID().uuidString)"
        try await touch.runExclusive(source: owner) { [self] in
            let geometry = touch.geometryGeneration
            do { try await operation(owner, geometry) }
            catch {
                // Cancellation also releases a held finger. If release fails,
                // DeviceTouchSession keeps the device in its uncertain state.
                try? await touch.cancel(source: owner)
                throw error
            }
        }
    }

    private func contact(_ phase: TouchPhase, _ point: CGPoint, owner: String, geometry: UInt64) async throws {
        try await touch.accept(TouchEvent(phase: phase, point: point), source: owner,
                               geometryGeneration: geometry,
                               waitForFlush: phase == .up || phase == .cancel,
                               waitForSend: phase == .down)
    }

    func tap(_ point: CGPoint) async throws {
        let point = normalized(point)
        guard touch.hasBackend else {
            return try await withAuxiliary(changesDevice: true) {
                try await $0.tap(DeviceControlSession.denormalize(point, $0.screenSize))
            }
        }
        try await gesture { [self] owner, geometry in
            try await contact(.down, point, owner: owner, geometry: geometry)
            try await Task.sleep(for: .milliseconds(80))
            try await contact(.up, point, owner: owner, geometry: geometry)
        }
    }

    func doubleTap(_ point: CGPoint) async throws {
        let point = normalized(point)
        guard touch.hasBackend else {
            return try await withAuxiliary(changesDevice: true) {
                try await $0.doubleTap(DeviceControlSession.denormalize(point, $0.screenSize))
            }
        }
        try await gesture { [self] owner, geometry in
            for index in 0..<2 {
                try await contact(.down, point, owner: owner, geometry: geometry)
                try await Task.sleep(for: .milliseconds(80))
                try await contact(.up, point, owner: owner, geometry: geometry)
                if index == 0 { try await Task.sleep(for: .milliseconds(90)) }
            }
        }
    }

    func longPress(_ point: CGPoint, durationSeconds: Double) async throws {
        let point = normalized(point)
        guard touch.hasBackend else {
            return try await withAuxiliary(changesDevice: true) {
                try await $0.longPress(DeviceControlSession.denormalize(point, $0.screenSize), durationSeconds: durationSeconds)
            }
        }
        try await gesture { [self] owner, geometry in
            try await contact(.down, point, owner: owner, geometry: geometry)
            try await Task.sleep(for: .seconds(max(0.05, durationSeconds)))
            try await contact(.up, point, owner: owner, geometry: geometry)
        }
    }

    func drag(from start: CGPoint, to end: CGPoint, durationMS: Int) async throws {
        guard touch.hasBackend else {
            let start = normalized(start), end = normalized(end)
            return try await withAuxiliary(changesDevice: true) {
                try await $0.drag(from: DeviceControlSession.denormalize(start, $0.screenSize),
                                  to: DeviceControlSession.denormalize(end, $0.screenSize), durationMS: durationMS)
            }
        }
        let duration = max(1, min(durationMS, 30_000))
        let count = max(1, duration / 16)
        let path = (0...count).map { index in
            let fraction = Double(index) / Double(count)
            return DevicePathSample(
                point: CGPoint(x: start.x + (end.x - start.x) * fraction,
                               y: start.y + (end.y - start.y) * fraction),
                offsetMS: Int(Double(duration) * fraction)
            )
        }
        try await dragPath(path)
    }

    func dragPath(_ samples: [DevicePathSample]) async throws {
        let path = samples.map { DevicePathSample(point: normalized($0.point), offsetMS: $0.offsetMS) }
        guard touch.hasBackend else {
            return try await withAuxiliary(changesDevice: true) { backend in
                try await backend.dragPath(path.map {
                    DevicePathSample(point: DeviceControlSession.denormalize($0.point, backend.screenSize), offsetMS: $0.offsetMS)
                })
            }
        }
        guard let first = path.first, let last = path.last else { return }
        try await gesture { [self] owner, geometry in
            try await contact(.down, first.point, owner: owner, geometry: geometry)
            let started = ContinuousClock.now
            for sample in path.dropFirst() {
                try await Task.sleep(until: started + .milliseconds(max(0, sample.offsetMS - first.offsetMS)), clock: .continuous)
                try await contact(.move, sample.point, owner: owner, geometry: geometry)
            }
            try await contact(.up, last.point, owner: owner, geometry: geometry)
        }
    }

    // The host-native gesture service carries relative deltas, not a center.
    // Preserve this semantic API's explicit center through the auxiliary path.
    func pinch(at center: CGPoint, scale: Double, velocity: Double) async throws {
        let center = normalized(center)
        try await withAuxiliary(changesDevice: true) {
            try await $0.pinch(at: DeviceControlSession.denormalize(center, $0.screenSize), scale: scale, velocity: velocity)
        }
    }
    func rotate(at center: CGPoint, degrees: Double, velocity: Double) async throws {
        let center = normalized(center)
        try await withAuxiliary(changesDevice: true) {
            try await $0.rotate(at: DeviceControlSession.denormalize(center, $0.screenSize), degrees: degrees, velocity: velocity)
        }
    }
    func typeText(_ text: String) async throws {
        try await withAuxiliary(changesDevice: true) { try await $0.typeText(text) }
    }
    func clearActiveText() async throws -> ControlTextEditResult {
        try await withAuxiliary(changesDevice: true) { try await $0.clearActiveText() }
    }
    func replaceActiveText(_ text: String) async throws -> ControlTextEditResult {
        try await withAuxiliary(changesDevice: true) { try await $0.replaceActiveText(text) }
    }
    func press(_ button: DeviceButton) async throws {
        try await withAuxiliary(changesDevice: true) { try await $0.press(button) }
    }
    func screenshotPNG() async throws -> Data {
        try await withAuxiliary { try await $0.screenshotPNG() }
    }
    func uiTree() async throws -> String {
        try await withAuxiliary { try await $0.uiTree() }
    }
    func findTextElements(query: String, maximumMatches: Int) async throws -> [NativeElementMatch] {
        try await withAuxiliary { try await $0.findTextElements(query: query, maximumMatches: maximumMatches) }
    }
    func click(elementReference: String) async throws {
        try await withAuxiliary(changesDevice: true) { try await $0.click(elementReference: elementReference) }
    }
    func click(semantic element: ScreenElement) async throws -> Bool {
        try await withAuxiliary(changesDevice: true) { try await $0.click(semantic: element) }
    }
    func activateApp(_ identifier: String) async throws {
        try await withAuxiliary(changesDevice: true) { try await $0.activateApp(identifier) }
    }
    func terminateApp(_ identifier: String) async throws -> Bool {
        try await withAuxiliary(changesDevice: true) { try await $0.terminateApp(identifier) }
    }
    func openURL(_ url: String) async throws {
        try await withAuxiliary(changesDevice: true) { try await $0.openURL(url) }
    }

    func ping() async throws -> DeviceScreenSize {
        guard !closed else { throw ControlBackendError.rejected("Device control is closed.") }
        if auxiliary == nil, let size = sizeProvider() { sizeStorage.value = size }
        if touch.hasBackend, !touch.uncertain {
            do { _ = try await touch.probeIfIdle() }
            catch {
                // The probe held input ownership while idle, and retired the
                // failed transport before returning. No gesture is replayed.
                throw ControlBackendError.sessionLost(error.localizedDescription)
            }
        }
        if !touch.uncertain, let auxiliary, touch.isIdle {
            let geometry = touch.geometryGeneration
            do {
                try await touch.runExclusive(source: "auxiliary-health:\(UUID().uuidString)") { [self] in
                    let size = try await auxiliary.ping()
                    guard storeAuxiliarySize(size, generation: geometry, clearsDirty: true) else {
                        throw TouchSessionError.cancelled
                    }
                }
            } catch TouchSessionError.cancelled {
                // Geometry invalidation cancels this read, not the healthy
                // auxiliary connection. Its dirty flag remains set.
            } catch {
                auxiliaryDidExit()
                if !touch.hasBackend {
                    throw ControlBackendError.sessionLost(error.localizedDescription)
                }
                // Reading the old WDA endpoint can fail while HID remains
                // healthy. Retain HID and reconnect WDA only when requested.
            }
        }
        // HID has its own transport lifecycle. Do not bring up WDA merely for
        // its /status or /window/size endpoints, or insert RTTs into a drag.
        if !touch.hasBackend, !touch.uncertain, touch.isIdle, .now >= recoveryAfter {
            recoveryAfter = .now + .seconds(30)
            do {
                let backend = try await touchConnector()
                do { try touch.installBackend(backend) }
                catch { await backend.close() }
            } catch { /* Compatibility remains selected until a later idle probe. */ }
        }
        return screenSize
    }

    func close() async {
        guard !closed else { return }
        closed = true
        auxiliaryGeneration &+= 1
        auxiliaryTask?.cancel()
        auxiliaryTask = nil
        await touch.close()
        if let auxiliary {
            self.auxiliary = nil
            await auxiliary.close()
        }
    }
}
