// Adapted from iphone-use, Copyright (c) 2026 Sunghyun Kim (MIT).
// https://github.com/sunghyun-k/iphone-use/tree/6bf94902f1c30aac712ae594a9a3a08136157a48
// License: Assets/licenses/iphone-use-LICENSE.txt

import Darwin
import Foundation
@preconcurrency import XPC

/// Borrows device service sockets from CoreDevice's existing USB or Wi-Fi connection.
/// Call from a background serial queue: initialization and service requests are blocking.
/// The usage assertion keeps connectivity available without starting a media session.
final class PhysicalHIDCoreDeviceClient: @unchecked Sendable {
    private static let frameworkPath =
        "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/CoreDevice"
    private static let serviceName = "com.apple.CoreDevice.CoreDeviceService"
    private static let checkInTimeout: TimeInterval = 10
    private static let actionTimeout: TimeInterval = 20

    // Framework registration must outlive the XPC sockets. Load it once and keep it loaded.
    private static let frameworkAvailability: Result<Void, Failure> = {
        guard dlopen(frameworkPath, RTLD_NOW) != nil else {
            return .failure(.frameworkMissing(dlerror().map { String(cString: $0) } ?? "Unknown loader error"))
        }
        return .success(())
    }()

    enum Failure: LocalizedError, Sendable {
        case frameworkMissing(String)
        case serviceUnavailable
        case deviceNotFound(String)
        case actionFailed(action: String, message: String)
        case timedOut(String)
        case noSocket(String)
        case assertionEnded
        case invalidTimeout
        case unsupportedOS(String)

        var errorDescription: String? {
            switch self {
            case .frameworkMissing(let reason):
                return "CoreDevice is unavailable: \(reason). Install and finish setting up Xcode."
            case .serviceUnavailable:
                return "The CoreDevice connection was interrupted. Reconnect device control."
            case .deviceNotFound(let udid):
                return "CoreDevice cannot find device \(udid). Check its USB or Wi-Fi connection and trust pairing."
            case .actionFailed(let action, let message):
                return "CoreDevice \(action) failed: \(message)"
            case .timedOut(let operation):
                return "CoreDevice did not respond in time (\(operation))."
            case .noSocket(let service):
                return "CoreDevice returned no socket for \(service)."
            case .assertionEnded:
                return "The CoreDevice connectivity assertion ended before it was ready."
            case .invalidTimeout:
                return "The CoreDevice request timeout must be a finite positive duration."
            case .unsupportedOS(let detail):
                return "Direct device input requires a confirmed iOS 27 or later version (\(detail))."
            }
        }
    }

    private let callbackQueue = DispatchQueue(label: "StupidMirror.PhysicalHID.CoreDeviceCallbacks")
    private let connections = PhysicalHIDCoreDeviceConnections()
    private let connection: xpc_connection_t
    private let deviceIdentifier: String
    private let versionString: String
    let osVersion: OperatingSystemVersion
    private let metadataLock = NSLock()
    private var metadataConnection: PhysicalHIDConnection?

    private struct CheckedInDevice: Sendable {
        let identifier: String
        let osVersion: OperatingSystemVersion
    }

