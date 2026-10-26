// RemoteXPC framing adapted from iphone-use, Copyright (c) 2026 Sunghyun Kim.
// Distributed under the MIT license in Assets/licenses/iphone-use-LICENSE.txt.

import Darwin
import Foundation

enum PhysicalHIDTransportError: LocalizedError, Sendable {
    case closed
    case connection(String)
    case timedOut(String)
    case invalidProtocol(String)

    var errorDescription: String? {
        switch self {
        case .closed:
            return "The system touch connection is closed. Reconnect device control."
        case .connection(let detail):
            return "The system touch connection failed: \(detail)"
        case .timedOut(let operation):
            return "The system touch connection timed out (\(operation))."
        case .invalidProtocol(let detail):
            return "The device rejected the system touch protocol: \(detail)"
        }
    }
}

/// A persistent RemoteXPC connection. The owning backend serializes requests;
/// a separate reader handles flow control and peer health even between gestures.
/// None of the operations start a media or XCTest session.
final class PhysicalHIDConnection: @unchecked Sendable {
    private static let operationTimeout: TimeInterval = 2
    private let socket: PhysicalHIDSocket
    private let readerQueue = DispatchQueue(label: "StupidMirror.PhysicalHID.Reader")
    private let readerGroup = DispatchGroup()
    private let state = NSCondition()
    private var terminalError: PhysicalHIDTransportError?
    private var receivedSettings = false
    private var connectionWindow: Int64 = 65_535
    private var initialStreamWindow: Int64 = 65_535
    private var streamWindows: [UInt32: Int64] = [1: 65_535, 3: 65_535]
    private var maximumOutgoingFrameBytes = 16_384
    private var pendingPing: Data?
    private var receivedPong = false
    private let receivesResponses: Bool
    private var pendingResponseIdentifier: UInt64?
    private var receivedResponse: [String: PhysicalHIDValue]?
    // Only the reader queue accesses partially received response envelopes.
    private var responseBuffers: [UInt32: Data] = [:]
    // Accessed only by the owning backend's serial queue.
    private var nextMessageIdentifier: UInt64 = 1

