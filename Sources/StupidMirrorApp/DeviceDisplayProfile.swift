import CoreGraphics

struct DeviceDisplayProfile: Sendable, Equatable {
    let logicalSize: CGSize
    let pixelSize: CGSize

    var aspectRatio: Double {
        Double(logicalSize.width / max(logicalSize.height, 1))
    }

    static func profile(for productType: String, name: String) -> DeviceDisplayProfile? {
        profile(for: productType, name: name, posture: .open)
    }

    static func profile(
        for productType: String,
        name: String,
        posture: DevicePosture
    ) -> DeviceDisplayProfile? {
        let normalized = "\(productType) \(name)".lowercased()
        if normalized.contains("iphone duo") || normalized.contains("iphone19,4") {
            // iPhone Duo (iOS 27) has two screens; portrait, native resolutions.
            switch posture {
            case .closed:
                return DeviceDisplayProfile(
                    logicalSize: CGSize(width: 466, height: 678),
                    pixelSize: CGSize(width: 1398, height: 2034)
                )
            case .open, .partiallyOpen:
                return DeviceDisplayProfile(
                    logicalSize: CGSize(width: 669, height: 951),
                    pixelSize: CGSize(width: 2007, height: 2853)
                )
            }
        }
        if normalized.contains("iphone air") {
            return DeviceDisplayProfile(
                logicalSize: CGSize(width: 420, height: 912),
                pixelSize: CGSize(width: 1260, height: 2736)
            )
        }
        return nil
    }
}
