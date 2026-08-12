@preconcurrency import AVFoundation
import CoreImage
import Foundation
import ImageIO
@preconcurrency import Vision

struct MirrorFrameSnapshot: @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    let sequence: UInt64
    let pngData: Data?
    let width: Int
    let height: Int
}

/// Retains only the newest decoded/captured frame. AI observation and local OCR
/// can inspect this frame without asking WDA/XCTest to take another screenshot.
final class MirrorFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private let renderLock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var latestSampleBuffer: CMSampleBuffer?
    private var sequence: UInt64 = 0

    func submit(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            sequence &+= 1
            latestSampleBuffer = sampleBuffer
        }
    }

    func clear() {
        lock.withLock {
            sequence &+= 1
            latestSampleBuffer = nil
        }
    }

    func snapshot(includePNG: Bool) -> MirrorFrameSnapshot? {
        guard let stored: (CMSampleBuffer, UInt64) = lock.withLock({
            guard let latestSampleBuffer else { return nil }
            return (latestSampleBuffer, sequence)
        }), let pixelBuffer = CMSampleBufferGetImageBuffer(stored.0) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var pngData: Data?
        if includePNG {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            pngData = renderLock.withLock {
                context.pngRepresentation(
                    of: image,
                    format: .RGBA8,
                    colorSpace: colorSpace,
                    options: [:]
                )
            }
        }
        return MirrorFrameSnapshot(
            sampleBuffer: stored.0,
            sequence: stored.1,
            pngData: pngData,
            width: width,
            height: height
        )
    }

    func pngSnapshot() -> MirrorFrameSnapshot? {
        snapshot(includePNG: true)
    }
}

enum ScreenElementSource: String, Codable, Sendable {
    case accessibility
    case ocr
}

enum ScreenElementFrameSpace: String, Codable, Sendable {
    case screenPoints = "screen_points"
    case imagePixels = "image_pixels"
}

enum ScreenOCRMode: String, Codable, CaseIterable, Sendable {
    case fast
    case accurate
}

struct ScreenElementFrame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
    var maxX: Double { x + width }
    var maxY: Double { y + height }

    func normalized(width totalWidth: Double, height totalHeight: Double) -> ScreenElementFrame? {
        guard totalWidth > 0, totalHeight > 0 else { return nil }
        return ScreenElementFrame(
            x: x / totalWidth,
            y: y / totalHeight,
            width: width / totalWidth,
            height: height / totalHeight
        ).clampedToUnit()
    }

    func scaled(width totalWidth: Double, height totalHeight: Double) -> ScreenElementFrame {
        ScreenElementFrame(
            x: x * totalWidth,
            y: y * totalHeight,
            width: width * totalWidth,
            height: height * totalHeight
        )
    }

    func clampedToUnit() -> ScreenElementFrame {
        let minX = min(max(x, 0), 1)
        let minY = min(max(y, 0), 1)
        let upperX = min(max(maxX, minX), 1)
        let upperY = min(max(maxY, minY), 1)
        return ScreenElementFrame(
            x: minX,
            y: minY,
            width: upperX - minX,
            height: upperY - minY
        )
    }

    func overlapRatio(relativeTo other: ScreenElementFrame) -> Double {
        let overlapWidth = max(0, min(maxX, other.maxX) - max(x, other.x))
        let overlapHeight = max(0, min(maxY, other.maxY) - max(y, other.y))
        let intersection = overlapWidth * overlapHeight
        let smallerArea = min(width * height, other.width * other.height)
        guard smallerArea > 0 else { return 0 }
        return intersection / smallerArea
    }
}

