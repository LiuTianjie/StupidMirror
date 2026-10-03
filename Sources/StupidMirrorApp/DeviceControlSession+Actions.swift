import CoreGraphics
import Foundation

/// Awaited control actions for automation. Coordinates are normalized
/// mirror coordinates (0...1); the session converts them to device points.
extension DeviceControlSession {
    func tap(normalizedX x: Double, normalizedY y: Double) async throws {
        let point = try devicePoint(normalizedX: x, normalizedY: y)
        try await perform { try await $0.tap(point) }
    }

    func doubleTap(normalizedX x: Double, normalizedY y: Double) async throws {
        let point = try devicePoint(normalizedX: x, normalizedY: y)
        try await perform { try await $0.doubleTap(point) }
    }

    func longPress(normalizedX x: Double, normalizedY y: Double, durationSeconds: Double) async throws {
        let point = try devicePoint(normalizedX: x, normalizedY: y)
        try await perform { try await $0.longPress(point, durationSeconds: durationSeconds) }
    }

    func swipe(fromNormalized start: CGPoint, toNormalized end: CGPoint, durationMS: Int) async throws {
        let startPoint = try devicePoint(normalizedX: start.x, normalizedY: start.y)
        let endPoint = try devicePoint(normalizedX: end.x, normalizedY: end.y)
        try await perform { try await $0.drag(from: startPoint, to: endPoint, durationMS: durationMS) }
    }

    func flick(_ direction: ControlFlickDirection) async throws {
        try await perform { backend in
            let points = Self.flickPoints(direction: direction, size: backend.screenSize)
            try await backend.drag(from: points.start, to: points.end, durationMS: 120)
        }
    }

    func typeText(_ text: String) async throws {
        try await perform { try await $0.typeText(text) }
    }

    func clearText() async throws -> ControlTextEditResult {
        try await perform { try await $0.clearActiveText() }
    }

    func replaceText(_ text: String) async throws -> ControlTextEditResult {
        try await perform { try await $0.replaceActiveText(text) }
    }

    func press(_ button: DeviceButton) async throws {
        try await perform { try await $0.press(button) }
    }

    func screenshot() async throws -> Data {
        try await perform { try await $0.screenshotPNG() }
    }

    func uiTree() async throws -> String {
        try await perform { try await $0.uiTree() }
    }

    func findTextElements(query: String, maximumMatches: Int = 12) async throws -> [NativeElementMatch] {
        try await perform { try await $0.findTextElements(query: query, maximumMatches: maximumMatches) }
    }

    func click(elementReference: String) async throws {
        try await perform { try await $0.click(elementReference: elementReference) }
    }

    func click(semantic element: ScreenElement) async throws -> Bool {
        try await perform { try await $0.click(semantic: element) }
    }

    func activateApp(_ identifier: String) async throws {
        try await perform { try await $0.activateApp(identifier) }
    }

    func terminateApp(_ identifier: String) async throws -> Bool {
        try await perform { try await $0.terminateApp(identifier) }
    }
}
