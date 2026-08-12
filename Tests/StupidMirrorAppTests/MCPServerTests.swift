import MCP
@testable import StupidMirrorApp
import XCTest

final class MCPServerTests: XCTestCase {
    func testToolCatalogContainsTheApprovedSurfaceAndStrictSchemas() {
        let expected = Set([
            "list_devices", "refresh_devices", "get_device_status", "get_diagnostics",
            "start_mirror", "stop_mirror", "set_mirror_floating",
            "connect_control", "disconnect_control", "screenshot", "get_ui_tree",
            "observe_screen", "find_element", "find_any_element", "tap_text",
            "tap_element", "highlight_elements", "highlight_clickable_elements", "clear_highlights",
            "wait_for", "assert_screen",
            "tap", "double_tap", "long_press", "swipe", "scroll", "type_text", "clear_text", "replace_text",
            "press_button", "back", "app_switcher", "activate_app", "terminate_app"
        ])

        XCTAssertEqual(Set(StupidMirrorMCPToolCatalog.tools.map(\.name)), expected)
        XCTAssertEqual(StupidMirrorMCPToolCatalog.tools.count, expected.count)
        for tool in StupidMirrorMCPToolCatalog.tools {
            let schema = tool.inputSchema.objectValue
            XCTAssertEqual(schema?["type"]?.stringValue, "object", tool.name)
            XCTAssertEqual(schema?["additionalProperties"]?.boolValue, false, tool.name)
            XCTAssertEqual(tool.annotations.openWorldHint, false, tool.name)
        }
        let destructive = Set([
            "tap_text", "tap_element", "tap", "double_tap", "long_press", "swipe", "scroll",
            "type_text", "clear_text", "replace_text", "press_button", "back", "app_switcher", "activate_app", "terminate_app"
        ])
        for tool in StupidMirrorMCPToolCatalog.tools {
            XCTAssertEqual(tool.annotations.destructiveHint, destructive.contains(tool.name), tool.name)
        }
    }

    func testSemanticObservationSchemasExposeSafeDefaultsAndBounds() throws {
        let observe = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "observe_screen" })
        let observeProperties = try XCTUnwrap(observe.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(observeProperties["include_image"]?.objectValue?["default"]?.boolValue, true)
        XCTAssertEqual(observeProperties["include_accessibility"]?.objectValue?["default"]?.boolValue, false)
        XCTAssertEqual(observeProperties["include_ocr"]?.objectValue?["default"]?.boolValue, false)
        XCTAssertEqual(observeProperties["ocr_mode"]?.objectValue?["default"]?.stringValue, "fast")
        XCTAssertEqual(
            observeProperties["ocr_languages"]?.objectValue?["default"]?.arrayValue?.compactMap(\.stringValue),
            ["zh-Hans", "en-US"]
        )
        XCTAssertEqual(observeProperties["ocr_languages"]?.objectValue?["maxItems"]?.intValue, 8)
        XCTAssertEqual(observe.annotations.readOnlyHint, true)

        let find = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "find_element" })
        let findProperties = try XCTUnwrap(find.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(findProperties["include_ocr"]?.objectValue?["default"]?.boolValue, true)

        let findAny = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "find_any_element" })
        let findAnyProperties = try XCTUnwrap(findAny.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(findAnyProperties["queries"]?.objectValue?["minItems"]?.intValue, 1)
        XCTAssertEqual(findAnyProperties["queries"]?.objectValue?["maxItems"]?.intValue, 16)
        XCTAssertEqual(findAny.annotations.readOnlyHint, true)

        let tapText = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "tap_text" })
        let tapTextProperties = try XCTUnwrap(tapText.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(tapTextProperties["queries"]?.objectValue?["maxItems"]?.intValue, 16)
        XCTAssertEqual(tapText.annotations.destructiveHint, true)

        let clearText = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "clear_text" })
        XCTAssertNil(clearText.inputSchema.objectValue?["required"])
        XCTAssertEqual(clearText.annotations.destructiveHint, true)

        let replaceText = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "replace_text" })
        XCTAssertEqual(
            replaceText.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue),
            ["text"]
        )
        XCTAssertEqual(replaceText.annotations.destructiveHint, true)

        let highlightElements = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "highlight_elements" })
        let highlightProperties = try XCTUnwrap(highlightElements.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(highlightProperties["element_ids"]?.objectValue?["minItems"]?.intValue, 1)
        XCTAssertNil(highlightProperties["element_ids"]?.objectValue?["maxItems"])
        XCTAssertEqual(highlightProperties["duration_seconds"]?.objectValue?["default"]?.doubleValue, 8)
        XCTAssertEqual(highlightProperties["duration_seconds"]?.objectValue?["maximum"]?.doubleValue, 60)
        XCTAssertEqual(highlightElements.annotations.destructiveHint, false)
        XCTAssertEqual(highlightElements.annotations.idempotentHint, true)

        let highlightClickable = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "highlight_clickable_elements" })
        let clickableProperties = try XCTUnwrap(highlightClickable.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertNil(clickableProperties["maximum_elements"])
        XCTAssertEqual(highlightClickable.annotations.destructiveHint, false)
        XCTAssertEqual(highlightClickable.annotations.idempotentHint, true)

        let wait = try XCTUnwrap(StupidMirrorMCPToolCatalog.tools.first { $0.name == "wait_for" })
        let waitProperties = try XCTUnwrap(wait.inputSchema.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(waitProperties["timeout_seconds"]?.objectValue?["maximum"]?.doubleValue, 60)
        XCTAssertEqual(wait.annotations.readOnlyHint, true)
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
