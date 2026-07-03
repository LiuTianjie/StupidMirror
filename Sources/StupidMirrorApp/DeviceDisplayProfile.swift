import CoreGraphics

struct DeviceDisplayProfile: Sendable {
    let logicalSize: CGSize
    let pixelSize: CGSize

    var aspectRatio: Double {
        Double(logicalSize.width / max(logicalSize.height, 1))
    }

    static func profile(for productType: String, name: String) -> DeviceDisplayProfile? {
        let normalized = "\(productType) \(name)".lowercased()
        if normalized.contains("iphone air") {
            return DeviceDisplayProfile(
                logicalSize: CGSize(width: 420, height: 912),
                pixelSize: CGSize(width: 1260, height: 2736)
            )
        }
        return nil
    }
}
