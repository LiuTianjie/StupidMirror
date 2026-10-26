import AppKit
import Darwin

/// Converts individual host gestures without retaining or synthesizing gesture state.
enum NativeHIDGestureTranslator {
    enum Kind: CaseIterable, Hashable, Sendable {
        case scroll, scale, rotation

        fileprivate var eventType: NSEvent.EventType {
            switch self {
            case .scroll: .scrollWheel
            case .scale: .magnify
            case .rotation: .rotate
            }
        }
    }

    enum TranslationError: LocalizedError {
        case unexpectedEventType
        case invalidTimestamp
        case invalidTimebase

        var errorDescription: String? {
            switch self {
            case .unexpectedEventType: "The event does not contain the requested gesture."
            case .invalidTimestamp: "The gesture timestamp is invalid."
            case .invalidTimebase: "The system clock timebase is invalid."
            }
        }
    }

    struct Timebase: Equatable, Sendable {
        let numerator: UInt32
        let denominator: UInt32

        static let system: Self = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return Self(numerator: info.numer, denominator: info.denom)
        }()
    }

    /// The source's raw and accelerated deltas are separate quantities.
    /// The sender identifies the source event, never the destination service.
    struct CGScrollValues: Sendable {
        let senderID: Int64
        let rawDelta: CGPoint
        let acceleratedDelta: CGPoint
        let directionFlag: Int64
        let momentumOptions: Int64
    }

    private static let serviceID: UInt64 = 0x501

    @MainActor
    static func report(for event: NSEvent, kind: Kind) throws -> HIDInputReport {
        guard event.type == kind.eventType else { throw TranslationError.unexpectedEventType }
        switch kind {
        case .scroll:
            return try scrollReport(
                scrollingDelta: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
                phase: event.phase,
                momentumPhase: event.momentumPhase,
                timestamp: event.timestamp,
                cgValues: event.cgEvent.flatMap(scrollValues)
            )
        case .scale:
            return try scaleReport(magnification: Double(event.magnification), phase: event.phase)
        case .rotation:
            return try rotationReport(degrees: Double(event.rotation), phase: event.phase)
        }
    }

    static func phase(_ phase: NSEvent.Phase) -> UInt8 {
        var result: UInt8 = 0
        if phase.contains(.began) { result |= 0x01 }
        if phase.contains(.stationary) || phase.contains(.changed) { result |= 0x02 }
        if phase.contains(.ended) { result |= 0x04 }
        if phase.contains(.cancelled) { result |= 0x08 }
        if phase.contains(.mayBegin) { result |= 0x80 }
        return result
    }

    static func scrollReport(
        scrollingDelta: CGPoint,
        phase sourcePhase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase,
        timestamp: TimeInterval,
        cgValues: CGScrollValues? = nil,
        timebase: Timebase = .system
    ) throws -> HIDInputReport {
        var rawDelta = scrollingDelta
        var acceleratedDelta = CGPoint.zero
        var momentumFlags = momentum(momentumPhase)
        // Zero has no source metadata; a malformed negative sender also falls back.
        if let cgValues, cgValues.senderID > 0 {
            let direction: CGFloat = cgValues.directionFlag == 1 ? -1 : 1
            rawDelta = CGPoint(x: cgValues.rawDelta.x * direction, y: cgValues.rawDelta.y * direction)
            acceleratedDelta = CGPoint(
                x: cgValues.acceleratedDelta.x * direction,
                y: cgValues.acceleratedDelta.y * direction
            )
            if cgValues.momentumOptions & 0x10 != 0 { momentumFlags |= 0x10 }
        }
        return HIDInputReport(
            serviceID: serviceID,
            data: try PhysicalHIDWire.scrollReport(
                rawDelta: rawDelta,
                acceleratedDelta: acceleratedDelta,
                phase: phase(sourcePhase),
                momentum: momentumFlags,
                timestampTicks: timestampTicks(for: timestamp, timebase: timebase)
            )
        )
    }

    static func scaleReport(
        magnification: Double,
        phase sourcePhase: NSEvent.Phase,
        timestampTicks: UInt64 = mach_absolute_time()
    ) throws -> HIDInputReport {
        HIDInputReport(
            serviceID: serviceID,
            data: try PhysicalHIDWire.scaleReport(
                magnification: magnification, phase: phase(sourcePhase), timestampTicks: timestampTicks
            )
        )
    }

    static func rotationReport(
        degrees: Double,
        phase sourcePhase: NSEvent.Phase,
        timestampTicks: UInt64 = mach_absolute_time()
    ) throws -> HIDInputReport {
        HIDInputReport(
            serviceID: serviceID,
            data: try PhysicalHIDWire.rotationReport(
                radians: degrees * (.pi / 180), phase: phase(sourcePhase), timestampTicks: timestampTicks
            )
        )
    }

    static func cancellationReport(
        kind: Kind, timestampTicks: UInt64 = mach_absolute_time()
    ) throws -> HIDInputReport {
        switch kind {
        case .scroll:
            return HIDInputReport(
                serviceID: serviceID,
                data: try PhysicalHIDWire.scrollReport(
                    rawDelta: .zero, phase: phase(.cancelled), momentum: 0x04, timestampTicks: timestampTicks
                )
            )
        case .scale:
            return try scaleReport(magnification: 0, phase: .cancelled, timestampTicks: timestampTicks)
        case .rotation:
            return try rotationReport(degrees: 0, phase: .cancelled, timestampTicks: timestampTicks)
        }
    }

    static func timestampTicks(for seconds: TimeInterval, timebase: Timebase = .system) throws -> UInt64 {
        guard seconds.isFinite, seconds >= 0 else { throw TranslationError.invalidTimestamp }
        guard timebase.numerator > 0, timebase.denominator > 0 else { throw TranslationError.invalidTimebase }
        let ticks = ((seconds * 1_000_000_000) * Double(timebase.denominator) / Double(timebase.numerator))
            .rounded(.toNearestOrAwayFromZero)
        if ticks >= Double(UInt64.max) { return .max }
        return UInt64(ticks)
    }

    private static func momentum(_ phase: NSEvent.Phase) -> UInt8 {
        switch phase {
        case .began, .mayBegin: 0x02
        case .changed: 0x01
        case .ended, .cancelled: 0x04
        default: 0
        }
    }

    private static func scrollValues(_ event: CGEvent) -> CGScrollValues? {
        func integer(_ field: UInt32) -> Int64 {
            event.getIntegerValueField(CGEventField(rawValue: field)!)
        }
        func double(_ field: UInt32) -> Double {
            event.getDoubleValueField(CGEventField(rawValue: field)!)
        }
        let senderID = integer(87)
        guard senderID > 0 else { return nil }
        return CGScrollValues(
            senderID: senderID,
            rawDelta: CGPoint(x: double(177), y: double(178)),
            acceleratedDelta: CGPoint(x: double(175), y: double(176)),
            directionFlag: integer(137),
            momentumOptions: integer(173)
        )
    }
}
