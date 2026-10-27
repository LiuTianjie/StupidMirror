import Foundation
import MCP

enum StupidMirrorMCPToolCatalog {
    static let tools: [Tool] = [
        tool("list_devices", "List connected and reconnecting iOS and Android devices, including booted iOS Simulators and Android emulators (transport \"simulator\"), with mirror and control state.", readOnly: true),
        tool("refresh_devices", "Refresh iOS and Android discovery and return the updated device list."),
        tool("get_device_status", "Get detailed state for one mobile device. supports_native_gestures indicates support for host-native scroll, pinch and rotation events, not arbitrary-center multi-finger gesture synthesis.", deviceProperties, readOnly: true),
        tool("get_diagnostics", "Get StupidMirror runtime, permission, Appium, control-agent, and device diagnostics.", readOnly: true),
        tool(
            "show_screen", "Start capturing the live phone screen in the background, without opening a Mac mirror window, so observe_screen has frames. Hosts that render MCP Apps, such as Codex, also open or reuse the live screen panel. With multiple devices, pass device_id or choose one in the screen panel. Pause/resume controls preview only.",
            deviceProperties.merging(["action": enumeration("Preview action.", values: ["open", "pause", "resume"], defaultValue: "open")]) { _, new in new },
            title: StupidMirrorScreenResource.displayName,
            idempotent: true,
            metadata: Metadata(additionalFields: [
                "ui": .object(["resourceUri": .string(StupidMirrorScreenResource.uri)]),
                "openai/ui": .object(["entrypoints": .array([.object(["type": "thread"])])])
            ])
        ),
        tool(
            "open_viewer", "Start capture like show_screen and return a link to the live phone viewer, a local page on this Mac (127.0.0.1) with the same live video, device picker, refresh and manual control as the embedded panel. Use it in hosts that cannot render MCP Apps, such as Claude Code: in the Claude desktop app, open it by default when you start working with a device; elsewhere, when the user wants to watch or operate the phone. In the Claude desktop app, open it in the Browser pane with the result's browser_pane origin; elsewhere show the url as a clickable link. The link opens one viewer and expires after 10 minutes unused; call again for a new one.",
            deviceProperties
        ),
        tool(
            "screen_frame", "App-only cached preview frame. Never captures through WDA, queries accessibility or acquires the device action lock.",
            deviceProperties.merging([
                "after_seq": integer("Last displayed frame sequence.", minimum: 0, maximum: Int.max, defaultValue: 0),
                "shell_id": string("ID of cached device shell artwork; omit to receive the current artwork and framebuffer mask."),
                "model_id": string("Cached articulated device model ID; send an empty string to request its geometry and animation."),
                "include_frame": boolean("Include a native PNG fallback. False while WebRTC video is active.", defaultValue: true)
            ]) { _, new in new },
            readOnly: true, metadata: Metadata(additionalFields: ["ui": .object(["visibility": .array(["app"])])])
        ),
        tool(
            "screen_action", "App-only user controls: refresh, connect control, tap/long press/swipe, Home, screenshot copy, pause/resume preview, or change a foldable simulator's actual hinge posture.",
            deviceProperties.merging([
                "action": enumeration("User action.", values: ["refresh", "home", "screenshot", "pause", "resume", "connect", "tap", "long_press", "swipe", "rotate", "closed", "partially_open", "open"]),
                "x": number("Normalized start X.", minimum: 0, maximum: 1),
                "y": number("Normalized start Y.", minimum: 0, maximum: 1),
                "end_x": number("Normalized destination X.", minimum: 0, maximum: 1),
                "end_y": number("Normalized destination Y.", minimum: 0, maximum: 1),
                "duration_ms": integer("Gesture duration; long press requires at least 500 ms.", minimum: 50, maximum: 5_000, defaultValue: 300)
            ]) { _, new in new },
            required: ["action"], destructive: true,
            metadata: Metadata(additionalFields: ["ui": .object(["visibility": .array(["app"])])])
        ),
        tool(
            "screen_signal", "App-only WebRTC signaling. Media is sent over encrypted local loopback; no STUN/TURN or cloud relay is used.",
            deviceProperties.merging([
                "action": enumeration("Signal action.", values: ["offer", "close"], defaultValue: "offer"),
                "sdp": string("Browser SDP offer."), "peer_id": string("Peer to close.")
            ]) { _, new in new },
            metadata: Metadata(additionalFields: ["ui": .object(["visibility": .array(["app"])])])
        ),
        tool("start_mirror", "Open and start the device mirror. Unactivated installations can mirror one device at a time.", deviceProperties),
        tool(
            "set_device_posture", "Set a foldable iOS Simulator's actual hinge to Closed (0°), Partially Open (130°) or Open (180°), matching Device Hub. Waits for the system to confirm the posture and active display. Check can_set_posture in list_devices first.",
            deviceProperties.merging([
                "posture": enumeration("Hinge posture.", values: DevicePosture.allCases.map(\.rawValue))
            ]) { _, new in new },
            required: ["posture"], idempotent: true
        ),
        tool("stop_mirror", "Stop and close the device mirror.", deviceProperties, idempotent: true),
        tool(
            "set_mirror_floating",
            "Set whether the mirror window stays above normal windows.",
            deviceProperties.merging(["floating": boolean("Whether the mirror floats above other windows.")]) { _, new in new },
            required: ["floating"],
            idempotent: true
        ),
        tool("connect_control", "Connect device control. iOS prefers system touch with WDA compatibility and on-demand semantic automation; Android uses Appium/UiAutomator2.", deviceProperties),
        tool("disconnect_control", "Disconnect the device control session while keeping its agent warm for quick reuse.", deviceProperties, idempotent: true),
        tool("screenshot", "Capture the current device screen as a native PNG. Control must be ready.", deviceProperties, readOnly: true),
        tool("get_ui_tree", "Read the current device accessibility hierarchy as XML. Control must be ready.", deviceProperties, readOnly: true),
        tool(
            "observe_screen",
            "Read the screen with an image and compact local OCR by default, without a native hierarchy. Keep the image for visual or ambiguous tasks; set include_image=false for text-only reads. Keeps actionable ids and normalized centers. Request include_accessibility=true for control state, response_format=full for diagnostics.",
            deviceProperties.merging([
                "response_format": enumeration("Compact keeps actionable ids, text, state and normalized centers; full returns original metadata and geometry.", values: ScreenResponseFormat.allCases.map(\.rawValue), defaultValue: "compact"),
                "include_image": boolean("Include the latest live mirror frame as PNG. Defaults to true; disable for explicitly text-only reads.", defaultValue: ScreenMCPResponse.defaultIncludeImage),
                "include_accessibility": boolean("Explicitly fetch and parse the full native accessibility hierarchy. Keep false for routine navigation.", defaultValue: false),
                "include_ocr": boolean("Run local Apple Vision OCR on the latest frame.", defaultValue: ScreenMCPResponse.defaultIncludeOCR),
                "ocr_mode": enumeration("OCR speed and accuracy mode.", values: ScreenOCRMode.allCases.map(\.rawValue), defaultValue: "fast"),
                "ocr_languages": stringArray("OCR language identifiers in priority order.", defaultValues: DeviceAutomationService.defaultOCRLanguages, maximumItems: 8)
            ]) { _, new in new },
            readOnly: true
        ),
        tool(
            "find_element",
            "Locate one text target with compact matches by default. Uses local OCR first, then one native hierarchy fallback. Use response_format=full only for raw match diagnostics.",
            deviceProperties.merging([
                "response_format": enumeration("Compact keeps actionable ids, text, state and normalized centers; full returns original metadata and geometry.", values: ScreenResponseFormat.allCases.map(\.rawValue), defaultValue: "compact"),
                "query": string("Text to locate across type, name, label, and value."),
                "include_ocr": boolean("Use local OCR when accessibility has no match.", defaultValue: true),
                "ocr_mode": enumeration("OCR speed and accuracy mode.", values: ScreenOCRMode.allCases.map(\.rawValue), defaultValue: "fast"),
                "ocr_languages": stringArray("OCR language identifiers in priority order.", defaultValues: DeviceAutomationService.defaultOCRLanguages, maximumItems: 8)
            ]) { _, new in new },
            required: ["query"],
            readOnly: true
        ),
        tool(
            "find_any_element",
            "Inspect a target among alternative texts in one call. Returns compact matches and observationID for tap_element. Uses local OCR first, then one shared native hierarchy fallback. Use tap_text directly when ready to tap; response_format=full is for diagnostics.",
            deviceProperties.merging([
                "response_format": enumeration("Compact keeps actionable ids, text, state and normalized centers; full returns original metadata and geometry.", values: ScreenResponseFormat.allCases.map(\.rawValue), defaultValue: "compact"),
                "queries": stringList("Alternative texts in priority order.", minimumItems: 1, maximumItems: 16),
                "include_ocr": boolean("Inspect the live mirror with local OCR before the shared accessibility fallback.", defaultValue: true),
                "ocr_mode": enumeration("OCR speed and accuracy mode.", values: ScreenOCRMode.allCases.map(\.rawValue), defaultValue: "fast"),
                "ocr_languages": stringArray("OCR language identifiers in priority order.", defaultValues: DeviceAutomationService.defaultOCRLanguages, maximumItems: 8)
            ]) { _, new in new },
            required: ["queries"],
            readOnly: true
        ),
        tool(
            "tap_text",
            "Find and tap the first visible match among alternative texts in one MCP call. Uses local OCR first, one shared native hierarchy fallback, then the fresh observed frame.",
            deviceProperties.merging([
                "queries": stringList("Alternative texts in priority order.", minimumItems: 1, maximumItems: 16),
                "include_ocr": boolean("Inspect the live mirror with local OCR before the shared accessibility fallback.", defaultValue: true),
                "ocr_mode": enumeration("OCR speed and accuracy mode.", values: ScreenOCRMode.allCases.map(\.rawValue), defaultValue: "fast"),
                "ocr_languages": stringArray("OCR language identifiers in priority order.", defaultValues: DeviceAutomationService.defaultOCRLanguages, maximumItems: 8)
            ]) { _, new in new },
            required: ["queries"],
            destructive: true
        ),
        tool(
            "tap_element",
            "Tap an observed element. Accessibility elements use a fresh native element click first; OCR elements use their normalized frame.",
            deviceProperties.merging([
                "element_id": string("Stable element id from the most recent observation."),
                "observation_id": string("Optional observation UUID. Pass it to reject stale element ids.")
            ]) { _, new in new },
            required: ["element_id"],
            destructive: true
        ),
        tool(
            "highlight_elements",
            "Highlight observed elements on the Mac mirror without tapping or changing the device. Every requested visible element is highlighted and numbered; there is no element-count limit.",
            deviceProperties.merging([
                "element_ids": unlimitedStringList("Element ids from the latest observation."),
                "observation_id": string("Optional observation UUID. Pass it to reject stale element ids."),
                "duration_seconds": number("How long highlights remain visible.", minimum: 1, maximum: 60, defaultValue: 8)
            ]) { _, new in new },
            required: ["element_ids"],
            idempotent: true
        ),
        tool(
            "highlight_clickable_elements",
            "Read the current accessibility hierarchy and highlight every visible enabled clickable element on the Mac mirror without tapping or changing the device. Returns the complete numbered element list with no count limit.",
            deviceProperties.merging([
                "duration_seconds": number("How long highlights remain visible.", minimum: 1, maximum: 60, defaultValue: 8)
            ]) { _, new in new },
            idempotent: true
        ),
        tool(
            "clear_highlights",
            "Remove all AI guide highlights from the Mac mirror without changing the device.",
            deviceProperties,
            idempotent: true
        ),
        tool(
            "wait_for",
            "Wait until matching visible accessibility or local OCR text is present or absent.",
            deviceProperties.merging([
                "query": string("Text to match on the current screen."),
                "state": enumeration("Expected state.", values: ["present", "absent"]),
                "timeout_seconds": number("Wait timeout.", minimum: 0.5, maximum: 60, defaultValue: 10),
                "include_ocr": boolean("Use local OCR when accessibility has no match.", defaultValue: true),
                "ocr_mode": enumeration("OCR speed and accuracy mode.", values: ScreenOCRMode.allCases.map(\.rawValue), defaultValue: "fast"),
                "ocr_languages": stringArray("OCR language identifiers in priority order.", defaultValues: DeviceAutomationService.defaultOCRLanguages, maximumItems: 8)
            ]) { _, new in new },
            required: ["query", "state"],
            readOnly: true
        ),
        tool(
            "assert_screen",
            "Assert that matching visible accessibility or local OCR text is currently present or absent.",
            deviceProperties.merging([
                "query": string("Text to match on the current screen."),
                "state": enumeration("Expected state.", values: ["present", "absent"]),
                "include_ocr": boolean("Use local OCR when accessibility has no match.", defaultValue: true),
                "ocr_mode": enumeration("OCR speed and accuracy mode.", values: ScreenOCRMode.allCases.map(\.rawValue), defaultValue: "fast"),
                "ocr_languages": stringArray("OCR language identifiers in priority order.", defaultValues: DeviceAutomationService.defaultOCRLanguages, maximumItems: 8)
            ]) { _, new in new },
            required: ["query", "state"],
            readOnly: true
        ),
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
            required: ["x", "y"],
            destructive: true
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
            required: ["start_x", "start_y", "end_x", "end_y"],
            destructive: true
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
            required: ["direction"],
            destructive: true
        ),
        tool(
            "type_text",
            "Type text into the currently focused device field.",
            deviceProperties.merging(["text": string("Text to type, up to 10,000 UTF-8 bytes.")]) { _, new in new },
            required: ["text"],
            destructive: true
        ),
        tool(
            "clear_text",
            "Clear the currently focused field through its native accessibility element, then verify the value is empty. No selection menu or coordinate guessing is used.",
            deviceProperties,
            destructive: true
        ),
        tool(
            "replace_text",
            "Atomically clear and replace the currently focused field through its native accessibility element, then verify the exact value. Use this instead of manually selecting all and deleting.",
            deviceProperties.merging(["text": string("Replacement text, up to 10,000 UTF-8 bytes.")]) { _, new in new },
            required: ["text"],
            destructive: true
        ),
        tool(
            "press_button",
            "Press a hardware-style device button.",
            deviceProperties.merging([
                "button": enumeration("Button name.", values: ["home", "volume_up", "volume_down"])
            ]) { _, new in new },
            required: ["button"],
            destructive: true
        ),
        tool("back", "Go back using Android Back or the conventional top-left iOS back location.", deviceProperties, destructive: true),
        tool("app_switcher", "Open the native app switcher.", deviceProperties, destructive: true),
        tool(
            "activate_app",
            "Launch or foreground an installed app by iOS bundle identifier or Android package name.",
            deviceProperties.merging(["bundle_id": string("iOS bundle identifier or Android package name.")]) { _, new in new },
            required: ["bundle_id"],
            destructive: true
        ),
        tool(
            "terminate_app",
            "Terminate an installed app by iOS bundle identifier or Android package name.",
            deviceProperties.merging(["bundle_id": string("iOS bundle identifier or Android package name.")]) { _, new in new },
            required: ["bundle_id"],
            destructive: true
        ),
        tool(
            "list_apps",
            "List apps installed on the device: bundle_id, and name and version where the platform reports them. Lists user-installed apps unless include_system is true. Needs no control session.",
            deviceProperties.merging([
                "include_system": boolean("Also list system and preinstalled apps.", defaultValue: false)
            ]) { _, new in new },
            readOnly: true
        ),
        tool(
            "install_app",
            "Install or update an app from a package on this Mac: a signed .app or .ipa for an iPhone, a simulator-built .app for an iOS Simulator, an .apk for Android. Android keeps the app's data across a reinstall. Needs no control session; can take a few minutes.",
            deviceProperties.merging([
                "path": string("Absolute path on this Mac to the .app, .ipa or .apk.")
            ]) { _, new in new },
            required: ["path"],
            destructive: true
        ),
        tool(
            "uninstall_app",
            "Uninstall an app and its data by iOS bundle identifier or Android package name. Needs no control session.",
            deviceProperties.merging(["bundle_id": string("iOS bundle identifier or Android package name.")]) { _, new in new },
            required: ["bundle_id"],
            destructive: true
        ),
        tool(
            "open_url",
            "Open a URL or app deep link (https://…, myapp://…) on the device with whichever app handles it. iPhones need connect_control first; simulators and Android do not.",
            deviceProperties.merging(["url": string("Absolute URL with a scheme.")]) { _, new in new },
            required: ["url"],
            destructive: true
        ),
        tool(
            "start_recording",
            "Start recording the live mirror to an .mp4 on this Mac (~/Movies/StupidMirror). The mirror must be live (start_mirror). Records up to 10 minutes; call stop_recording to finish the file.",
            deviceProperties
        ),
        tool(
            "stop_recording",
            "Stop a recording and return the .mp4 path, duration, frame count and size.",
            deviceProperties
        )
    ]

    private static let deviceProperties: [String: Value] = [
        "device_id": string("Optional StupidMirror device_id, iOS UDID, or Android ADB serial. Omit only when one device is connected.")
    ]

    private static func pointTool(_ name: String, _ description: String) -> Tool {
        tool(
            name,
            description,
            deviceProperties.merging([
                "x": coordinate("Normalized horizontal coordinate."),
                "y": coordinate("Normalized vertical coordinate.")
            ]) { _, new in new },
            required: ["x", "y"],
            destructive: true
        )
    }

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Value] = [:],
        title: String? = nil,
        required: [String] = [],
        readOnly: Bool = false,
        idempotent: Bool = false,
        destructive: Bool = false,
        metadata: Metadata? = nil
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
            title: title ?? name.replacingOccurrences(of: "_", with: " ").capitalized,
            description: description,
            inputSchema: .object(schema),
            annotations: .init(
                readOnlyHint: readOnly,
                destructiveHint: destructive,
                idempotentHint: idempotent,
                openWorldHint: false
            ),
            _meta: metadata
        )
    }

    private static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    private static func boolean(_ description: String, defaultValue: Bool? = nil) -> Value {
        var value: [String: Value] = ["type": "boolean", "description": .string(description)]
        if let defaultValue { value["default"] = .bool(defaultValue) }
        return .object(value)
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

    private static func enumeration(
        _ description: String,
        values: [String],
        defaultValue: String? = nil
    ) -> Value {
        var value: [String: Value] = [
            "type": "string",
            "description": .string(description),
            "enum": .array(values.map(Value.string))
        ]
        if let defaultValue { value["default"] = .string(defaultValue) }
        return .object(value)
    }

    private static func stringArray(
        _ description: String,
        defaultValues: [String],
        maximumItems: Int
    ) -> Value {
        [
            "type": "array",
            "description": .string(description),
            "items": .object(["type": "string"]),
            "maxItems": .int(maximumItems),
            "default": .array(defaultValues.map(Value.string))
        ]
    }

    private static func stringList(
        _ description: String,
        minimumItems: Int,
        maximumItems: Int
    ) -> Value {
        [
            "type": "array",
            "description": .string(description),
            "items": .object(["type": "string"]),
            "minItems": .int(minimumItems),
            "maxItems": .int(maximumItems)
        ]
    }

    private static func unlimitedStringList(_ description: String) -> Value {
        [
            "type": "array",
            "description": .string(description),
            "items": .object(["type": "string"]),
            "minItems": 1
        ]
    }
}

