import Foundation
import MCP

enum StupidMirrorMCPToolCatalog {
    static let tools: [Tool] = [
        tool("list_devices", "List connected and reconnecting iPhones with mirror and control state.", readOnly: true),
        tool("refresh_devices", "Refresh iPhone discovery and return the updated device list."),
        tool("get_device_status", "Get detailed state for one iPhone.", deviceProperties, readOnly: true),
        tool("get_diagnostics", "Get StupidMirror runtime, permission, Appium, WDA, and device diagnostics.", readOnly: true),
        tool("start_mirror", "Open and start the iPhone mirror. Unactivated installations can mirror one device at a time.", deviceProperties),
        tool("stop_mirror", "Stop and close the iPhone mirror.", deviceProperties, idempotent: true),
        tool(
            "set_mirror_floating",
            "Set whether the mirror window stays above normal windows.",
            deviceProperties.merging(["floating": boolean("Whether the mirror floats above other windows.")]) { _, new in new },
            required: ["floating"],
            idempotent: true
        ),
        tool("connect_control", "Activated feature: start or reuse Appium and WDA, then wait until iPhone control is ready.", deviceProperties),
        tool("disconnect_control", "Delete the iPhone control session.", deviceProperties, idempotent: true),
        tool("screenshot", "Capture the current iPhone screen as a native PNG. Control must be ready.", deviceProperties, readOnly: true),
        tool("get_ui_tree", "Read the current iPhone accessibility hierarchy as XML. Control must be ready.", deviceProperties, readOnly: true),
        pointTool("tap", "Tap at normalized screen coordinates."),
        pointTool("double_tap", "Double tap at normalized screen coordinates."),
        tool(
            "long_press",
            "Press and hold normalized screen coordinates.",
            deviceProperties.merging([
                "x": coordinate("Normalized horizontal coordinate."),
                "y": coordinate("Normalized vertical coordinate."),
                "duration_seconds": number("Hold duration from 0.5 to 10 seconds.", minimum: 0.5, maximum: 10, defaultValue: 1)
            ]) { _, new in new },
            required: ["x", "y"]
        ),
        tool(
            "swipe",
            "Swipe from one normalized point to another.",
            deviceProperties.merging([
                "start_x": coordinate("Normalized start x."),
                "start_y": coordinate("Normalized start y."),
                "end_x": coordinate("Normalized end x."),
                "end_y": coordinate("Normalized end y."),
                "duration_ms": integer("Duration from 50 to 5000 milliseconds.", minimum: 50, maximum: 5_000, defaultValue: 300)
            ]) { _, new in new },
            required: ["start_x", "start_y", "end_x", "end_y"]
        ),
        tool(
            "scroll",
            "Scroll content in a semantic direction. For down, the finger swipes upward.",
            deviceProperties.merging([
                "direction": enumeration("Scroll direction.", values: AutomationScrollDirection.allCases.map(\.rawValue)),
                "distance": number("Normalized scroll distance.", minimum: 0.05, maximum: 0.9, defaultValue: 0.5),
                "center_x": coordinate("Gesture center x.", defaultValue: 0.5),
                "center_y": coordinate("Gesture center y.", defaultValue: 0.5)
            ]) { _, new in new },
            required: ["direction"]
        ),
        tool(
            "type_text",
            "Type text into the currently focused iPhone field.",
            deviceProperties.merging(["text": string("Text to type, up to 10,000 UTF-8 bytes.")]) { _, new in new },
            required: ["text"]
        ),
        tool(
            "press_button",
            "Press an iPhone hardware-style button.",
            deviceProperties.merging([
                "button": enumeration("Button name.", values: ["home", "volume_up", "volume_down"])
            ]) { _, new in new },
            required: ["button"]
        ),
        tool("back", "Tap the conventional top-left iOS back location.", deviceProperties),
        tool("app_switcher", "Open the iOS app switcher using a best-effort double Home action.", deviceProperties),
        tool(
            "activate_app",
            "Launch or foreground an installed iPhone app by bundle identifier.",
            deviceProperties.merging(["bundle_id": string("iPhone app bundle identifier.")]) { _, new in new },
            required: ["bundle_id"]
        ),
        tool(
            "terminate_app",
            "Terminate an installed iPhone app by bundle identifier.",
            deviceProperties.merging(["bundle_id": string("iPhone app bundle identifier.")]) { _, new in new },
            required: ["bundle_id"]
        )
    ]

    private static let deviceProperties: [String: Value] = [
        "device_id": string("Optional StupidMirror device_id or iPhone UDID. Omit only when one iPhone is connected.")
    ]

