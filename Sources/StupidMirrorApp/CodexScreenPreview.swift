import Foundation
import CryptoKit
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

/// DeviceKit artwork and the exact viewport inside it. Images are sent once
/// per shell to the app-only polling endpoint, never in model-visible results.
struct CodexPreviewShell: Codable, Sendable {
    let id: String
    let width: Double
    let height: Double
    let screenX: Double
    let screenY: Double
    let screenWidth: Double
    let screenHeight: Double
    let artwork: String?
    let mask: String?
    let mesh: MirrorScreenMesh?
    let duo: DuoModelPose?
    let model: DuoModelAsset?
    let postureIcons: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, width, height, artwork, mask, mesh, duo, model
        case postureIcons = "posture_icons"
        case screenX = "screen_x", screenY = "screen_y"
        case screenWidth = "screen_width", screenHeight = "screen_height"
    }
}

struct CodexPreviewDevice: Codable, Sendable {
    let id: String
    let model: String
    let platform: String
    var formFactor: String = "standard"
    var activeScreen: String?
    var posture: DevicePosture?
    var hingeAngle: Double?
    var canSetPosture = false
    var changingPosture = false

    enum CodingKeys: String, CodingKey {
        case id, model, platform
        case formFactor = "form_factor"
        case activeScreen = "active_screen"
        case posture
        case hingeAngle = "hinge_angle"
        case canSetPosture = "can_set_posture"
        case changingPosture = "changing_posture"
    }
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
    var shell: CodexPreviewShell?
    let devices: [AutomationDeviceSnapshot]
    var message: String?
    let events: [String] = []

    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time", streamID = "stream_id"
        case frameAvailable = "frame_available", pauseReason = "pause_reason"
        case frame, viewport, busy, paused, device, shell, devices, message, events
    }
}

enum StupidMirrorScreenResource {
    static let displayName = "StupidMirror"
    private static var pageURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("CodexPlugin/plugins/stupidmirror/assets/phone-screen.html")
    }
    // Codex may retain an opened MCP App by resource URI across app upgrades.
    // A content revision keeps a newly opened preview on the installed UI.
    static let uri: String = {
        guard let url = pageURL, let data = try? Data(contentsOf: url) else {
            return "ui://stupidmirror/phone-screen-v3.html"
        }
        let revision = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "ui://stupidmirror/phone-screen-\(revision).html"
    }()
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
        // Existing Codex connections can still have the previous tool metadata.
        guard requestedURI == uri || requestedURI.range(of: "^ui://stupidmirror/phone-screen-(v[23]|[0-9a-f]{16})\\.html$", options: .regularExpression) != nil else {
            throw MCPError.invalidParams("Unknown screen resource")
        }
        guard let url = pageURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw MCPError.internalError("The screen component is missing. Install an updated StupidMirror app.")
        }
        return ReadResource.Result(contents: [.text(
            try String(contentsOf: url, encoding: .utf8), uri: requestedURI,
            mimeType: mimeType, _meta: metadata
        )])
    }
}