    /// Takes ownership of descriptor, including when initialization fails.
    init(adopting descriptor: Int32, receivesResponses: Bool = false, timeout: TimeInterval = 2) throws {
        self.receivesResponses = receivesResponses
        socket = try PhysicalHIDSocket(adopting: descriptor)
        do {
            guard timeout.isFinite, timeout > 0, timeout <= 60 else {
                throw PhysicalHIDTransportError.invalidProtocol("invalid handshake timeout")
            }
            let deadline = PhysicalHIDDeadline.after(timeout)
            // Write the complete preamble atomically. Peer SETTINGS cannot insert
            // an ACK between the RemoteXPC channel-opening messages.
            let initial = PhysicalHIDWire.envelope([:], identifier: 0)
            let rootControl = PhysicalHIDWire.controlEnvelope(flags: 0x0201)
            let replyControl = PhysicalHIDWire.controlEnvelope(flags: 0x400001)
            var preamble = PhysicalHIDWire.preface
            preamble.append(PhysicalHIDWire.settings())
            preamble.append(PhysicalHIDWire.windowUpdate(stream: 0, count: PhysicalHIDWire.receiveWindow - 65_535))
            preamble.append(PhysicalHIDWire.frame(.headers, flags: 0x04, stream: 1))
            preamble.append(PhysicalHIDWire.frame(.data, stream: 1, payload: initial))
            preamble.append(PhysicalHIDWire.frame(.headers, flags: 0x04, stream: 3))
            preamble.append(PhysicalHIDWire.frame(.data, stream: 1, payload: rootControl))
            preamble.append(PhysicalHIDWire.frame(.data, stream: 3, payload: replyControl))
            connectionWindow -= Int64(initial.count + rootControl.count + replyControl.count)
            streamWindows[1, default: 65_535] -= Int64(initial.count + rootControl.count)
            streamWindows[3, default: 65_535] -= Int64(replyControl.count)
            try socket.write(preamble, deadline: deadline)
            readerGroup.enter()
            readerQueue.async { [self] in
                defer { readerGroup.leave() }
                do {
                    while true { try handle(readFrame()) }
                } catch {
                    fail(Self.transportError(error))
                }
            }
            // The metadata request's reply confirms the protocol and liveness.
            // Send it after the preamble without adding handshake round trips.
            if receivesResponses { return }
            try wait(deadline: deadline, operation: "HTTP/2 settings") {
                receivedSettings
            }
            // A PING confirms a live transport. It cannot confirm that iOS accepted
            // a touch, which may depend on the device's interactive-session state.
            guard deadline.remaining > 0 else { throw PhysicalHIDTransportError.timedOut("HTTP/2 handshake") }
            try flush(timeout: deadline.remaining)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func send(report: Data, serviceID: UInt64 = 257) throws {
        let payload = PhysicalHIDWire.envelope(
            PhysicalHIDWire.touchRequest(report, serviceID: serviceID), identifier: nextMessageIdentifier
        )
        nextMessageIdentifier &+= 1
        do {
            try sendData(payload, stream: 1, deadline: .after(Self.operationTimeout))
        } catch {
            fail(Self.transportError(error))
            throw error
        }
    }

    /// Only used by the separate metadata service connection. The caller must
    /// serialize requests; a timeout terminates it so a late reply cannot be reused.
    func request(_ values: [String: PhysicalHIDValue], timeout: TimeInterval) throws -> [String: PhysicalHIDValue] {
        guard receivesResponses, timeout.isFinite, timeout > 0 else {
            throw PhysicalHIDTransportError.invalidProtocol("invalid metadata request")
        }
        let deadline = PhysicalHIDDeadline.after(timeout)
        let identifier = nextMessageIdentifier
        nextMessageIdentifier &+= 1
        state.lock()
        if let error = terminalError {
            state.unlock()
            throw error
        }
        guard pendingResponseIdentifier == nil else {
            state.unlock()
            throw PhysicalHIDTransportError.invalidProtocol("concurrent metadata requests")
        }
        pendingResponseIdentifier = identifier
        receivedResponse = nil
        state.unlock()
        do {
            let payload = PhysicalHIDWire.envelope(values, identifier: identifier, wantingReply: true)
            try sendData(payload, stream: 1, deadline: deadline)
            try wait(deadline: deadline, operation: "display metadata") { receivedResponse != nil }
            state.lock()
            let response = receivedResponse
            receivedResponse = nil
            pendingResponseIdentifier = nil
            state.unlock()
            guard let response else { throw PhysicalHIDTransportError.invalidProtocol("missing metadata response") }
            return response
        } catch {
            fail(Self.transportError(error))
            throw error
        }
    }

    /// One round trip at a gesture boundary; no per-MOVE round trip.
    /// Success proves preceding data reached the service's HTTP/2 transport.
    func flush(timeout: TimeInterval = 2) throws {
        let token = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        let deadline = PhysicalHIDDeadline.after(timeout)
        state.lock()
        if let error = terminalError {
            state.unlock()
            throw error
        }
        pendingPing = token
        receivedPong = false
        state.unlock()
        do {
            try socket.write(PhysicalHIDWire.frame(.ping, payload: token), deadline: deadline)
            try wait(deadline: deadline, operation: "touch drain") { receivedPong }
            state.lock()
            pendingPing = nil
            state.unlock()
        } catch {
            fail(Self.transportError(error))
            throw error
        }
    }

    func close() {
        fail(.closed)
        // Shutdown wakes the nonblocking reader. Its writes and partial reads
        // have bounded deadlines, so the descriptor is never closed underneath
        // an outstanding syscall and accidentally reused by another connection.
        readerGroup.wait()
        socket.finishClose()
    }

    private func fail(_ error: PhysicalHIDTransportError) {
        state.lock()
        if terminalError == nil { terminalError = error }
        state.broadcast()
        state.unlock()
        socket.interrupt()
    }

    private func wait(
        deadline: PhysicalHIDDeadline, operation: String, until ready: () -> Bool
    ) throws {
        state.lock()
        defer { state.unlock() }
        while true {
            if ready() { return }
            if let error = terminalError { throw error }
            let remaining = deadline.remaining
            guard remaining > 0 else { throw PhysicalHIDTransportError.timedOut(operation) }
            _ = state.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.2)))
        }
    }

    private func sendData(_ payload: Data, stream: UInt32, deadline: PhysicalHIDDeadline) throws {
        var offset = 0
        while offset < payload.count {
            state.lock()
            let count: Int
            do {
                while true {
                    if let error = terminalError { throw error }
                    let credit = min(connectionWindow, streamWindows[stream, default: 0])
                    if credit > 0 {
                        count = min(payload.count - offset, min(maximumOutgoingFrameBytes, Int(credit)))
                        connectionWindow -= Int64(count)
                        streamWindows[stream, default: 0] -= Int64(count)
                        break
                    }
                    let remaining = deadline.remaining
                    guard remaining > 0 else {
                        throw PhysicalHIDTransportError.timedOut("touch flow control")
                    }
                    _ = state.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.2)))
                }
                state.unlock()
            } catch {
                state.unlock()
                throw error
            }
            let part = payload.subdata(in: offset..<(offset + count))
            try socket.write(PhysicalHIDWire.frame(.data, stream: stream, payload: part), deadline: deadline)
            offset += count
        }
    }

    private func readFrame() throws -> PhysicalHIDWire.Frame {
        let header = [UInt8](try socket.readExactly(9, allowIdle: true))
        let length = Int(header[0]) << 16 | Int(header[1]) << 8 | Int(header[2])
        guard length <= PhysicalHIDWire.maximumFrameBytes else {
            throw PhysicalHIDTransportError.invalidProtocol("oversized frame")
        }
        let stream = UInt32(header[5] & 0x7f) << 24 | UInt32(header[6]) << 16
            | UInt32(header[7]) << 8 | UInt32(header[8])
        return PhysicalHIDWire.Frame(
            type: header[3], flags: header[4], stream: stream,
            payload: try socket.readExactly(length, allowIdle: false)
        )
    }

    private func handle(_ frame: PhysicalHIDWire.Frame) throws {
        switch frame.kind {
        case .settings:
            try handleSettings(frame)
        case .ping:
            guard frame.stream == 0, frame.payload.count == 8 else {
                throw PhysicalHIDTransportError.invalidProtocol("invalid PING")
            }
            if frame.flags & 0x01 == 0 {
                try socket.write(
                    PhysicalHIDWire.frame(.ping, flags: 0x01, payload: frame.payload),
                    deadline: .after(Self.operationTimeout)
                )
            } else {
                state.lock()
                if frame.payload == pendingPing {
                    receivedPong = true
                    state.broadcast()
                }
                state.unlock()
            }
        case .windowUpdate:
            try handleWindowUpdate(frame)
        case .data:
            guard frame.stream == 1 || frame.stream == 3, frame.flags & 0x01 == 0 else {
                throw PhysicalHIDTransportError.invalidProtocol("input stream ended")
            }
            if receivesResponses { try consumeResponse(frame) }
            if !frame.payload.isEmpty {
                // Touch reports are no-reply messages. Consume bounded service
                // traffic without retaining an unbounded RemoteXPC response buffer.
                let count = UInt32(frame.payload.count)
                var update = PhysicalHIDWire.windowUpdate(stream: 0, count: count)
                update.append(PhysicalHIDWire.windowUpdate(stream: frame.stream, count: count))
                try socket.write(update, deadline: .after(Self.operationTimeout))
            }
        case .headers:
            if (frame.stream == 1 || frame.stream == 3), frame.flags & 0x01 != 0 {
                throw PhysicalHIDTransportError.invalidProtocol("input stream ended")
            }
        case .reset:
            throw PhysicalHIDTransportError.connection("device reset input stream \(frame.stream)")
        case .goAway:
            let bytes = [UInt8](frame.payload)
            let code = bytes.count >= 8 ? Self.bigEndianUInt32(bytes, at: 4) : 0
            throw PhysicalHIDTransportError.connection("device closed HTTP/2 (code \(code))")
        case nil:
            // HTTP/2 permits unknown extensions. Length has already been bounded.
            break
        }
    }

    private func consumeResponse(_ frame: PhysicalHIDWire.Frame) throws {
        var payload = frame.payload
        if frame.flags & 0x08 != 0 {
            guard let padding = payload.first, payload.count > Int(padding) else {
                throw PhysicalHIDTransportError.invalidProtocol("invalid DATA padding")
            }
            payload = payload.subdata(in: 1..<(payload.count - Int(padding)))
        }
        var pending = responseBuffers[frame.stream, default: Data()]
        guard pending.count + payload.count <= PhysicalHIDWire.maximumFrameBytes + 24 else {
            throw PhysicalHIDTransportError.invalidProtocol("oversized metadata response")
        }
        pending.append(payload)
        while pending.count >= 24 {
            let header = [UInt8](pending.prefix(24))
            let magic = UInt32(Self.littleEndianUInt64(header, at: 0, count: 4))
            guard magic == 0x29b0_0b92 else {
                throw PhysicalHIDTransportError.invalidProtocol("invalid RemoteXPC envelope")
            }
            let flags = UInt32(Self.littleEndianUInt64(header, at: 4, count: 4))
            guard flags & 0x0030_0000 == 0 else {
                throw PhysicalHIDTransportError.invalidProtocol("unexpected metadata file transfer")
            }
            let size = Self.littleEndianUInt64(header, at: 8)
            guard size <= UInt64(PhysicalHIDWire.maximumFrameBytes) else {
                throw PhysicalHIDTransportError.invalidProtocol("oversized RemoteXPC payload")
            }
            let end = 24 + Int(size)
            guard pending.count >= end else { break }
            let identifier = Self.littleEndianUInt64(header, at: 16)
            if size > 0 {
                let response = try PhysicalHIDResponseDecoder.decode(pending.subdata(in: 24..<end))
                if !response.isEmpty {
                    state.lock()
                    if pendingResponseIdentifier == identifier, receivedResponse == nil {
                        receivedResponse = response
                        state.broadcast()
                    }
                    state.unlock()
                }
            }
            pending = pending.subdata(in: end..<pending.count)
        }
        responseBuffers[frame.stream] = pending
    }

    private func handleSettings(_ frame: PhysicalHIDWire.Frame) throws {
        guard frame.stream == 0 else {
            throw PhysicalHIDTransportError.invalidProtocol("SETTINGS on an input stream")
        }
        if frame.flags & 0x01 != 0 {
            guard frame.payload.isEmpty else {
                throw PhysicalHIDTransportError.invalidProtocol("nonempty SETTINGS acknowledgment")
            }
            return
        }
        guard frame.payload.count.isMultiple(of: 6) else {
            throw PhysicalHIDTransportError.invalidProtocol("invalid SETTINGS length")
        }
        let bytes = [UInt8](frame.payload)
        state.lock()
        do {
            for offset in stride(from: 0, to: bytes.count, by: 6) {
                let key = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
                let value = Self.bigEndianUInt32(bytes, at: offset + 2)
                switch key {
                case 4:
                    guard value <= 0x7fff_ffff else {
                        throw PhysicalHIDTransportError.invalidProtocol("invalid stream window")
                    }
                    let delta = Int64(value) - initialStreamWindow
                    for stream in [UInt32(1), UInt32(3)] {
                        let window = streamWindows[stream, default: 0] + delta
                        guard window <= 0x7fff_ffff else {
                            throw PhysicalHIDTransportError.invalidProtocol("stream window overflow")
                        }
                        streamWindows[stream] = window
                    }
                    initialStreamWindow = Int64(value)
                case 5:
                    guard (16_384...16_777_215).contains(value) else {
                        throw PhysicalHIDTransportError.invalidProtocol("invalid maximum frame size")
                    }
                    maximumOutgoingFrameBytes = min(Int(value), PhysicalHIDWire.maximumFrameBytes)
                default:
                    break
                }
            }
            state.broadcast()
            state.unlock()
        } catch {
            state.unlock()
            throw error
        }
        try socket.write(PhysicalHIDWire.frame(.settings, flags: 0x01), deadline: .after(Self.operationTimeout))
        state.lock()
        receivedSettings = true
        state.broadcast()
        state.unlock()
    }

    private func handleWindowUpdate(_ frame: PhysicalHIDWire.Frame) throws {
        guard frame.payload.count == 4 else {
            throw PhysicalHIDTransportError.invalidProtocol("invalid WINDOW_UPDATE")
        }
        let credit = Int64(Self.bigEndianUInt32([UInt8](frame.payload), at: 0) & 0x7fff_ffff)
        guard credit > 0 else {
            throw PhysicalHIDTransportError.invalidProtocol("empty window update")
        }
        state.lock()
        defer { state.unlock() }
        if frame.stream == 0 {
            guard connectionWindow + credit <= 0x7fff_ffff else {
                throw PhysicalHIDTransportError.invalidProtocol("connection window overflow")
            }
            connectionWindow += credit
        } else if frame.stream == 1 || frame.stream == 3 {
            let window = streamWindows[frame.stream, default: 0] + credit
            guard window <= 0x7fff_ffff else {
                throw PhysicalHIDTransportError.invalidProtocol("stream window overflow")
            }
            streamWindows[frame.stream] = window
        }
        state.broadcast()
    }

    private static func bigEndianUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func littleEndianUInt64(_ bytes: [UInt8], at index: Int, count: Int = 8) -> UInt64 {
        var result: UInt64 = 0
        for offset in 0..<count { result |= UInt64(bytes[index + offset]) << (8 * offset) }
        return result
    }

    private static func transportError(_ error: Error) -> PhysicalHIDTransportError {
        (error as? PhysicalHIDTransportError) ?? .connection(error.localizedDescription)
    }
}

