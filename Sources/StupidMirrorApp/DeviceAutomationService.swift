import Foundation

enum DeviceAutomationError: LocalizedError, Sendable {
    case deviceNotFound(String)
    case multipleDevices([String])
    case deviceUnavailable
    case permissionRequired
    case appiumUnavailable
    case controlNotReady
    case controlFailed(String)
    case activationRequired
    case mirrorFailed(String)
    case invalidArgument(String)
    case timedOut(String)

    var code: String {
        switch self {
        case .deviceNotFound: "device_not_found"
        case .multipleDevices: "multiple_devices"
        case .deviceUnavailable: "device_unavailable"
        case .permissionRequired: "permission_required"
        case .appiumUnavailable: "appium_unavailable"
        case .controlNotReady: "control_not_ready"
        case .controlFailed: "control_failed"
        case .activationRequired: "activation_required"
        case .mirrorFailed: "mirror_failed"
        case .invalidArgument: "invalid_argument"
        case .timedOut: "timed_out"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .deviceNotFound(id):
            "No connected iPhone matches '\(id)'. Call list_devices first."
        case let .multipleDevices(ids):
            "Multiple iPhones are connected. Pass device_id. Available: \(ids.joined(separator: ", "))."
        case .deviceUnavailable:
            "The selected iPhone is unavailable or reconnecting."
        case .permissionRequired:
            "Camera permission is required for USB mirroring. Enable wireless mode to discover Xcode-paired devices without it."
        case .appiumUnavailable:
            "The local Appium service could not start."
        case .controlNotReady:
            "iPhone control is not ready. Call connect_control first."
        case let .controlFailed(message), let .mirrorFailed(message), let .timedOut(message):
            message
        case .activationRequired:
            "Activation is required for iPhone control or for using more than one device at the same time."
        case let .invalidArgument(message):
            message
        }
    }
}

struct AutomationDeviceSnapshot: Codable, Equatable, Sendable {
    let deviceID: String
    let udid: String?
    let name: String
    let productType: String
    let osVersion: String?
    let connectionState: String
    let mirrorState: String
    let controlState: String
    let controlMessage: String
    let screenWidth: Double?
    let screenHeight: Double?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case udid, name
        case productType = "product_type"
        case osVersion = "os_version"
        case connectionState = "connection_state"
        case mirrorState = "mirror_state"
        case controlState = "control_state"
        case controlMessage = "control_message"
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
    }
}

struct AutomationDiagnosticSnapshot: Codable, Equatable, Sendable {
    let items: [String: String]
    let devices: [AutomationDeviceSnapshot]
}

enum AutomationScrollDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

