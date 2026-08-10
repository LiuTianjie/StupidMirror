import MCP
@testable import StupidMirrorApp
import XCTest

final class MCPServerTests: XCTestCase {
    func testToolCatalogContainsTheApprovedSurfaceAndStrictSchemas() {
        let expected = Set([
            "list_devices", "refresh_devices", "get_device_status", "get_diagnostics",
            "start_mirror", "stop_mirror", "set_mirror_floating",
            "connect_control", "disconnect_control", "screenshot", "get_ui_tree",
            "tap", "double_tap", "long_press", "swipe", "scroll", "type_text",
            "press_button", "back", "app_switcher", "activate_app", "terminate_app"
        ])

        XCTAssertEqual(Set(StupidMirrorMCPToolCatalog.tools.map(\.name)), expected)
        XCTAssertEqual(StupidMirrorMCPToolCatalog.tools.count, expected.count)
        for tool in StupidMirrorMCPToolCatalog.tools {
            let schema = tool.inputSchema.objectValue
            XCTAssertEqual(schema?["type"]?.stringValue, "object", tool.name)
            XCTAssertEqual(schema?["additionalProperties"]?.boolValue, false, tool.name)
            XCTAssertEqual(tool.annotations.destructiveHint, false, tool.name)
            XCTAssertEqual(tool.annotations.openWorldHint, false, tool.name)
        }
    }

    func testCoordinateAndDurationSchemasExposeHardBounds() throws {
        let tap = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "tap" })
        let tapProperties = try XCTUnwrap(tap.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(tapProperties["x"]?.objectValue?["minimum"]?.doubleValue, 0)
        XCTAssertEqual(tapProperties["x"]?.objectValue?["maximum"]?.doubleValue, 1)

        let swipe = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "swipe" })
        let swipeProperties = try XCTUnwrap(swipe.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(swipeProperties["duration_ms"]?.objectValue?["minimum"]?.intValue, 50)
        XCTAssertEqual(swipeProperties["duration_ms"]?.objectValue?["maximum"]?.intValue, 5_000)
    }

    func testBearerValidationRejectsMissingAndWrongTokensAndAcceptsExactToken() {
        let box = MCPTokenBox(token: "0123456789abcdef")
        let validator = MCPBearerTokenValidator(tokenBox: box)
        let context = HTTPValidationContext(httpMethod: "POST", isInitializationRequest: true)

        XCTAssertEqual(
            validator.validate(HTTPRequest(method: "POST"), context: context)?.statusCode,
            401
        )
        XCTAssertEqual(
            validator.validate(
                HTTPRequest(method: "POST", headers: ["Authorization": "Bearer wrong"]),
                context: context
            )?.statusCode,
            401
        )
        XCTAssertNil(validator.validate(
            HTTPRequest(
                method: "POST",
                headers: ["authorization": "Bearer 0123456789abcdef"]
            ),
            context: context
        ))
    }

    func testTokenRotationInvalidatesOldAuthorizationImmediately() {
        let box = MCPTokenBox(token: "old-token")
        XCTAssertTrue(box.matches(authorizationHeader: "Bearer old-token"))
        box.replace(with: "new-token")
        XCTAssertFalse(box.matches(authorizationHeader: "Bearer old-token"))
        XCTAssertTrue(box.matches(authorizationHeader: "Bearer new-token"))
    }

    func testLocalOriginValidatorRejectsForeignHostAndOrigin() {
        let validator = OriginValidator.localhost(port: 17_373)
        let context = HTTPValidationContext(httpMethod: "POST", isInitializationRequest: true)

        XCTAssertNil(validator.validate(
            HTTPRequest(
                method: "POST",
                headers: ["Host": "127.0.0.1:17373", "Origin": "http://127.0.0.1:17373"]
            ),
            context: context
        ))
        XCTAssertEqual(
            validator.validate(
                HTTPRequest(
                    method: "POST",
                    headers: ["Host": "evil.example:17373", "Origin": "https://evil.example"]
                ),
                context: context
            )?.statusCode,
            421
        )
    }

    func testPerDeviceCommandLockSerializesWaiters() async {
        let lock = DeviceCommandLock()
        try? await lock.acquire("device")
        let waiter = Task {
            try await lock.acquire("device")
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(waiter.isCancelled)
        await lock.release("device")
        let acquired = try? await waiter.value
        XCTAssertEqual(acquired, true)
        await lock.release("device")
    }
}
