@testable import StupidMirrorApp
import CoreGraphics
import XCTest
import XPC

final class SimulatorHIDBackendTests: XCTestCase {
    func testRoutesActiveDuoScreenByIdentityInsteadOfPrimaryOrArrayOrder() throws {
        let output = report([
            display(id: "cover", active: false, backlight: "off", primary: true),
            display(id: "external", active: true, integrated: false),
            display(id: "inner", active: true, primary: false),
        ])
        let parsed = try SimulatorHIDDisplayReport(output)
        let targets = try SimulatorHIDDisplayReport.touchscreenTargets(services([
            touchscreen(id: "inner", serviceID: 0x152),
            touchscreen(id: "cover", serviceID: 0x11D),
        ]))

        XCTAssertEqual(parsed.integratedCount, 2)
        XCTAssertEqual(parsed.selected.id, "inner")
        XCTAssertEqual(try parsed.resolved(using: targets).target, 82)
        XCTAssertThrowsError(try parsed.resolved(using: ["cover": 29]))
    }

    func testRejectsStaleAmbiguousTransitioningAndPartialDisplayReports() {
        let invalid = [
            report([display(id: "cover")], current: false),
            report([display(id: "cover"), display(id: "inner")]),
            report([display(id: "cover", active: false), display(id: "inner")]),
            report([display(id: "cover", active: nil, backlight: "off"), display(id: "inner")]),
            report([display(id: "same", active: false, backlight: "off"), display(id: "same")]),
            report([display(id: "cover", active: nil, backlight: "unknown"), display(id: "inner", active: nil)]),
            report([display(id: "cover", orientation: "rot45")]),
        ]
        for output in invalid {
            XCTAssertThrowsError(try SimulatorHIDDisplayReport(output))
        }
    }

    func testUnidentifiedLegacyReportRequiresExactlyOneIntegratedScreen() throws {
        let legacy = display(id: nil, active: nil, backlight: "unknown")
        let single = try SimulatorHIDDisplayReport(report([legacy]))
        XCTAssertEqual(try single.resolved(using: [:]).target, 0)
        XCTAssertThrowsError(try SimulatorHIDDisplayReport(report([
            legacy, display(id: nil, active: nil, backlight: nil),
        ])))
    }

    func testNormalizesAllFourCurrentOrientationsIntoPanelCoordinates() throws {
        let cases: [(String, CGPoint)] = [
            ("rot0", CGPoint(x: 0.17, y: 0.63)),
            ("rot90", CGPoint(x: 0.63, y: 0.83)),
            ("rot180", CGPoint(x: 0.83, y: 0.37)),
            ("rot270", CGPoint(x: 0.37, y: 0.17)),
        ]
        for (orientation, expected) in cases {
            let parsed = try SimulatorHIDDisplayReport(report([display(id: "screen", orientation: orientation)]))
            let geometry = try parsed.resolved(using: [:])
            let actual = geometry.panelPoint(CGPoint(x: 0.17, y: 0.63))
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, orientation)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, orientation)
        }
    }

    func testTouchscreenMappingRejectsAliasesMissingIdentityAndCollisions() {
        let invalid = [
            services([touchscreen(id: "screen", serviceID: 0x100)]),
            services([touchscreen(id: "screen", serviceID: 0x201)]),
            services([touchscreen(id: nil, serviceID: 0x101)]),
            services([touchscreen(id: "same", serviceID: 0x101), touchscreen(id: "same", serviceID: 0x102)]),
            services([touchscreen(id: "a", serviceID: 0x101), touchscreen(id: "b", serviceID: 0x101)]),
        ]
        for reply in invalid {
            XCTAssertThrowsError(try SimulatorHIDDisplayReport.touchscreenTargets(reply))
        }
    }

    private func report(_ records: [xpc_object_t], current: Bool = true) -> xpc_object_t {
        let output = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(output, "current", current)
        xpc_dictionary_set_value(output, "displays", array(records))
        return output
    }

    private func display(
        id: String?, active: Bool? = true, backlight: String? = "activeOn",
        orientation: String = "rot0", primary: Bool = false, integrated: Bool = true
    ) -> xpc_object_t {
        let record = xpc_dictionary_create(nil, nil, 0)
        if let id { xpc_dictionary_set_string(record, "uniqueId", id) }
        if let active { xpc_dictionary_set_bool(record, "active", active) }
        if let backlight { xpc_dictionary_set_string(record, "backlightState", backlight) }
        xpc_dictionary_set_string(record, "currentOrientation", orientation)
        xpc_dictionary_set_bool(record, "primary", primary)
        xpc_dictionary_set_int64(record, "pointScale", 3)
        xpc_dictionary_set_value(record, "bounds", array([
            array([xpc_double_create(0), xpc_double_create(0)]),
            array([xpc_double_create(1398), xpc_double_create(2034)]),
        ]))
        let type = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(type, integrated ? "integrated" : "external", xpc_dictionary_create(nil, nil, 0))
        xpc_dictionary_set_value(record, "type", type)
        return record
    }

    private func services(_ records: [xpc_object_t]) -> xpc_object_t {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(reply, "connectedServices", array(records))
        return reply
    }

    private func touchscreen(id: String?, serviceID: UInt64) -> xpc_object_t {
        let record = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(record, "PrimaryUsagePage", 0x0D)
        xpc_dictionary_set_uint64(record, "PrimaryUsage", 0x04)
        xpc_dictionary_set_uint64(record, "_ServiceID", serviceID)
        if let id { xpc_dictionary_set_string(record, "displayUUID", id) }
        return record
    }

    private func array(_ values: [xpc_object_t]) -> xpc_object_t {
        let result = xpc_array_create(nil, 0)
        for value in values { xpc_array_append_value(result, value) }
        return result
    }
}