    init(udid: String) throws {
        try Self.frameworkAvailability.get()
        versionString = try Self.readFrameworkVersion()
        connection = xpc_connection_create(Self.serviceName, callbackQueue)
        connections.add(connection)
        do {
            let device = try Self.checkIn(
                connection, udid: udid, queue: callbackQueue, connections: connections
            )
            deviceIdentifier = device.identifier
            osVersion = device.osVersion
            try validateMediaFreeHIDSupport()
            try acquireUsageAssertion()
        } catch {
            // Throwing initializers need explicit cleanup before every stored property is initialized.
            connections.close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        connections.close()
        metadataLock.lock()
        let metadata = metadataConnection
        metadataConnection = nil
        metadataLock.unlock()
        metadata?.close()
    }

    /// Older systems may accept the HID protocol but discard touches without a media session.
    /// Never start media to compensate; let the caller choose its existing fallback instead.
    private func validateMediaFreeHIDSupport() throws {
        guard osVersion.majorVersion >= 27 else {
            throw Failure.unsupportedOS(
                "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
            )
        }
    }

    /// Returns a connected descriptor owned by the caller, which must close it.
    /// RemoteXPC services still require their protocol handshake on this socket.
    func serviceSocket(_ service: String, timeout: TimeInterval = 20) throws -> Int32 {
        guard !connections.isClosed else { throw Failure.serviceUnavailable }
        let input = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(input, "serviceName", service)
        let output = try invoke("com.apple.coredevice.action.createservicesocket", input: input, timeout: timeout)
        guard let descriptor = xpc_dictionary_get_value(output, "fileDescriptor"),
              xpc_get_type(descriptor) == XPC_TYPE_FD else {
            throw Failure.noSocket(service)
        }
        let fd = xpc_fd_dup(descriptor)
        guard fd >= 0 else { throw Failure.noSocket(service) }
        guard !connections.isClosed else {
            Darwin.close(fd)
            throw Failure.serviceUnavailable
        }
        return fd
    }

    /// Reads the active display without opening a media stream. Call before beginning a contact;
    /// a caller may read again on another background queue and cancel if the geometry changes.
    func getDisplayGeometry(timeout: TimeInterval = 1.5) throws -> PhysicalHIDDisplayGeometry {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw Failure.invalidTimeout }
        let started = DispatchTime.now().uptimeNanoseconds
        func remainingBudget() throws -> TimeInterval {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            let remaining = timeout - elapsed
            guard remaining > 0 else { throw Failure.timedOut("display information") }
            return remaining
        }
        // Device display information is a remote feature, not a CoreDevice host
        // action. Its service closes the socket after a response, so reuse the
        // host connection/assertion but give each serialized query its own socket.
        metadataLock.lock()
        defer { metadataLock.unlock() }
        guard !connections.isClosed else { throw Failure.serviceUnavailable }
        do {
            let descriptor = try serviceSocket("com.apple.coredevice.deviceinfo", timeout: remainingBudget())
            let handshakeBudget: TimeInterval
            do {
                handshakeBudget = try remainingBudget()
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            metadataConnection = try PhysicalHIDConnection(
                adopting: descriptor, receivesResponses: true, timeout: handshakeBudget
            )
            defer {
                metadataConnection?.close()
                metadataConnection = nil
            }
            guard let metadataConnection else { throw Failure.serviceUnavailable }
            let versionComponents = versionString.split(separator: ".").compactMap { UInt64($0) }
            let response = try metadataConnection.request([
                "CoreDevice.CoreDeviceDDIProtocolVersion": .int64(2),
                "CoreDevice.coreDeviceVersion": .dictionary([
                    "components": .array(versionComponents.map { .uint64($0) }),
                    "originalComponentsCount": .int64(Int64(versionComponents.count)),
                    "stringValue": .string(versionString),
                ]),
                "CoreDevice.deviceIdentifier": .string(deviceIdentifier),
                "CoreDevice.featureIdentifier": .string("com.apple.coredevice.feature.getdisplayinfo"),
                "CoreDevice.action": .dictionary([:]),
                "CoreDevice.input": .dictionary([:]),
                "CoreDevice.invocationIdentifier": .string(UUID().uuidString),
            ], timeout: remainingBudget())
            let object = PhysicalHIDValue.dictionary(response).xpcObject()
            if let failure = Self.responseFailure(object, action: "display information") { throw failure }
            guard let output = xpc_dictionary_get_value(object, "CoreDevice.output") else {
                throw Failure.actionFailed(action: "display information", message: "The response has no output.")
            }
            return try PhysicalHIDDisplayGeometry.read(output)
        } catch {
            metadataConnection?.close()
            metadataConnection = nil
            throw error
        }
    }

    private static func checkIn(
        _ connection: xpc_connection_t,
        udid: String,
        queue: DispatchQueue,
        connections: PhysicalHIDCoreDeviceConnections
    ) throws -> CheckedInDevice {
        let reply = PhysicalHIDCoreDeviceReply<CheckedInDevice>()
        xpc_connection_set_event_handler(connection) { event in
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
                reply.resolve(.failure(Failure.serviceUnavailable))
                connections.close()
                return
            }
            var message = event
            if let value = xpc_dictionary_get_value(event, "value"),
               let request = xpc_dictionary_get_value(value, "request") {
                message = request
            }
            guard let type = xpc_dictionary_get_string(message, "mangledTypeName"),
                  String(cString: type) == "CoreDevice.DeviceManagerCheckInCompleteEvent",
                  let value = xpc_dictionary_get_value(message, "value"),
                  let snapshots = xpc_dictionary_get_value(value, "initialDeviceSnapshots"),
                  xpc_get_type(snapshots) == XPC_TYPE_ARRAY else { return }

            var identifier: String?
            var selectedSnapshot: xpc_object_t?
            xpc_array_apply(snapshots) { _, snapshot in
                guard contains(udid: udid, in: snapshot),
                      let info = xpc_dictionary_get_value(snapshot, "deviceInfo"),
                      let value = xpc_dictionary_get_value(info, "identifier"),
                      xpc_get_type(value) == XPC_TYPE_UUID,
                      let bytes = xpc_uuid_get_bytes(value) else { return true }
                identifier = NSUUID(uuidBytes: bytes).uuidString
                selectedSnapshot = snapshot
                return false
            }
            if let identifier, let selectedSnapshot {
                do {
                    reply.resolve(.success(CheckedInDevice(
                        identifier: identifier,
                        osVersion: try operatingSystemVersion(in: selectedSnapshot)
                    )))
                } catch {
                    reply.resolve(.failure(error))
                }
            } else {
                reply.resolve(.failure(Failure.deviceNotFound(udid)))
            }
        }
        xpc_connection_activate(connection)

        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(request, "mangledTypeName", "CoreDevice.DeviceManagerCheckInRequest")
        let body = xpc_dictionary_create(nil, nil, 0)
        var requestID = UUID().uuid
        withUnsafeBytes(of: &requestID) { bytes in
            xpc_dictionary_set_uuid(body, "identifier", bytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        xpc_dictionary_set_value(request, "value", body)
        xpc_connection_send_message_with_reply(connection, request, queue) { response in
            if let failure = responseFailure(response, action: "check-in") {
                reply.resolve(.failure(failure))
            }
            // Only the check-in event contains the device snapshots.
        }
        let device = try reply.wait(timeout: checkInTimeout, operation: "check-in")
        guard !connections.isClosed else { throw Failure.serviceUnavailable }
        return device
    }

    /// A device snapshot contains descriptor/value pairs nested in dictionaries and arrays.
    private static func contains(udid: String, in object: xpc_object_t, depth: Int = 0) -> Bool {
        guard depth < 64 else { return false }
        switch xpc_get_type(object) {
        case XPC_TYPE_DICTIONARY:
            if let descriptor = xpc_dictionary_get_value(object, "descriptorIdentifier"),
               let key = xpc_dictionary_get_string(descriptor, "key"),
               String(cString: key) == "udid",
               let value = xpc_dictionary_get_string(object, "value"),
               String(cString: value).caseInsensitiveCompare(udid) == .orderedSame {
                return true
            }
            var found = false
            xpc_dictionary_apply(object) { _, child in
                found = contains(udid: udid, in: child, depth: depth + 1)
                return !found
            }
            return found
        case XPC_TYPE_ARRAY:
            var found = false
            xpc_array_apply(object) { _, child in
                found = contains(udid: udid, in: child, depth: depth + 1)
                return !found
            }
            return found
        default:
            return false
        }
    }

    /// `osVersionNumber` is a CoreDevice VersionNumber field in the matching device snapshot.
    /// Its numeric components are authoritative; device names and human-readable OS labels are not.
    private static func operatingSystemVersion(in snapshot: xpc_object_t) throws -> OperatingSystemVersion {
        let candidates = descriptorValues("osVersionNumber", in: snapshot)
        guard !candidates.isEmpty, candidates.count <= 32 else {
            throw Failure.unsupportedOS("version unavailable or ambiguous")
        }
        let versions = try candidates.map { try versionComponents($0) }
        guard let first = versions.first, versions.allSatisfy({ $0 == first }) else {
            throw Failure.unsupportedOS("conflicting version information")
        }
        return OperatingSystemVersion(majorVersion: first[0], minorVersion: first[1], patchVersion: first[2])
    }

    private static func descriptorValues(
        _ key: String, in object: xpc_object_t, depth: Int = 0
    ) -> [xpc_object_t] {
        guard depth < 64 else { return [] }
        var values: [xpc_object_t] = []
        switch xpc_get_type(object) {
        case XPC_TYPE_DICTIONARY:
            if let descriptor = xpc_dictionary_get_value(object, "descriptorIdentifier"),
               xpc_get_type(descriptor) == XPC_TYPE_DICTIONARY,
               let name = xpc_dictionary_get_string(descriptor, "key"), String(cString: name) == key,
               let value = xpc_dictionary_get_value(object, "value") {
                return [value]
            }
            xpc_dictionary_apply(object) { _, child in
                values.append(contentsOf: descriptorValues(key, in: child, depth: depth + 1))
                return values.count <= 32
            }
        case XPC_TYPE_ARRAY:
            xpc_array_apply(object) { _, child in
                values.append(contentsOf: descriptorValues(key, in: child, depth: depth + 1))
                return values.count <= 32
            }
        default: break
        }
        return values
    }

    private static func versionComponents(_ value: xpc_object_t) throws -> [Int] {
        var components: [Int] = []
        if xpc_get_type(value) == XPC_TYPE_DICTIONARY,
           let array = xpc_dictionary_get_value(value, "components"), xpc_get_type(array) == XPC_TYPE_ARRAY {
            let count = xpc_array_get_count(array)
            guard count > 0, count <= 5 else { throw Failure.unsupportedOS("invalid version components") }
            for index in 0..<count {
                let component = xpc_array_get_value(array, index)
                let number: Int?
                switch xpc_get_type(component) {
                case XPC_TYPE_UINT64: number = Int(exactly: xpc_uint64_get_value(component))
                case XPC_TYPE_INT64: number = Int(exactly: xpc_int64_get_value(component))
                default: number = nil
                }
                guard let number, number >= 0 else { throw Failure.unsupportedOS("invalid version component") }
                components.append(number)
            }
        } else if xpc_get_type(value) == XPC_TYPE_STRING,
                  xpc_string_get_length(value) <= 64, let text = xpc_string_get_string_ptr(value) {
            let parts = String(cString: text).split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 3 else { throw Failure.unsupportedOS("invalid version number") }
            for part in parts {
                guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(part) else { throw Failure.unsupportedOS("invalid version number") }
                components.append(number)
            }
        } else {
            throw Failure.unsupportedOS("version components unavailable")
        }
        guard components[0] > 0, components.dropFirst(3).allSatisfy({ $0 == 0 }) else {
            throw Failure.unsupportedOS("unsupported version format")
        }
        while components.count < 3 { components.append(0) }
        return Array(components.prefix(3))
    }

    private func acquireUsageAssertion() throws {
        let ready = PhysicalHIDCoreDeviceReply<Void>()
        let connections = connections
        let listener = xpc_connection_create(nil, callbackQueue)
        guard connections.add(listener) else { throw Failure.serviceUnavailable }
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else {
                ready.resolve(.failure(Failure.serviceUnavailable))
                connections.close()
                return
            }
            guard connections.add(peer) else { return }
            xpc_connection_set_event_handler(peer) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
                    ready.resolve(.failure(Failure.serviceUnavailable))
                    connections.close()
                    return
                }
                guard let type = xpc_dictionary_get_string(message, "mangledTypeName"),
                      String(cString: type) == "CoreDevice.AssertionFulfilledMessage" else { return }
                ready.resolve(.success(()))
            }
            xpc_connection_activate(peer)
        }
        xpc_connection_activate(listener)