@MainActor
final class StupidMirrorMCPToolRouter: @unchecked Sendable {
    private let automation: DeviceAutomationService
    /// Mints viewer links. Weak: the gateway's tool caller retains this router.
    weak var viewer: MCPViewerGateway?

    init(automation: DeviceAutomationService) {
        self.automation = automation
    }

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        let args = arguments ?? [:]
        do {
            switch name {
            case "list_devices":
                return try success(automation.listDevices(), as: "devices")
            case "refresh_devices":
                return try success(try await automation.refreshDevices(), as: "devices")
            case "get_device_status":
                return try success(try automation.deviceStatus(deviceID: optionalString("device_id", args)))
            case "get_diagnostics":
                return try success(automation.diagnostics())
            case "show_screen":
                var preview = try await automation.showScreen(
                    deviceID: optionalString("device_id", args), action: optionalString("action", args) ?? "open"
                )
                preview.frame = nil
                return CallTool.Result(
                    content: [.text(preview.message ?? "The embedded phone preview is ready.")],
                    structuredContent: Optional.some(try Value(preview)), isError: false,
                    _meta: Metadata(additionalFields: ["openai/widgetSessionId": "stupidmirror-screen"])
                )
            case "open_viewer":
                guard let viewer else { throw DeviceAutomationError.controlFailed("The viewer is unavailable while the MCP server is stopped.") }
                let preview = try await automation.showScreen(deviceID: optionalString("device_id", args), action: "open")
                let link = try viewer.makeLink(deviceID: preview.device?.id)
                var structured: [String: Value] = [
                    "url": .string(link.url.absoluteString),
                    "expires_at": .string(ISO8601DateFormatter().string(from: link.expiresAt)),
                    "browser_pane": .object([
                        "launch_name": .string(MCPViewerGateway.launchName),
                        "origin": .string(viewer.origin)
                    ])
                ]
                if let device = preview.device {
                    structured["device_id"] = .string(device.id)
                    structured["device_name"] = .string(device.model)
                }
                if let message = preview.message { structured["message"] = .string(message) }
                return CallTool.Result(
                    content: [.text("""
                    Live phone viewer: \(link.url.absoluteString)
                    In the Claude desktop app, open it in the Browser pane yourself: give .claude/launch.json a configuration named "\(MCPViewerGateway.launchName)" with url "\(viewer.origin)" and no command, call preview_start with that name, then navigate the pane to the viewer link. Elsewhere, show the link to the user. It opens one viewer and expires in 10 minutes if unused.
                    """)],
                    structuredContent: .object(structured), isError: false
                )
            case "screen_frame":
                let afterSequence = args["after_seq"]?.intValue ?? 0
                guard afterSequence >= 0 else { throw DeviceAutomationError.invalidArgument("after_seq must be nonnegative") }
                let preview = try await automation.screenFrame(
                    deviceID: optionalString("device_id", args), afterSequence: UInt64(afterSequence),
                    includeFrame: optionalBool("include_frame", args) ?? true,
                    includeShellImages: true, knownShellID: optionalString("shell_id", args), knownModelID: optionalString("model_id", args)
                )
                // Encoding a first model payload must not stall native display
                // links. All of the preview's data is an immutable snapshot.
                let structured = try await Task.detached(priority: .utility) { try Value(preview) }.value
                return CallTool.Result(
                    content: [], structuredContent: Optional.some(structured), isError: false
                )
            case "screen_action":
                return CallTool.Result(
                    content: [], structuredContent: Optional.some(try Value(try await automation.screenAction(
                        deviceID: optionalString("device_id", args), action: try requiredString("action", args),
                        x: optionalDouble("x", args), y: optionalDouble("y", args),
                        endX: optionalDouble("end_x", args), endY: optionalDouble("end_y", args),
                        durationMS: args["duration_ms"]?.intValue
                    ))), isError: false
                )
            case "screen_signal":
                return CallTool.Result(content: [], structuredContent: Optional.some(try Value(try await automation.screenSignal(
                    deviceID: optionalString("device_id", args), action: optionalString("action", args) ?? "offer",
                    sdp: optionalString("sdp", args), peerID: optionalString("peer_id", args)
                ))), isError: false)
            case "start_mirror":
                return try success(try await automation.startMirror(deviceID: optionalString("device_id", args)))
            case "set_device_posture":
                return try success(try await automation.setDevicePosture(
                    deviceID: optionalString("device_id", args), posture: try requiredString("posture", args)
                ))
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
            case "observe_screen":
                let format = try ScreenResponseFormat(arguments: args)
                let result = try await automation.observeScreen(
                    deviceID: optionalString("device_id", args),
                    includeImage: optionalBool("include_image", args) ?? ScreenMCPResponse.defaultIncludeImage,
                    includeAccessibility: optionalBool("include_accessibility", args) ?? false,
                    includeOCR: optionalBool("include_ocr", args) ?? ScreenMCPResponse.defaultIncludeOCR,
                    ocrMode: try ocrMode(args),
                    ocrLanguages: try optionalStringArray("ocr_languages", args)
                        ?? DeviceAutomationService.defaultOCRLanguages
                )
                return try ScreenMCPResponse.observation(result, format: format)
            case "find_element":
                let format = try ScreenResponseFormat(arguments: args)
                let result = try await automation.findElements(
                    deviceID: optionalString("device_id", args),
                    query: try requiredString("query", args),
                    includeOCR: optionalBool("include_ocr", args) ?? true,
                    ocrMode: try ocrMode(args),
                    ocrLanguages: try optionalStringArray("ocr_languages", args)
                        ?? DeviceAutomationService.defaultOCRLanguages
                )
                return try success(ScreenMCPResponse.search(result, format: format))
            case "find_any_element":
                let format = try ScreenResponseFormat(arguments: args)
                let result = try await automation.findAnyElements(
                    deviceID: optionalString("device_id", args),
                    queries: try optionalStringArray("queries", args) ?? [],
                    includeOCR: optionalBool("include_ocr", args) ?? true,
                    ocrMode: try ocrMode(args),
                    ocrLanguages: try optionalStringArray("ocr_languages", args)
                        ?? DeviceAutomationService.defaultOCRLanguages
                )
                return try success(ScreenMCPResponse.search(result, format: format))
            case "tap_text":
                return try success(try await automation.tapText(
                    deviceID: optionalString("device_id", args),
                    queries: try optionalStringArray("queries", args) ?? [],
                    includeOCR: optionalBool("include_ocr", args) ?? true,
                    ocrMode: try ocrMode(args),
                    ocrLanguages: try optionalStringArray("ocr_languages", args)
                        ?? DeviceAutomationService.defaultOCRLanguages
                ))
            case "tap_element":
                return try success(try await automation.tapElement(
                    deviceID: optionalString("device_id", args),
                    observationID: try optionalUUID("observation_id", args),
                    elementID: try requiredString("element_id", args)
                ))
            case "wait_for":
                return try success(try await automation.waitForElement(
                    deviceID: optionalString("device_id", args),
                    query: try requiredString("query", args),
                    state: try requiredString("state", args),
                    timeoutSeconds: optionalDouble("timeout_seconds", args) ?? 10,
                    includeOCR: optionalBool("include_ocr", args) ?? true,
                    ocrMode: try ocrMode(args),
                    ocrLanguages: try optionalStringArray("ocr_languages", args)
                        ?? DeviceAutomationService.defaultOCRLanguages
                ))
            case "assert_screen":
                return try success(try await automation.assertScreen(
                    deviceID: optionalString("device_id", args),
                    query: try requiredString("query", args),
                    state: try requiredString("state", args),
                    includeOCR: optionalBool("include_ocr", args) ?? true,
                    ocrMode: try ocrMode(args),
                    ocrLanguages: try optionalStringArray("ocr_languages", args)
                        ?? DeviceAutomationService.defaultOCRLanguages
                ))
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
            case "clear_text":
                return try success(try await automation.clearText(
                    deviceID: optionalString("device_id", args)
                ))
            case "replace_text":
                return try success(try await automation.replaceText(
                    deviceID: optionalString("device_id", args),
                    text: try requiredString("text", args)
                ))
            case "highlight_elements":
                return try success(try automation.highlightElements(
                    deviceID: optionalString("device_id", args),
                    observationID: try optionalUUID("observation_id", args),
                    elementIDs: try optionalStringArray("element_ids", args) ?? [],
                    durationSeconds: optionalDouble("duration_seconds", args) ?? 8
                ))
            case "highlight_clickable_elements":
                return try success(try await automation.highlightClickableElements(
                    deviceID: optionalString("device_id", args),
                    durationSeconds: optionalDouble("duration_seconds", args) ?? 8
                ))
            case "clear_highlights":
                try automation.clearHighlights(deviceID: optionalString("device_id", args))
                return actionSuccess("clear_highlights")
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
            case "list_apps":
                let apps = try await automation.listApps(
                    deviceID: optionalString("device_id", args),
                    includeSystem: optionalBool("include_system", args) ?? false
                )
                return try success(apps, as: "apps")
            case "install_app":
                try await automation.installApp(
                    deviceID: optionalString("device_id", args),
                    path: try requiredString("path", args)
                )
                return actionSuccess("install_app")
            case "uninstall_app":
                try await automation.uninstallApp(
                    deviceID: optionalString("device_id", args),
                    bundleID: try requiredString("bundle_id", args)
                )
                return actionSuccess("uninstall_app")
            case "open_url":
                try await automation.openURL(
                    deviceID: optionalString("device_id", args),
                    url: try requiredString("url", args)
                )
                return actionSuccess("open_url")
            case "start_recording":
                let path = try automation.startRecording(deviceID: optionalString("device_id", args))
                return CallTool.Result(
                    content: [.text("Recording to \(path). Call stop_recording to finish the file.")],
                    structuredContent: .object(["ok": true, "path": .string(path)]),
                    isError: false
                )
            case "stop_recording":
                return try success(try await automation.stopRecording(deviceID: optionalString("device_id", args)))
            default:
                throw DeviceAutomationError.invalidArgument("Unknown tool '\(name)'.")
            }
        } catch {
            return failure(error)
        }
    }

    private func success<T: Codable>(_ value: T, as key: String = "items") throws -> CallTool.Result {
        let data = try JSONEncoder.stupidMirrorMCP.encode(value)
        let text = String(decoding: data, as: UTF8.self)
        return CallTool.Result(
            content: [.text(text)],
            structuredContent: Optional.some(Self.structuredContent(try Value(value), key: key)),
            isError: false
        )
    }

    /// MCP requires `structuredContent` to be an object; Claude Code rejects a
    /// bare array, so a list is wrapped under `key`. The text block keeps the
    /// list as it was.
    nonisolated static func structuredContent(_ value: Value, key: String) -> Value {
        if case .array = value { return .object([key: value]) }
        return value
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

    private func optionalBool(_ key: String, _ args: [String: Value]) -> Bool? {
        args[key]?.boolValue
    }

    private func optionalStringArray(_ key: String, _ args: [String: Value]) throws -> [String]? {
        guard let rawValue = args[key] else { return nil }
        guard let values = rawValue.arrayValue else {
            throw DeviceAutomationError.invalidArgument("\(key) must be an array of strings.")
        }
        return try values.map { value in
            guard let string = value.stringValue else {
                throw DeviceAutomationError.invalidArgument("\(key) must contain only strings.")
            }
            return string
        }
    }

    private func ocrMode(_ args: [String: Value]) throws -> ScreenOCRMode {
        let rawValue = optionalString("ocr_mode", args) ?? ScreenOCRMode.fast.rawValue
        guard let mode = ScreenOCRMode(rawValue: rawValue) else {
            throw DeviceAutomationError.invalidArgument("ocr_mode must be fast or accurate.")
        }
        return mode
    }

    private func optionalUUID(_ key: String, _ args: [String: Value]) throws -> UUID? {
        guard let raw = optionalString(key, args) else { return nil }
        guard let value = UUID(uuidString: raw) else {
            throw DeviceAutomationError.invalidArgument("\(key) must be a UUID.")
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

extension JSONEncoder {
    static let stupidMirrorMCP: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