private struct PhysicalHIDDeadline {
    let nanoseconds: UInt64

    static func after(_ seconds: TimeInterval) -> Self {
        Self(nanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000))
    }

    var remaining: TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return now < nanoseconds ? Double(nanoseconds - now) / 1_000_000_000 : 0
    }
}

/// Descriptor lifetime is separate from shutdown: the connection joins its reader
/// before closing, and this lock prevents a concurrent writer from using a reused fd.
private final class PhysicalHIDSocket: @unchecked Sendable {
    private let descriptor: Int32
    private let state = NSLock()
    private let writer = NSLock()
    private var interrupted = false
    private var descriptorClosed = false

    init(adopting descriptor: Int32) throws {
        self.descriptor = descriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            let failure = Self.posixFailure("configure input socket")
            Darwin.close(descriptor)
            descriptorClosed = true
            interrupted = true
            throw failure
        }
        var one: Int32 = 1
        _ = setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let failure = Self.posixFailure("disable input socket SIGPIPE")
            Darwin.close(descriptor)
            descriptorClosed = true
            interrupted = true
            throw failure
        }
    }

    deinit { finishClose() }

    func interrupt() {
        state.lock()
        defer { state.unlock() }
        guard !interrupted else { return }
        interrupted = true
        _ = shutdown(descriptor, SHUT_RDWR)
    }

    func finishClose() {
        interrupt()
        writer.lock()
        defer { writer.unlock() }
        state.lock()
        defer { state.unlock() }
        guard !descriptorClosed else { return }
        descriptorClosed = true
        Darwin.close(descriptor)
    }

    func write(_ data: Data, deadline: PhysicalHIDDeadline) throws {
        writer.lock()
        defer { writer.unlock() }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try checkOpen()
                guard deadline.remaining > 0 else {
                    throw PhysicalHIDTransportError.timedOut("socket write")
                }
                let count = Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    try pollUntilReady(Int16(POLLOUT), deadline: deadline)
                } else {
                    throw Self.posixFailure("send input")
                }
            }
        }
    }

    func readExactly(_ count: Int, allowIdle: Bool) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        var deadline: PhysicalHIDDeadline? = allowIdle ? nil : .after(3)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try checkOpen()
                if let deadline, deadline.remaining <= 0 {
                    throw PhysicalHIDTransportError.timedOut("partial HTTP/2 frame")
                }
                let received = recv(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if received > 0 {
                    offset += received
                    if deadline == nil { deadline = .after(3) }
                } else if received == 0 {
                    throw PhysicalHIDTransportError.connection("device closed the input socket")
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    try pollUntilReady(Int16(POLLIN), deadline: deadline)
                } else {
                    throw Self.posixFailure("receive input status")
                }
            }
        }
        return data
    }

    private func pollUntilReady(_ events: Int16, deadline: PhysicalHIDDeadline?) throws {
        while true {
            try checkOpen()
            let remaining = deadline?.remaining ?? 1
            guard remaining > 0 else { throw PhysicalHIDTransportError.timedOut("socket readiness") }
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&pollDescriptor, 1, Int32(max(1, min(remaining, 1) * 1_000)))
            if result > 0 {
                guard pollDescriptor.revents & Int16(POLLNVAL) == 0 else { throw PhysicalHIDTransportError.closed }
                // Let send/recv consume buffered data or expose a peer shutdown.
                return
            }
            if result < 0, errno != EINTR { throw Self.posixFailure("wait for input socket") }
        }
    }

    private func checkOpen() throws {
        state.lock()
        let closed = interrupted || descriptorClosed
        state.unlock()
        if closed { throw PhysicalHIDTransportError.closed }
    }

    private static func posixFailure(_ operation: String) -> PhysicalHIDTransportError {
        .connection("\(operation): \(String(cString: strerror(errno)))")
    }
}
