import CoreGraphics
import XCTest
@testable import StupidMirrorApp

final class PhysicalHIDWireTests: XCTestCase {
    func testBottomContactPreservesEdgeMetadataAndFullTimestampThroughRelease() {
        let timestamp: UInt64 = 0x0807_0605_0403_0201
        let down = PhysicalHIDWire.touchReport(
            point: CGPoint(x: 0.5, y: 1), contact: true, initialEdge: .bottom, timestampTicks: timestamp
        )
        let moved = PhysicalHIDWire.touchReport(
            point: CGPoint(x: 0.5, y: 0.5), contact: true, initialEdge: .bottom, timestampTicks: timestamp
        )
        let up = PhysicalHIDWire.touchReport(
            point: CGPoint(x: 0.5, y: 0.5), contact: false, initialEdge: .bottom, timestampTicks: timestamp
        )
        XCTAssertEqual(Array(down.prefix(8)), [9, 1, 5, 0xc2, 0, 0x80, 0xff, 0xff])
        XCTAssertEqual(up[3], 0x02)
        for report in [down, moved, up] {
            XCTAssertEqual(report.count, 58)
            XCTAssertEqual(Array(report[40..<45]), [2, 0, 0, 0, 0])
            XCTAssertEqual(Array(report[45..<53]), [1, 2, 3, 4, 5, 6, 7, 8])
            XCTAssertEqual(Array(report[53..<58]), [0x20, 0x04, 0, 0, 0])
        }
        let ordinary = PhysicalHIDWire.touchReport(point: CGPoint(x: 0.5, y: 0.5), contact: true)
        XCTAssertEqual(Array(ordinary[53..<58]), [0, 0, 0, 0, 0])
    }

    func testEdgeSelectionUsesDisplayPointsAndNearestEdgeWithoutMovingCoordinates() {
        let size = CGSize(width: 420, height: 912)
        XCTAssertEqual(PhysicalHIDContactEdge.beginning(at: CGPoint(x: 0.5, y: 902.0 / 912), displayPointSize: size), .bottom)
        XCTAssertNil(PhysicalHIDContactEdge.beginning(at: CGPoint(x: 0.5, y: 0.5), displayPointSize: size))
        XCTAssertNil(PhysicalHIDContactEdge.beginning(at: CGPoint(x: 0.5, y: 24.0 / 912), displayPointSize: size))
        XCTAssertEqual(PhysicalHIDContactEdge.beginning(at: CGPoint(x: 2.0 / 420, y: 902.0 / 912), displayPointSize: size), .left)
        let side = PhysicalHIDWire.touchReport(point: CGPoint(x: 1, y: 0.5), contact: true, initialEdge: .right)
        XCTAssertEqual(Array(side[53..<58]), [0x20, 0, 0x10, 0, 0])
    }
}
