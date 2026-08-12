import Foundation

enum DeviceAutomationError: LocalizedError, Sendable {
    case deviceNotFound(String)
    case multipleDevices([String])
    case deviceUnavailable
    case permissionRequired
    case appiumUnavailable
    case controlNotReady
    case controlFailed(String)
    case activationRequired
    case mirrorFailed(String)
    case invalidArgument(String)
    case timedOut(String)
    case assertionFailed(String)

    var code: String {
        switch self {
        case .deviceNotFound: "device_not_found"
        case .multipleDevices: "multiple_devices"
        case .deviceUnavailable: "device_unavailable"
        case .permissionRequired: "permission_required"
        case .appiumUnavailable: "appium_unavailable"
        case .controlNotReady: "control_not_ready"
        case .controlFailed: "control_failed"
        case .activationRequired: "activation_required"
        case .mirrorFailed: "mirror_failed"
        case .invalidArgument: "invalid_argument"
        case .timedOut: "timed_out"
        case .assertionFailed: "assertion_failed"
        }
    }

    var errorDescription: String? {
        switch self {
        case let .deviceNotFound(id):
            "No connected device matches '\(id)'. Call list_devices first."
        case let .multipleDevices(ids):
            "Multiple devices are connected. Pass device_id. Available: \(ids.joined(separator: ", "))."
        case .deviceUnavailable:
            "The selected device is unavailable or reconnecting."
        case .permissionRequired:
            "Camera permission is required for USB mirroring. Enable wireless mode to discover Xcode-paired devices without it."
        case .appiumUnavailable:
            "The local Appium service could not start."
        case .controlNotReady:
            "Device control is not ready. Call connect_control first."
        case let .controlFailed(message), let .mirrorFailed(message), let .timedOut(message),
             let .assertionFailed(message):
            message
        case .activationRequired:
            "Activation is required for device control or for using more than one device at the same time."
        case let .invalidArgument(message):
            message
        }
    }
}

struct AutomationDeviceSnapshot: Codable, Equatable, Sendable {
    let deviceID: String
    let udid: String?
    let platform: String
    let name: String
    let productType: String
    let osVersion: String?
    let connectionState: String
    let mirrorState: String
    let controlState: String
    let controlMessage: String
    let screenWidth: Double?
    let screenHeight: Double?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case udid, platform, name
        case productType = "product_type"
        case osVersion = "os_version"
        case connectionState = "connection_state"
        case mirrorState = "mirror_state"
        case controlState = "control_state"
        case controlMessage = "control_message"
        case screenWidth = "screen_width"
        case screenHeight = "screen_height"
    }
}

struct AutomationDiagnosticSnapshot: Codable, Equatable, Sendable {
    let items: [String: String]
    let devices: [AutomationDeviceSnapshot]
}

enum AutomationScrollDirection: String, CaseIterable, Sendable {
    case up, down, left, right
}

struct AutomationTextEditResult: Codable, Equatable, Sendable {
    let action: String
    let strategy: String
    let value: String?
    let verified: Bool
}

struct ScreenHighlightItem: Codable, Equatable, Sendable {
    let number: Int
    let elementID: String
    let type: String
    let label: String
    let normalizedFrame: ScreenElementFrame

    enum CodingKeys: String, CodingKey {
        case number
        case elementID = "element_id"
        case type, label
        case normalizedFrame = "normalized_frame"
    }
}

struct ScreenHighlightResult: Codable, Equatable, Sendable {
    let observationID: UUID
    let highlightedCount: Int
    let durationSeconds: Double
    let items: [ScreenHighlightItem]

    enum CodingKeys: String, CodingKey {
        case observationID = "observation_id"
        case highlightedCount = "highlighted_count"
        case durationSeconds = "duration_seconds"
        case items
    }
}