        let states = xpc_array_create(nil, 0)
        for state in [
            "com.apple.coredevice.remoteServiceDiscoveryTrustedConnectivityAvailable",
            "com.apple.coredevice.powerAssertionTaken",
        ] {
            let entry = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(entry, "identifier", state)
            xpc_array_append_value(states, entry)
        }
        let requirements = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(requirements, "deviceStates", states)
        xpc_dictionary_set_value(requirements, "capabilities", xpc_array_create(nil, 0))

        let input = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(input, "reason", "StupidMirror device input")
        xpc_dictionary_set_value(input, "requirements", requirements)
        xpc_dictionary_set_value(input, "endpoint", xpc_endpoint_create(listener))
        send("com.apple.coredevice.action.acquireusageassertion", input: input) { result in
            // This action replies when its assertion ends, not when connectivity is ready.
            // A successful reply must never substitute for AssertionFulfilledMessage.
            switch result {
            case .success:
                ready.resolve(.failure(Failure.assertionEnded))
            case .failure(let error):
                ready.resolve(.failure(error))
            }
            connections.close()
        }
        try ready.wait(timeout: Self.actionTimeout, operation: "usage assertion")
        guard !connections.isClosed else { throw Failure.serviceUnavailable }
    }

    private func invoke(
        _ action: String, input: xpc_object_t, timeout: TimeInterval? = nil
    ) throws -> xpc_object_t {
        guard !connections.isClosed else { throw Failure.serviceUnavailable }
        let reply = PhysicalHIDCoreDeviceReply<xpc_object_t>()
        send(action, input: input) { reply.resolve($0) }
        let output = try reply.wait(timeout: timeout ?? Self.actionTimeout, operation: action)
        guard !connections.isClosed else { throw Failure.serviceUnavailable }
        return output
    }

    private func send(
        _ action: String,
        input: xpc_object_t,
        completion: @escaping @Sendable (Result<xpc_object_t, Error>) -> Void
    ) {
        guard !connections.isClosed else {
            completion(.failure(Failure.serviceUnavailable))
            return
        }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(message, "CoreDevice.coreDeviceVersion", Self.versionObject(versionString))
        xpc_dictionary_set_string(message, "CoreDevice.deviceIdentifier", deviceIdentifier)
        xpc_dictionary_set_int64(message, "CoreDevice.CoreDeviceDDIProtocolVersion", 2)
        xpc_dictionary_set_string(message, "CoreDevice.invocationIdentifier", UUID().uuidString)
        xpc_dictionary_set_value(message, "CoreDevice.input", input)
        xpc_dictionary_set_string(message, "CoreDevice.actionIdentifier", action)
        xpc_connection_send_message_with_reply(connection, message, callbackQueue) { response in
            if let failure = Self.responseFailure(response, action: action) {
                completion(.failure(failure))
                return
            }
            completion(.success(
                xpc_dictionary_get_value(response, "CoreDevice.output") ?? xpc_dictionary_create(nil, nil, 0)
            ))
        }
    }

    private static func responseFailure(_ response: xpc_object_t, action: String) -> Failure? {
        guard xpc_get_type(response) == XPC_TYPE_DICTIONARY else { return .serviceUnavailable }
        guard let error = xpc_dictionary_get_value(response, "CoreDevice.error") else { return nil }
        var message = "The device rejected the request."
        if let info = xpc_dictionary_get_value(error, "userInfo") {
            if let description = xpc_dictionary_get_string(info, "NSLocalizedDescription")
                ?? xpc_dictionary_get_string(info, "NSDebugDescription") {
                message = String(String(cString: description).prefix(1024))
            }
        }
        return .actionFailed(action: action, message: message)
    }

    private static func readFrameworkVersion() throws -> String {
        let plist = URL(fileURLWithPath: frameworkPath).deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = values["CFBundleVersion"] as? String,
              !version.isEmpty else { throw Failure.frameworkMissing("Cannot read the installed framework version") }
        return version
    }

    private static func versionObject(_ versionString: String) -> xpc_object_t {
        let parts = versionString.split(separator: ".").compactMap { UInt64($0) }
        let version = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_int64(version, "originalComponentsCount", Int64(parts.count))
        let components = xpc_array_create(nil, 0)
        for index in 0..<5 {
            xpc_array_append_value(components, xpc_uint64_create(index < parts.count ? parts[index] : 0))
        }
        xpc_dictionary_set_value(version, "components", components)
        xpc_dictionary_set_string(version, "stringValue", versionString)
        return version
    }
}

/// Owns all XPC endpoints, including peers accepted by the assertion listener.
/// Cancel outside the lock because cancellation delivers further XPC callbacks.
private final class PhysicalHIDCoreDeviceConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [xpc_connection_t] = []
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    @discardableResult
    func add(_ connection: xpc_connection_t) -> Bool {
        lock.lock()
        let accepted = !closed
        if accepted { endpoints.append(connection) }
        lock.unlock()
        if !accepted { xpc_connection_cancel(connection) }
        return accepted
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let pending = endpoints
        endpoints.removeAll()
        lock.unlock()
        for endpoint in pending { xpc_connection_cancel(endpoint) }
    }
}

/// Transfers exactly one callback result to the calling background thread.
private final class PhysicalHIDCoreDeviceReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func resolve(_ newResult: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = newResult
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval, operation: String) throws -> Value {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw PhysicalHIDCoreDeviceClient.Failure.timedOut(operation)
        }
        lock.lock()
        let completed = result
        lock.unlock()
        guard let completed else { throw PhysicalHIDCoreDeviceClient.Failure.serviceUnavailable }
        return try completed.get()
    }
}
