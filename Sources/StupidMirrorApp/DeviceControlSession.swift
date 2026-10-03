import CoreGraphics
import Foundation
import OSLog

// MARK: - Backend contract

/// A hardware or system button the device understands.
enum DeviceButton: String, Equatable, Sendable {
    case home
    case back
    case appSwitcher
    case volumeUp
    case volumeDown
}

struct ControlTextEditResult: Equatable, Sendable {
    let strategy: String
    let value: String?
    let verified: Bool
}

enum ControlBackendError: LocalizedError {
    /// The agent or its session is gone; the backend must be rebuilt.
    case sessionLost(String)
    /// The device rejected this request; the session itself is fine.
    case rejected(String)
    case invalidResponse(String)

    var isSessionLoss: Bool {
        if case .sessionLost = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case let .sessionLost(message), let .rejected(message), let .invalidResponse(message):
            message
        }
    }
}

/// One point of a finger path in device points, with its offset from the
/// start of the gesture.
struct DevicePathSample: Equatable, Sendable {
    var point: CGPoint
    var offsetMS: Int
}

/// Everything the app needs from a device to drive it. Points are in the
/// device's own screen-point space (`screenSize`); the session converts
/// normalized mirror coordinates before calling.
protocol ControlBackend: AnyObject, Sendable {
    var screenSize: DeviceScreenSize { get }

    func tap(_ point: CGPoint) async throws
    func doubleTap(_ point: CGPoint) async throws
    func longPress(_ point: CGPoint, durationSeconds: Double) async throws
    func drag(from start: CGPoint, to end: CGPoint, durationMS: Int) async throws
    /// Replays a recorded finger path with its timing.
    func dragPath(_ samples: [DevicePathSample]) async throws
    func pinch(at center: CGPoint, scale: Double, velocity: Double) async throws
    func rotate(at center: CGPoint, degrees: Double, velocity: Double) async throws
    func typeText(_ text: String) async throws
    func clearActiveText() async throws -> ControlTextEditResult
    func replaceActiveText(_ text: String) async throws -> ControlTextEditResult
    func press(_ button: DeviceButton) async throws
    func screenshotPNG() async throws -> Data
    func uiTree() async throws -> String
    func findTextElements(query: String, maximumMatches: Int) async throws -> [NativeElementMatch]
    func click(elementReference: String) async throws
    func click(semantic element: ScreenElement) async throws -> Bool
    func activateApp(_ identifier: String) async throws
    func terminateApp(_ identifier: String) async throws -> Bool
    /// A cheap request that proves the session is alive; refreshes `screenSize`.
    func ping() async throws -> DeviceScreenSize
    func close() async
}

extension ControlBackend {
    /// Backends without timed-path support collapse the path to its endpoints.
    func dragPath(_ samples: [DevicePathSample]) async throws {
        guard let first = samples.first, let last = samples.last else { return }
        try await drag(from: first.point, to: last.point, durationMS: max(last.offsetMS, 50))
    }

    func pinch(at center: CGPoint, scale: Double, velocity: Double) async throws {
        throw ControlBackendError.rejected("Pinch gestures are not supported on this device.")
    }

    func rotate(at center: CGPoint, degrees: Double, velocity: Double) async throws {
        throw ControlBackendError.rejected("Rotation gestures are not supported on this device.")
    }
}

// MARK: - Fire-and-forget actions

/// Gestures from the mirror window. Coordinates are normalized (0...1).
enum ControlAction: Equatable {
    case tap(CGPoint)
    case doubleTap(CGPoint)
    case longPress(CGPoint, durationMS: Int)
    case swipe(from: CGPoint, to: CGPoint, durationMS: Int)
    /// A recorded path; sample timestamps are in seconds.
    case drag(path: [ControlPathSample])
    case flick(ControlFlickDirection)
    case pinch(center: CGPoint, scale: Double, velocity: Double)
    case rotate(center: CGPoint, degrees: Double, velocity: Double)
    case typeText(String)
    case press(DeviceButton)

    var isSwipe: Bool {
        switch self {
        case .swipe, .flick, .drag: true
        default: false
        }
    }

    var isTap: Bool {
        if case .tap = self { return true }
        return false
    }

    /// Pointer gestures that may be dropped when the device lags: replaying a
    /// stale tap or scroll seconds late is worse than skipping it. Text, key
    /// presses, long presses and multi-touch gestures are always delivered.
    var isDroppable: Bool {
        switch self {
        case .tap, .swipe, .flick, .drag: true
        default: false
        }
    }
}

