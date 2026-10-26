import AppKit

@MainActor
enum DeviceKitResources {
    static let duoBundle: Bundle? = {
        guard let result = try? HostCommand.run("/usr/bin/xcode-select", arguments: ["-p"], timeout: 5),
              result.status == 0 else { return nil }
        let developer = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let contents = URL(fileURLWithPath: developer).deletingLastPathComponent()
        return Bundle(url: contents.appendingPathComponent(
            "SharedFrameworks/DeviceKit.framework/Versions/A/PlugIns/CoreDevicePopDeviceKitExtension.devicekitplugin"
        ))
    }()

    static func postureIcon(_ posture: DevicePosture, landscape: Bool) -> NSImage? {
        let name: String
        switch posture {
        case .closed: name = "v68_Closed"
        case .partiallyOpen: name = landscape ? "v68_HalfOpen_Landscape" : "v68_HalfOpen_Portrait"
        case .open: name = "v68_Open"
        }
        return duoBundle?.image(forResource: name)
    }

    private static var iconCache: [Bool: [String: String]] = [:]
    static func previewIcons(landscape: Bool) -> [String: String]? {
        if let cached = iconCache[landscape] { return cached }
        var result: [String: String] = [:]
        for posture in DevicePosture.allCases {
            guard let icon = postureIcon(posture, landscape: landscape),
                  let configured = icon.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
                        .applying(.init(hierarchicalColor: .white))),
                  let tiff = configured.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            result[posture.rawValue] = png.base64EncodedString()
        }
        if let icon = duoBundle?.image(forResource: "rotate.device.right"),
           let configured = icon.withSymbolConfiguration(.init(pointSize: 28, weight: .regular)),
           let tiff = configured.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            result["rotate"] = png.base64EncodedString()
        }
        guard !result.isEmpty else { return nil }
        iconCache[landscape] = result
        return result
    }
}
