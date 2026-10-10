import Foundation
import MCP

struct CodexPreviewFrame: Codable, Sendable {
    let seq: UInt64
    let data: String?
    let mimeType = "image/png"
    let width: Int
    let height: Int
}

struct CodexPreviewSize: Codable, Sendable {
    let width: Int
    let height: Int
}

struct CodexPreviewDevice: Codable, Sendable {
    let id: String
    let model: String
    let platform: String
}

/// Uses the iPhone Use widget's frame protocol. Frames are returned only to
/// the app-only polling tool, never as repeated model-visible image messages.
struct CodexPreviewState: Codable, Sendable {
    var serverTime = Date().timeIntervalSince1970 * 1_000
    let streamID: String
    var frame: CodexPreviewFrame?
    var frameAvailable = false
    var viewport: CodexPreviewSize?
    var busy = false
    var paused = false
    var pauseReason: String?
    var device: CodexPreviewDevice?
    let devices: [AutomationDeviceSnapshot]
    var message: String?
    let events: [String] = []

    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time", streamID = "stream_id"
        case frameAvailable = "frame_available", pauseReason = "pause_reason"
        case frame, viewport, busy, paused, device, devices, message, events
    }
}

enum StupidMirrorScreenResource {
    static let displayName = "StupidMirror"
    static let uri = "ui://stupidmirror/phone-screen-v2.html"
    static let mimeType = "text/html;profile=mcp-app"
    static let metadata = Metadata(additionalFields: [
        "ui": .object([
            "csp": .object(["connectDomains": .array([]), "resourceDomains": .array([])]),
            "prefersBorder": false
        ]),
        "openai/ui": .object([
            "availableDisplayModes": .array(["fullscreen"]),
            "preferredDisplayMode": "fullscreen"
        ])
    ])
    static let resource = Resource(
        name: displayName, uri: uri, title: displayName,
        description: "Live iPhone and Android preview inside Codex.",
        mimeType: mimeType, _meta: metadata
    )

    static func read(_ requestedURI: String) throws -> ReadResource.Result {
        guard requestedURI == uri else { throw MCPError.invalidParams("Unknown screen resource") }
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("CodexPlugin/plugins/stupidmirror/assets/phone-screen.html"),
              FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.internalError("The screen component is missing. Install an updated StupidMirror app.")
        }
        return ReadResource.Result(contents: [.text(
            try String(contentsOf: url, encoding: .utf8), uri: uri,
            mimeType: mimeType, _meta: metadata
        )])
    }
}