/// Keeps interactive input bounded when the device lags: consecutive swipes
/// collapse to the newest, consecutive taps to the last one, and once the
/// queue is full the oldest droppable gesture goes first.
struct ControlActionBuffer {
    private(set) var actions: [ControlAction] = []
    let maximumCount: Int

    init(maximumCount: Int = 4) {
        self.maximumCount = max(1, maximumCount)
    }

    var count: Int { actions.count }
    var isEmpty: Bool { actions.isEmpty }

    mutating func append(_ action: ControlAction) {
        if case .doubleTap = action, actions.last?.isTap == true {
            // A double click reports its first click as a tap. When that tap
            // is still waiting, the pair becomes one double tap rather than
            // three taps on the device.
            actions[actions.count - 1] = action
        } else if action.isSwipe, actions.last?.isSwipe == true {
            actions[actions.count - 1] = action
        } else if action.isTap, actions.last?.isTap == true {
            actions[actions.count - 1] = action
        } else {
            actions.append(action)
        }
        while actions.count > maximumCount,
              let index = actions.firstIndex(where: \.isDroppable) {
            actions.remove(at: index)
        }
        // Text and key presses are kept, but a device that stopped answering
        // must not collect an unbounded backlog either.
        if actions.count > Self.hardLimit {
            actions.removeFirst(actions.count - Self.hardLimit)
        }
    }

    static let hardLimit = 32

    mutating func popFirst() -> ControlAction? {
        guard !actions.isEmpty else { return nil }
        return actions.removeFirst()
    }

    mutating func removeAll() {
        actions.removeAll(keepingCapacity: true)
    }
}

/// The local Appium service (Android control) could not be started.
struct ControlServiceUnavailableError: LocalizedError {
    var errorDescription: String? { "control.error.appiumUnavailable" }
}

// MARK: - Failure wording

/// Maps raw agent or driver errors to the localized copy keys the UI shows.
enum ControlFailure {
    static func messageKey(for error: Error) -> String {
        if let agentError = error as? IOSAgentError {
            return agentError.copyKey
        }
        let haystack = [String(describing: error), error.localizedDescription]
            .joined(separator: " ")
            .lowercased()
        if haystack.contains("unlock")
            || haystack.contains("reason: locked")
            || haystack.contains("device is locked") {
            return "control.error.unlockDevice"
        }
        if haystack.contains("developer mode") {
            return "control.error.developerMode"
        }
        if haystack.contains("enable ui automation") || haystack.contains("ui automation") {
            return "control.error.uiAutomation"
        }
        if haystack.contains("not trusted") || haystack.contains("trust this computer") || haystack.contains("pairing") {
            return "control.error.trustDevice"
        }
        if haystack.contains("provisioning profile")
            || haystack.contains("requires a development team")
            || haystack.contains("code signing")
            || haystack.contains("xcodebuild failed") {
            return "control.error.signing"
        }
        return error.localizedDescription
    }
}

// MARK: - Session

/// The control state of one mirrored device, shared by the mirror window, the
/// dashboard card, and the MCP automation layer.
///
/// The session owns a `ControlBackend` once connected. How that backend is
/// built is the caller's business (`connect(using:)` takes a connector), which
/// keeps iOS (WebDriverAgent over the device tunnel) and Android (UiAutomator2
/// through Appium) out of this file. Interactive gestures go through a small
/// coalescing queue; automation calls await their result directly.
@MainActor
final class DeviceControlSession: ObservableObject {
    typealias ProgressReporter = @Sendable (ControlConnectionPhase, String?) async -> Void
    typealias Connector = @Sendable (@escaping ProgressReporter) async throws -> any ControlBackend

    private static let logger = Logger(subsystem: "com.stupidmirror.app", category: "DeviceControl")

    @Published private(set) var state: ControlState = .unavailable
    @Published private(set) var screenSize: DeviceScreenSize?
    @Published private(set) var statusMessage = "Control not connected"
    @Published private(set) var connectionPhase: ControlConnectionPhase?
    @Published private(set) var connectionStartedAt: Date?

    private(set) var device: DeviceIdentity
    private var backend: (any ControlBackend)?
    private var connector: Connector?
    private var connectTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var pending = ControlActionBuffer()
    private var lastSentTap: (point: CGPoint, at: Date)?
    private var generation: UInt64 = 0
    private var keepAliveInterval: Duration = .seconds(30)

