import CoreGraphics
import Foundation

/// A single contact in normalized, top-left device coordinates.
enum TouchPhase: String, Codable, Sendable {
    case down, move, up, cancel
}

struct TouchEvent: Equatable, Sendable {
    var phase: TouchPhase
    var point: CGPoint
    /// Already translated system gestures share the same ordered input owner.
    /// This is an internal wire representation, never accepted directly from MCP.
    var nativeInput: HIDNativeInput? = nil

    var isValid: Bool {
        point.x.isFinite && point.y.isFinite
            && (0...1).contains(point.x) && (0...1).contains(point.y)
            && (nativeInput?.isValid ?? true)
    }
}

struct HIDInputReport: Equatable, Sendable {
    let serviceID: UInt64
    let data: Data

    var isValid: Bool {
        serviceID == 0x501 && !data.isEmpty && data.count <= 256
    }

    /// Cached releases keep their gesture state but use the actual cleanup time.
    /// Other report formats are left untouched until their layout is known.
    func withTimestampTicks(_ ticks: UInt64) -> Self {
        guard let reportID = data.first else { return self }
        let timestampOffset: Int
        switch (reportID, data.count) {
        case (7, 21): timestampOffset = 13
        case (15, 12), (16, 12): timestampOffset = 4
        default: return self
        }
        var updated = data
        for byte in 0..<8 {
            updated[updated.startIndex + timestampOffset + byte] = UInt8(truncatingIfNeeded: ticks >> (byte * 8))
        }
        return Self(serviceID: serviceID, data: updated)
    }
}

/// A single host event can produce multiple reports. Preserve their order and
/// the cancellation state of all gesture components (scroll/scale/rotation).
struct HIDNativeInput: Equatable, Sendable {
    var reports: [HIDInputReport]
    var cancellationReports: [HIDInputReport]

    var isValid: Bool {
        reports.count <= 8 && cancellationReports.count <= 8
            && reports.allSatisfy(\.isValid) && cancellationReports.allSatisfy(\.isValid)
    }
}

/// System input is independent of capture and semantic automation. Calls are
/// ordered by the owning touch session. A completed flush only confirms the
/// transport drained; it does not prove that the application handled a touch.
protocol TouchInputBackend: AnyObject, Sendable {
    var name: String { get }
    var supportsNativeGestures: Bool { get }
    func send(_ event: TouchEvent) async throws
    func flush() async throws
    func close() async
}

extension TouchInputBackend {
    var supportsNativeGestures: Bool { false }
}
