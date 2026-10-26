import CoreGraphics
import Darwin
import Foundation

/// Direct touch and system gestures through CoreDevice's existing USB or Wi-Fi transport.
/// Capture and semantic automation are owned by other channels. This backend
/// never starts a media stream or installs an on-device automation runner.
final class PhysicalHIDBackend: TouchInputBackend, @unchecked Sendable {
    let name = "CoreDevice HID"
    let supportsNativeGestures: Bool

    enum Failure: LocalizedError, Sendable {
        case invalidPoint
        case contactAlreadyActive
        case contactNotActive
        case geometryChanged
        case nativeGesturesUnavailable
        case invalidNativeInput

        var errorDescription: String? {
            switch self {
            case .invalidPoint:
                return "System touch requires finite coordinates between zero and one."
            case .contactAlreadyActive:
                return "A system touch is already active. Reconnect before starting another contact."
            case .contactNotActive:
                return "System touch cannot move or release a contact that has not started."
            case .geometryChanged:
                return "The device display changed during this touch. The contact was canceled; try again."
            case .nativeGesturesUnavailable:
                return "This device does not provide the system gesture service."
            case .invalidNativeInput:
                return "The system gesture input is invalid."
            }
        }
    }

    private let queue: DispatchQueue
    private let geometryQueue = DispatchQueue(label: "StupidMirror.PhysicalHID.Geometry")
    private let client: PhysicalHIDCoreDeviceClient
    private let connection: PhysicalHIDConnection
    // All mutable state below belongs to queue.
    private var geometry: PhysicalHIDDisplayGeometry
    private var contactTimer: DispatchSourceTimer?
    private var contactActive = false
    private var lastSentPoint: CGPoint?
    private var initialEdge: PhysicalHIDContactEdge?
    private var nativeActive = false
    private var nativeCancellationReports: [HIDInputReport] = []
    private var terminalError: Error?
    private var closed = false
    private var generation: UInt64 = 0
    private var pendingGeometryCheck: UUID?
    private var lastGeometryCheck: UInt64 = 0

