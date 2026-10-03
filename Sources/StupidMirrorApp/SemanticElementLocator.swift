import Foundation

/// A native element query: a locator strategy name plus its expression.
struct SemanticLocator: Equatable, Sendable {
    let using: String
    let value: String
}

struct ResolvedNativeElement: Equatable, Sendable {
    let id: String
    let frame: ScreenElementFrame?
}

/// A native element found for a text query, with the public element the
/// automation layer hands back to callers.
struct NativeElementMatch: Equatable, Sendable {
    let reference: String
    let query: String
    let element: ScreenElement
}

/// Builds native locators from observed screen elements so a tap can target
/// the real control instead of its last known coordinates.
enum SemanticElementLocator {
    static let w3cElementKey = "element-6066-11e4-a52e-4f735466cecf"

    static func textContainsLocator(query: String, platform: DevicePlatform) -> SemanticLocator {
        if platform == .android {
            let literal = xpathLiteral(query)
            return SemanticLocator(
                using: "xpath",
                value: "//*[contains(@text, \(literal)) or contains(@content-desc, \(literal)) or contains(@resource-id, \(literal))]"
            )
        }
        let literal = predicateLiteral(query)
        return SemanticLocator(
            using: "predicate string",
            value: "visible == 1 AND (name CONTAINS[c] '\(literal)' OR label CONTAINS[c] '\(literal)' OR value CONTAINS[c] '\(literal)')"
        )
    }

    /// The predicate that finds the focused text input on iOS.
    static let focusedIOSInputLocator = SemanticLocator(
        using: "predicate string",
        value: "focused == 1 AND (type == 'XCUIElementTypeTextField' OR type == 'XCUIElementTypeSecureTextField' OR type == 'XCUIElementTypeSearchField' OR type == 'XCUIElementTypeTextView')"
    )

    static let focusedAndroidInputLocator = SemanticLocator(
        using: "-android uiautomator",
        value: "new UiSelector().focused(true).classNameMatches(\"android\\.widget\\.(EditText|AutoCompleteTextView)\")"
    )

    static func locators(for element: ScreenElement, platform: DevicePlatform) -> [SemanticLocator] {
        guard element.source == .accessibility else { return [] }
        if platform == .android {
            var androidLocators: [SemanticLocator] = []
            if let name = usableValue(element.name), name.contains(":id/") {
                androidLocators.append(SemanticLocator(using: "id", value: name))
            }
            if let label = usableValue(element.label) {
                androidLocators.append(SemanticLocator(using: "accessibility id", value: label))
            }
            if let value = usableValue(element.value) {
                androidLocators.append(SemanticLocator(
                    using: "-android uiautomator",
                    value: "new UiSelector().text(\(javaStringLiteral(value)))"
                ))
            }
            if let name = usableValue(element.name), !name.contains(":id/") {
                androidLocators.append(SemanticLocator(using: "accessibility id", value: name))
            }
            return unique(androidLocators)
        }
        var locators: [SemanticLocator] = []
        var predicates: [String] = []
        if isElementType(element.type) {
            predicates.append("type == '\(predicateLiteral(element.type))'")
        }
        if let name = usableValue(element.name) {
            predicates.append("name == '\(predicateLiteral(name))'")
        }
        if let label = usableValue(element.label) {
            predicates.append("label == '\(predicateLiteral(label))'")
        }
        if let value = usableValue(element.value) {
            predicates.append("value == '\(predicateLiteral(value))'")
        }
        if !predicates.isEmpty {
            locators.append(SemanticLocator(using: "predicate string", value: predicates.joined(separator: " AND ")))
        }
        if let name = usableValue(element.name) {
            locators.append(SemanticLocator(using: "accessibility id", value: name))
        }
        if element.name == nil, let label = usableValue(element.label) {
            locators.append(SemanticLocator(using: "accessibility id", value: label))
        }
        return unique(locators)
    }

    static func bestMatch(
        among candidates: [ResolvedNativeElement],
        observedFrame: ScreenElementFrame?
    ) -> ResolvedNativeElement? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        guard let observedFrame else { return nil }
        return candidates.compactMap { candidate -> (ResolvedNativeElement, Double)? in
            guard let frame = candidate.frame else { return nil }
            let centerDistance = hypot(
                frame.centerX - observedFrame.centerX,
                frame.centerY - observedFrame.centerY
            )
            let sizeDistance = abs(frame.width - observedFrame.width)
                + abs(frame.height - observedFrame.height)
            return (candidate, centerDistance + sizeDistance * 0.2)
        }.min { $0.1 < $1.1 }?.0
    }

    /// Reads an element reference from a WebDriver element value.
    static func elementReference(_ value: [String: Any]) -> String? {
        value[w3cElementKey] as? String ?? value["ELEMENT"] as? String
    }

    static func frame(_ value: Any?) -> ScreenElementFrame? {
        guard let value = value as? [String: Any],
              let x = number(value["x"]),
              let y = number(value["y"]),
              let width = number(value["width"]),
              let height = number(value["height"]),
              width > 0, height > 0 else { return nil }
        return ScreenElementFrame(x: x, y: y, width: width, height: height)
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Turns a found native element into the public element shape.
    static func publicElement(
        from value: [String: Any],
        reference: String,
        query: String,
        screenSize: DeviceScreenSize
    ) -> ScreenElement {
        let frame = frame(value["rect"])
        let normalizedFrame = frame?.normalized(width: screenSize.width, height: screenSize.height)
        let publicID = String(format: "native-%016llx-00", StableDeviceHash.fnv1a64(reference))
        return ScreenElement(
            id: publicID,
            type: value["type"] as? String ?? "NativeTextMatch",
            name: value["name"] as? String ?? query,
            label: value["label"] as? String ?? query,
            value: value["text"] as? String,
            enabled: value["enabled"] as? Bool ?? true,
            visible: value["displayed"] as? Bool ?? true,
            accessible: true,
            selected: value["selected"] as? Bool,
            index: 0,
            frame: frame,
            frameSpace: frame == nil ? nil : .screenPoints,
            normalizedFrame: normalizedFrame,
            path: "native/0"
        )
    }

    private static func unique(_ locators: [SemanticLocator]) -> [SemanticLocator] {
        locators.reduce(into: []) { result, locator in
            guard !result.contains(locator) else { return }
            result.append(locator)
        }
    }

    private static func usableValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 500 else { return nil }
        return value
    }

    private static func isElementType(_ value: String) -> Bool {
        value.hasPrefix("XCUIElementType")
            && value.dropFirst("XCUIElementType".count).allSatisfy { $0.isLetter || $0.isNumber }
    }

    static func predicateLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\u{0}", with: "")
    }

    private static func javaStringLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{0}", with: "") + "\""
    }

    private static func xpathLiteral(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\u{0}", with: "")
        if !cleaned.contains("'") { return "'\(cleaned)'" }
        if !cleaned.contains("\"") { return "\"\(cleaned)\"" }
        let parts = cleaned.split(separator: "'", omittingEmptySubsequences: false)
        return "concat(" + parts.enumerated().flatMap { index, part -> [String] in
            var result = ["'\(part)'"]
            if index < parts.count - 1 { result.append("\"'\"") }
            return result
        }.joined(separator: ",") + ")"
    }
}
