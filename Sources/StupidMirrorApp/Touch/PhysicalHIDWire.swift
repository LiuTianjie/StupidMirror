// Protocol encoding adapted from iphone-use, Copyright (c) 2026 Sunghyun Kim.
// Distributed under the MIT license in Assets/licenses/iphone-use-LICENSE.txt.

import Foundation
import Darwin

/// The edge where a contact began, in the touchscreen's native orientation.
/// This is digitizer metadata; it never changes the contact's coordinates.
enum PhysicalHIDContactEdge: Sendable {
    case top, bottom, left, right

    static func beginning(at point: CGPoint, displayPointSize: CGSize) -> Self? {
        // Match the source-display gesture margin across native and embedded views.
        // Keep this input policy separate from the report's bit layout.
        let margin: CGFloat = 24
        let distances: [(Self, CGFloat)] = [
            (.top, point.y * displayPointSize.height),
            (.bottom, (1 - point.y) * displayPointSize.height),
            (.left, point.x * displayPointSize.width),
            (.right, (1 - point.x) * displayPointSize.width),
        ]
        var nearest: (Self, CGFloat)?
        for candidate in distances where candidate.1 < margin {
            if nearest == nil || candidate.1 < nearest!.1 { nearest = candidate }
        }
        return nearest?.0
    }
}

/// The small RemoteXPC value subset needed to send input reports.
indirect enum PhysicalHIDValue: Sendable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    case data(Data)
    case string(String)
    case uuid(UUID)
    case array([PhysicalHIDValue])
    case dictionary([String: PhysicalHIDValue])

    func encode(into output: inout Data) {
        switch self {
        case .null:
            output.hidAppendLittle(UInt32(0x1000))
        case let .bool(value):
            output.hidAppendLittle(UInt32(0x2000))
            output.hidAppendLittle(UInt32(value ? 1 : 0))
        case let .int64(value):
            output.hidAppendLittle(UInt32(0x3000))
            output.hidAppendLittle(UInt64(bitPattern: value))
        case let .uint64(value):
            output.hidAppendLittle(UInt32(0x4000))
            output.hidAppendLittle(value)
        case let .double(value):
            output.hidAppendLittle(UInt32(0x5000))
            output.hidAppendLittle(value.bitPattern)
        case let .data(value):
            output.hidAppendLittle(UInt32(0x8000))
            output.hidAppendLittle(UInt32(value.count))
            output.append(value)
            output.hidAlign()
        case let .string(value):
            output.hidAppendLittle(UInt32(0x9000))
            let bytes = Data(value.utf8) + Data([0])
            output.hidAppendLittle(UInt32(bytes.count))
            output.append(bytes)
            output.hidAlign()
        case let .uuid(value):
            output.hidAppendLittle(UInt32(0xa000))
            var bytes = value.uuid
            Swift.withUnsafeBytes(of: &bytes) { output.append(contentsOf: $0) }
        case let .array(items):
            output.hidAppendLittle(UInt32(0xe000))
            var body = Data()
            body.hidAppendLittle(UInt32(items.count))
            for item in items { item.encode(into: &body) }
            output.hidAppendLittle(UInt32(body.count))
            output.append(body)
        case let .dictionary(entries):
            output.hidAppendLittle(UInt32(0xf000))
            var body = Data()
            body.hidAppendLittle(UInt32(entries.count))
            for key in entries.keys.sorted() {
                body.append(contentsOf: key.utf8)
                body.append(0)
                body.hidAlign()
                entries[key]?.encode(into: &body)
            }
            output.hidAppendLittle(UInt32(body.count))
            output.append(body)
        }
    }
}

enum PhysicalHIDWire {
    static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static let receiveWindow: UInt32 = 1_048_576
    static let maximumFrameBytes = 1_048_576

    enum EncodingError: LocalizedError {
        case invalidScrollDelta
        case invalidGestureDelta

        var errorDescription: String? {
            switch self {
            case .invalidScrollDelta: "Scroll deltas are outside the supported range."
            case .invalidGestureDelta: "Gesture deltas are outside the supported range."
            }
        }
    }

    enum FrameType: UInt8 {
        case data = 0, headers = 1, reset = 3, settings = 4
        case ping = 6, goAway = 7, windowUpdate = 8
    }

    struct Frame: Sendable {
        let type: UInt8
        let flags: UInt8
        let stream: UInt32
        let payload: Data

        var kind: FrameType? { FrameType(rawValue: type) }
    }

    static func frame(_ type: FrameType, flags: UInt8 = 0, stream: UInt32 = 0, payload: Data = Data()) -> Data {
        let count = UInt32(payload.count)
        var result = Data([
            UInt8((count >> 16) & 0xff), UInt8((count >> 8) & 0xff), UInt8(count & 0xff),
            type.rawValue, flags,
            UInt8((stream >> 24) & 0x7f), UInt8((stream >> 16) & 0xff),
            UInt8((stream >> 8) & 0xff), UInt8(stream & 0xff)
        ])
        result.append(payload)
        return result
    }

    static func settings() -> Data {
        var payload = Data()
        let settings: [(UInt16, UInt32)] = [(3, 100), (4, receiveWindow)]
        for (key, value) in settings {
            payload.hidAppendBig(key)
            payload.hidAppendBig(value)
        }
        return frame(.settings, payload: payload)
    }

    static func windowUpdate(stream: UInt32, count: UInt32) -> Data {
        var payload = Data()
        payload.hidAppendBig(count & 0x7fff_ffff)
        return frame(.windowUpdate, stream: stream, payload: payload)
    }