    static func connect(udid: String) async throws -> PhysicalHIDBackend {
        try Task.checkCancellation()
        let queue = DispatchQueue(label: "StupidMirror.PhysicalHID.Input", qos: .userInitiated)
        let backend: PhysicalHIDBackend = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                var client: PhysicalHIDCoreDeviceClient?
                do {
                    let newClient = try PhysicalHIDCoreDeviceClient(udid: udid)
                    client = newClient
                    let geometry = try newClient.getDisplayGeometry()
                    let supportsNativeGestures = (try? nativeGestureServiceIsAvailable(client: newClient)) ?? false
                    let descriptor = try newClient.serviceSocket("com.apple.coredevice.hid.universalhidservice")
                    let connection = try PhysicalHIDConnection(adopting: descriptor)
                    continuation.resume(returning: PhysicalHIDBackend(
                        queue: queue, client: newClient, connection: connection, geometry: geometry,
                        supportsNativeGestures: supportsNativeGestures
                    ))
                } catch {
                    client?.close()
                    continuation.resume(throwing: error)
                }
            }
        }
        if Task.isCancelled {
            await backend.close()
            throw CancellationError()
        }
        return backend
    }

    private init(
        queue: DispatchQueue,
        client: PhysicalHIDCoreDeviceClient,
        connection: PhysicalHIDConnection,
        geometry: PhysicalHIDDisplayGeometry,
        supportsNativeGestures: Bool
    ) {
        self.queue = queue
        self.client = client
        self.connection = connection
        self.geometry = geometry
        self.supportsNativeGestures = supportsNativeGestures
    }

    private static func nativeGestureServiceIsAvailable(client: PhysicalHIDCoreDeviceClient) throws -> Bool {
        let descriptor = try client.serviceSocket("com.apple.coredevice.hid.universalhidservice")
        let query = try PhysicalHIDConnection(adopting: descriptor, receivesResponses: true)
        defer { query.close() }
        let response = try query.request([
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.universalhidservice"),
            "messageType": .string("Request"),
            "isBarrier": .bool(false),
            "payload": .dictionary(["connectedServices": .dictionary([:])]),
        ], timeout: 2)
        let payload: [String: PhysicalHIDValue]
        if case .dictionary(let wrapped)? = response["payload"] { payload = wrapped }
        else { payload = response }
        guard case .array(let services)? = payload["connectedServices"], services.count <= 256 else {
            throw PhysicalHIDTransportError.invalidProtocol("missing connected HID services")
        }
        return services.contains { service in
            guard case .dictionary(let properties) = service,
                  case .uint64(let identifier)? = properties["_ServiceID"] else { return false }
            return identifier == 0x501
        }
    }

    deinit {
        contactTimer?.cancel()
        // Avoid blocking whichever executor drops the session's last reference.
        // The queue retains only these resources, not the backend being destroyed.
        let pointToRelease = contactActive ? lastSentPoint : nil
        let edgeToRelease = initialEdge
        let reportsToRelease = nativeActive ? nativeCancellationReports : []
        let connection = connection
        let client = client
        queue.async {
            let cleanupTime = mach_absolute_time()
            for report in reportsToRelease {
                let release = report.withTimestampTicks(cleanupTime)
                try? connection.send(report: release.data, serviceID: release.serviceID)
            }
            if let pointToRelease {
                try? connection.send(report: PhysicalHIDWire.touchReport(
                    point: pointToRelease, contact: false, initialEdge: edgeToRelease
                ))
            }
            try? connection.flush(timeout: 0.75)
            connection.close()
            client.close()
        }
    }

    func send(_ event: TouchEvent) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try checkUsable()
                    try handle(event)
                    continuation.resume()
                } catch {
                    fail(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try checkUsable()
                    try connection.flush()
                    continuation.resume()
                } catch {
                    fail(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard !closed else {
                    continuation.resume()
                    return
                }
                closed = true
                stopContactTimer()
                releaseNativeBestEffort()
                if contactActive, let point = lastSentPoint {
                    try? sendReport(point: point, contact: false)
                }
                contactActive = false
                initialEdge = nil
                try? connection.flush(timeout: 0.75)
                connection.close()
                client.close()
                continuation.resume()
            }
        }
    }

    private func handle(_ event: TouchEvent) throws {
        if event.phase == .cancel, nativeActive {
            try releaseNative()
            return
        }
        if let input = event.nativeInput {
            try handleNative(input, phase: event.phase)
            return
        }
        guard !nativeActive else { throw Failure.contactAlreadyActive }
        if event.phase != .cancel, !event.isValid { throw Failure.invalidPoint }
        switch event.phase {
        case .down:
            guard !contactActive else { throw Failure.contactAlreadyActive }
            // Frame aspect ratio cannot distinguish landscape-left from right.
            // Obtain current display identity and orientation before every contact.
            geometry = try client.getDisplayGeometry()
            generation &+= 1
            lastGeometryCheck = DispatchTime.now().uptimeNanoseconds
            pendingGeometryCheck = nil
            let point = try geometry.transform(event.point)
            initialEdge = PhysicalHIDContactEdge.beginning(at: point, displayPointSize: CGSize(
                width: geometry.bounds.width / geometry.pointScale,
                height: geometry.bounds.height / geometry.pointScale
            ))
            // Retain the attempted position even if delivery becomes uncertain,
            // so cleanup only releases and never replays the original gesture.
            contactActive = true
            lastSentPoint = point
            try sendReport(point: point, contact: true)
            startContactTimer()
        case .move:
            guard contactActive else { throw Failure.contactNotActive }
            let point = try geometry.transform(event.point)
            lastSentPoint = point
            try sendReport(point: point, contact: true)
        case .up:
            guard contactActive else { throw Failure.contactNotActive }
            let point = try geometry.transform(event.point)
            lastSentPoint = point
            stopContactTimer()
            try sendReport(point: point, contact: false)
            contactActive = false
            initialEdge = nil
        case .cancel:
            stopContactTimer()
            if contactActive, let point = lastSentPoint {
                try sendReport(point: point, contact: false)
            }
            contactActive = false
            initialEdge = nil
        }
    }

    private func handleNative(_ input: HIDNativeInput, phase: TouchPhase) throws {
        guard supportsNativeGestures else { throw Failure.nativeGesturesUnavailable }
        guard input.isValid else { throw Failure.invalidNativeInput }
        guard !contactActive else { throw Failure.contactAlreadyActive }
        switch phase {
        case .down:
            guard !nativeActive else { throw Failure.contactAlreadyActive }
            nativeActive = true
            nativeCancellationReports = input.cancellationReports
            try sendNative(input.reports)
        case .move:
            guard nativeActive else { throw Failure.contactNotActive }
            stageNativeCancellation(input.cancellationReports)
            try sendNative(input.reports)
            nativeCancellationReports = input.cancellationReports
        case .up:
            guard nativeActive else { throw Failure.contactNotActive }
            // Keep a release available if only part of the terminal batch sends.
            stageNativeCancellation(input.cancellationReports)
            try sendNative(input.reports)
            nativeActive = false
            nativeCancellationReports.removeAll(keepingCapacity: true)
        case .cancel:
            try releaseNative()
        }
    }

    private func sendNative(_ reports: [HIDInputReport]) throws {
        for report in reports {
            try connection.send(report: report.data, serviceID: report.serviceID)
        }
    }

    private func stageNativeCancellation(_ reports: [HIDInputReport]) {
        // A batch can end one gesture component while updating another. Until
        // every report sends, either the previous or the new state may be active.
        let previous = nativeCancellationReports
        nativeCancellationReports = previous + reports.filter { !previous.contains($0) }
    }

    private func releaseNative() throws {
        guard nativeActive else { return }
        let cleanupTime = mach_absolute_time()
        var firstError: Error?
        for report in nativeCancellationReports {
            let release = report.withTimestampTicks(cleanupTime)
            do { try connection.send(report: release.data, serviceID: release.serviceID) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
        nativeActive = false
        nativeCancellationReports.removeAll(keepingCapacity: true)
    }

    private func releaseNativeBestEffort() {
        guard nativeActive else { return }
        let cleanupTime = mach_absolute_time()
        for report in nativeCancellationReports {
            let release = report.withTimestampTicks(cleanupTime)
            try? connection.send(report: release.data, serviceID: release.serviceID)
        }
        nativeActive = false
        nativeCancellationReports.removeAll(keepingCapacity: true)
    }

    private func sendReport(point: CGPoint, contact: Bool) throws {
        try connection.send(report: PhysicalHIDWire.touchReport(
            point: point, contact: contact, initialEdge: initialEdge
        ))
    }

    private func startContactTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            guard let self, self.contactActive else { return }
            do {
                try self.checkUsable()
                // A stationary finger stays down until its release. Validate the
                // display separately without synthesizing extra motion reports.
                self.refreshGeometryIfNeeded()
            } catch {
                self.fail(error)
            }
        }
        contactTimer = timer
        timer.resume()
    }

    private func stopContactTimer() {
        contactTimer?.cancel()
        contactTimer = nil
        generation &+= 1
        pendingGeometryCheck = nil
    }

    private func refreshGeometryIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard pendingGeometryCheck == nil, now - lastGeometryCheck >= 250_000_000 else { return }
        lastGeometryCheck = now
        let token = UUID()
        let contactGeneration = generation
        pendingGeometryCheck = token
        let client = client
        geometryQueue.async { [weak self] in
            let result = Result { try client.getDisplayGeometry() }
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.pendingGeometryCheck == token else { return }
                self.pendingGeometryCheck = nil
                guard self.contactActive, self.generation == contactGeneration, !self.closed,
                      self.terminalError == nil else { return }
                do {
                    guard try result.get() == self.geometry else { throw Failure.geometryChanged }
                } catch {
                    // Release at the last native point, then terminate the channel.
                    // A later backend may start a new gesture, never replay this one.
                    self.fail(error)
                }
            }
        }
    }

    private func checkUsable() throws {
        if let terminalError { throw terminalError }
        if closed { throw PhysicalHIDTransportError.closed }
    }

    private func fail(_ error: Error) {
        guard terminalError == nil, !closed else { return }
        terminalError = error
        stopContactTimer()
        let hadNativeInput = nativeActive
        releaseNativeBestEffort()
        if contactActive, let point = lastSentPoint {
            try? sendReport(point: point, contact: false)
        }
        if hadNativeInput || contactActive { try? connection.flush(timeout: 0.75) }
        contactActive = false
        initialEdge = nil
        connection.close()
        client.close()
    }
}
