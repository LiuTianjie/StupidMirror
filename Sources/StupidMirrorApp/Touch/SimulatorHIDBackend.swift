// CoreSimulator XPC and display/digitizer protocols adapted from Meta idb at
// dd6633645d52f6535b458315482cc9587b181820. See Assets/licenses/idb-LICENSE.txt.
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC
import OSLog
@preconcurrency import XPC

private let simulatorHIDLogger = Logger(subsystem: "com.stupidmirror.app", category: "SimulatorHID")

/// The modern simulator digitizer service. Points are normalized in the currently
/// displayed orientation; the backend translates them to the physical panel.
///
/// All contact state and private Objective-C calls are confined to `queue`. XPC
/// replies use a different queue so bounded synchronous replies cannot deadlock
/// input delivery. No capture, media session, or XCTest runner is involved.
final class SimulatorHIDBackend: TouchInputBackend, @unchecked Sendable {
    let name = "Simulator DTUHID"
    var supportsNativeGestures: Bool {
        capabilityLock.withLock { nativeGesturesAvailable }
    }

    private static let service = "com.apple.coredevice.feature.remote.hid.digitizer"
    private static let nativeService = "com.apple.coredevice.feature.remote.universalhidservice"
    private let queue = DispatchQueue(label: "com.stupidmirror.simulator.hid", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let replies = DispatchQueue(label: "com.stupidmirror.simulator.hid.replies", qos: .userInteractive)
    private let udid: String
    private let failures = SimulatorHIDFailureState()
    private let nativeFailures = SimulatorHIDFailureState()
    private let capabilityLock = NSLock()
    private var nativeGesturesAvailable = false
    private var runtime: SimulatorHIDRuntime?
    private var connection: xpc_connection_t?
    private var nativeConnection: xpc_connection_t?
    private var targets: [String: UInt64] = [:]
    private var geometryCheckedAt: UInt64 = 0
    private var contact: (geometry: SimulatorHIDGeometry, point: CGPoint, edge: PhysicalHIDContactEdge?)?
    private var nativeCancellationReports: [HIDInputReport]?
    private var pendingSends = false
    private var pendingNativeSends = false
    private var closed = false

    private init(udid: String) {
        self.udid = udid
        queue.setSpecific(key: queueKey, value: true)
    }

    static func connect(udid: String) async throws -> SimulatorHIDBackend {
        guard let identifier = UUID(uuidString: udid) else { throw SimulatorHIDError.unavailable("Invalid simulator identifier.") }
        let backend = SimulatorHIDBackend(udid: identifier.uuidString)
        let cancellation = SimulatorHIDOperationCancellation()
        do {
            try await withTaskCancellationHandler {
                try await backend.perform {
                    try cancellation.check()
                    try backend.open(cancellation: cancellation)
                    try cancellation.check()
                }
            } onCancel: { cancellation.cancel() }
            return backend
        } catch {
            await backend.close()
            throw error
        }
    }

    func send(_ event: TouchEvent) async throws {
        let cancellation = SimulatorHIDOperationCancellation()
        try await withTaskCancellationHandler {
            try await perform {
                do {
                    try cancellation.check()
                    try self.deliver(event, cancellation: cancellation)
                    try cancellation.check()
                } catch {
                    self.finishContact()
                    try? self.drain()
                    throw error
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    func flush() async throws {
        try await perform {
            do {
                if self.pendingNativeSends || self.nativeCancellationReports != nil {
                    try self.checkNativeConnection()
                } else {
                    try self.checkConnection()
                }
                try self.drain()
            } catch {
                self.finishContact()
                try? self.drain()
                throw error
            }
        }
    }

    /// Call before an app-initiated fold/rotation. A contact belongs to the panel
    /// on which it began and must end there before a new configuration is used.
    func invalidateDisplayConfiguration() async {
        _ = try? await perform {
            self.geometryCheckedAt = 0
            self.finishContact()
            try self.drain()
        }
    }

    func close() async {
        _ = try? await perform { self.tearDown() }
    }

    deinit {
        // The last owner may be a queued send. Stay on that queue when already
        // there; otherwise synchronously release before connection cancellation.
        if DispatchQueue.getSpecific(key: queueKey) == true { tearDown() }
        else { queue.sync { tearDown() } }
    }

    private func tearDown() {
        guard !closed else { return }
        finishContact()
        do {
            try drain()
        } catch { simulatorHIDLogger.debug("Simulator HID teardown: \(error.localizedDescription, privacy: .public)") }
        // Neither transport barrier is a UIKit acknowledgement. Keep either
        // connection alive after release even if the other channel failed.
        Thread.sleep(forTimeInterval: 0.08)
        closed = true
        capabilityLock.withLock { nativeGesturesAvailable = false }
        if let connection { xpc_connection_cancel(connection) }
        if let nativeConnection { xpc_connection_cancel(nativeConnection) }
        connection = nil
        nativeConnection = nil
        runtime = nil
        geometryCheckedAt = 0
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func open(cancellation: SimulatorHIDOperationCancellation) throws {
        let runtime = try SimulatorHIDRuntime(udid: udid)
        self.runtime = runtime
        try cancellation.check()
        let connection = try runtime.connect(service: Self.service)
        self.connection = connection
        let failures = failures
        xpc_connection_set_target_queue(connection, replies)
        xpc_connection_set_event_handler(connection) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR { failures.fail() }
        }
        xpc_connection_activate(connection)
        _ = try request(barrierMessage(), on: connection, timeout: 4)
        try cancellation.check()
        // The barrier confirms peer activation; the virtual device can still be
        // opening. This tail is paid once, before exposing the input backend.
        Thread.sleep(forTimeInterval: 0.2)
        try cancellation.check()
        let report = try readDisplayReport()
        try cancellation.check()
        do {
            let services = try openNativeConnection()
            let available = try SimulatorHIDDisplayReport.hasNativeGestureService(services)
            if report.integratedCount > 1 { targets = try SimulatorHIDDisplayReport.touchscreenTargets(services) }
            capabilityLock.withLock { nativeGesturesAvailable = available }
        } catch {
            if let nativeConnection { xpc_connection_cancel(nativeConnection) }
            nativeConnection = nil
            // Older runtimes can still accept direct Indigo contacts. Multiple
            // panels additionally require the service list for target routing.
            if report.integratedCount > 1 { throw error }
            simulatorHIDLogger.debug("Simulator native gestures unavailable: \(error.localizedDescription, privacy: .public)")
        }
        try cancellation.check()
        _ = try report.resolved(using: targets)
        geometryCheckedAt = DispatchTime.now().uptimeNanoseconds
        try checkConnection()
    }

    private func deliver(_ event: TouchEvent, cancellation: SimulatorHIDOperationCancellation) throws {
        guard event.point.x.isFinite, event.point.y.isFinite,
              (0...1).contains(event.point.x), (0...1).contains(event.point.y) else {
            throw SimulatorHIDError.invalidPoint
        }
        guard event.nativeInput?.isValid != false else { throw SimulatorHIDError.invalidReport }
        if event.phase == .cancel {
            finishContact()
            return
        }
        if let input = event.nativeInput {
            try deliverNative(input, phase: event.phase, cancellation: cancellation)
            return
        }
        guard nativeCancellationReports == nil else { throw SimulatorHIDError.invalidSequence }
        try checkConnection()
        switch event.phase {
        case .down:
            guard contact == nil else {
                finishContact()
                throw SimulatorHIDError.invalidSequence
            }
            let current = try refreshGeometry()
            let point = current.panelPoint(event.point)
            let edge = PhysicalHIDContactEdge.beginning(at: point, displayPointSize: CGSize(
                width: current.bounds.width / current.scale, height: current.bounds.height / current.scale
            ))
            try cancellation.check()
            try write(type: 0, point: point, target: current.target, edge: edge)
            contact = (current, point, edge)
        case .move:
            guard let previous = contact else { throw SimulatorHIDError.invalidSequence }
            // Catch configuration changes made by another client as well as
            // explicit invalidations. Never enumerate HID services on this path.
            if DispatchTime.now().uptimeNanoseconds - geometryCheckedAt >= 250_000_000 {
                do {
                    guard try refreshGeometry() == previous.geometry else { throw SimulatorHIDError.displayChanged }
                } catch {
                    finishContact()
                    throw error
                }
            }
            let point = previous.geometry.panelPoint(event.point)
            try cancellation.check()
            try write(type: 1, point: point, target: previous.geometry.target, edge: previous.edge)
            contact = (previous.geometry, point, previous.edge)
        case .up:
            guard let previous = contact else { return }
            // Even if a panel is now off, release on the original target.
            let point = previous.geometry.panelPoint(event.point)
            try write(type: 2, point: point, target: previous.geometry.target, edge: previous.edge)
            contact = nil
        case .cancel:
            finishContact()
        }
    }

    private func deliverNative(_ input: HIDNativeInput, phase: TouchPhase, cancellation: SimulatorHIDOperationCancellation) throws {
        try checkNativeConnection()
        guard contact == nil else { throw SimulatorHIDError.invalidSequence }
        switch phase {
        case .down:
            guard nativeCancellationReports == nil else { throw SimulatorHIDError.invalidSequence }
        case .move, .up:
            guard nativeCancellationReports != nil else { throw SimulatorHIDError.invalidSequence }
        case .cancel:
            finishContact()
            return
        }
        // A batch may end one component while starting another. Until all its
        // reports are sent, either component can still need a final release.
        var releases = nativeCancellationReports ?? []
        for report in input.cancellationReports where !releases.contains(report) { releases.append(report) }
        nativeCancellationReports = releases
        for report in input.reports {
            try cancellation.check()
            try writeNative(report)
        }
        try cancellation.check()
        try checkNativeConnection()
        nativeCancellationReports = phase == .up ? nil : input.cancellationReports
    }

    private func checkConnection() throws {
        guard !closed, connection != nil, !failures.failed else { throw SimulatorHIDError.disconnected }
    }

    private func checkNativeConnection() throws {
        guard !closed, nativeConnection != nil, supportsNativeGestures, !nativeFailures.failed else {
            throw SimulatorHIDError.disconnected
        }
    }

    private func finishContact() {
        if let reports = nativeCancellationReports {
            nativeCancellationReports = nil
            let ticks = mach_absolute_time()
            for report in reports { try? writeNative(report.withTimestampTicks(ticks), bestEffort: true) }
        }
        guard let previous = contact else { return }
        // Cancelling XPC was observed to emit an ended event at (0,0), not a
        // semantic cancel. Send our own final position before normal teardown.
        try? write(type: 2, point: previous.point, target: previous.geometry.target, edge: previous.edge, bestEffort: true)
        contact = nil
    }

    private func write(type: UInt64, point: CGPoint, target: UInt64, edge: PhysicalHIDContactEdge?, bestEffort: Bool = false) throws {
        if !bestEffort { try checkConnection() }
        guard !closed, let connection else { throw SimulatorHIDError.disconnected }
        let coordinates = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_double(coordinates, "x", point.x)
        xpc_dictionary_set_double(coordinates, "y", point.y)
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(payload, "pointOne", coordinates)
        xpc_dictionary_set_uint64(payload, "eventType", type)
        let edgeValue: UInt64
        switch edge {
        case .top: edgeValue = 1
        case .left: edgeValue = 2
        case .bottom: edgeValue = 3
        case .right: edgeValue = 4
        case nil: edgeValue = 0
        }
        xpc_dictionary_set_uint64(payload, "edge", edgeValue)
        xpc_dictionary_set_uint64(payload, "target", target)
        xpc_connection_send_message(connection, message(type: "IndigoDigitizerEvent", payload: payload))
        pendingSends = true
    }

    private func writeNative(_ report: HIDInputReport, bestEffort: Bool = false) throws {
        if !bestEffort { try checkNativeConnection() }
        guard !closed, let nativeConnection else { throw SimulatorHIDError.disconnected }
        let send = xpc_dictionary_create(nil, nil, 0)
        report.data.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(send, "_0", bytes.baseAddress, bytes.count)
        }
        xpc_dictionary_set_uint64(send, "_1", report.serviceID)
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(payload, "send", send)
        xpc_connection_send_message(nativeConnection, nativeMessage(payload: payload))
        pendingNativeSends = true
    }

    private func drain() throws {
        var failure: Error?
        if pendingSends, let connection {
            let barrier = DispatchSemaphore(value: 0)
            xpc_connection_send_barrier(connection) { barrier.signal() }
            if barrier.wait(timeout: .now() + 2) == .success {
                pendingSends = false
                if failures.failed { failure = SimulatorHIDError.disconnected }
            } else { failure = SimulatorHIDError.timedOut }
        }
        if pendingNativeSends, let nativeConnection {
            do {
                // A remote request barrier follows the report batch. Its reply
                // proves the peer reached this request, not UIKit completion.
                let reply = try request(nativeMessage(payload: xpc_dictionary_create(nil, nil, 0), barrier: true), on: nativeConnection)
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY, !nativeFailures.failed else {
                    throw SimulatorHIDError.disconnected
                }
                pendingNativeSends = false
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }

    private func message(type: String, payload: xpc_object_t, barrier: Bool = false) -> xpc_object_t {
        let value = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(value, "messageType", type)
        xpc_dictionary_set_string(value, "featureIdentifier", Self.service)
        xpc_dictionary_set_bool(value, "isBarrier", barrier)
        xpc_dictionary_set_value(value, "payload", payload)
        return value
    }

    private func barrierMessage() -> xpc_object_t {
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(payload, "usageCode", 0)
        xpc_dictionary_set_uint64(payload, "state", 2)
        return message(type: "IndigoKeyboardButtonEvent", payload: payload, barrier: true)
    }

    private func nativeMessage(payload: xpc_object_t, barrier: Bool = false) -> xpc_object_t {
        let value = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(value, "messageType", "Request")
        xpc_dictionary_set_string(value, "featureIdentifier", Self.nativeService)
        xpc_dictionary_set_bool(value, "isBarrier", barrier)
        xpc_dictionary_set_value(value, "payload", payload)
        return value
    }

    private func request(_ value: xpc_object_t, on connection: xpc_connection_t, timeout: TimeInterval = 2) throws -> xpc_object_t {
        let result = SimulatorHIDReply()
        xpc_connection_send_message_with_reply(connection, value, replies) { result.complete($0) }
        guard result.ready.wait(timeout: .now() + timeout) == .success, let reply = result.value else {
            throw SimulatorHIDError.timedOut
        }
        guard xpc_get_type(reply) != XPC_TYPE_ERROR else { throw SimulatorHIDError.disconnected }
        return reply
    }

    private func oneShot(service: String, message: xpc_object_t) throws -> xpc_object_t {
        guard let runtime else { throw SimulatorHIDError.disconnected }
        let connection = try runtime.connect(service: service)
        defer { xpc_connection_cancel(connection) }
        xpc_connection_set_target_queue(connection, replies)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        return try request(message, on: connection)
    }

    private func refreshGeometry() throws -> SimulatorHIDGeometry {
        let current = try readDisplayReport().resolved(using: targets)
        geometryCheckedAt = DispatchTime.now().uptimeNanoseconds
        return current
    }

    private func readDisplayReport() throws -> SimulatorHIDDisplayReport {
        guard let version = Bundle(path: "/Library/Developer/PrivateFrameworks/CoreDevice.framework")?
            .object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw SimulatorHIDError.unavailable("CoreDevice version metadata is unavailable.")
        }
        let parts = version.split(separator: ".").compactMap { UInt64($0) }
        guard !parts.isEmpty, parts.count == version.split(separator: ".").count else { throw SimulatorHIDError.malformedDisplay }
        let components = xpc_array_create(nil, 0)
        parts.forEach { xpc_array_append_value(components, xpc_uint64_create($0)) }
        let versionObject = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(versionObject, "components", components)
        xpc_dictionary_set_int64(versionObject, "originalComponentsCount", Int64(parts.count))
        xpc_dictionary_set_string(versionObject, "stringValue", version)
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(request, "CoreDevice.actionIdentifier", "com.apple.coredevice.action.displayinfo")
        xpc_dictionary_set_string(request, "CoreDevice.deviceIdentifier", udid)
        xpc_dictionary_set_string(request, "CoreDevice.invocationIdentifier", UUID().uuidString)
        xpc_dictionary_set_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion", 1)
        xpc_dictionary_set_value(request, "CoreDevice.coreDeviceVersion", versionObject)
        xpc_dictionary_set_value(request, "CoreDevice.input", xpc_dictionary_create(nil, nil, 0))
        let reply = try oneShot(service: "com.apple.coredevice.feature.getdisplayinfo", message: request)
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_value(reply, "CoreDevice.error") == nil,
              let output = xpc_dictionary_get_value(reply, "CoreDevice.output") else { throw SimulatorHIDError.malformedDisplay }
        return try SimulatorHIDDisplayReport(output)
    }

    private func openNativeConnection() throws -> xpc_object_t {
        guard let runtime else { throw SimulatorHIDError.disconnected }
        let connection = try runtime.connect(service: Self.nativeService)
        nativeConnection = connection
        let failures = nativeFailures
        xpc_connection_set_target_queue(connection, replies)
        xpc_connection_set_event_handler(connection) { event in
            if xpc_get_type(event) == XPC_TYPE_ERROR { failures.fail() }
        }
        xpc_connection_activate(connection)
        let payload = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(payload, "connectedServices", xpc_dictionary_create(nil, nil, 0))
        return try request(nativeMessage(payload: payload), on: connection)
    }
}

struct SimulatorHIDGeometry: Equatable, Sendable {
    let id: String
    let bounds: CGRect
    let scale: Double
    let orientation: String
    let target: UInt64

    func panelPoint(_ point: CGPoint) -> CGPoint {
        switch orientation {
        case "rot90": CGPoint(x: point.y, y: 1 - point.x)
        case "rot180": CGPoint(x: 1 - point.x, y: 1 - point.y)
        case "rot270": CGPoint(x: 1 - point.y, y: point.x)
        default: point
        }
    }
}

struct SimulatorHIDDisplayReport {
    let integratedCount: Int
    let selected: SimulatorHIDGeometry

    private static func connectedServices(_ reply: xpc_object_t) throws -> xpc_object_t {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              let services = xpc_dictionary_get_value(reply, "connectedServices"),
              xpc_get_type(services) == XPC_TYPE_ARRAY, xpc_array_get_count(services) <= 256 else { throw SimulatorHIDError.malformedDisplay }
        return services
    }

    static func hasNativeGestureService(_ reply: xpc_object_t) throws -> Bool {
        let services = try connectedServices(reply)
        for index in 0..<xpc_array_get_count(services) {
            let entry = xpc_array_get_value(services, index)
            if xpc_get_type(entry) == XPC_TYPE_DICTIONARY, uint64(entry, "_ServiceID") == 0x501 { return true }
        }
        return false
    }

    static func touchscreenTargets(_ reply: xpc_object_t) throws -> [String: UInt64] {
        let services = try connectedServices(reply)
        var mapping: [String: UInt64] = [:]
        for index in 0..<xpc_array_get_count(services) {
            let entry = xpc_array_get_value(services, index)
            guard xpc_get_type(entry) == XPC_TYPE_DICTIONARY else { continue }
            guard uint64(entry, "PrimaryUsagePage") == 0x0D,
                  uint64(entry, "PrimaryUsage") == 0x04 else { continue }
            guard let serviceID = uint64(entry, "_ServiceID"),
                  serviceID & ~0xFF == 0x100, serviceID & 0xFF != 0,
                  let id = string(entry, "displayUUID"),
                  !id.isEmpty, mapping[id] == nil, !mapping.values.contains(serviceID & 0xFF) else { throw SimulatorHIDError.malformedDisplay }
            mapping[id] = serviceID & 0xFF
        }
        guard !mapping.isEmpty else { throw SimulatorHIDError.malformedDisplay }
        return mapping
    }

    init(_ output: xpc_object_t) throws {
        guard xpc_get_type(output) == XPC_TYPE_DICTIONARY,
              let current = xpc_dictionary_get_value(output, "current"),
              xpc_get_type(current) == XPC_TYPE_BOOL, xpc_bool_get_value(current),
              let displays = xpc_dictionary_get_value(output, "displays"),
              xpc_get_type(displays) == XPC_TYPE_ARRAY,
              (1...32).contains(xpc_array_get_count(displays)) else { throw SimulatorHIDError.malformedDisplay }
        var records: [(geometry: SimulatorHIDGeometry, integrated: Bool, active: Bool?, backlight: String?)] = []
        for index in 0..<xpc_array_get_count(displays) {
            let record = xpc_array_get_value(displays, index)
            guard xpc_get_type(record) == XPC_TYPE_DICTIONARY,
                  let type = xpc_dictionary_get_value(record, "type"), xpc_get_type(type) == XPC_TYPE_DICTIONARY,
                  xpc_dictionary_get_count(type) == 1 else { throw SimulatorHIDError.malformedDisplay }
            guard let array = xpc_dictionary_get_value(record, "bounds"),
                  xpc_get_type(array) == XPC_TYPE_ARRAY, xpc_array_get_count(array) == 2 else { throw SimulatorHIDError.malformedDisplay }
            let origin = xpc_array_get_value(array, 0)
            let size = xpc_array_get_value(array, 1)
            guard xpc_get_type(origin) == XPC_TYPE_ARRAY, xpc_array_get_count(origin) == 2,
                  xpc_get_type(size) == XPC_TYPE_ARRAY, xpc_array_get_count(size) == 2,
                  let x = Self.number(xpc_array_get_value(origin, 0)), let y = Self.number(xpc_array_get_value(origin, 1)),
                  let width = Self.number(xpc_array_get_value(size, 0)), let height = Self.number(xpc_array_get_value(size, 1)),
                  width >= 0, height >= 0,
                  let scale = Self.number(xpc_dictionary_get_value(record, "pointScale")), scale > 0,
                  let orientation = Self.string(record, "currentOrientation"),
                  ["rot0", "rot90", "rot180", "rot270"].contains(orientation) else { throw SimulatorHIDError.malformedDisplay }
            let backlight = try Self.optionalString(record, "backlightState")
            let activity = xpc_dictionary_get_value(record, "active")
            let active: Bool?
            if let activity {
                guard xpc_get_type(activity) == XPC_TYPE_BOOL else { throw SimulatorHIDError.malformedDisplay }
                active = xpc_bool_get_value(activity)
            } else { active = nil }
            let geometry = SimulatorHIDGeometry(id: try Self.optionalString(record, "uniqueId") ?? "", bounds: CGRect(x: x, y: y, width: width, height: height), scale: scale, orientation: orientation, target: 0)
            records.append((geometry, xpc_dictionary_get_value(type, "integrated") != nil, active, backlight))
        }
        let hasLayoutActivity = records.contains { $0.active != nil }
        let legacy = records.allSatisfy { $0.active == nil && ($0.backlight == nil || $0.backlight == "unknown") }
        var identities: Set<String> = []
        var integrated: [(geometry: SimulatorHIDGeometry, active: Bool)] = []
        for record in records {
            let active: Bool
            if legacy {
                // Older runtimes omit activity and sometimes identity. Only a
                // sole integrated screen can be addressed without guessing.
                active = true
            } else {
                guard !record.geometry.id.isEmpty, identities.insert(record.geometry.id).inserted else { throw SimulatorHIDError.malformedDisplay }
                if hasLayoutActivity {
                    guard let layoutActive = record.active else { throw SimulatorHIDError.malformedDisplay }
                    if !layoutActive, ["activeOn", "activeDimmed"].contains(record.backlight ?? "") { throw SimulatorHIDError.displayChanged }
                    active = layoutActive
                } else {
                    switch record.backlight {
                    case "activeOn", "activeDimmed": active = true
                    case "off", "inactiveOn": active = false
                    default: throw SimulatorHIDError.malformedDisplay
                    }
                }
            }
            if record.integrated { integrated.append((record.geometry, active)) }
        }
        integratedCount = integrated.count
        let candidates = integrated.filter { $0.active }
        guard !legacy || integrated.count == 1,
              candidates.count == 1, let display = candidates.first?.geometry,
              display.bounds.width > 0, display.bounds.height > 0,
              integrated.count == 1 || !display.id.isEmpty else { throw SimulatorHIDError.displayChanged }
        selected = display
    }

    func resolved(using targets: [String: UInt64]) throws -> SimulatorHIDGeometry {
        let target: UInt64
        if integratedCount == 1 { target = 0 }
        else if let known = targets[selected.id], (1...255).contains(known) { target = known }
        else { throw SimulatorHIDError.unavailable("The active simulator display has no known digitizer target. Reconnect control.") }
        return SimulatorHIDGeometry(id: selected.id, bounds: selected.bounds, scale: selected.scale, orientation: selected.orientation, target: target)
    }

    static func string(_ object: xpc_object_t, _ key: String) -> String? {
        guard let value = xpc_dictionary_get_string(object, key) else { return nil }
        let result = String(cString: value)
        return result.utf8.count <= 1024 ? result : nil
    }

    private static func optionalString(_ object: xpc_object_t, _ key: String) throws -> String? {
        guard let value = xpc_dictionary_get_value(object, key) else { return nil }
        guard xpc_get_type(value) == XPC_TYPE_STRING, let result = string(object, key) else { throw SimulatorHIDError.malformedDisplay }
        return result
    }

    private static func uint64(_ object: xpc_object_t, _ key: String) -> UInt64? {
        guard let value = xpc_dictionary_get_value(object, key), xpc_get_type(value) == XPC_TYPE_UINT64 else { return nil }
        return xpc_uint64_get_value(value)
    }

    private static func number(_ object: xpc_object_t?) -> Double? {
        guard let object else { return nil }
        let result: Double
        switch xpc_get_type(object) {
        case XPC_TYPE_DOUBLE: result = xpc_double_get_value(object)
        case XPC_TYPE_INT64: result = Double(xpc_int64_get_value(object))
        case XPC_TYPE_UINT64: result = Double(xpc_uint64_get_value(object))
        default: return nil
        }
        return result.isFinite ? result : nil
    }
}

private final class SimulatorHIDRuntime {
    // CoreSimulator's shared context retains Objective-C classes for process life.
    private static let frameworkLoaded = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator", RTLD_NOW) != nil
    private let device: NSObject

    init(udid: String) throws {
        // Keep the framework loaded: its Objective-C classes cannot safely be
        // unloaded while CoreSimulator's shared context remains in the process.
        guard Self.frameworkLoaded,
              let contextClass = NSClassFromString("SimServiceContext"),
              let version = Bundle(for: contextClass).object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              version.compare("1155.4", options: .numeric) != .orderedAscending else {
            throw SimulatorHIDError.unavailable("This CoreSimulator does not support the modern digitizer service.")
        }
        let result = try HostCommand.run("/usr/bin/xcode-select", arguments: ["-p"], timeout: 5)
        let developer = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !developer.isEmpty else { throw SimulatorHIDError.unavailable("Xcode is not selected.") }
        let selector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let method = class_getClassMethod(contextClass, selector) else { throw SimulatorHIDError.unavailable("CoreSimulator context API is unavailable.") }
        typealias Context = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
        var error: NSError?
        guard let context = unsafeBitCast(method_getImplementation(method), to: Context.self)(contextClass as AnyObject, selector, developer as NSString, &error)?.takeUnretainedValue() as? NSObject else {
            if let error { throw error }
            throw SimulatorHIDError.unavailable("CoreSimulator context could not be opened.")
        }
        let setSelector = NSSelectorFromString("defaultDeviceSetWithError:")
        guard let setMethod = class_getInstanceMethod(type(of: context), setSelector) else { throw SimulatorHIDError.unavailable("CoreSimulator device-set API is unavailable.") }
        typealias DeviceSet = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
        error = nil
        guard let set = unsafeBitCast(method_getImplementation(setMethod), to: DeviceSet.self)(context, setSelector, &error)?.takeUnretainedValue() as? NSObject,
              let devices = Self.object(set, "availableDevices") as? [NSObject],
              let device = devices.first(where: { (Self.object($0, "UDID") as? NSUUID)?.uuidString.caseInsensitiveCompare(udid) == .orderedSame }) else {
            if let error { throw error }
            throw SimulatorHIDError.unavailable("The requested simulator could not be found.")
        }
        self.device = device
    }

    func connect(service: String) throws -> xpc_connection_t {
        let selector = NSSelectorFromString("lookup:error:")
        guard let method = class_getInstanceMethod(type(of: device), selector) else { throw SimulatorHIDError.unavailable("CoreSimulator service lookup is unavailable.") }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>?) -> mach_port_t
        var error: NSError?
        let port = unsafeBitCast(method_getImplementation(method), to: Lookup.self)(device, selector, service as NSString, &error)
        guard port != MACH_PORT_NULL else {
            if let error { throw error }
            throw SimulatorHIDError.unavailable("The simulator HID service is unavailable. Keep the simulator booted.")
        }
        typealias Endpoint = @convention(c) (mach_port_t, UInt64, UInt64) -> Unmanaged<AnyObject>?
        typealias Connection = @convention(c) (xpc_object_t) -> Unmanaged<AnyObject>?
        typealias Enable = @convention(c) (xpc_connection_t) -> Void
        guard let endpointSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_endpoint_create_mach_port_4sim"),
              let connectionSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_connection_create_from_endpoint"),
              let enableSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_connection_enable_sim2host_4sim") else {
            mach_port_deallocate(mach_task_self_, port)
            throw SimulatorHIDError.unavailable("Simulator XPC transport is unavailable.")
        }
        guard let endpoint = unsafeBitCast(endpointSymbol, to: Endpoint.self)(port, 0, 0)?.takeRetainedValue() as? xpc_object_t,
              let connection = unsafeBitCast(connectionSymbol, to: Connection.self)(endpoint)?.takeRetainedValue() as? xpc_connection_t else { throw SimulatorHIDError.disconnected }
        unsafeBitCast(enableSymbol, to: Enable.self)(connection)
        return connection
    }

    private static func object(_ receiver: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard receiver.responds(to: selector) else { return nil }
        return receiver.perform(selector)?.takeUnretainedValue()
    }
}

private final class SimulatorHIDOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

private final class SimulatorHIDFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var lost = false
    var failed: Bool { lock.withLock { lost } }
    func fail() { lock.withLock { lost = true } }
}

private final class SimulatorHIDReply: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reply: xpc_object_t?
    var value: xpc_object_t? { lock.withLock { reply } }
    func complete(_ value: xpc_object_t) {
        lock.withLock { reply = value }
        ready.signal()
    }
}

private enum SimulatorHIDError: LocalizedError {
    case unavailable(String), disconnected, timedOut, invalidPoint, invalidReport, invalidSequence, malformedDisplay, displayChanged

    var errorDescription: String? {
        switch self {
        case let .unavailable(detail): detail
        case .disconnected: "The simulator touch connection ended. Reconnect control."
        case .timedOut: "The simulator touch service did not answer in time."
        case .invalidPoint: "Simulator touch coordinates must be finite normalized screen coordinates."
        case .invalidReport: "The simulator native gesture report is invalid."
        case .invalidSequence: "The simulator touch sequence has no matching contact."
        case .malformedDisplay: "The simulator did not provide usable display and touch routing information."
        case .displayChanged: "The simulator display changed during interaction. Start the gesture again after it settles."
        }
    }
}
