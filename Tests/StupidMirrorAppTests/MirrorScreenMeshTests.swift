@testable import StupidMirrorApp
import XCTest

final class MirrorScreenMeshTests: XCTestCase {
    // A projected screen with a narrowed, slanted top edge, like a folded panel.
    private let mesh = MirrorScreenMesh(
        vertices: [[0.2, 0.1, 0, 0], [0.8, 0.2, 1, 0], [0.9, 0.9, 1, 1], [0.1, 0.9, 0, 1]],
        triangles: [0, 1, 2, 0, 2, 3], frameAspectRatio: 1
    )

    func testProjectedTriangleMapsBackToFramebuffer() throws {
        let point = try XCTUnwrap(mesh.screenPoint(CGPoint(x: (0.2 + 0.8 + 0.9) / 3, y: (0.1 + 0.2 + 0.9) / 3), clamped: false))
        XCTAssertEqual(point.x, 2.0 / 3, accuracy: 0.000001)
        XCTAssertEqual(point.y, 1.0 / 3, accuracy: 0.000001)
        XCTAssertNil(mesh.screenPoint(CGPoint(x: 0, y: 0), clamped: false))
    }

    func testDragLeavingScreenClampsToEdgeWithoutSnappingToCorner() throws {
        let point = try XCTUnwrap(mesh.screenPoint(CGPoint(x: 0.5, y: 1.2), clamped: true))
        XCTAssertEqual(point.x, 0.5, accuracy: 0.000001)
        XCTAssertEqual(point.y, 1, accuracy: 0.000001)
    }
}
