import AppKit
import XCTest
@testable import StupidMirrorApp

@MainActor
final class NativeHIDGestureTranslatorTests: XCTestCase {
    private typealias Translator = NativeHIDGestureTranslator
    private let timebase = Translator.Timebase(numerator: 125, denominator: 3)

    func testPhaseMappingCombinesAllPresentBits() {
        let cases: [(NSEvent.Phase, UInt8)] = [
            ([], 0), (.began, 1), (.stationary, 2), (.changed, 2),
            (.ended, 4), (.cancelled, 8), (.mayBegin, 128),
            ([.began, .stationary, .changed, .ended, .cancelled, .mayBegin], 0x8f),
            (NSEvent.Phase(rawValue: 0x40), 0),
        ]
        for (source, expected) in cases {
            XCTAssertEqual(Translator.phase(source), expected, "Source phase: \(source.rawValue)")
        }
    }

    func testEnrichedScrollPreservesIndependentAxesAndDirection() throws {
        let report = try Translator.scrollReport(
            scrollingDelta: CGPoint(x: 99, y: 99),
            phase: [.changed, .ended],
            momentumPhase: .changed,
            timestamp: 1.25,
            cgValues: .init(
                senderID: 12,
                rawDelta: CGPoint(x: 1.5, y: -2.5),
                acceleratedDelta: CGPoint(x: 0.5, y: -0.25),
                directionFlag: 1,
                momentumOptions: 0x10
            ),
            timebase: timebase
        )
        XCTAssertEqual(report.serviceID, 0x501)
        XCTAssertEqual(Array(report.data), [
            7, 6, 0x11, 0xfe, 3,
            0, 0x80, 0xff, 0xff,
            0, 0x40, 0, 0,
            0x80, 0xc3, 0xc9, 1, 0, 0, 0, 0,
        ])

        let otherDirectionFlag = try Translator.scrollReport(
            scrollingDelta: .zero, phase: .changed, momentumPhase: [], timestamp: 0,
            cgValues: .init(
                senderID: 12,
                rawDelta: CGPoint(x: 1.5, y: -2.5),
                acceleratedDelta: CGPoint(x: 0.5, y: -0.25),
                directionFlag: 2,
                momentumOptions: 0
            ),
            timebase: timebase
        )
        XCTAssertEqual(Array(otherDirectionFlag.data[3..<5]), [2, 0xfd])
        XCTAssertEqual(int32(otherDirectionFlag.data, at: 5), 32_768)
        XCTAssertEqual(int32(otherDirectionFlag.data, at: 9), -16_384)
    }

    func testFallbackIgnoresCGDeltasDirectionAndMomentumOptionsWithoutValidSender() throws {
        let senders: [Int64?] = [nil, 0, -1]
        for sender in senders {
            let source = sender.map {
                Translator.CGScrollValues(
                    senderID: $0,
                    rawDelta: CGPoint(x: 99, y: 99),
                    acceleratedDelta: CGPoint(x: 99, y: 99),
                    directionFlag: 1,
                    momentumOptions: 0x10
                )
            }
            let report = try Translator.scrollReport(
                scrollingDelta: CGPoint(x: 2.5, y: -3.5),
                phase: .changed, momentumPhase: .changed, timestamp: 0,
                cgValues: source, timebase: timebase
            )
            XCTAssertEqual(Array(report.data.prefix(13)), [7, 2, 1, 3, 0xfc, 0, 0, 0, 0, 0, 0, 0, 0])
        }
    }

    func testMomentumMatchesWholePhaseValuesInsteadOfCombiningBits() throws {
        let cases: [(NSEvent.Phase, UInt8)] = [
            ([], 0), (.began, 2), (.mayBegin, 2), (.changed, 1),
            (.ended, 4), (.cancelled, 4), (.stationary, 0), ([.began, .changed], 0),
        ]
        for (source, expected) in cases {
            let report = try Translator.scrollReport(
                scrollingDelta: .zero, phase: [], momentumPhase: source, timestamp: 0, timebase: timebase
            )
            XCTAssertEqual(report.data[2], expected, "Momentum phase: \(source.rawValue)")
        }
    }

    func testTimestampUsesMachTimebaseAndRoundsHalfAwayFromZero() throws {
        XCTAssertEqual(try Translator.timestampTicks(for: 1.25, timebase: timebase), 30_000_000)
        let oneSecondPerTick = Translator.Timebase(numerator: 1_000_000_000, denominator: 1)
        XCTAssertEqual(try Translator.timestampTicks(for: 1.49, timebase: oneSecondPerTick), 1)
        XCTAssertEqual(try Translator.timestampTicks(for: 1.5, timebase: oneSecondPerTick), 2)
        XCTAssertEqual(try Translator.timestampTicks(for: 2.5, timebase: oneSecondPerTick), 3)
        XCTAssertEqual(try Translator.timestampTicks(for: .greatestFiniteMagnitude, timebase: timebase), .max)
        XCTAssertThrowsError(try Translator.timestampTicks(for: -.infinity, timebase: timebase))
        XCTAssertThrowsError(try Translator.timestampTicks(for: .nan, timebase: timebase))
        XCTAssertThrowsError(try Translator.timestampTicks(for: -1, timebase: timebase))
        XCTAssertThrowsError(try Translator.timestampTicks(for: 1, timebase: .init(numerator: 0, denominator: 1)))
        XCTAssertThrowsError(try Translator.timestampTicks(for: 1, timebase: .init(numerator: 1, denominator: 0)))
    }