    private static func pointTool(_ name: String, _ description: String) -> Tool {
        tool(
            name,
            description,
            deviceProperties.merging([
                "x": coordinate("Normalized horizontal coordinate."),
                "y": coordinate("Normalized vertical coordinate.")
            ]) { _, new in new },
            required: ["x", "y"]
        )
    }

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Value] = [:],
        required: [String] = [],
        readOnly: Bool = false,
        idempotent: Bool = false
    ) -> Tool {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(Value.string))
        }
        return Tool(
            name: name,
            title: name.replacingOccurrences(of: "_", with: " ").capitalized,
            description: description,
            inputSchema: .object(schema),
            annotations: .init(
                readOnlyHint: readOnly,
                destructiveHint: false,
                idempotentHint: idempotent,
                openWorldHint: false
            )
        )
    }

    private static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    private static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    private static func coordinate(_ description: String, defaultValue: Double? = nil) -> Value {
        number(description, minimum: 0, maximum: 1, defaultValue: defaultValue)
    }

    private static func number(
        _ description: String,
        minimum: Double,
        maximum: Double,
        defaultValue: Double? = nil
    ) -> Value {
        var value: [String: Value] = [
            "type": "number",
            "description": .string(description),
            "minimum": .double(minimum),
            "maximum": .double(maximum)
        ]
        if let defaultValue { value["default"] = .double(defaultValue) }
        return .object(value)
    }

    private static func integer(
        _ description: String,
        minimum: Int,
        maximum: Int,
        defaultValue: Int
    ) -> Value {
        [
            "type": "integer",
            "description": .string(description),
            "minimum": .int(minimum),
            "maximum": .int(maximum),
            "default": .int(defaultValue)
        ]
    }

    private static func enumeration(_ description: String, values: [String]) -> Value {
        [
            "type": "string",
            "description": .string(description),
            "enum": .array(values.map(Value.string))
        ]
    }
}

@MainActor
final class StupidMirrorMCPToolRouter: @unchecked Sendable {
    private let automation: DeviceAutomationService