    static func envelope(
        _ values: [String: PhysicalHIDValue], identifier: UInt64, wantingReply: Bool = false
    ) -> Data {
        var payload = Data()
        payload.hidAppendLittle(UInt32(0x4213_3742))
        payload.hidAppendLittle(UInt32(5))
        PhysicalHIDValue.dictionary(values).encode(into: &payload)
        var message = Data()
        message.hidAppendLittle(UInt32(0x29b0_0b92))
        let flags: UInt32 = (values.isEmpty ? 1 : 0x101) | (wantingReply ? 0x10000 : 0)
        message.hidAppendLittle(flags)
        message.hidAppendLittle(UInt64(payload.count))
        message.hidAppendLittle(identifier)
        message.append(payload)
        return message
    }

    static func controlEnvelope(flags: UInt32) -> Data {
        var data = Data()
        data.hidAppendLittle(UInt32(0x29b0_0b92))
        data.hidAppendLittle(flags)
        data.hidAppendLittle(UInt64(0))
        data.hidAppendLittle(UInt64(0))
        return data
    }

    static func touchReport(
        point: CGPoint, contact: Bool, initialEdge: PhysicalHIDContactEdge? = nil,
        timestampTicks: UInt64 = mach_absolute_time()
    ) -> Data {
        let x = UInt16((min(max(point.x, 0), 1) * 65_535).rounded())
        let y = UInt16((min(max(point.y, 0), 1) * 65_535).rounded())
        var data = Data([0x09, 0x01, 0x05, contact ? 0xc2 : 0x02])
        data.hidAppendLittle(x)
        data.hidAppendLittle(y)
        data.append(Data(repeating: 0, count: 32))
        // Five contact identities, followed by the complete remote mach timestamp.
        data.append(contentsOf: [0x02, 0, 0, 0, 0])
        data.hidAppendLittle(timestampTicks)
        data.append(Data(repeating: 0, count: 5))
        if let initialEdge {
            // Contact slot zero: swipeLocked plus the direction into the display.
            // The same metadata accompanies DOWN, MOVE, held reports and release.
            data[53] |= 0x20
            switch initialEdge {
            case .top: data[54] |= 0x80
            case .bottom: data[54] |= 0x04
            case .left: data[56] |= 0x02
            case .right: data[55] |= 0x10
            }
        }
        return data
    }

    static func touchRequest(_ report: Data, serviceID: UInt64 = 257) -> [String: PhysicalHIDValue] {
        [
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.universalhidservice"),
            "messageType": .string("Request"),
            "payload": .dictionary([
                "send": .dictionary(["_0": .data(report), "_1": .uint64(serviceID)])
            ])
        ]
    }

    /// A scroll collection with independent raw and accelerated deltas.
    /// Phase and momentum are HID values, not NSEventPhase raw values.
    static func scrollReport(
        rawDelta: CGPoint,
        acceleratedDelta: CGPoint = .zero,
        phase: UInt8,
        momentum: UInt8,
        timestampTicks: UInt64 = mach_absolute_time()
    ) throws -> Data {
        guard let rawX = Int64(exactly: Double(rawDelta.x).rounded(.toNearestOrAwayFromZero)),
              let rawY = Int64(exactly: Double(rawDelta.y).rounded(.toNearestOrAwayFromZero)) else {
            throw EncodingError.invalidScrollDelta
        }
        var data = Data([
            0x07, phase & 0x8f, momentum,
            UInt8(bitPattern: Int8(clamping: rawX)),
            UInt8(bitPattern: Int8(clamping: rawY)),
        ])
        data.hidAppendLittle(scrollFixedPoint(Double(acceleratedDelta.x)))
        data.hidAppendLittle(scrollFixedPoint(Double(acceleratedDelta.y)))
        data.hidAppendLittle(timestampTicks)
        return data
    }

    /// Magnification is the change for this event, not a cumulative scale factor.
    static func scaleReport(
        magnification: Double,
        phase: UInt8,
        timestampTicks: UInt64 = mach_absolute_time()
    ) throws -> Data {
        try normalizedGestureReport(
            id: 0x0f, value: magnification, phase: phase, timestampTicks: timestampTicks
        )
    }

    /// Rotation is the change for this event in radians.
    static func rotationReport(
        radians: Double,
        phase: UInt8,
        timestampTicks: UInt64 = mach_absolute_time()
    ) throws -> Data {
        try normalizedGestureReport(
            id: 0x10, value: radians, phase: phase, timestampTicks: timestampTicks
        )
    }

    private static func normalizedGestureReport(
        id: UInt8, value: Double, phase: UInt8, timestampTicks: UInt64
    ) throws -> Data {
        guard value.isFinite else { throw EncodingError.invalidGestureDelta }
        let scaled = value * (value >= 0 ? 32_767 : 32_768)
        let bounded = min(max(scaled, Double(Int16.min)), Double(Int16.max))
        let encoded = Int16(bounded.rounded(.towardZero))
        var data = Data([id, phase & 0x8f])
        data.hidAppendLittle(encoded)
        data.hidAppendLittle(timestampTicks)
        return data
    }

    private static func scrollFixedPoint(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let scaled = (value * 65_536).rounded(.toNearestOrAwayFromZero)
        return Int32(min(max(scaled, Double(Int32.min)), Double(Int32.max)))
    }
}

private extension Data {
    mutating func hidAppendLittle<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func hidAppendBig<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func hidAlign() {
        let remainder = count % 4
        if remainder != 0 { append(Data(repeating: 0, count: 4 - remainder)) }
    }
}