struct ScreenElement: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let source: ScreenElementSource
    let type: String
    let name: String?
    let label: String?
    let value: String?
    let enabled: Bool
    let visible: Bool
    let accessible: Bool?
    let selected: Bool?
    let focused: Bool?
    let hittable: Bool?
    let index: Int?
    let confidence: Double?
    let frame: ScreenElementFrame?
    let frameSpace: ScreenElementFrameSpace?
    let normalizedFrame: ScreenElementFrame?
    let parentID: String?
    let childrenIDs: [String]
    let depth: Int
    let path: String

    init(
        id: String,
        source: ScreenElementSource = .accessibility,
        type: String,
        name: String?,
        label: String?,
        value: String?,
        enabled: Bool,
        visible: Bool,
        accessible: Bool? = nil,
        selected: Bool? = nil,
        focused: Bool? = nil,
        hittable: Bool? = nil,
        index: Int? = nil,
        confidence: Double? = nil,
        frame: ScreenElementFrame?,
        frameSpace: ScreenElementFrameSpace? = nil,
        normalizedFrame: ScreenElementFrame? = nil,
        parentID: String? = nil,
        childrenIDs: [String] = [],
        depth: Int = 0,
        path: String = ""
    ) {
        self.id = id
        self.source = source
        self.type = type
        self.name = name
        self.label = label
        self.value = value
        self.enabled = enabled
        self.visible = visible
        self.accessible = accessible
        self.selected = selected
        self.focused = focused
        self.hittable = hittable
        self.index = index
        self.confidence = confidence
        self.frame = frame
        self.frameSpace = frameSpace
        self.normalizedFrame = normalizedFrame
        self.parentID = parentID
        self.childrenIDs = childrenIDs
        self.depth = depth
        self.path = path
    }

    var searchableText: String {
        [type, name, label, value]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

struct ScreenObservation: Codable, Equatable, Sendable {
    let id: UUID
    let deviceID: String
    let capturedAt: Date
    let mirrorState: String
    let controlState: String
    let imageAvailable: Bool
    let imageWidth: Int?
    let imageHeight: Int?
    let accessibilityAvailable: Bool
    let accessibilityError: String?
    let ocrAvailable: Bool
    let ocrError: String?
    let ocrMode: ScreenOCRMode?
    let ocrLanguages: [String]
    let elements: [ScreenElement]
}

struct ScreenObservationResult: @unchecked Sendable {
    let observation: ScreenObservation
    let imageData: Data?
}

struct ScreenElementSearchResult: Codable, Equatable, Sendable {
    let observationID: UUID
    let query: String
    let sourcesChecked: [ScreenElementSource]
    let matches: [ScreenElement]
}

struct ScreenElementTapResult: Codable, Equatable, Sendable {
    let observationID: UUID
    let elementID: String
    let source: ScreenElementSource
    let strategy: String
}

struct ScreenConditionResult: Codable, Equatable, Sendable {
    let observationID: UUID
    let query: String
    let state: String
    let satisfied: Bool
    let matchCount: Int
    let sourcesChecked: [ScreenElementSource]
}

struct RecognizedScreenText: Equatable, Sendable {
    let text: String
    let confidence: Double
    let normalizedFrame: ScreenElementFrame
}

actor VisionScreenTextRecognizer {
    private struct CacheKey: Hashable, Sendable {
        let deviceID: String
        let mode: ScreenOCRMode
        let languages: [String]
        let width: Int
        let height: Int
    }

    private struct CacheEntry: Sendable {
        let createdAt: Date
        let values: [RecognizedScreenText]
    }

    private let cacheLifetime: TimeInterval
    private var cache: [CacheKey: CacheEntry] = [:]

    init(cacheLifetime: TimeInterval = 0.75) {
        self.cacheLifetime = cacheLifetime
    }

    func recognize(
        deviceID: String,
        snapshot: MirrorFrameSnapshot,
        mode: ScreenOCRMode,
        languages: [String]
    ) throws -> [RecognizedScreenText] {
        let key = CacheKey(
            deviceID: deviceID,
            mode: mode,
            languages: languages,
            width: snapshot.width,
            height: snapshot.height
        )
        let now = Date()
        if let cached = cache[key], now.timeIntervalSince(cached.createdAt) <= cacheLifetime {
            return cached.values
        }

        let values = try Self.perform(snapshot: snapshot, mode: mode, languages: languages)
        cache[key] = CacheEntry(createdAt: now, values: values)
        if cache.count > 12 {
            cache = cache.filter { now.timeIntervalSince($0.value.createdAt) <= cacheLifetime }
        }
        return values
    }

    nonisolated private static func perform(
        snapshot: MirrorFrameSnapshot,
        mode: ScreenOCRMode,
        languages: [String]
    ) throws -> [RecognizedScreenText] {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(snapshot.sampleBuffer) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = mode == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = mode == .accurate
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0.006

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .up,
            options: [:]
        )
        try handler.perform([request])

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let frame = ScreenOCRGeometry.topLeftNormalizedFrame(
                fromVisionBoundingBox: observation.boundingBox
            )
            guard frame.width > 0, frame.height > 0 else { return nil }
            return RecognizedScreenText(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                normalizedFrame: frame
            )
        }.sorted {
            if abs($0.normalizedFrame.y - $1.normalizedFrame.y) > 0.008 {
                return $0.normalizedFrame.y < $1.normalizedFrame.y
            }
            return $0.normalizedFrame.x < $1.normalizedFrame.x
        }
    }
}

