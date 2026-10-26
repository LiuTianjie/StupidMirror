// Display report schema and rotation conventions follow Meta idb (MIT).
// https://github.com/facebook/idb/tree/dd6633645d52f6535b458315482cc9587b181820
// License: Assets/licenses/idb-LICENSE.txt

import CoreGraphics
import Foundation
@preconcurrency import XPC

/// A confirmed display configuration for UniversalHID's touchscreen surface 257.
/// Multiple integrated panels require an explicit display-to-surface mapping and are unsupported.
struct PhysicalHIDDisplayGeometry: Equatable, Sendable {
    enum Rotation: String, Equatable, Sendable {
        case rot0, rot90, rot180, rot270
    }

    enum Failure: LocalizedError, Sendable {
        case malformed(String)
        case displayUnavailable(String)
        case unsupportedNativeOrientation(String)
        case invalidPoint

        var errorDescription: String? {
            switch self {
            case .malformed(let detail):
                return "CoreDevice returned invalid display information: \(detail)."
            case .displayUnavailable(let detail):
                return "Device input cannot select a display: \(detail)."
            case .unsupportedNativeOrientation(let orientation):
                return "Device input does not yet support this panel's native orientation (\(orientation))."
            case .invalidPoint:
                return "Device input requires a finite point within the displayed image."
            }
        }
    }

    let displayIdentifier: String
    let bounds: CGRect
    let pointScale: Double
    let currentOrientation: Rotation
    let nativeOrientation: Rotation

    private init(
        displayIdentifier: String, bounds: CGRect, pointScale: Double,
        currentOrientation: Rotation, nativeOrientation: Rotation
    ) {
        self.displayIdentifier = displayIdentifier
        self.bounds = bounds
        self.pointScale = pointScale
        self.currentOrientation = currentOrientation
        self.nativeOrientation = nativeOrientation
    }

    /// Converts a current-viewport point in 0...1, with a top-left origin, into the
    /// touchscreen's native coordinates. The viewport must already exclude letterboxing and
    /// undo any user-selected mirror rotation; callers must not apply the device rotation twice.
    func transform(_ point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else {
            throw Failure.invalidPoint
        }
        // The relation between nonzero nativeOrientation and currentOrientation is not yet
        // established for physical devices. Refuse those panels instead of guessing a sum/difference.
        guard nativeOrientation == .rot0 else {
            throw Failure.unsupportedNativeOrientation(nativeOrientation.rawValue)
        }
        switch currentOrientation {
        case .rot0: return point
        case .rot90: return CGPoint(x: point.y, y: 1 - point.x)
        case .rot180: return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .rot270: return CGPoint(x: 1 - point.y, y: point.x)
        }
    }

    static func read(_ output: xpc_object_t) throws -> Self {
        guard xpc_get_type(output) == XPC_TYPE_DICTIONARY,
              let current = try bool(output, "current"), current else {
            throw Failure.displayUnavailable("the report is not current")
        }
        guard let array = xpc_dictionary_get_value(output, "displays"),
              xpc_get_type(array) == XPC_TYPE_ARRAY else {
            throw Failure.malformed("missing displays")
        }
        let count = xpc_array_get_count(array)
        guard count > 0, count <= 32 else { throw Failure.malformed("invalid display count") }

        var records: [(object: xpc_object_t, identifier: String, integrated: Bool, active: Bool?)] = []
        var identifiers = Set<String>()
        for index in 0..<count {
            let record = xpc_array_get_value(array, index)
            guard xpc_get_type(record) == XPC_TYPE_DICTIONARY else {
                throw Failure.malformed("display is not a dictionary")
            }
            let identifier = try displayIdentity(record)
            guard !identifier.isEmpty, identifiers.insert(identifier).inserted else {
                throw Failure.malformed("duplicate or empty display identity")
            }
            guard let type = xpc_dictionary_get_value(record, "type"),
                  xpc_get_type(type) == XPC_TYPE_DICTIONARY,
                  xpc_dictionary_get_count(type) == 1 else {
                throw Failure.malformed("invalid display type")
            }
            records.append((
                object: record, identifier: identifier,
                integrated: xpc_dictionary_get_value(type, "integrated") != nil,
                active: try bool(record, "active")
            ))
        }

        let panels = records.filter(\.integrated)
        guard panels.count == 1, let panel = panels.first else {
            throw Failure.displayUnavailable("surface 257 requires exactly one identified integrated panel")
        }
        if let primary = try bool(panel.object, "primary"), !primary {
            throw Failure.displayUnavailable("the integrated panel is not the primary touchscreen")
        }
        if let external = try bool(panel.object, "external"), external {
            throw Failure.malformed("the integrated panel is also marked external")
        }
        let usesLayoutActivity = records.contains { $0.active != nil }
        for record in records {
            let backlight = try optionalString(record.object, "backlightState")
            if usesLayoutActivity {
                guard let active = record.active else {
                    throw Failure.malformed("display activity is only partially reported")
                }
                if !active, backlight == "activeOn" || backlight == "activeDimmed" {
                    throw Failure.displayUnavailable("the display is changing")
                }
                if record.integrated, !active {
                    throw Failure.displayUnavailable("the integrated panel is inactive")
                }
            } else if record.integrated {
                switch backlight {
                case "activeOn", "activeDimmed": break
                case "off", "inactiveOn":
                    throw Failure.displayUnavailable("the integrated panel is inactive")
                case nil, "unknown":
                    throw Failure.displayUnavailable("the integrated panel's activity is unknown")
                default:
                    throw Failure.malformed("unknown backlight state")
                }
            }
        }

        let currentOrientation = try rotation(panel.object, "currentOrientation")
        let nativeOrientation = try rotation(panel.object, "nativeOrientation")
        guard nativeOrientation == .rot0 else {
            throw Failure.unsupportedNativeOrientation(nativeOrientation.rawValue)
        }
        let scale = try number(panel.object, "pointScale")
        guard scale > 0 else { throw Failure.malformed("invalid point scale") }
        return Self(
            displayIdentifier: panel.identifier, bounds: try rectangle(panel.object), pointScale: scale,
            currentOrientation: currentOrientation, nativeOrientation: nativeOrientation
        )
    }