actor DeviceCommandLock {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var lockedIDs: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    func acquire(_ id: String) async throws {
        try Task.checkCancellation()
        if lockedIDs.insert(id).inserted { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: []].append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, deviceID: id) }
        }
    }

    func release(_ id: String) {
        if var queued = waiters[id], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[id] = queued.isEmpty ? nil : queued
            next.continuation.resume()
        } else {
            lockedIDs.remove(id)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, deviceID: String) {
        guard var queued = waiters[deviceID],
              let index = queued.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = queued.remove(at: index)
        waiters[deviceID] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class DeviceAutomationService: @unchecked Sendable {
    private unowned let store: DeviceGalleryStore
    private let commandLock = DeviceCommandLock()

    init(store: DeviceGalleryStore) {
        self.store = store
    }

    func listDevices() -> [AutomationDeviceSnapshot] {
        store.sessions.map(snapshot(for:))
    }

    func refreshDevices() async throws -> [AutomationDeviceSnapshot] {
        try await store.refreshForAutomation()
        return listDevices()
    }

    func deviceStatus(deviceID: String?) throws -> AutomationDeviceSnapshot {
        snapshot(for: try selectSession(deviceID: deviceID))
    }

    func diagnostics() -> AutomationDiagnosticSnapshot {
        AutomationDiagnosticSnapshot(
            items: Dictionary(uniqueKeysWithValues: store.diagnostics.map { ($0.name, $0.value) }),
            devices: listDevices()
        )
    }

    func startMirror(deviceID: String?) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await self.store.startMirrorForAutomation(for: session)
        }
        return snapshot(for: session)
    }

    func stopMirror(deviceID: String?) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        await withDeviceLockIgnoringResult(session.id) {
            self.store.stop(session)
        }
        return snapshot(for: session)
    }

    func setMirrorFloating(deviceID: String?, floating: Bool) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        await withDeviceLockIgnoringResult(session.id) {
            self.store.setFloatingForAutomation(floating, session: session)
        }
        return snapshot(for: session)
    }

    func connectControl(deviceID: String?) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await self.store.connectControlForAutomation(for: session)
        }
        return snapshot(for: session)
    }

    func disconnectControl(deviceID: String?) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            await session.controlSession.shutdown(serverURL: self.store.appiumServerURL)
        }
        return snapshot(for: session)
    }

    func screenshot(deviceID: String?) async throws -> Data {
        let session = try readyControlSession(deviceID: deviceID)
        return try await withDeviceLock(session.id) {
            try await session.controlSession.screenshot(serverURL: self.store.appiumServerURL)
        }
    }

    func uiTree(deviceID: String?) async throws -> String {
        let session = try readyControlSession(deviceID: deviceID)
        return try await withDeviceLock(session.id) {
            try await session.controlSession.pageSource(serverURL: self.store.appiumServerURL)
        }
    }

    func tap(deviceID: String?, x: Double, y: Double) async throws {
        try Self.validatePoint(x: x, y: y)
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.tapNormalizedAwaiting(
                x: x, y: y, serverURL: self.store.appiumServerURL
            )
        }
    }

    func doubleTap(deviceID: String?, x: Double, y: Double) async throws {
        try Self.validatePoint(x: x, y: y)
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.doubleTapNormalizedAwaiting(
                x: x, y: y, serverURL: self.store.appiumServerURL
            )
        }
    }

    func longPress(deviceID: String?, x: Double, y: Double, durationSeconds: Double) async throws {
        try Self.validatePoint(x: x, y: y)
        guard (0.5...10).contains(durationSeconds) else {
            throw DeviceAutomationError.invalidArgument("duration_seconds must be between 0.5 and 10.")
        }
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.longPressNormalizedAwaiting(
                x: x,
                y: y,
                durationSeconds: durationSeconds,
                serverURL: self.store.appiumServerURL
            )
        }
    }

    func swipe(
        deviceID: String?,
        startX: Double,
        startY: Double,
        endX: Double,
        endY: Double,
        durationMS: Int
    ) async throws {
        try Self.validatePoint(x: startX, y: startY)
        try Self.validatePoint(x: endX, y: endY)
        guard (50...5_000).contains(durationMS) else {
            throw DeviceAutomationError.invalidArgument("duration_ms must be between 50 and 5000.")
        }
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.swipeNormalizedAwaiting(
                from: CGPoint(x: startX, y: startY),
                to: CGPoint(x: endX, y: endY),
                durationMS: durationMS,
                serverURL: self.store.appiumServerURL
            )
        }
    }

    func flick(deviceID: String?, direction: ControlFlickDirection) async throws {
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.flickAwaiting(
                direction: direction,
                serverURL: self.store.appiumServerURL
            )
        }
    }

    func scroll(
        deviceID: String?,
        direction: AutomationScrollDirection,
        distance: Double,
        centerX: Double,
        centerY: Double
    ) async throws {
        try Self.validatePoint(x: centerX, y: centerY)
        guard (0.05...0.9).contains(distance) else {
            throw DeviceAutomationError.invalidArgument("distance must be between 0.05 and 0.9.")
        }
        let margin = 0.03
        let start = CGPoint(x: centerX, y: centerY)
        let end: CGPoint
        switch direction {
        case .down:
            end = CGPoint(x: centerX, y: max(margin, centerY - distance))
        case .up:
            end = CGPoint(x: centerX, y: min(1 - margin, centerY + distance))
        case .right:
            end = CGPoint(x: max(margin, centerX - distance), y: centerY)
        case .left:
            end = CGPoint(x: min(1 - margin, centerX + distance), y: centerY)
        }
        try await swipe(
            deviceID: deviceID,
            startX: start.x,
            startY: start.y,
            endX: end.x,
            endY: end.y,
            durationMS: 300
        )
    }

    func typeText(deviceID: String?, text: String) async throws {
        guard !text.isEmpty else {
            throw DeviceAutomationError.invalidArgument("text must not be empty.")
        }
        guard text.utf8.count <= 10_000 else {
            throw DeviceAutomationError.invalidArgument("text is limited to 10,000 UTF-8 bytes.")
        }
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.typeTextAwaiting(text, serverURL: self.store.appiumServerURL)
        }
    }

    func pressButton(deviceID: String?, name: String) async throws {
        let appiumName: String
        switch name {
        case "home": appiumName = "home"
        case "volume_up": appiumName = "volumeUp"
        case "volume_down": appiumName = "volumeDown"
        default:
            throw DeviceAutomationError.invalidArgument(
                "button must be home, volume_up, or volume_down."
            )
        }
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.pressButtonAwaiting(
                appiumName, serverURL: self.store.appiumServerURL
            )
        }
    }

    func back(deviceID: String?) async throws {
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.pressBackAwaiting(serverURL: self.store.appiumServerURL)
        }
    }

    func appSwitcher(deviceID: String?) async throws {
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.openAppSwitcherAwaiting(serverURL: self.store.appiumServerURL)
        }
    }

    func activateApp(deviceID: String?, bundleID: String) async throws {
        try Self.validateBundleID(bundleID)
        let session = try readyControlSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await session.controlSession.activateApp(
                bundleID: bundleID, serverURL: self.store.appiumServerURL
            )
        }
    }

    func terminateApp(deviceID: String?, bundleID: String) async throws -> Bool {
        try Self.validateBundleID(bundleID)
        let session = try readyControlSession(deviceID: deviceID)
        return try await withDeviceLock(session.id) {
            try await session.controlSession.terminateApp(
                bundleID: bundleID, serverURL: self.store.appiumServerURL
            )
        }
    }

    nonisolated static func validatePoint(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw DeviceAutomationError.invalidArgument("Coordinates must be finite values from 0 to 1.")
        }
    }

    nonisolated static func validateBundleID(_ bundleID: String) throws {
        let value = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard value.count >= 3,
              value.count <= 255,
              value.contains("."),
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DeviceAutomationError.invalidArgument("bundle_id is invalid.")
        }
    }

    private func selectSession(deviceID: String?) throws -> DeviceSession {
        let connected = store.sessions.filter { $0.device.connectionState == .connected }
        if let requested = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard let session = connected.first(where: {
                $0.id == requested || $0.device.udid == requested
            }) else {
                throw DeviceAutomationError.deviceNotFound(requested)
            }
            return session
        }
        guard connected.count == 1 else {
            if connected.isEmpty { throw DeviceAutomationError.deviceNotFound("connected") }
            throw DeviceAutomationError.multipleDevices(connected.map(\.id))
        }
        return connected[0]
    }

    private func readyControlSession(deviceID: String?) throws -> DeviceSession {
        guard store.canUseControl else {
            throw DeviceAutomationError.activationRequired
        }
        let session = try selectSession(deviceID: deviceID)
        guard session.controlSession.isReady else { throw DeviceAutomationError.controlNotReady }
        return session
    }

    private func snapshot(for session: DeviceSession) -> AutomationDeviceSnapshot {
        let mirrorState: String
        switch session.mirrorSession.state {
        case .stopped: mirrorState = "stopped"
        case .starting: mirrorState = "starting"
        case .running: mirrorState = "running"
        case .failed: mirrorState = "failed"
        }
        let controlState: String
        switch session.controlSession.state {
        case .unavailable: controlState = "disconnected"
        case .connecting: controlState = "connecting"
        case .ready: controlState = "ready"
        case .failed: controlState = "failed"
        }
        return AutomationDeviceSnapshot(
            deviceID: session.id,
            udid: session.device.udid,
            name: session.device.name,
            productType: session.device.productType,
            osVersion: session.device.osVersion,
            connectionState: session.device.connectionState.rawValue,
            mirrorState: mirrorState,
            controlState: controlState,
            controlMessage: session.controlSession.statusMessage,
            screenWidth: session.controlSession.screenSize?.width,
            screenHeight: session.controlSession.screenSize?.height
        )
    }

    private func withDeviceLock<T: Sendable>(
        _ id: String,
        operation: () async throws -> T
    ) async throws -> T {
        try await commandLock.acquire(id)
        if Task.isCancelled {
            await commandLock.release(id)
            throw CancellationError()
        }
        let result: Result<T, Error>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        await commandLock.release(id)
        return try result.get()
    }

    private func withDeviceLockIgnoringResult(
        _ id: String,
        operation: () -> Void
    ) async {
        guard (try? await commandLock.acquire(id)) != nil else { return }
        guard !Task.isCancelled else {
            await commandLock.release(id)
            return
        }
        operation()
        await commandLock.release(id)
    }
}