    func testScaleAndRotationQuantizePerEventDeltasAndPreserveTimestamp() throws {
        let timestamp: UInt64 = 0x0807_0605_0403_0201
        let cases: [(Double, Int16)] = [
            (0.5, 16_383), (-0.5, -16_384), (1, .max), (-1, .min), (2, .max), (-2, .min),
        ]
        for (delta, expected) in cases {
            let report = try Translator.scaleReport(magnification: delta, phase: .changed, timestampTicks: timestamp)
            XCTAssertEqual(report.serviceID, 0x501)
            XCTAssertEqual(Array(report.data.prefix(2)), [15, 2])
            XCTAssertEqual(report.data.count, 12)
            XCTAssertEqual(int16(report.data, at: 2), expected)
            XCTAssertEqual(Array(report.data[4..<12]), [1, 2, 3, 4, 5, 6, 7, 8])
        }
        let rotations: [(Double, Int16)] = [(15, 8_578), (-15, -8_578), (90, .max), (-90, .min)]
        for (degrees, expected) in rotations {
            let report = try Translator.rotationReport(degrees: degrees, phase: .began, timestampTicks: timestamp)
            XCTAssertEqual(report.serviceID, 0x501)
            XCTAssertEqual(Array(report.data.prefix(2)), [16, 1])
            XCTAssertEqual(report.data.count, 12)
            XCTAssertEqual(int16(report.data, at: 2), expected)
            XCTAssertEqual(Array(report.data[4..<12]), [1, 2, 3, 4, 5, 6, 7, 8])
        }
        XCTAssertThrowsError(try Translator.scaleReport(magnification: .nan, phase: .changed))
        XCTAssertThrowsError(try Translator.rotationReport(degrees: .infinity, phase: .changed))
    }

    func testScrollQuantizationSaturatesFiniteDeltasAndRejectsInvalidRawData() throws {
        let report = try PhysicalHIDWire.scrollReport(
            rawDelta: CGPoint(x: 200.5, y: -200.5),
            acceleratedDelta: CGPoint(x: Double.greatestFiniteMagnitude, y: -Double.greatestFiniteMagnitude),
            phase: 0xff, momentum: 0xff, timestampTicks: 0
        )
        XCTAssertEqual(Array(report.prefix(5)), [7, 0x8f, 0xff, 127, 128])
        XCTAssertEqual(int32(report, at: 5), .max)
        XCTAssertEqual(int32(report, at: 9), .min)

        let invalidAcceleration = try PhysicalHIDWire.scrollReport(
            rawDelta: .zero, acceleratedDelta: CGPoint(x: Double.nan, y: Double.infinity),
            phase: 0, momentum: 0, timestampTicks: 0
        )
        XCTAssertEqual(Array(invalidAcceleration[5..<13]), Array(repeating: 0, count: 8))
        XCTAssertThrowsError(try PhysicalHIDWire.scrollReport(
            rawDelta: CGPoint(x: Double.nan, y: 0), phase: 0, momentum: 0
        ))
        XCTAssertThrowsError(try PhysicalHIDWire.scrollReport(
            rawDelta: CGPoint(x: Double.infinity, y: 0), phase: 0, momentum: 0
        ))
    }

    func testCancellationReportsCarryZeroDeltasAndTerminateMomentum() throws {
        let timestamp: UInt64 = 0x0807_0605_0403_0201
        for kind in Translator.Kind.allCases {
            let report = try Translator.cancellationReport(kind: kind, timestampTicks: timestamp)
            XCTAssertEqual(report.serviceID, 0x501)
            XCTAssertEqual(report.data[1], 8)
            if kind == .scroll {
                XCTAssertEqual(report.data[0], 7)
                XCTAssertEqual(report.data[2], 4)
                XCTAssertEqual(Array(report.data[3..<13]), Array(repeating: 0, count: 10))
                XCTAssertEqual(Array(report.data[13..<21]), [1, 2, 3, 4, 5, 6, 7, 8])
            } else {
                XCTAssertEqual(report.data[0], kind == .scale ? 15 : 16)
                XCTAssertEqual(int16(report.data, at: 2), 0)
                XCTAssertEqual(Array(report.data[4..<12]), [1, 2, 3, 4, 5, 6, 7, 8])
            }
        }
    }

    func testNSEventExtractionReadsCGScrollFieldsAndRejectsMismatchedKind() throws {
        let source = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 99, wheel2: 99, wheel3: 0
        ))
        source.timestamp = 1_500_000_000
        source.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.changed.rawValue))
        source.setIntegerValueField(CGEventField(rawValue: 87)!, value: 123)
        source.setDoubleValueField(CGEventField(rawValue: 177)!, value: 32.5)
        source.setDoubleValueField(CGEventField(rawValue: 178)!, value: -12.5)
        source.setDoubleValueField(CGEventField(rawValue: 175)!, value: 0.25)
        source.setDoubleValueField(CGEventField(rawValue: 176)!, value: -0.5)
        source.setIntegerValueField(CGEventField(rawValue: 137)!, value: 1)
        source.setIntegerValueField(CGEventField(rawValue: 173)!, value: 0x10)
        let event = try XCTUnwrap(NSEvent(cgEvent: source))
        let expected = try Translator.scrollReport(
            scrollingDelta: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
            phase: event.phase, momentumPhase: event.momentumPhase, timestamp: event.timestamp,
            cgValues: .init(
                senderID: 123,
                rawDelta: CGPoint(x: 32.5, y: -12.5),
                acceleratedDelta: CGPoint(x: 0.25, y: -0.5),
                directionFlag: 1,
                momentumOptions: 0x10
            )
        )
        XCTAssertEqual(try Translator.report(for: event, kind: .scroll), expected)
        XCTAssertThrowsError(try Translator.report(for: event, kind: .scale))
    }

    private func int16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
    }

    private func int32(_ data: Data, at offset: Int) -> Int32 {
        let bits = data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << ($1.offset * 8))
        }
        return Int32(bitPattern: bits)
    }
}
