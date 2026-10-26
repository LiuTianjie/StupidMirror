// RemoteXPC serialization constants follow iphone-use, Copyright (c) 2026 Sunghyun Kim.
// https://github.com/sunghyun-k/iphone-use/tree/6bf94902f1c30aac712ae594a9a3a08136157a48
// Distributed under the MIT license in Assets/licenses/iphone-use-LICENSE.txt.

import Foundation
@preconcurrency import XPC

/// Decodes one complete RemoteXPC payload, after the outer wrapper has been validated.
/// Wrapper flags (including file-transfer messages) are the connection's responsibility.
enum PhysicalHIDResponseDecoder {
    static let maximumPayloadBytes = 1_048_576
    private static let maximumDepth = 32
    private static let maximumNodes = 4_096

    enum Failure: LocalizedError, Sendable {
        case malformed(String)
        case limitExceeded(String)
        case unsupportedType(UInt32)

        var errorDescription: String? {
            switch self {
            case .malformed(let detail):
                return "Invalid device metadata response: \(detail)."
            case .limitExceeded(let detail):
                return "Device metadata response exceeds the \(detail) limit."
            case .unsupportedType(let type):
                return "Device metadata response contains unsupported XPC type \(type)."
            }
        }
    }

    static func decode(_ payload: Data) throws -> [String: PhysicalHIDValue] {
        guard payload.count <= maximumPayloadBytes else { throw Failure.limitExceeded("payload size") }
        var reader = Reader(bytes: Array(payload))
        let end = reader.bytes.count
        guard try reader.uint32(until: end) == 0x4213_3742 else {
            throw Failure.malformed("payload magic")
        }
        guard try reader.uint32(until: end) == 5 else {
            throw Failure.malformed("payload version")
        }
        guard case .dictionary(let dictionary) = try reader.value(depth: 1, until: end) else {
            throw Failure.malformed("payload is not a dictionary")
        }
        guard reader.offset == end else { throw Failure.malformed("trailing payload bytes") }
        return dictionary
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var remainingNodes = PhysicalHIDResponseDecoder.maximumNodes

        mutating func value(depth: Int, until end: Int) throws -> PhysicalHIDValue {
            guard depth <= PhysicalHIDResponseDecoder.maximumDepth else {
                throw Failure.limitExceeded("nesting depth")
            }
            guard remainingNodes > 0 else { throw Failure.limitExceeded("node count") }
            remainingNodes -= 1
            let type = try uint32(until: end)
            switch type {
            case 0x1000:
                return .null
            case 0x2000:
                let raw = try uint32(until: end)
                guard raw <= 1 else { throw Failure.malformed("boolean value") }
                return .bool(raw == 1)
            case 0x3000:
                return .int64(Int64(bitPattern: try uint64(until: end)))
            case 0x4000:
                return .uint64(try uint64(until: end))
            case 0x5000:
                return .double(Double(bitPattern: try uint64(until: end)))
            case 0x8000:
                let range = try countedBytes(until: end)
                let data = Data(bytes[range])
                try align(until: end)
                return .data(data)
            case 0x9000:
                let range = try countedBytes(until: end)
                guard !range.isEmpty, bytes[range.upperBound - 1] == 0 else {
                    throw Failure.malformed("unterminated string")
                }
                let contents = range.lowerBound..<(range.upperBound - 1)
                guard !bytes[contents].contains(0), let text = String(bytes: bytes[contents], encoding: .utf8) else {
                    throw Failure.malformed("invalid UTF-8 string")
                }
                try align(until: end)
                return .string(text)
            case 0xa000:
                let range = try take(16, until: end)
                let start = range.lowerBound
                return .uuid(UUID(uuid: (
                    bytes[start], bytes[start + 1], bytes[start + 2], bytes[start + 3],
                    bytes[start + 4], bytes[start + 5], bytes[start + 6], bytes[start + 7],
                    bytes[start + 8], bytes[start + 9], bytes[start + 10], bytes[start + 11],
                    bytes[start + 12], bytes[start + 13], bytes[start + 14], bytes[start + 15]
                )))
            case 0xe000:
                let (bodyEnd, count) = try container(until: end)
                var values: [PhysicalHIDValue] = []
                values.reserveCapacity(count)
                for _ in 0..<count { values.append(try value(depth: depth + 1, until: bodyEnd)) }
                guard offset == bodyEnd else { throw Failure.malformed("array body length") }
                return .array(values)
            case 0xf000:
                let (bodyEnd, count) = try container(until: end)
                var values: [String: PhysicalHIDValue] = [:]
                values.reserveCapacity(count)
                var keys = Set<String>()
                keys.reserveCapacity(count)
                for _ in 0..<count {
                    let key = try dictionaryKey(until: bodyEnd)
                    guard keys.insert(key).inserted else { throw Failure.malformed("duplicate dictionary key") }
                    values[key] = try value(depth: depth + 1, until: bodyEnd)
                }
                guard offset == bodyEnd else { throw Failure.malformed("dictionary body length") }
                return .dictionary(values)
            default:
                throw Failure.unsupportedType(type)
            }
        }

        /// Container length includes its entry count but excludes the type and length words.
        private mutating func container(until end: Int) throws -> (end: Int, count: Int) {
            let length = Int(try uint32(until: end))
            guard length <= PhysicalHIDResponseDecoder.maximumPayloadBytes else {
                throw Failure.limitExceeded("container size")
            }
            guard length >= 4, length <= end - offset else { throw Failure.malformed("container length") }
            let bodyEnd = offset + length
            let count = Int(try uint32(until: bodyEnd))
            guard count <= remainingNodes else { throw Failure.limitExceeded("node count") }
            return (bodyEnd, count)
        }

        private mutating func countedBytes(until end: Int) throws -> Range<Int> {
            let count = Int(try uint32(until: end))
            guard count <= PhysicalHIDResponseDecoder.maximumPayloadBytes else {
                throw Failure.limitExceeded("value size")
            }
            return try take(count, until: end)
        }

        private mutating func dictionaryKey(until end: Int) throws -> String {
            let start = offset
            while offset < end, bytes[offset] != 0 { offset += 1 }
            guard offset < end, let text = String(bytes: bytes[start..<offset], encoding: .utf8) else {
                throw Failure.malformed("unterminated or invalid dictionary key")
            }
            offset += 1
            try align(until: end)
            return text
        }

        private mutating func align(until end: Int) throws {
            let padding = (4 - (offset % 4)) % 4
            _ = try take(padding, until: end)
        }

        private mutating func take(_ count: Int, until end: Int) throws -> Range<Int> {
            guard count >= 0, offset <= end, end <= bytes.count, count <= end - offset else {
                throw Failure.malformed("truncated value")
            }
            let start = offset
            offset += count
            return start..<offset
        }

        mutating func uint32(until end: Int) throws -> UInt32 {
            let range = try take(4, until: end)
            var result: UInt32 = 0
            for index in 0..<4 { result |= UInt32(bytes[range.lowerBound + index]) << (index * 8) }
            return result
        }

        private mutating func uint64(until end: Int) throws -> UInt64 {
            let range = try take(8, until: end)
            var result: UInt64 = 0
            for index in 0..<8 { result |= UInt64(bytes[range.lowerBound + index]) << (index * 8) }
            return result
        }
    }
}

extension PhysicalHIDValue {
    /// Bridges an already-decoded bounded value to the existing display-geometry parser.
    func xpcObject() -> xpc_object_t {
        switch self {
        case .null:
            return xpc_null_create()
        case .bool(let value):
            return xpc_bool_create(value)
        case .int64(let value):
            return xpc_int64_create(value)
        case .uint64(let value):
            return xpc_uint64_create(value)
        case .double(let value):
            return xpc_double_create(value)
        case .data(let value):
            return value.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }
        case .string(let value):
            return xpc_string_create(value)
        case .uuid(let value):
            var bytes = value.uuid
            return withUnsafeBytes(of: &bytes) {
                xpc_uuid_create($0.bindMemory(to: UInt8.self).baseAddress!)
            }
        case .array(let values):
            let object = xpc_array_create(nil, 0)
            for value in values { xpc_array_append_value(object, value.xpcObject()) }
            return object
        case .dictionary(let values):
            let object = xpc_dictionary_create(nil, nil, 0)
            for (key, value) in values { xpc_dictionary_set_value(object, key, value.xpcObject()) }
            return object
        }
    }
}
