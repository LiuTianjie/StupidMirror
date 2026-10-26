import Foundation

struct CodexPreviewSignal: Codable, Sendable {
    var peerID: String?
    var type: String?
    var sdp: String?
    enum CodingKeys: String, CodingKey { case peerID = "peer_id", type, sdp }
}

struct CodexPreviewTouchEvent: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case down, move, up, cancel }
    struct Scroll: Codable, Sendable {
        let deltaX: Double
        let deltaY: Double
        enum CodingKeys: String, CodingKey { case deltaX = "delta_x", deltaY = "delta_y" }
        var isValid: Bool {
            deltaX.isFinite && deltaY.isFinite && abs(deltaX) <= 1_000_000 && abs(deltaY) <= 1_000_000
        }
    }
    let phase: Phase
    let gestureID: String
    let sequence: Int
    let x: Double
    let y: Double
    let geometryID: String?
    var scroll: Scroll? = nil
    enum CodingKeys: String, CodingKey {
        case phase, x, y, scroll
        case gestureID = "gesture_id", sequence = "seq", geometryID = "geometry_id"
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        phase = try values.decode(Phase.self, forKey: .phase)
        gestureID = try values.decode(String.self, forKey: .gestureID)
        sequence = try values.decode(Int.self, forKey: .sequence)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        geometryID = try values.decodeIfPresent(String.self, forKey: .geometryID)
        // Omission selects the legacy pointer contract; explicit null is not
        // an input type and must match the helper's strict validation.
        scroll = values.contains(.scroll) ? try values.decode(Scroll.self, forKey: .scroll) : nil
    }
    var isValid: Bool {
        !gestureID.isEmpty && gestureID.utf8.count <= 128 && sequence >= 0
            && sequence <= 9_007_199_254_740_991 && x.isFinite && y.isFinite
            && (0...1).contains(x) && (0...1).contains(y)
            && (geometryID?.utf8.count ?? 0) <= 128
            && (scroll?.isValid ?? true)
            && (scroll == nil || phase == .down || phase == .move || (scroll?.deltaX == 0 && scroll?.deltaY == 0))
    }

    /// Browser wheel input has no AppKit phase or Mach clock. Timestamp its
    /// arrival and preserve each source delta, without creating a finger.
    func touchEvent() throws -> TouchEvent {
        guard isValid, let phase = TouchPhase(rawValue: phase.rawValue) else {
            throw TouchSessionError.invalidPoint
        }
        let nativeInput: HIDNativeInput?
        if let scroll {
            let reports: [HIDInputReport]
            if phase == .down || phase == .move {
                reports = [HIDInputReport(serviceID: 0x501, data: try PhysicalHIDWire.scrollReport(
                    rawDelta: CGPoint(x: scroll.deltaX, y: scroll.deltaY), phase: 0, momentum: 0
                ))]
            } else { reports = [] }
            nativeInput = HIDNativeInput(reports: reports, cancellationReports: [])
        } else { nativeInput = nil }
        return TouchEvent(phase: phase, point: CGPoint(x: x, y: y), nativeInput: nativeInput)
    }
}

private struct PreviewMediaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Pipe writes can block. Keep them off the media actor so touch authorization
/// and disconnect cancellation stay responsive. Encoded frames remain ordered;
/// overflow terminates this preview rather than silently losing H264 references.
private final class PreviewMediaWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let failure: @Sendable () -> Void
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "StupidMirror.PreviewPipe", qos: .userInteractive)
    private var commands: [Data] = []
    private var frames: [(deviceID: String, data: Data)] = []
    private var bytes = 0
    private var draining = false
    private var stopped = false

    init(handle: FileHandle, failure: @escaping @Sendable () -> Void) {
        self.handle = handle; self.failure = failure
    }
    func enqueue(_ data: Data, frameDeviceID: String?) throws {
        let schedule = try lock.withLock {
            guard !stopped, bytes + data.count <= 16 * 1024 * 1024, commands.count + frames.count < 128 else {
                throw PreviewMediaError(message: "Video pipe is unavailable or congested")
            }
            if let frameDeviceID { frames.append((frameDeviceID, data)) } else { commands.append(data) }
            bytes += data.count
            guard !draining else { return false }
            draining = true
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }
    func removeFrames(deviceID: String) {
        lock.withLock {
            bytes -= frames.filter { $0.deviceID == deviceID }.reduce(0) { $0 + $1.data.count }
            frames.removeAll { $0.deviceID == deviceID }
        }
    }
    func stop() {
        lock.withLock { stopped = true; commands.removeAll(); frames.removeAll(); bytes = 0 }
        queue.async { [handle] in try? handle.close() }
    }
    private func drain() {
        while true {
            let data = lock.withLock { () -> Data? in
                guard !stopped else { draining = false; return nil }
                let next = !commands.isEmpty ? commands.removeFirst() : (!frames.isEmpty ? frames.removeFirst().data : nil)
                if let next { bytes -= next.count } else { draining = false }
                return next
            }
            guard let data else { return }
            do { try handle.write(contentsOf: data) }
            catch { stop(); failure(); return }
        }
    }
}