enum ScreenOCRGeometry {
    static func topLeftNormalizedFrame(fromVisionBoundingBox box: CGRect) -> ScreenElementFrame {
        ScreenElementFrame(
            x: box.minX,
            y: 1 - box.maxY,
            width: box.width,
            height: box.height
        ).clampedToUnit()
    }
}

enum ScreenOCRElementFactory {
    static func makeElements(
        from recognized: [RecognizedScreenText],
        screenSize: DeviceScreenSize?,
        imageWidth: Int,
        imageHeight: Int
    ) -> [ScreenElement] {
        var occurrenceByFingerprint: [String: Int] = [:]
        return recognized.enumerated().map { index, item in
            let normalized = item.normalizedFrame.clampedToUnit()
            let frame: ScreenElementFrame
            let frameSpace: ScreenElementFrameSpace
            if let screenSize, screenSize.width > 0, screenSize.height > 0 {
                frame = normalized.scaled(width: screenSize.width, height: screenSize.height)
                frameSpace = .screenPoints
            } else {
                frame = normalized.scaled(width: Double(imageWidth), height: Double(imageHeight))
                frameSpace = .imagePixels
            }
            let fingerprint = [
                item.text,
                String(format: "%.4f,%.4f,%.4f,%.4f", normalized.x, normalized.y, normalized.width, normalized.height)
            ].joined(separator: "|")
            let occurrence = occurrenceByFingerprint[fingerprint, default: 0]
            occurrenceByFingerprint[fingerprint] = occurrence + 1
            return ScreenElement(
                id: "ocr-\(ScreenElementIdentity.fnv1a64("\(fingerprint)|\(occurrence)"))",
                source: .ocr,
                type: "OCRText",
                name: nil,
                label: item.text,
                value: nil,
                enabled: true,
                visible: true,
                confidence: item.confidence,
                frame: frame,
                frameSpace: frameSpace,
                normalizedFrame: normalized,
                depth: 0,
                path: "ocr/\(index)"
            )
        }
    }
}

enum ScreenElementFusion {
    static func merge(accessibility: [ScreenElement], ocr: [ScreenElement]) -> [ScreenElement] {
        accessibility + ocr.filter { ocrElement in
            guard let ocrFrame = ocrElement.normalizedFrame else { return true }
            let ocrText = normalizedText(ocrElement.label ?? "")
            guard !ocrText.isEmpty else { return false }
            return !accessibility.contains { nativeElement in
                guard let nativeFrame = nativeElement.normalizedFrame,
                      nativeFrame.overlapRatio(relativeTo: ocrFrame) >= 0.55 else { return false }
                let nativeText = normalizedText(nativeElement.searchableText)
                return nativeText.contains(ocrText) || ocrText.contains(nativeText)
            }
        }
    }

    private static func normalizedText(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace && !$0.isNewline }
    }
}

enum ScreenElementParser {
    static func parse(_ xml: String, screenSize: DeviceScreenSize? = nil) -> [ScreenElement] {
        let delegate = XMLScreenElementDelegate(screenSize: screenSize)
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return [] }
        return delegate.finalizedElements
    }
}

private final class XMLScreenElementDelegate: NSObject, XMLParserDelegate {
    private struct NodeContext {
        let path: String
        let semanticID: String?
        let semanticDepth: Int
        var nextChildIndex: Int
    }

    private struct ElementBuilder {
        let id: String
        let type: String
        let name: String?
        let label: String?
        let value: String?
        let enabled: Bool
        let visible: Bool
        let accessible: Bool?
        let selected: Bool?
        let focused: Bool?
        let hittable: Bool?
        let index: Int?
        let frame: ScreenElementFrame?
        let normalizedFrame: ScreenElementFrame?
        let parentID: String?
        var childrenIDs: [String]
        let depth: Int
        let path: String
    }

    private let screenSize: DeviceScreenSize?
    private var builders: [ElementBuilder] = []
    private var indexByID: [String: Int] = [:]
    private var stack: [NodeContext] = []
    private var rootIndex = 0

