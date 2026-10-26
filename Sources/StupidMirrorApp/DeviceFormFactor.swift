import Foundation

/// Only devices with a physical hinge expose posture controls.
enum DeviceFormFactor: String, Codable, Sendable {
    case standard
    case foldable

    var availablePostures: [DevicePosture] {
        self == .foldable ? DevicePosture.allCases : []
    }

    static func detect(productType: String, modelID: String?) -> DeviceFormFactor {
        let identity = "\(productType) \(modelID ?? "")".lowercased()
        return identity.contains("iphone duo") || identity.contains("iphone19,4") ? .foldable : .standard
    }
}

enum DevicePosture: String, Codable, Sendable, CaseIterable, Identifiable {
    case closed
    case partiallyOpen = "partially_open"
    case open

    var id: String { rawValue }
    var hingeAngle: Double {
        switch self { case .closed: 0; case .partiallyOpen: 130; case .open: 180 }
    }
    var labelKey: String { "mirror.posture.\(rawValue)" }
    var systemImage: String {
        switch self {
        case .closed: "iphone"
        case .partiallyOpen: "book"
        case .open: "rectangle"
        }
    }
}

/// Read from the runner's display controller, including changes made in Device
/// Hub. The native dimensions identify the panel; orientation describes the
/// current framebuffer. Posture is never inferred from a selected UI button.
struct SimulatorDisplayState: Codable, Equatable, Sendable {
    let displayID: Int
    let nativeWidth: Double
    let nativeHeight: Double
    let pointScale: Double
    let orientation: String
    let foldable: Bool
    let hingeAngle: Double?
    let posture: DevicePosture?

    var nativeSize: CGSize { CGSize(width: nativeWidth, height: nativeHeight) }
    var isLandscape: Bool { orientation == "rot90" || orientation == "rot270" }
    var activeScreen: String? {
        guard foldable else { return nil }
        return max(nativeWidth, nativeHeight) > 2400 ? "inner" : "outer"
    }
    var logicalSize: CGSize {
        let scale = max(pointScale, 1)
        return isLandscape
            ? CGSize(width: nativeHeight / scale, height: nativeWidth / scale)
            : CGSize(width: nativeWidth / scale, height: nativeHeight / scale)
    }

    enum CodingKeys: String, CodingKey {
        case displayID = "display_id", nativeWidth = "native_width", nativeHeight = "native_height"
        case pointScale = "point_scale", hingeAngle = "hinge_angle"
        case orientation, foldable, posture
    }
}

extension SimulatorDisplayState {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try values.decode(Int.self, forKey: .displayID)
        nativeWidth = try values.decode(Double.self, forKey: .nativeWidth)
        nativeHeight = try values.decode(Double.self, forKey: .nativeHeight)
        pointScale = try values.decode(Double.self, forKey: .pointScale)
        orientation = try values.decode(String.self, forKey: .orientation)
        // Older Objective-C runners boxed the C comparison as 0/1. Accept
        // those cached runners while new builds send a proper JSON boolean.
        if let boolean = try? values.decode(Bool.self, forKey: .foldable) {
            foldable = boolean
        } else {
            let flag = try values.decode(Int.self, forKey: .foldable)
            guard flag == 0 || flag == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .foldable, in: values, debugDescription: "Expected a boolean or 0/1")
            }
            foldable = flag == 1
        }
        hingeAngle = try values.decodeIfPresent(Double.self, forKey: .hingeAngle)
        posture = try values.decodeIfPresent(DevicePosture.self, forKey: .posture)
    }
}