actor DeviceCommandLock {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var lockedIDs: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]

    func acquire(_ id: String) async throws {
        try Task.checkCancellation()
        if lockedIDs.insert(id).inserted { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id, default: []].append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, deviceID: id) }
        }
    }

    func release(_ id: String) {
        if var queued = waiters[id], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[id] = queued.isEmpty ? nil : queued
            next.continuation.resume()
        } else {
            lockedIDs.remove(id)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, deviceID: String) {
        guard var queued = waiters[deviceID],
              let index = queued.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = queued.remove(at: index)
        waiters[deviceID] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class DeviceAutomationService: @unchecked Sendable {
    private struct NativeElementReferenceCache {
        let observationID: UUID
        let referencesByElementID: [String: String]
    }

    private struct PreparedQuery {
        let raw: String
        let normalized: String
    }

    private unowned let store: DeviceGalleryStore
    private let commandLock = DeviceCommandLock()
    private let screenTextRecognizer = VisionScreenTextRecognizer()
    private var latestObservations: [String: ScreenObservation] = [:]
    private var latestNativeElementReferences: [String: NativeElementReferenceCache] = [:]

    init(store: DeviceGalleryStore) {
        self.store = store
    }

    func listDevices() -> [AutomationDeviceSnapshot] {
        store.sessions.map(snapshot(for:))
    }

    func refreshDevices() async throws -> [AutomationDeviceSnapshot] {
        try await store.refreshForAutomation()
        return listDevices()
    }

    func deviceStatus(deviceID: String?) throws -> AutomationDeviceSnapshot {
        snapshot(for: try selectSession(deviceID: deviceID))
    }

    func diagnostics() -> AutomationDiagnosticSnapshot {
        AutomationDiagnosticSnapshot(
            items: Dictionary(uniqueKeysWithValues: store.diagnostics.map { ($0.name, $0.value) }),
            devices: listDevices()
        )
    }

    func observeScreen(
        deviceID: String?,
        includeImage: Bool,
        includeAccessibility: Bool,
        includeOCR: Bool,
        ocrMode: ScreenOCRMode,
        ocrLanguages: [String]
    ) async throws -> ScreenObservationResult {
        let session = try selectSession(deviceID: deviceID)
        let normalizedOCRLanguages = includeOCR
            ? try Self.normalizedOCRLanguages(ocrLanguages)
            : []
        let frameTask = includeImage || includeOCR
            ? Task.detached(priority: .utility) {
                session.mirrorSession.latestFrameStore.snapshot(includePNG: includeImage)
            }
            : nil

        var accessibilityElements: [ScreenElement] = []
        var accessibilityAvailable = false
        var accessibilityError: String?
        if includeAccessibility, session.controlSession.isReady {
            do {
                let xml = try await withDeviceLock(session.id) {
                    try await session.controlSession.pageSource(serverURL: self.store.appiumServerURL)
                }
                let screenSize = session.controlSession.screenSize
                accessibilityElements = await Task.detached(priority: .utility) {
                    ScreenElementParser.parse(xml, screenSize: screenSize)
                }.value
                accessibilityAvailable = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                accessibilityError = error.localizedDescription
            }
        } else if includeAccessibility {
            accessibilityError = DeviceAutomationError.controlNotReady.localizedDescription
        }
        let frame = await frameTask?.value

        var ocrElements: [ScreenElement] = []
        var ocrAvailable = false
        var ocrError: String?
        if includeOCR {
            if let frame {
                do {
                    try Task.checkCancellation()
                    let recognized = try await screenTextRecognizer.recognize(
                        deviceID: session.id,
                        snapshot: frame,
                        mode: ocrMode,
                        languages: normalizedOCRLanguages
                    )
                    ocrElements = ScreenOCRElementFactory.makeElements(
                        from: recognized,
                        screenSize: session.controlSession.screenSize,
                        imageWidth: frame.width,
                        imageHeight: frame.height
                    )
                    ocrAvailable = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    ocrError = error.localizedDescription
                }
            } else {
                ocrError = "No live mirror frame is available. Call start_mirror first."
            }
        }
        let elements = ScreenElementFusion.merge(
            accessibility: accessibilityElements,
            ocr: ocrElements
        )
        let observation = ScreenObservation(
            id: UUID(),
            deviceID: session.id,
            capturedAt: Date(),
            mirrorState: Self.mirrorStateValue(session.mirrorSession.state),
            controlState: Self.controlStateValue(session.controlSession.state),
            imageAvailable: frame?.pngData != nil,
            imageWidth: frame?.width,
            imageHeight: frame?.height,
            accessibilityAvailable: accessibilityAvailable,
            accessibilityError: accessibilityError,
            ocrAvailable: ocrAvailable,
            ocrError: ocrError,
            ocrMode: includeOCR ? ocrMode : nil,
            ocrLanguages: normalizedOCRLanguages,
            elements: elements
        )
        let result = ScreenObservationResult(
            observation: observation,
            imageData: frame?.pngData
        )
        // Cache semantic metadata only. The full PNG is returned to the caller
        // but must not remain retained in the long-lived automation service.
        latestObservations[session.id] = observation
        latestNativeElementReferences[session.id] = nil
        return result
    }

    func findElements(
        deviceID: String?,
        query: String,
        includeOCR: Bool,
        ocrMode: ScreenOCRMode,
        ocrLanguages: [String]
    ) async throws -> ScreenElementSearchResult {
        let batch = try await findAnyElements(
            deviceID: deviceID,
            queries: [query],
            includeOCR: includeOCR,
            ocrMode: ocrMode,
            ocrLanguages: ocrLanguages
        )
        return ScreenElementSearchResult(
            observationID: batch.observationID,
            query: query,
            sourcesChecked: batch.sourcesChecked,
            matches: batch.matches
        )
    }

    /// Resolves multiple alternative labels as one state inspection. The live
    /// mirror is cheap to OCR, so use it first when requested. If pixels do not
    /// expose the label (for example an icon-only SpringBoard item), fetch and
    /// parse the WDA hierarchy once for every candidate instead of paying one
    /// negative native predicate lookup per synonym.
    func findAnyElements(
        deviceID: String?,
        queries: [String],
        includeOCR: Bool,
        ocrMode: ScreenOCRMode,
        ocrLanguages: [String]
    ) async throws -> ScreenElementBatchSearchResult {
        let preparedQueries = try Self.preparedQueries(queries)
        let session = try readyControlSession(deviceID: deviceID)

        if includeOCR {
            let ocrResult = try await observeScreen(
                deviceID: session.id,
                includeImage: false,
                includeAccessibility: false,
                includeOCR: true,
                ocrMode: ocrMode,
                ocrLanguages: ocrLanguages
            )
            guard ocrResult.observation.ocrAvailable else {
                throw DeviceAutomationError.controlFailed(
                    ocrResult.observation.ocrError ?? "Local OCR is unavailable."
                )
            }
            if let match = Self.firstMatch(
                in: ocrResult.observation.elements,
                candidates: preparedQueries,
                source: .ocr
            ) {
                return ScreenElementBatchSearchResult(
                    observationID: ocrResult.observation.id,
                    queries: preparedQueries.map(\.raw),
                    matchedQuery: match.query.raw,
                    sourcesChecked: [.ocr],
                    matches: match.elements
                )
            }
        }

        let hierarchyResult = try await observeScreen(
            deviceID: session.id,
            includeImage: false,
            includeAccessibility: true,
            includeOCR: false,
            ocrMode: ocrMode,
            ocrLanguages: []
        )
        if let match = Self.firstMatch(
            in: hierarchyResult.observation.elements,
            candidates: preparedQueries,
            source: .accessibility
        ) {
            return ScreenElementBatchSearchResult(
                observationID: hierarchyResult.observation.id,
                queries: preparedQueries.map(\.raw),
                matchedQuery: match.query.raw,
                sourcesChecked: includeOCR ? [.ocr, .accessibility] : [.accessibility],
                matches: match.elements
            )
        }
        return ScreenElementBatchSearchResult(
            observationID: hierarchyResult.observation.id,
            queries: preparedQueries.map(\.raw),
            matchedQuery: nil,
            sourcesChecked: includeOCR ? [.ocr, .accessibility] : [.accessibility],
            matches: []
        )
    }

    func tapText(
        deviceID: String?,
        queries: [String],
        includeOCR: Bool,
        ocrMode: ScreenOCRMode,
        ocrLanguages: [String]
    ) async throws -> ScreenTextTapResult {
        let result = try await findAnyElements(
            deviceID: deviceID,
            queries: queries,
            includeOCR: includeOCR,
            ocrMode: ocrMode,
            ocrLanguages: ocrLanguages
        )
        guard let matchedQuery = result.matchedQuery,
              let match = result.matches.first else {
            throw DeviceAutomationError.invalidArgument(
                "No visible element matched any requested text."
            )
        }
        let tap = try await tapElement(
            deviceID: deviceID,
            observationID: result.observationID,
            elementID: match.id
        )
        return ScreenTextTapResult(
            matchedQuery: matchedQuery,
            observationID: tap.observationID,
            elementID: tap.elementID,
            source: tap.source,
            strategy: tap.strategy
        )
    }

    func tapElement(
        deviceID: String?,
        observationID: UUID?,
        elementID: String
    ) async throws -> ScreenElementTapResult {
        let session = try readyControlSession(deviceID: deviceID)
        guard let cached = latestObservations[session.id] else {
            throw DeviceAutomationError.invalidArgument(
                "No screen observation is available. Call observe_screen or find_element first."
            )
        }
        if let observationID, cached.id != observationID {
            throw DeviceAutomationError.invalidArgument(
                "The observation is stale. Observe the screen again before tapping."
            )
        }
        guard let element = cached.elements.first(where: { $0.id == elementID }),
              element.visible, element.enabled else {
            throw DeviceAutomationError.invalidArgument(
                "The element is missing, hidden, or disabled."
            )
        }
        session.mirrorSession.showAutomationTarget(
            normalizedFrame: element.normalizedFrame,
            label: element.source == .accessibility ? "AI · Element" : "AI · OCR"
        )
        await Task.yield()

        if element.source == .accessibility {
            if let nativeCache = latestNativeElementReferences[session.id],
               nativeCache.observationID == cached.id,
               let reference = nativeCache.referencesByElementID[element.id] {
                do {
                    try await withDeviceLock(session.id) {
                        try await session.controlSession.clickElementReferenceAwaiting(
                            reference,
                            serverURL: self.store.appiumServerURL
                        )
                    }
                    return ScreenElementTapResult(
                        observationID: cached.id,
                        elementID: element.id,
                        source: element.source,
                        strategy: "wda_element"
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The reference can become stale after an app transition.
                    // Re-resolve the semantic metadata below before falling
                    // back to the observed frame.
                }
            }
            // A parsed hierarchy has no WDA element reference. Its frame is
            // already fresh and actionable, whereas resolving the same label
            // again can cost several seconds on SpringBoard. Only re-resolve
            // elements that have no usable geometry.
            if element.normalizedFrame == nil, element.frame == nil {
                let clicked = try await withDeviceLock(session.id) {
                    try await session.controlSession.clickSemanticElementAwaiting(
                        element,
                        serverURL: self.store.appiumServerURL
                    )
                }
                if clicked {
                    return ScreenElementTapResult(
                        observationID: cached.id,
                        elementID: element.id,
                        source: element.source,
                        strategy: "wda_element"
                    )
                }
            }
        }

        guard let size = session.controlSession.screenSize, size.width > 0, size.height > 0 else {
            throw DeviceAutomationError.controlNotReady
        }
        let normalizedFrame = element.normalizedFrame
            ?? element.frame?.normalized(width: size.width, height: size.height)
        guard let normalizedFrame else {
            throw DeviceAutomationError.invalidArgument(
                "The element could not be resolved by WDA and has no tappable frame."
            )
        }
        let x = min(max(normalizedFrame.centerX, 0), 1)
        let y = min(max(normalizedFrame.centerY, 0), 1)
        try await withDeviceLock(session.id) {
            try await session.controlSession.tapNormalizedAwaiting(
                x: x,
                y: y,
                serverURL: self.store.appiumServerURL
            )
        }
        return ScreenElementTapResult(
            observationID: cached.id,
            elementID: element.id,
            source: element.source,
            strategy: "coordinate_fallback"
        )
    }

    func highlightElements(
        deviceID: String?,
        observationID: UUID?,
        elementIDs: [String],
        durationSeconds: Double
    ) throws -> ScreenHighlightResult {
        let session = try readyControlSession(deviceID: deviceID)
        let durationMilliseconds = try Self.highlightDurationMilliseconds(durationSeconds)
        guard !elementIDs.isEmpty else {
            throw DeviceAutomationError.invalidArgument("element_ids must not be empty.")
        }
        guard let cached = latestObservations[session.id] else {
            throw DeviceAutomationError.invalidArgument(
                "No screen observation is available. Call observe_screen or find_element first."
            )
        }
        if let observationID, cached.id != observationID {
            throw DeviceAutomationError.invalidArgument(
                "The observation is stale. Observe the screen again before highlighting."
            )
        }
        let items = try Self.highlightItems(
            elements: cached.elements,
            requestedIDs: elementIDs
        )
        session.mirrorSession.showAutomationHighlights(
            items.map { ($0.normalizedFrame, "\($0.number)") },
            durationMilliseconds: durationMilliseconds
        )
        return ScreenHighlightResult(
            observationID: cached.id,
            highlightedCount: items.count,
            durationSeconds: durationSeconds,
            items: items
        )
    }

    func highlightClickableElements(
        deviceID: String?,
        durationSeconds: Double
    ) async throws -> ScreenHighlightResult {
        let durationMilliseconds = try Self.highlightDurationMilliseconds(durationSeconds)
        let session = try readyControlSession(deviceID: deviceID)
        let observationResult = try await observeScreen(
            deviceID: session.id,
            includeImage: false,
            includeAccessibility: true,
            includeOCR: false,
            ocrMode: .fast,
            ocrLanguages: []
        )
        let clickable = observationResult.observation.elements
            .filter(\.isGuideClickable)
            .sorted { lhs, rhs in
                guard let left = lhs.normalizedFrame, let right = rhs.normalizedFrame else {
                    return lhs.id < rhs.id
                }
                if abs(left.y - right.y) > 0.001 { return left.y < right.y }
                if abs(left.x - right.x) > 0.001 { return left.x < right.x }
                return lhs.id < rhs.id
            }
        let items = try Self.highlightItems(
            elements: clickable,
            requestedIDs: clickable.map(\.id)
        )
        session.mirrorSession.showAutomationHighlights(
            items.map { ($0.normalizedFrame, "\($0.number)") },
            durationMilliseconds: durationMilliseconds
        )
        return ScreenHighlightResult(
            observationID: observationResult.observation.id,
            highlightedCount: items.count,
            durationSeconds: durationSeconds,
            items: items
        )
    }

    func clearHighlights(deviceID: String?) throws {
        let session = try selectSession(deviceID: deviceID)
        session.mirrorSession.clearAutomationHighlights()
    }

    nonisolated private static func highlightDurationMilliseconds(_ seconds: Double) throws -> Int {
        guard (1...60).contains(seconds) else {
            throw DeviceAutomationError.invalidArgument("duration_seconds must be between 1 and 60.")
        }
        return Int((seconds * 1_000).rounded())
    }

    nonisolated static func highlightItems(
        elements: [ScreenElement],
        requestedIDs: [String]
    ) throws -> [ScreenHighlightItem] {
        let byID = elements.reduce(into: [String: ScreenElement]()) { result, element in
            result[element.id] = element
        }
        var seenIDs: Set<String> = []
        var seenFrames: Set<String> = []
        var selected: [(ScreenElement, ScreenElementFrame)] = []
        for id in requestedIDs where seenIDs.insert(id).inserted {
            guard let element = byID[id], element.visible, element.enabled,
                  let frame = element.normalizedFrame,
                  frame.width > 0, frame.height > 0 else { continue }
            // Native trees can expose both a tappable container and a child
            // with the same geometry. Keep one guide mark for that target.
            let frameKey = [frame.x, frame.y, frame.width, frame.height]
                .map { String(format: "%.4f", $0) }
                .joined(separator: ":")
            guard seenFrames.insert(frameKey).inserted else { continue }
            selected.append((element, frame))
        }
        guard !selected.isEmpty else {
            throw DeviceAutomationError.invalidArgument("No visible enabled elements with geometry were found.")
        }
        return selected.enumerated().map { offset, entry in
            let element = entry.0
            let label = [element.label, element.name, element.value]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? element.type
            return ScreenHighlightItem(
                number: offset + 1,
                elementID: element.id,
                type: element.type,
                label: label,
                normalizedFrame: entry.1
            )
        }
    }

    func waitForElement(
        deviceID: String?,
        query: String,
        state: String,
        timeoutSeconds: Double,
        includeOCR: Bool,
        ocrMode: ScreenOCRMode,
        ocrLanguages: [String]
    ) async throws -> ScreenConditionResult {
        _ = try Self.normalizedQuery(query)
        guard state == "present" || state == "absent" else {
            throw DeviceAutomationError.invalidArgument("state must be present or absent.")
        }
        guard (0.5...60).contains(timeoutSeconds) else {
            throw DeviceAutomationError.invalidArgument("timeout_seconds must be between 0.5 and 60.")
        }
        let deadline = ContinuousClock.now + .milliseconds(Int(timeoutSeconds * 1_000))
        while true {
            try Task.checkCancellation()
            let result = try await findElements(
                deviceID: deviceID,
                query: query,
                includeOCR: includeOCR,
                ocrMode: ocrMode,
                ocrLanguages: ocrLanguages
            )
            let count = result.matches.count
            let satisfied = state == "present" ? count > 0 : count == 0
            if satisfied {
                return ScreenConditionResult(
                    observationID: result.observationID,
                    query: query,
                    state: state,
                    satisfied: true,
                    matchCount: count,
                    sourcesChecked: result.sourcesChecked
                )
            }
            guard .now < deadline else {
                throw DeviceAutomationError.timedOut(
                    "Screen condition was not met within \(timeoutSeconds) seconds: \(state) '\(query)'."
                )
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    func assertScreen(
        deviceID: String?,
        query: String,
        state: String,
        includeOCR: Bool,
        ocrMode: ScreenOCRMode,
        ocrLanguages: [String]
    ) async throws -> ScreenConditionResult {
        _ = try Self.normalizedQuery(query)
        guard state == "present" || state == "absent" else {
            throw DeviceAutomationError.invalidArgument("state must be present or absent.")
        }
        let result = try await findElements(
            deviceID: deviceID,
            query: query,
            includeOCR: includeOCR,
            ocrMode: ocrMode,
            ocrLanguages: ocrLanguages
        )
        let count = result.matches.count
        let satisfied = state == "present" ? count > 0 : count == 0
        guard satisfied else {
            throw DeviceAutomationError.assertionFailed(
                "Expected screen element to be \(state): '\(query)'. Found \(count) matches."
            )
        }
        return ScreenConditionResult(
            observationID: result.observationID,
            query: query,
            state: state,
            satisfied: true,
            matchCount: count,
            sourcesChecked: result.sourcesChecked
        )
    }

    func startMirror(deviceID: String?) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await self.store.startMirrorForAutomation(for: session)
        }
        return snapshot(for: session)
    }

    func stopMirror(deviceID: String?) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        await withDeviceLockIgnoringResult(session.id) {
            self.store.stop(session)
        }
        return snapshot(for: session)
    }

    func setMirrorFloating(deviceID: String?, floating: Bool) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        await withDeviceLockIgnoringResult(session.id) {
            self.store.setFloatingForAutomation(floating, session: session)
        }
        return snapshot(for: session)
    }

    func connectControl(deviceID: String?) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            try await self.store.connectControlForAutomation(for: session)
        }
        return snapshot(for: session)
    }

    func disconnectControl(deviceID: String?) async throws -> AutomationDeviceSnapshot {
        let session = try selectSession(deviceID: deviceID)
        try await withDeviceLock(session.id) {
            await session.controlSession.shutdown(serverURL: self.store.appiumServerURL)
        }
        return snapshot(for: session)
    }

    func screenshot(deviceID: String?) async throws -> Data {
        let session = try readyControlSession(deviceID: deviceID)
        return try await withDeviceLock(session.id) {
            try await session.controlSession.screenshot(serverURL: self.store.appiumServerURL)
        }
    }

    func uiTree(deviceID: String?) async throws -> String {
        let session = try readyControlSession(deviceID: deviceID)
        return try await withDeviceLock(session.id) {
            try await session.controlSession.pageSource(serverURL: self.store.appiumServerURL)
        }
    }

    func tap(deviceID: String?, x: Double, y: Double) async throws {
        try Self.validatePoint(x: x, y: y)
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationPoint(
            CGPoint(x: x, y: y),
            label: "AI · Tap"
        )
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.tapNormalizedAwaiting(
                x: x, y: y, serverURL: self.store.appiumServerURL
            )
        }
    }

    func doubleTap(deviceID: String?, x: Double, y: Double) async throws {
        try Self.validatePoint(x: x, y: y)
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationPoint(
            CGPoint(x: x, y: y),
            kind: .doubleTap,
            label: "AI · Double Tap"
        )
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.doubleTapNormalizedAwaiting(
                x: x, y: y, serverURL: self.store.appiumServerURL
            )
        }
    }

    func longPress(deviceID: String?, x: Double, y: Double, durationSeconds: Double) async throws {
        try Self.validatePoint(x: x, y: y)
        guard (0.5...10).contains(durationSeconds) else {
            throw DeviceAutomationError.invalidArgument("duration_seconds must be between 0.5 and 10.")
        }
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationPoint(
            CGPoint(x: x, y: y),
            kind: .longPress,
            label: "AI · Long Press"
        )
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.longPressNormalizedAwaiting(
                x: x,
                y: y,
                durationSeconds: durationSeconds,
                serverURL: self.store.appiumServerURL
            )
        }
    }

    func swipe(
        deviceID: String?,
        startX: Double,
        startY: Double,
        endX: Double,
        endY: Double,
        durationMS: Int
    ) async throws {
        try Self.validatePoint(x: startX, y: startY)
        try Self.validatePoint(x: endX, y: endY)
        guard (50...5_000).contains(durationMS) else {
            throw DeviceAutomationError.invalidArgument("duration_ms must be between 50 and 5000.")
        }
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationSwipe(
            from: CGPoint(x: startX, y: startY),
            to: CGPoint(x: endX, y: endY),
            label: "AI · Swipe"
        )
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.swipeNormalizedAwaiting(
                from: CGPoint(x: startX, y: startY),
                to: CGPoint(x: endX, y: endY),
                durationMS: durationMS,
                serverURL: self.store.appiumServerURL
            )
        }
    }

    func flick(deviceID: String?, direction: ControlFlickDirection) async throws {
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationNotice("AI · Flick")
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.flickAwaiting(
                direction: direction,
                serverURL: self.store.appiumServerURL
            )
        }
    }

    func scroll(
        deviceID: String?,
        direction: AutomationScrollDirection,
        distance: Double,
        centerX: Double,
        centerY: Double
    ) async throws {
        try Self.validatePoint(x: centerX, y: centerY)
        guard (0.05...0.9).contains(distance) else {
            throw DeviceAutomationError.invalidArgument("distance must be between 0.05 and 0.9.")
        }
        let margin = 0.03
        let start = CGPoint(x: centerX, y: centerY)
        let end: CGPoint
        switch direction {
        case .down:
            end = CGPoint(x: centerX, y: max(margin, centerY - distance))
        case .up:
            end = CGPoint(x: centerX, y: min(1 - margin, centerY + distance))
        case .right:
            end = CGPoint(x: max(margin, centerX - distance), y: centerY)
        case .left:
            end = CGPoint(x: min(1 - margin, centerX + distance), y: centerY)
        }
        try await swipe(
            deviceID: deviceID,
            startX: start.x,
            startY: start.y,
            endX: end.x,
            endY: end.y,
            durationMS: 300
        )
    }

    func typeText(deviceID: String?, text: String) async throws {
        guard !text.isEmpty else {
            throw DeviceAutomationError.invalidArgument("text must not be empty.")
        }
        guard text.utf8.count <= 10_000 else {
            throw DeviceAutomationError.invalidArgument("text is limited to 10,000 UTF-8 bytes.")
        }
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationNotice("AI · Type \(text.count) chars")
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.typeTextAwaiting(text, serverURL: self.store.appiumServerURL)
        }
    }

    func clearText(deviceID: String?) async throws -> AutomationTextEditResult {
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationNotice("AI · Clear text")
        await Task.yield()
        let result = try await withDeviceLock(session.id) {
            try await session.controlSession.clearTextAwaiting(
                serverURL: self.store.appiumServerURL
            )
        }
        return AutomationTextEditResult(
            action: "clear_text",
            strategy: result.strategy,
            value: result.value,
            verified: result.verified
        )
    }

    func replaceText(deviceID: String?, text: String) async throws -> AutomationTextEditResult {
        guard !text.isEmpty else {
            throw DeviceAutomationError.invalidArgument(
                "text must not be empty. Use clear_text to empty the active field."
            )
        }
        guard text.utf8.count <= 10_000 else {
            throw DeviceAutomationError.invalidArgument("text is limited to 10,000 UTF-8 bytes.")
        }
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationNotice("AI · Replace with \(text.count) chars")
        await Task.yield()
        let result = try await withDeviceLock(session.id) {
            try await session.controlSession.replaceTextAwaiting(
                text,
                serverURL: self.store.appiumServerURL
            )
        }
        return AutomationTextEditResult(
            action: "replace_text",
            strategy: result.strategy,
            value: result.value,
            verified: result.verified
        )
    }

    func pressButton(deviceID: String?, name: String) async throws {
        let appiumName: String
        switch name {
        case "home": appiumName = "home"
        case "volume_up": appiumName = "volumeUp"
        case "volume_down": appiumName = "volumeDown"
        default:
            throw DeviceAutomationError.invalidArgument(
                "button must be home, volume_up, or volume_down."
            )
        }
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationNotice("AI · \(name.replacingOccurrences(of: "_", with: " ").capitalized)")
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.pressButtonAwaiting(
                appiumName, serverURL: self.store.appiumServerURL
            )
        }
    }

    func back(deviceID: String?) async throws {
        let session = try readyControlSession(deviceID: deviceID)
        if session.platform == .android {
            session.mirrorSession.showAutomationNotice("AI · Back")
        } else {
            session.mirrorSession.showAutomationPoint(
                CGPoint(x: 0.09, y: 0.075),
                label: "AI · Back"
            )
        }
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.pressBackAwaiting(serverURL: self.store.appiumServerURL)
        }
    }

    func appSwitcher(deviceID: String?) async throws {
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationNotice("AI · App Switcher")
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.openAppSwitcherAwaiting(serverURL: self.store.appiumServerURL)
        }
    }

    func activateApp(deviceID: String?, bundleID: String) async throws {
        try Self.validateBundleID(bundleID)
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationNotice("AI · Open App")
        await Task.yield()
        try await withDeviceLock(session.id) {
            try await session.controlSession.activateApp(
                bundleID: bundleID, serverURL: self.store.appiumServerURL
            )
        }
    }

    func terminateApp(deviceID: String?, bundleID: String) async throws -> Bool {
        try Self.validateBundleID(bundleID)
        let session = try readyControlSession(deviceID: deviceID)
        session.mirrorSession.showAutomationNotice("AI · Terminate App")
        await Task.yield()
        return try await withDeviceLock(session.id) {
            try await session.controlSession.terminateApp(
                bundleID: bundleID, serverURL: self.store.appiumServerURL
            )
        }
    }

    private func cacheFastAccessibilityObservation(
        session: DeviceSession,
        nativeMatches: [AppiumNativeElementMatch]
    ) -> ScreenObservation {
        let observation = ScreenObservation(
            id: UUID(),
            deviceID: session.id,
            capturedAt: Date(),
            mirrorState: Self.mirrorStateValue(session.mirrorSession.state),
            controlState: Self.controlStateValue(session.controlSession.state),
            imageAvailable: false,
            imageWidth: nil,
            imageHeight: nil,
            accessibilityAvailable: true,
            accessibilityError: nil,
            ocrAvailable: false,
            ocrError: nil,
            ocrMode: nil,
            ocrLanguages: [],
            elements: nativeMatches.map(\.element)
        )
        latestObservations[session.id] = observation
        latestNativeElementReferences[session.id] = NativeElementReferenceCache(
            observationID: observation.id,
            referencesByElementID: Dictionary(
                uniqueKeysWithValues: nativeMatches.map { ($0.element.id, $0.reference) }
            )
        )
        return observation
    }

    nonisolated static func validatePoint(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw DeviceAutomationError.invalidArgument("Coordinates must be finite values from 0 to 1.")
        }
    }

    nonisolated static func validateBundleID(_ bundleID: String) throws {
        let value = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard value.count >= 3,
              value.count <= 255,
              value.contains("."),
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DeviceAutomationError.invalidArgument("bundle_id is invalid.")
        }
    }

    nonisolated private static func normalizedQuery(_ query: String) throws -> String {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.count <= 500 else {
            throw DeviceAutomationError.invalidArgument("query must contain 1 to 500 characters.")
        }
        return value
    }

    nonisolated private static func preparedQueries(_ queries: [String]) throws -> [PreparedQuery] {
        guard (1...16).contains(queries.count) else {
            throw DeviceAutomationError.invalidArgument("queries must contain 1 to 16 values.")
        }
        var seen: Set<String> = []
        var result: [PreparedQuery] = []
        for query in queries {
            let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = try normalizedQuery(raw)
            guard seen.insert(normalized).inserted else { continue }
            result.append(PreparedQuery(raw: raw, normalized: normalized))
        }
        guard !result.isEmpty else {
            throw DeviceAutomationError.invalidArgument("queries must contain a nonempty value.")
        }
        return result
    }

    nonisolated private static func firstMatch(
        in elements: [ScreenElement],
        candidates: [PreparedQuery],
        source: ScreenElementSource
    ) -> (query: PreparedQuery, elements: [ScreenElement])? {
        for candidate in candidates {
            let matches = elements.filter {
                $0.source == source
                    && $0.visible
                    && $0.enabled
                    && $0.searchableText.contains(candidate.normalized)
            }
            if !matches.isEmpty {
                return (candidate, matches)
            }
        }
        return nil
    }

    nonisolated static var defaultOCRLanguages: [String] {
        ["zh-Hans", "en-US"]
    }

    nonisolated private static func normalizedOCRLanguages(_ languages: [String]) throws -> [String] {
        let requested = languages.isEmpty ? defaultOCRLanguages : languages
        guard requested.count <= 8 else {
            throw DeviceAutomationError.invalidArgument("ocr_languages accepts at most 8 language identifiers.")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var result: [String] = []
        for rawValue in requested {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...35).contains(value.count),
                  value.unicodeScalars.allSatisfy(allowed.contains) else {
                throw DeviceAutomationError.invalidArgument(
                    "OCR language identifiers must look like zh-Hans or en-US."
                )
            }
            if !result.contains(value) { result.append(value) }
        }
        return result
    }

    nonisolated private static func mirrorStateValue(_ state: MirrorState) -> String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .failed: "failed"
        }
    }

    nonisolated private static func controlStateValue(_ state: ControlState) -> String {
        switch state {
        case .unavailable: "disconnected"
        case .connecting: "connecting"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    private func selectSession(deviceID: String?) throws -> DeviceSession {
        let connected = store.sessions.filter { $0.device.connectionState == .connected }
        if let requested = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            guard let session = connected.first(where: {
                $0.id == requested || $0.device.udid == requested
            }) else {
                throw DeviceAutomationError.deviceNotFound(requested)
            }
            return session
        }
        guard connected.count == 1 else {
            if connected.isEmpty { throw DeviceAutomationError.deviceNotFound("connected") }
            throw DeviceAutomationError.multipleDevices(connected.map(\.id))
        }
        return connected[0]
    }

    private func readyControlSession(deviceID: String?) throws -> DeviceSession {
        guard store.canUseControl else {
            throw DeviceAutomationError.activationRequired
        }
        let session = try selectSession(deviceID: deviceID)
        guard session.controlSession.isReady else { throw DeviceAutomationError.controlNotReady }
        return session
    }

    private func snapshot(for session: DeviceSession) -> AutomationDeviceSnapshot {
        let mirrorState: String
        switch session.mirrorSession.state {
        case .stopped: mirrorState = "stopped"
        case .starting: mirrorState = "starting"
        case .running: mirrorState = "running"
        case .failed: mirrorState = "failed"
        }
        let controlState: String
        switch session.controlSession.state {
        case .unavailable: controlState = "disconnected"
        case .connecting: controlState = "connecting"
        case .ready: controlState = "ready"
        case .failed: controlState = "failed"
        }
        return AutomationDeviceSnapshot(
            deviceID: session.id,
            udid: session.device.udid,
            platform: session.platform.rawValue,
            name: session.device.name,
            productType: session.device.productType,
            osVersion: session.device.osVersion,
            connectionState: session.device.connectionState.rawValue,
            mirrorState: mirrorState,
            controlState: controlState,
            controlMessage: session.controlSession.statusMessage,
            screenWidth: session.controlSession.screenSize?.width,
            screenHeight: session.controlSession.screenSize?.height
        )
    }

    private func withDeviceLock<T: Sendable>(
        _ id: String,
        operation: () async throws -> T
    ) async throws -> T {
        try await commandLock.acquire(id)
        if Task.isCancelled {
            await commandLock.release(id)
            throw CancellationError()
        }
        let result: Result<T, Error>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        await commandLock.release(id)
        return try result.get()
    }

    private func withDeviceLockIgnoringResult(
        _ id: String,
        operation: () -> Void
    ) async {
        guard (try? await commandLock.acquire(id)) != nil else { return }
        guard !Task.isCancelled else {
            await commandLock.release(id)
            return
        }
        operation()
        await commandLock.release(id)
    }
}
