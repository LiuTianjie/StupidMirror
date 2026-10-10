import Foundation

struct CodexPreviewSignal: Codable, Sendable {
    var peerID: String?
    var type: String?
    var sdp: String?
    enum CodingKeys: String, CodingKey { case peerID = "peer_id", type, sdp }
}

private struct PreviewMediaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns the bundled local WebRTC process and hardware encoders. The browser
/// receives SDP through MCP; media remains encrypted on the loopback interface.
actor CodexPreviewMediaService {
    private struct Capture {
        let store: MirrorFrameStore
        let observerID: UUID
        let encoder: CodexPreviewEncoder
    }
    private var generation = UUID()
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var pending: [String: CheckedContinuation<CodexPreviewSignal, Error>] = [:]
    private var captures: [String: Capture] = [:]
    private var peers: [String: String] = [:]
    private var leases: [String: Date] = [:]
    private var cleanupTask: Task<Void, Never>?

    func offer(deviceID: String, sdp: String, store: MirrorFrameStore) async throws -> CodexPreviewSignal {
        guard sdp.utf8.count < 262_144 else { throw PreviewMediaError(message: "Invalid video offer") }
        try startIfNeeded()
        let peerID = UUID().uuidString
        peers[peerID] = deviceID
        leases[deviceID] = Date()
        do {
            let response = try await request(["op": "offer", "device": deviceID, "peer": peerID, "sdp": sdp])
            if captures[deviceID] == nil {
                let encoder = CodexPreviewEncoder { [weak self] data, duration in
                    Task { await self?.sendFrame(deviceID: deviceID, data: data, duration: duration) }
                }
                let observerID = store.addObserver { [weak encoder] sample in encoder?.submit(sample) }
                captures[deviceID] = Capture(store: store, observerID: observerID, encoder: encoder)
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
        cleanupTask?.cancel(); cleanupTask = nil
        for capture in captures.values {
            capture.store.removeObserver(capture.observerID)
            capture.encoder.stop()
        }
        captures.removeAll(); peers.removeAll(); leases.removeAll()
        try? input?.close(); input = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; reader?.cancel(); reader = nil; buffer.removeAll()
        let waiting = pending; pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: PreviewMediaError(message: "Video service disconnected")) }
    }

    private func removePeer(_ id: String) {
        guard let device = peers.removeValue(forKey: id), !peers.values.contains(device) else { return }
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
        process = task; input = stdin.fileHandleForWriting
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

    private func write(_ fields: [String: Any]) throws {
        guard let input else { throw PreviewMediaError(message: "Video service is not running") }
        var data = try JSONSerialization.data(withJSONObject: fields)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func sendFrame(deviceID: String, data: Data, duration: Double) {
        guard captures[deviceID] != nil else { return }
        do { try write(["op": "frame", "device": deviceID, "data": data.base64EncodedString(), "duration": duration]) }
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
        }
    }
}