/// Owns the bundled local WebRTC process and hardware encoders. The browser
/// receives SDP through MCP; media remains encrypted on the loopback interface.
actor CodexPreviewMediaService {
    typealias TouchInputHandler = @Sendable (_ deviceID: String, _ ownerID: String, _ event: CodexPreviewTouchEvent) async throws -> Void
    typealias TouchCancelHandler = @Sendable (_ deviceID: String, _ ownerID: String) async -> Void
    private struct Capture {
        let token: UUID
        let store: MirrorFrameStore
        let observerID: UUID
        let encoder: CodexPreviewEncoder
    }
    private var generation = UUID()
    private var process: Process?
    private var writer: PreviewMediaWriter?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<CodexPreviewSignal, Error>] = [:]
    private var captures: [String: Capture] = [:]
    private var peers: [String: String] = [:]
    private var leases: [String: Date] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var touchInputHandler: TouchInputHandler?
    private var touchCancelHandler: TouchCancelHandler?
    private var revokedTouchPeers: Set<String> = []
    private var touchTasks: [String: Task<Void, Never>] = [:]

    func setTouchHandlers(input: @escaping TouchInputHandler, cancel: @escaping TouchCancelHandler) {
        touchInputHandler = input
        touchCancelHandler = cancel
    }

    func offer(deviceID: String, sdp: String, store: MirrorFrameStore) async throws -> CodexPreviewSignal {
        guard sdp.utf8.count < 262_144 else { throw PreviewMediaError(message: "Invalid video offer") }
        try startIfNeeded()
        let peerID = UUID().uuidString
        peers[peerID] = deviceID
        leases[deviceID] = Date()
        do {
            let response = try await request(["op": "offer", "device": deviceID, "peer": peerID, "sdp": sdp])
            guard peers[peerID] == deviceID else { throw PreviewMediaError(message: "Video peer disconnected") }
            if captures[deviceID] == nil {
                let token = UUID()
                let encoder = CodexPreviewEncoder { [weak self] data, duration in
                    Task { await self?.sendFrame(deviceID: deviceID, token: token, data: data, duration: duration) }
                }
                let observerID = store.addObserver { [weak encoder] sample in encoder?.submit(sample) }
                captures[deviceID] = Capture(token: token, store: store, observerID: observerID, encoder: encoder)
            }
            captures[deviceID]?.encoder.requestKeyFrame()
            return response
        } catch {
            close(peerID: peerID)
            throw error
        }
    }

    func touch(deviceID: String) { if leases[deviceID] != nil { leases[deviceID] = Date() } }

    func close(peerID: String) {
        try? write(["op": "close", "peer": peerID])
        removePeer(peerID)
    }

    func closeDevice(_ deviceID: String) {
        for id in peers.filter({ $0.value == deviceID }).map(\.key) { close(peerID: id) }
    }

    func shutdown() {
        generation = UUID()
        for (id, device) in peers { cancelTouch(peerID: id, deviceID: device) }
        cleanupTask?.cancel(); cleanupTask = nil
        for capture in captures.values {
            capture.store.removeObserver(capture.observerID)
            capture.encoder.stop()
        }
        captures.removeAll(); peers.removeAll(); leases.removeAll()
        revokedTouchPeers = Set(touchTasks.keys)
        writer?.stop(); writer = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; reader?.cancel(); reader = nil; buffer.removeAll()
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: PreviewMediaError(message: "Video service disconnected")) }
    }

    private func removePeer(_ id: String) {
        guard let device = peers.removeValue(forKey: id) else { return }
        cancelTouch(peerID: id, deviceID: device)
        if touchTasks[id] == nil { revokedTouchPeers.remove(id) }
        guard !peers.values.contains(device) else { return }
        writer?.removeFrames(deviceID: device)
        if let capture = captures.removeValue(forKey: device) {
            capture.store.removeObserver(capture.observerID)
            capture.encoder.stop()
        }
        leases[device] = nil
    }

    private func expireLeases() {
        let stale = leases.filter { Date().timeIntervalSince($0.value) > 30 }.map(\.key)
        for id in stale { closeDevice(id) }
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StupidMirrorPreview")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/smpreview/smpreview")
        let executable = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : development
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PreviewMediaError(message: "当前 App 缺少视频组件，请安装完整构建。")
        }
        let task = Process(), stdin = Pipe(), stdout = Pipe()
        task.executableURL = executable
        task.standardInput = stdin; task.standardOutput = stdout
        task.standardError = FileHandle.standardError
        try task.run()
        let currentGeneration = UUID(); generation = currentGeneration
        process = task
        writer = PreviewMediaWriter(handle: stdin.fileHandleForWriting) { [weak self] in
            Task { await self?.processEnded(currentGeneration) }
        }
        let handle = stdout.fileHandleForReading
        reader = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                await self?.receive(data, generation: currentGeneration)
            }
            await self?.processEnded(currentGeneration)
        }
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.expireLeases()
            }
        }
    }

    private func request(_ fields: [String: String]) async throws -> CodexPreviewSignal {
        let id = UUID().uuidString
        var command = fields; command["id"] = id
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try write(command) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                await self?.timeout(id)
            }
        }
    }

    private func timeout(_ id: String) {
        pending.removeValue(forKey: id)?.resume(throwing: PreviewMediaError(message: "视频连接超时，请点击刷新。"))
    }

    private func write(_ fields: [String: Any], frameDeviceID: String? = nil) throws {
        guard let writer else { throw PreviewMediaError(message: "Video service is not running") }
        var data = try JSONSerialization.data(withJSONObject: fields)
        data.append(10)
        try writer.enqueue(data, frameDeviceID: frameDeviceID)
    }

    private func sendFrame(deviceID: String, token: UUID, data: Data, duration: Double) {
        guard captures[deviceID]?.token == token else { return }
        do { try write(["op": "frame", "device": deviceID, "data": data.base64EncodedString(), "duration": duration], frameDeviceID: deviceID) }
        catch { shutdown() }
    }

    private func processEnded(_ expectedGeneration: UUID) {
        guard expectedGeneration == generation else { return }
        shutdown()
    }

    private func receive(_ data: Data, generation expectedGeneration: UUID) {
        guard expectedGeneration == generation else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) {
                if let error = object["error"] as? String { continuation.resume(throwing: PreviewMediaError(message: error)) }
                else if let signal = try? JSONDecoder().decode(CodexPreviewSignal.self, from: line) { continuation.resume(returning: signal) }
                else { continuation.resume(throwing: PreviewMediaError(message: "Invalid video answer")) }
            }
            if object["event"] as? String == "closed", let peer = object["peer"] as? String { removePeer(peer) }
            if object["event"] as? String == "keyframe", let device = object["device"] as? String { captures[device]?.encoder.requestKeyFrame() }
            if object["event"] as? String == "touch_cancel", let peer = object["peer"] as? String,
               let device = peers[peer] { cancelTouch(peerID: peer, deviceID: device) }
            if object["event"] as? String == "touch" { receiveTouch(object, byteCount: line.count) }
        }
    }

    private func cancelTouch(peerID: String, deviceID: String) {
        revokedTouchPeers.insert(peerID)
        touchTasks[peerID]?.cancel()
        if let cancel = touchCancelHandler { Task { await cancel(deviceID, peerID) } }
    }

    private func receiveTouch(_ object: [String: Any], byteCount: Int) {
        guard let peerID = object["peer"] as? String, let requestID = object["touch_id"] as? String,
              let deviceID = peers[peerID] else { return }
        guard byteCount <= 8192, !revokedTouchPeers.contains(peerID), touchTasks[peerID] == nil,
              let fields = object["touch"] as? [String: Any], fields["type"] as? String == "touch",
              let data = try? JSONSerialization.data(withJSONObject: fields),
              let event = try? JSONDecoder().decode(CodexPreviewTouchEvent.self, from: data), event.isValid,
              let handler = touchInputHandler else {
            replyTouch(peerID: peerID, requestID: requestID, error: "Touch input is unavailable")
            cancelTouch(peerID: peerID, deviceID: deviceID)
            return
        }
        let expectedGeneration = generation
        // The helper permits one in-flight input per peer; never block stdout
        // draining (or video delivery) while the main app authorizes/sends it.
        touchTasks[peerID] = Task { [weak self] in
            var failure: String?
            do { try Task.checkCancellation(); try await handler(deviceID, peerID, event) }
            catch { failure = error.localizedDescription }
            await self?.finishTouch(peerID: peerID, deviceID: deviceID, requestID: requestID,
                                    generation: expectedGeneration, error: failure)
        }
    }

    private func finishTouch(peerID: String, deviceID: String, requestID: String, generation expectedGeneration: UUID, error: String?) async {
        touchTasks[peerID] = nil
        guard generation == expectedGeneration, peers[peerID] == deviceID, !revokedTouchPeers.contains(peerID) else {
            // A close may race an already dispatched down. Release again once
            // that dispatch finishes, so cancellation cannot leave a held finger.
            await touchCancelHandler?(deviceID, peerID)
            if peers[peerID] == nil { revokedTouchPeers.remove(peerID) }
            return
        }
        replyTouch(peerID: peerID, requestID: requestID, error: error)
        if error != nil { cancelTouch(peerID: peerID, deviceID: deviceID) }
    }

    private func replyTouch(peerID: String, requestID: String, error: String?) {
        do {
            try write(["op": "touch_result", "peer": peerID, "touch_id": requestID,
                       "accepted": error == nil, "error": error ?? ""])
        } catch { shutdown() }
    }
}