    init(screenSize: DeviceScreenSize?) {
        self.screenSize = screenSize
    }

    fileprivate var finalizedElements: [ScreenElement] {
        builders.map { builder in
            ScreenElement(
                id: builder.id,
                type: builder.type,
                name: builder.name,
                label: builder.label,
                value: builder.value,
                enabled: builder.enabled,
                visible: builder.visible,
                accessible: builder.accessible,
                selected: builder.selected,
                focused: builder.focused,
                hittable: builder.hittable,
                index: builder.index,
                frame: builder.frame,
                frameSpace: builder.frame == nil ? nil : .screenPoints,
                normalizedFrame: builder.normalizedFrame,
                parentID: builder.parentID,
                childrenIDs: builder.childrenIDs,
                depth: builder.depth,
                path: builder.path
            )
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let path: String
        if stack.isEmpty {
            path = "/\(rootIndex)"
            rootIndex += 1
        } else {
            let childIndex = stack[stack.count - 1].nextChildIndex
            stack[stack.count - 1].nextChildIndex += 1
            path = "\(stack[stack.count - 1].path)/\(childIndex)"
        }

        let type = attributeDict["type"] ?? elementName
        let name = Self.nonEmpty(attributeDict["name"])
        let label = Self.nonEmpty(attributeDict["label"])
        let value = Self.nonEmpty(attributeDict["value"])
        let frame = Self.frame(attributeDict)
        let parentID = stack.reversed().compactMap(\.semanticID).first
        let parentDepth = stack.reversed().first(where: { $0.semanticID != nil })?.semanticDepth ?? -1
        let shouldInclude = name != nil || label != nil || value != nil || frame != nil

        var semanticID: String?
        var semanticDepth = parentDepth
        if shouldInclude {
            let fingerprint = [
                type,
                name ?? "",
                label ?? "",
                value ?? "",
                frame.map { "\($0.x),\($0.y),\($0.width),\($0.height)" } ?? "",
                path
            ].joined(separator: "|")
            let id = "el-\(ScreenElementIdentity.fnv1a64(fingerprint))"
            semanticID = id
            semanticDepth = parentDepth + 1
            let normalizedFrame: ScreenElementFrame?
            if let frame, let screenSize {
                normalizedFrame = frame.normalized(width: screenSize.width, height: screenSize.height)
            } else {
                normalizedFrame = nil
            }
            let builder = ElementBuilder(
                id: id,
                type: type,
                name: name,
                label: label,
                value: value,
                enabled: Self.bool(attributeDict["enabled"], defaultValue: true),
                visible: Self.bool(attributeDict["visible"], defaultValue: true),
                accessible: Self.optionalBool(attributeDict["accessible"]),
                selected: Self.optionalBool(attributeDict["selected"]),
                focused: Self.optionalBool(attributeDict["focused"]),
                hittable: Self.optionalBool(attributeDict["hittable"]),
                index: Int(attributeDict["index"] ?? ""),
                frame: frame,
                normalizedFrame: normalizedFrame,
                parentID: parentID,
                childrenIDs: [],
                depth: semanticDepth,
                path: path
            )
            indexByID[id] = builders.count
            builders.append(builder)
            if let parentID, let parentIndex = indexByID[parentID] {
                builders[parentIndex].childrenIDs.append(id)
            }
        }

        stack.append(NodeContext(
            path: path,
            semanticID: semanticID,
            semanticDepth: semanticDepth,
            nextChildIndex: 0
        ))
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty { stack.removeLast() }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func bool(_ value: String?, defaultValue: Bool) -> Bool {
        optionalBool(value) ?? defaultValue
    }

    private static func optionalBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        if value == "true" || value == "1" { return true }
        if value == "false" || value == "0" { return false }
        return nil
    }

    private static func frame(_ attributes: [String: String]) -> ScreenElementFrame? {
        guard let x = Double(attributes["x"] ?? ""),
              let y = Double(attributes["y"] ?? ""),
              let width = Double(attributes["width"] ?? ""),
              let height = Double(attributes["height"] ?? ""),
              width > 0, height > 0 else { return nil }
        return ScreenElementFrame(x: x, y: y, width: width, height: height)
    }
}

enum ScreenElementIdentity {
    static func fnv1a64(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }
}