    init(automation: DeviceAutomationService) {
        self.automation = automation
    }

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let args = arguments ?? [:]
        do {
            switch name {
            case "list_devices":
                return try success(automation.listDevices())
            case "refresh_devices":
                return try success(try await automation.refreshDevices())
            case "get_device_status":
                return try success(try automation.deviceStatus(deviceID: optionalString("device_id", args)))
            case "get_diagnostics":
                return try success(automation.diagnostics())
            case "start_mirror":
                return try success(try await automation.startMirror(deviceID: optionalString("device_id", args)))
            case "stop_mirror":
                return try success(try await automation.stopMirror(deviceID: optionalString("device_id", args)))
            case "set_mirror_floating":
                return try success(try await automation.setMirrorFloating(
                    deviceID: optionalString("device_id", args),
                    floating: try requiredBool("floating", args)
                ))
            case "connect_control":
                return try success(try await automation.connectControl(deviceID: optionalString("device_id", args)))
            case "disconnect_control":
                return try success(try await automation.disconnectControl(deviceID: optionalString("device_id", args)))
            case "screenshot":
                let data = try await automation.screenshot(deviceID: optionalString("device_id", args))
                return CallTool.Result(
                    content: [
                        .text("Captured \(data.count) bytes of PNG data."),
                        .image(data: data.base64EncodedString(), mimeType: "image/png", metadata: nil)
                    ],
                    structuredContent: .object([
                        "ok": true,
                        "mime_type": "image/png",
                        "byte_count": .int(data.count)
                    ]),
                    isError: false
                )
            case "get_ui_tree":
                let source = try await automation.uiTree(deviceID: optionalString("device_id", args))
                return CallTool.Result(
                    content: [.text(source)],
                    structuredContent: .object(["ok": true, "xml": .string(source)]),
                    isError: false
                )
            case "tap":
                try await automation.tap(
                    deviceID: optionalString("device_id", args),
                    x: try requiredDouble("x", args),
                    y: try requiredDouble("y", args)
                )
                return actionSuccess("tap")
            case "double_tap":
                try await automation.doubleTap(
                    deviceID: optionalString("device_id", args),
                    x: try requiredDouble("x", args),
                    y: try requiredDouble("y", args)
                )
                return actionSuccess("double_tap")
            case "long_press":
                try await automation.longPress(
                    deviceID: optionalString("device_id", args),
                    x: try requiredDouble("x", args),
                    y: try requiredDouble("y", args),
                    durationSeconds: optionalDouble("duration_seconds", args) ?? 1
                )
                return actionSuccess("long_press")
            case "swipe":
                try await automation.swipe(
                    deviceID: optionalString("device_id", args),
                    startX: try requiredDouble("start_x", args),
                    startY: try requiredDouble("start_y", args),
                    endX: try requiredDouble("end_x", args),
                    endY: try requiredDouble("end_y", args),
                    durationMS: optionalInt("duration_ms", args) ?? 300
                )
                return actionSuccess("swipe")
            case "scroll":
                let directionValue = try requiredString("direction", args)
                guard let direction = AutomationScrollDirection(rawValue: directionValue) else {
                    throw DeviceAutomationError.invalidArgument("direction must be up, down, left, or right.")
                }
                try await automation.scroll(
                    deviceID: optionalString("device_id", args),
                    direction: direction,
                    distance: optionalDouble("distance", args) ?? 0.5,
                    centerX: optionalDouble("center_x", args) ?? 0.5,
                    centerY: optionalDouble("center_y", args) ?? 0.5
                )
                return actionSuccess("scroll")
            case "type_text":
                try await automation.typeText(
                    deviceID: optionalString("device_id", args),
                    text: try requiredString("text", args)
                )
                return actionSuccess("type_text")
            case "press_button":
                try await automation.pressButton(
                    deviceID: optionalString("device_id", args),
                    name: try requiredString("button", args)
                )
                return actionSuccess("press_button")
            case "back":
                try await automation.back(deviceID: optionalString("device_id", args))
                return actionSuccess("back")
            case "app_switcher":
                try await automation.appSwitcher(deviceID: optionalString("device_id", args))
                return actionSuccess("app_switcher")
            case "activate_app":
                try await automation.activateApp(
                    deviceID: optionalString("device_id", args),
                    bundleID: try requiredString("bundle_id", args)
                )
                return actionSuccess("activate_app")
            case "terminate_app":
                let terminated = try await automation.terminateApp(
                    deviceID: optionalString("device_id", args),
                    bundleID: try requiredString("bundle_id", args)
                )
                return CallTool.Result(
                    content: [.text(terminated ? "App terminated." : "App was not running.")],
                    structuredContent: .object(["ok": true, "terminated": .bool(terminated)]),
                    isError: false
                )
            default:
                throw DeviceAutomationError.invalidArgument("Unknown tool '\(name)'.")
            }
        } catch {
            return failure(error)
        }
    }

    private func success<T: Codable>(_ value: T) throws -> CallTool.Result {
        let structured = try Value(value)
        let data = try JSONEncoder.stupidMirrorMCP.encode(value)
        let text = String(decoding: data, as: UTF8.self)
        return CallTool.Result(
            content: [.text(text)],
            structuredContent: Optional.some(structured),
            isError: false
        )
    }

    private func actionSuccess(_ action: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text("\(action) completed.")],
            structuredContent: .object(["ok": true, "action": .string(action)]),
            isError: false
        )
    }

    private func failure(_ error: Error) -> CallTool.Result {
        let mapped = Self.mapError(error)
        let value: Value = .object([
            "ok": false,
            "error": .object([
                "code": .string(mapped.code),
                "message": .string(mapped.message)
            ])
        ])
        return CallTool.Result(
            content: [.text("\(mapped.code): \(mapped.message)")],
            structuredContent: Optional.some(value),
            isError: true
        )
    }

    nonisolated static func mapError(_ error: Error) -> (code: String, message: String) {
        let message = error.localizedDescription
        let lower = message.lowercased()
        if lower.contains("unlock")
            || lower.contains("device is locked")
            || lower.contains("reason: locked")
            || lower.contains("解锁") {
            return ("device_locked", message)
        }
        if let error = error as? DeviceAutomationError {
            return (error.code, error.localizedDescription)
        }
        if error is CancellationError {
            return ("cancelled", "The operation was cancelled.")
        }
        return ("control_failed", message)
    }

    private func optionalString(_ key: String, _ args: [String: Value]) -> String? {
        args[key]?.stringValue
    }

    private func requiredString(_ key: String, _ args: [String: Value]) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else {
            throw DeviceAutomationError.invalidArgument("Missing or invalid \(key).")
        }
        return value
    }

    private func requiredBool(_ key: String, _ args: [String: Value]) throws -> Bool {
        guard let value = args[key]?.boolValue else {
            throw DeviceAutomationError.invalidArgument("Missing or invalid \(key).")
        }
        return value
    }

    private func requiredDouble(_ key: String, _ args: [String: Value]) throws -> Double {
        guard let value = optionalDouble(key, args) else {
            throw DeviceAutomationError.invalidArgument("Missing or invalid \(key).")
        }
        return value
    }

    private func optionalDouble(_ key: String, _ args: [String: Value]) -> Double? {
        args[key]?.doubleValue ?? args[key]?.intValue.map(Double.init)
    }

    private func optionalInt(_ key: String, _ args: [String: Value]) -> Int? {
        args[key]?.intValue
    }
}

private extension JSONEncoder {
    static let stupidMirrorMCP: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