    private static func bool(_ object: xpc_object_t, _ key: String) throws -> Bool? {
        guard let value = xpc_dictionary_get_value(object, key) else { return nil }
        guard xpc_get_type(value) == XPC_TYPE_BOOL else { throw Failure.malformed("invalid \(key)") }
        return xpc_bool_get_value(value)
    }

    private static func displayIdentity(_ record: xpc_object_t) throws -> String {
        // Physical-device reports identify the built-in panel by displayId;
        // uniqueId may exist only on external/wireless displays. Never select by
        // array position, and keep identities distinct from UUID-only reports.
        if let value = xpc_dictionary_get_value(record, "displayId") {
            let identifier: UInt64
            switch xpc_get_type(value) {
            case XPC_TYPE_UINT64:
                identifier = xpc_uint64_get_value(value)
            case XPC_TYPE_INT64:
                let number = xpc_int64_get_value(value)
                guard number > 0 else { throw Failure.malformed("invalid display ID") }
                identifier = UInt64(number)
            default:
                throw Failure.malformed("invalid display ID")
            }
            guard identifier > 0 else { throw Failure.malformed("empty display ID") }
            return "displayId:\(identifier)"
        }
        let identifier = try string(record, "uniqueId")
        guard !identifier.isEmpty else { throw Failure.malformed("empty display identity") }
        return "uniqueId:\(identifier)"
    }

    private static func optionalString(_ object: xpc_object_t, _ key: String) throws -> String? {
        guard xpc_dictionary_get_value(object, key) != nil else { return nil }
        return try string(object, key)
    }

    private static func string(_ object: xpc_object_t, _ key: String) throws -> String {
        guard let value = xpc_dictionary_get_value(object, key), xpc_get_type(value) == XPC_TYPE_STRING,
              let pointer = xpc_string_get_string_ptr(value), xpc_string_get_length(value) <= 1024 else {
            throw Failure.malformed("missing or invalid \(key)")
        }
        return String(cString: pointer)
    }

    private static func rotation(_ object: xpc_object_t, _ key: String) throws -> Rotation {
        guard let rotation = Rotation(rawValue: try string(object, key)) else {
            throw Failure.malformed("unknown \(key)")
        }
        return rotation
    }

    private static func number(_ object: xpc_object_t, _ key: String) throws -> Double {
        guard let value = xpc_dictionary_get_value(object, key) else {
            throw Failure.malformed("missing \(key)")
        }
        return try scalar(value)
    }

    private static func scalar(_ value: xpc_object_t) throws -> Double {
        let number: Double
        switch xpc_get_type(value) {
        case XPC_TYPE_DOUBLE: number = xpc_double_get_value(value)
        case XPC_TYPE_INT64: number = Double(xpc_int64_get_value(value))
        case XPC_TYPE_UINT64: number = Double(xpc_uint64_get_value(value))
        default: throw Failure.malformed("non-numeric coordinate")
        }
        guard number.isFinite else { throw Failure.malformed("non-finite coordinate") }
        return number
    }

    private static func rectangle(_ record: xpc_object_t) throws -> CGRect {
        guard let bounds = xpc_dictionary_get_value(record, "bounds"),
              xpc_get_type(bounds) == XPC_TYPE_ARRAY, xpc_array_get_count(bounds) == 2 else {
            throw Failure.malformed("invalid bounds")
        }
        var values: [Double] = []
        for index in 0..<2 {
            let pair = xpc_array_get_value(bounds, index)
            guard xpc_get_type(pair) == XPC_TYPE_ARRAY,
                  xpc_array_get_count(pair) == 2 else { throw Failure.malformed("invalid bounds") }
            for component in 0..<2 {
                let value = xpc_array_get_value(pair, component)
                values.append(try scalar(value))
            }
        }
        guard values[2] > 0, values[3] > 0 else { throw Failure.malformed("empty panel bounds") }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
