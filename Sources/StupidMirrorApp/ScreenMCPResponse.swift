import Foundation
import MCP

/// Formatting only: the automation service retains the original observation,
/// identities and full-precision geometry used by tap_element and highlights.
enum ScreenResponseFormat: String, CaseIterable {
    case compact, full

    init(arguments: [String: Value]) throws {
        guard let value = arguments["response_format"] else {
            self = .compact
            return
        }
        guard let name = value.stringValue, let format = Self(rawValue: name) else {
            throw DeviceAutomationError.invalidArgument("response_format must be compact or full.")
        }
        self = format
    }
}

enum ScreenMCPResponse {
    static let defaultIncludeImage = true
    static let defaultIncludeOCR = true

    static func observation(_ result: ScreenObservationResult, format: ScreenResponseFormat) throws -> CallTool.Result {
        var value = try Value(result.observation)
        if format == .compact, var fields = value.objectValue {
            for key in ["capturedAt", "ocrMode", "ocrLanguages"] { fields.removeValue(forKey: key) }
            fields["elements"] = .array(result.observation.elements.map(element))
            value = .object(fields)
        }
        var content: [Tool.Content] = [
            .text(text: String(decoding: try JSONEncoder.stupidMirrorMCP.encode(value), as: UTF8.self), annotations: nil, _meta: nil)
        ]
        if let image = result.imageData {
            content.append(.image(data: image.base64EncodedString(), mimeType: "image/png", annotations: nil, _meta: nil))
        }
        return CallTool.Result(content: content, structuredContent: Optional.some(value), isError: false)
    }

    static func search(_ result: ScreenElementSearchResult, format: ScreenResponseFormat) throws -> Value {
        try searchValue(result, matches: result.matches, format: format)
    }

    static func search(_ result: ScreenElementBatchSearchResult, format: ScreenResponseFormat) throws -> Value {
        try searchValue(result, matches: result.matches, format: format)
    }

    private static func searchValue<T: Codable>(
        _ result: T, matches: [ScreenElement], format: ScreenResponseFormat
    ) throws -> Value {
        let value = try Value(result)
        guard format == .compact, var fields = value.objectValue else { return value }
        fields["matches"] = .array(matches.map(element))
        return .object(fields)
    }

    static func element(_ element: ScreenElement) -> Value {
        var fields: [String: Value] = ["id": .string(element.id), "source": .string(element.source.rawValue)]
        if let label = element.label { fields["label"] = .string(label) }
        if let name = element.name, name != element.label { fields["name"] = .string(name) }
        if let value = element.value {
            fields["value"] = .string(value)
        }
        if let frame = element.normalizedFrame {
            // A reading/disambiguation hint, not replacement tap geometry.
            fields["center"] = .array([frame.centerX, frame.centerY].map { .double(($0 * 1_000).rounded() / 1_000) })
        }
        if element.source == .accessibility {
            fields["type"] = .string(element.type)
            fields["enabled"] = .bool(element.enabled)
            fields["visible"] = .bool(element.visible)
            if let accessible = element.accessible { fields["accessible"] = .bool(accessible) }
            if let selected = element.selected { fields["selected"] = .bool(selected) }
            if let focused = element.focused { fields["focused"] = .bool(focused) }
            if let hittable = element.hittable { fields["hittable"] = .bool(hittable) }
        } else if let confidence = element.confidence {
            fields["confidence"] = .double((confidence * 100).rounded() / 100)
        }
        return .object(fields)
    }
}