    /// Called with a localized-copy key or message when a connection attempt
    /// fails, so the owner can open the matching guide.
    var onFailure: ((String) -> Void)?

    init(device: DeviceIdentity) {
        self.device = device
    }

    var platform: DevicePlatform { device.platform }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    func updateDevice(_ device: DeviceIdentity) {
        self.device = device
    }

    // MARK: Connecting

    /// Starts a connection. A second call while connecting or ready is a no-op.
    func connect(keepAliveInterval: Duration = .seconds(30), using connector: @escaping Connector) {
        guard !isReady, !isConnecting else { return }
        self.connector = connector
        self.keepAliveInterval = keepAliveInterval
        startConnection(connector)
    }

    private func startConnection(_ connector: @escaping Connector) {
        generation &+= 1
        let attempt = generation
        state = .connecting
        connectionPhase = .startingAgent
        connectionStartedAt = Date()
        statusMessage = "Connecting device control"
        let previousBackend = backend
        backend = nil
        screenSize = nil
        pending.removeAll()
        connectTask = Task { [weak self] in
            if let previousBackend {
                await previousBackend.close()
            }
            let report: ProgressReporter = { [weak self] phase, message in
                await MainActor.run {
                    guard let self, self.generation == attempt else { return }
                    self.connectionPhase = phase
                    if let message { self.statusMessage = message }
                }
            }
            do {
                let backend = try await connector(report)
                guard let self, self.generation == attempt else {
                    await backend.close()
                    return
                }
                self.adopt(backend)
            } catch is CancellationError {
                guard let self, self.generation == attempt else { return }
                self.resetToUnavailable()
            } catch {
                guard let self, self.generation == attempt else { return }
                let message = ControlFailure.messageKey(for: error)
                Self.logger.error("Control connection failed for \(self.device.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.state = .failed(message)
                self.connectionPhase = nil
                self.connectionStartedAt = nil
                self.statusMessage = message
                self.onFailure?(message)
            }
            if let self, self.generation == attempt {
                self.connectTask = nil
            }
        }
    }

    private func adopt(_ backend: any ControlBackend) {
        self.backend = backend
        screenSize = backend.screenSize
        state = .ready
        connectionPhase = nil
        connectionStartedAt = nil
        statusMessage = "Control ready: \(Int(backend.screenSize.width)) x \(Int(backend.screenSize.height))"
        startKeepAlive()
    }

    // MARK: Disconnecting

    /// Ends the control session. The device-side agent is left to its owner
    /// (the iOS agent registry keeps it warm; Appium keeps UiAutomator2).
    func disconnect() {
        let closing = backend
        resetToUnavailable()
        if let closing {
            Task.detached(priority: .utility) { await closing.close() }
        }
    }

    /// Awaitable teardown for app termination.
    func shutdown() async {
        let closing = backend
        let task = connectTask
        resetToUnavailable()
        task?.cancel()
        _ = await task?.value
        if let closing {
            await closing.close()
        }
    }

    private func resetToUnavailable() {
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        pending.removeAll()
        backend = nil
        screenSize = nil
        state = .unavailable
        connectionPhase = nil
        connectionStartedAt = nil
        statusMessage = "Control not connected"
    }

    // MARK: Interactive input

    func enqueue(_ action: ControlAction) {
        guard backend != nil, isReady else { return }
        pending.append(Self.resolvingDoubleClick(action, after: lastSentTap, now: Date()))
        pump()
    }

    /// The first click of a double click is sent as a tap before the second
    /// arrives. If that tap already reached the device, a double tap on top
    /// would make three; the second click becomes one more tap instead. A tap
    /// still waiting in the queue merges with it (`ControlActionBuffer`).
    nonisolated static func resolvingDoubleClick(
        _ action: ControlAction,
        after lastTap: (point: CGPoint, at: Date)?,
        now: Date
    ) -> ControlAction {
        guard case let .doubleTap(point) = action,
              let lastTap,
              now.timeIntervalSince(lastTap.at) <= doubleClickWindow,
              hypot(lastTap.point.x - point.x, lastTap.point.y - point.y) <= doubleClickSlop else {
            return action
        }
        return .tap(point)
    }

    nonisolated static let doubleClickWindow: TimeInterval = 1.5
    /// In normalized mirror coordinates.
    nonisolated static let doubleClickSlop: CGFloat = 0.03

    private func pump() {
        guard pumpTask == nil else { return }
        let attempt = generation
        pumpTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.pumpTask = nil
                    if !self.pending.isEmpty { self.pump() }
                }
            }
            while let self, self.generation == attempt, let backend = self.backend,
                  let action = self.pending.popFirst() {
                if case let .tap(point) = action {
                    self.lastSentTap = (point, Date())
                }
                do {
                    try await Self.perform(action, on: backend)
                    guard self.generation == attempt else { return }
                    self.statusMessage = Self.statusText(for: action)
                } catch {
                    guard self.generation == attempt else { return }
                    self.handleActionError(error)
                    return
                }
            }
        }
    }

    nonisolated private static func perform(_ action: ControlAction, on backend: any ControlBackend) async throws {
        let size = backend.screenSize
        switch action {
        case let .tap(point):
            try await backend.tap(denormalize(point, size))
        case let .doubleTap(point):
            try await backend.doubleTap(denormalize(point, size))
        case let .longPress(point, durationMS):
            try await backend.longPress(denormalize(point, size), durationSeconds: Double(durationMS) / 1_000)
        case let .swipe(start, end, durationMS):
            try await backend.drag(from: denormalize(start, size), to: denormalize(end, size), durationMS: durationMS)
        case let .drag(path):
            try await backend.dragPath(devicePath(path, size))
        case let .flick(direction):
            let points = flickPoints(direction: direction, size: size)
            try await backend.drag(from: points.start, to: points.end, durationMS: 120)
        case let .pinch(center, scale, velocity):
            try await backend.pinch(at: denormalize(center, size), scale: scale, velocity: velocity)
        case let .rotate(center, degrees, velocity):
            try await backend.rotate(at: denormalize(center, size), degrees: degrees, velocity: velocity)
        case let .typeText(text):
            try await backend.typeText(text)
        case let .press(button):
            try await backend.press(button)
        }
    }

    /// The replay can only start once the mouse is up, so a slow drag would
    /// land as late again as it took to perform. Replaying faster, within a
    /// bounded window, keeps the shape and most of the release velocity.
    nonisolated static let pathReplaySpeed = 2.0
    nonisolated static let pathReplayDurationMS = 120...700

    nonisolated static func devicePath(_ path: [ControlPathSample], _ size: DeviceScreenSize) -> [DevicePathSample] {
        guard let first = path.first, let last = path.last else { return [] }
        let realDuration = max(last.timestamp - first.timestamp, 0.001)
        let replayMS = Double(min(
            max(Int(realDuration * 1_000 / pathReplaySpeed), pathReplayDurationMS.lowerBound),
            pathReplayDurationMS.upperBound
        ))
        return path.map { sample in
            let fraction = (sample.timestamp - first.timestamp) / realDuration
            return DevicePathSample(
                point: denormalize(sample.point, size),
                offsetMS: Int((fraction * replayMS).rounded())
            )
        }
    }

    private static func statusText(for action: ControlAction) -> String {
        switch action {
        case .tap, .doubleTap: "Tap sent"
        case .longPress: "Long press sent"
        case .swipe, .flick, .drag: "Swipe sent"
        case .pinch: "Pinch sent"
        case .rotate: "Rotation sent"
        case let .typeText(text): "Typed \(text.count) character\(text.count == 1 ? "" : "s")"
        case let .press(button): "Pressed \(button.rawValue)"
        }
    }

    nonisolated static func denormalize(_ point: CGPoint, _ size: DeviceScreenSize) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1) * size.width,
            y: min(max(point.y, 0), 1) * size.height
        )
    }

    /// A full-screen flick trajectory in screen points. The direction names
    /// where the finger moves.
    nonisolated static func flickPoints(
        direction: ControlFlickDirection,
        size: DeviceScreenSize
    ) -> (start: CGPoint, end: CGPoint) {
        let midX = size.width / 2
        let midY = size.height / 2
        switch direction {
        case .up:
            return (CGPoint(x: midX, y: size.height * 0.78), CGPoint(x: midX, y: size.height * 0.22))
        case .down:
            return (CGPoint(x: midX, y: size.height * 0.22), CGPoint(x: midX, y: size.height * 0.78))
        case .left:
            return (CGPoint(x: size.width * 0.82, y: midY), CGPoint(x: size.width * 0.18, y: midY))
        case .right:
            return (CGPoint(x: size.width * 0.18, y: midY), CGPoint(x: size.width * 0.82, y: midY))
        }
    }

    // MARK: Awaited actions (automation)

    /// Runs one backend call. A lost session is reported once and rebuilt in
    /// the background; the caller gets the error for this attempt.
    func perform<T: Sendable>(_ body: @escaping @Sendable (any ControlBackend) async throws -> T) async throws -> T {
        guard let backend, isReady else {
            throw ControlBackendError.sessionLost("Device control is not connected. Call connect_control first.")
        }
        let attempt = generation
        do {
            return try await body(backend)
        } catch {
            if generation == attempt {
                handleActionError(error)
            }
            throw error
        }
    }

    /// Converts normalized coordinates to the device's point space.
    func devicePoint(normalizedX x: Double, normalizedY y: Double) throws -> CGPoint {
        guard let screenSize else {
            throw ControlBackendError.sessionLost("Device control is not connected. Call connect_control first.")
        }
        return Self.denormalize(CGPoint(x: x, y: y), screenSize)
    }

    /// Confirms the session still answers; a dead one is rebuilt.
    func verifyReady() async -> Bool {
        guard let backend, isReady else { return false }
        let attempt = generation
        do {
            let size = try await backend.ping()
            if generation == attempt { screenSize = size }
            return true
        } catch {
            if generation == attempt { handleActionError(error) }
            return false
        }
    }

    /// The device-side agent went away (its tunnel ended). A ready session is
    /// rebuilt right away instead of waiting for the next gesture or ping.
    func agentDidExit() {
        guard isReady else { return }
        let error = ControlBackendError.sessionLost("The device tunnel ended.")
        rebuild(after: error, message: ControlFailure.messageKey(for: error))
    }

    /// Re-reads the device's screen size, for example after the mirror saw
    /// the phone rotate. A dead session is rebuilt.
    func refreshScreenSize() {
        guard isReady else { return }
        Task { _ = await verifyReady() }
    }

    private func handleActionError(_ error: Error) {
        let message = ControlFailure.messageKey(for: error)
        statusMessage = message
        guard Self.isSessionLoss(error) else { return }
        rebuild(after: error, message: message)
    }

    private func rebuild(after error: Error, message: String) {
        Self.logger.error("Control session lost for \(self.device.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        let connector = self.connector
        let dead = backend
        resetToUnavailable()
        if let dead {
            Task.detached(priority: .utility) { await dead.close() }
        }
        state = .failed(message)
        statusMessage = message
        if let connector {
            startConnection(connector)
        }
    }

    /// Whether an error means the agent or its session is gone. A single
    /// timeout is not: a slow `/source` or a phone that stalls for a moment
    /// would otherwise relaunch the whole agent. The keep-alive treats
    /// repeated ping timeouts as a loss instead.
    nonisolated static func isSessionLoss(_ error: Error) -> Bool {
        if let backendError = error as? ControlBackendError {
            return backendError.isSessionLoss
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        return false
    }

    nonisolated static func isTimeout(_ error: Error) -> Bool {
        (error as? URLError)?.code == .timedOut
    }

    /// Consecutive keep-alive pings that may time out before the session is
    /// rebuilt.
    nonisolated static let keepAliveTimeoutLimit = 2

    // MARK: Keep-alive

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        let attempt = generation
        let interval = keepAliveInterval
        keepAliveTask = Task { [weak self] in
            var timeouts = 0
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, self.generation == attempt, let backend = self.backend else { return }
                do {
                    let size = try await backend.ping()
                    guard self.generation == attempt else { return }
                    timeouts = 0
                    self.screenSize = size
                } catch {
                    guard self.generation == attempt else { return }
                    if Self.isTimeout(error) {
                        timeouts += 1
                        guard timeouts >= Self.keepAliveTimeoutLimit else { continue }
                        self.rebuild(after: error, message: ControlFailure.messageKey(for: error))
                        return
                    }
                    self.handleActionError(error)
                    return
                }
            }
        }
    }

    #if DEBUG
    func showConnectionPreview(phase: ControlConnectionPhase, elapsedSeconds: TimeInterval) {
        state = .connecting
        connectionPhase = phase
        connectionStartedAt = Date().addingTimeInterval(-elapsedSeconds)
        statusMessage = "Control connection preview"
    }

    /// Installs a backend directly, for tests.
    func adoptForTesting(_ backend: any ControlBackend, keepAliveInterval: Duration = .seconds(30), connector: Connector? = nil) {
        self.connector = connector
        self.keepAliveInterval = keepAliveInterval
        generation &+= 1
        adopt(backend)
    }
    #endif
}
