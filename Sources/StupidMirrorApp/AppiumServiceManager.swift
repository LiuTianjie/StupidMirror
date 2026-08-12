import Darwin
import Foundation

@MainActor
final class AppiumServiceManager: ObservableObject {
    @Published private(set) var state: AppiumServiceState = .unknown
    @Published private(set) var message = "Not checked"

    private final class ManagedProcess: @unchecked Sendable {
        let process: Process
        let record: ManagedProcessRecord
        let logFileHandle: FileHandle
        let logURL: URL

        init(process: Process, record: ManagedProcessRecord, logFileHandle: FileHandle, logURL: URL) {
            self.process = process
            self.record = record
            self.logFileHandle = logFileHandle
            self.logURL = logURL
        }
    }

    private var managedProcess: ManagedProcess?
    private let orphanRecoveryTask: Task<Bool, Never>
    private var lifecycleTail: Task<Void, Never>?
    private var startOperation: (key: String, id: UUID, task: Task<Void, Never>)?
    private var stopOperation: (id: UUID, task: Task<Void, Never>)?
    private var checkOperation: (key: String, id: UUID, task: Task<Bool, Never>)?
    private var ensureOperation: (key: String, id: UUID, task: Task<Bool, Never>)?
    private var readinessTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var lifecycleGeneration: UInt64 = 0
    private var statusRevision: UInt64 = 0

    init() {
        // Every lifecycle operation waits for this task. A new local Appium
        // process therefore cannot race an orphan from a previous app crash.
        orphanRecoveryTask = Task.detached(priority: .utility) {
            Self.recoverRecordedOrphan()
        }
    }

    var isRunning: Bool {
        if case .running = state {
            true
        } else {
            false
        }
    }

    var canStartLocally: Bool {
        findExecutable(named: "appium") != nil
    }

    @discardableResult
    func checkNow(serverURL: String) async -> Bool {
        let key = AppiumHTTPClient.normalizedBaseURLString(serverURL)
        if let operation = checkOperation, operation.key == key {
            return await operation.task.value
        }

        statusRevision &+= 1
        let revision = statusRevision
        state = .checking
        message = "Checking Appium..."

        let id = UUID()
        let task = Task {
            do {
                try await AppiumHTTPClient(baseURL: key).status(timeout: 5)
                return true
            } catch {
                return false
            }
        }
        checkOperation = (key, id, task)
        let reachable = await task.value

        if checkOperation?.id == id {
            checkOperation = nil
        }
        if statusRevision == revision {
            if reachable {
                state = .running
                message = "Appium is reachable at \(key)"
            } else if managedProcess != nil {
                state = .starting
                message = "Managed Appium is still starting."
            } else {
                state = .stopped
                message = "Appium is not reachable."
            }
        }
        return reachable
    }

    @discardableResult
    func ensureRunning(serverURL: String) async -> Bool {
        guard !isShuttingDown else { return false }
        let key = AppiumHTTPClient.normalizedBaseURLString(serverURL)
        if let operation = ensureOperation, operation.key == key {
            return await operation.task.value
        }

        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.performEnsureRunning(serverURL: key)
        }
        ensureOperation = (key, id, task)
        let result = await task.value
        if ensureOperation?.id == id {
            ensureOperation = nil
        }
        return result
    }

    func check(serverURL: String) {
        Task { [weak self] in
            _ = await self?.checkNow(serverURL: serverURL)
        }
    }

    func start(serverURL: String) {
        guard !isShuttingDown else { return }
        let key = AppiumHTTPClient.normalizedBaseURLString(serverURL)
        let operation = queueStart(serverURL: key)
        readinessTask?.cancel()
        readinessTask = Task { [weak self] in
            await operation.value
            guard let self, !Task.isCancelled else { return }
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, self.managedProcess != nil else { return }
                if await self.checkNow(serverURL: key) {
                    return
                }
            }
        }
    }

    /// Queue a bounded stop. A subsequent start is serialized behind the
    /// complete TERM/KILL/reap sequence, not merely behind clearing `process`.
    func stop() {
        _ = queueStop()
    }

    /// Awaitable teardown for callers that can delay app termination.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        activateShutdownGate()
        let operation = queueStop()
        shutdownTask = operation
        await operation.value
    }

    /// AppKit's `applicationWillTerminate` cannot await. This bounded fallback
    /// cancels queued work and synchronously reaps the direct child and its
    /// private process group before the app disappears.
    func stopForShutdown() {
        activateShutdownGate()

        guard let managedProcess else {
            // Recovery may still be running or the app may be terminating very
            // early. Re-read the strongly-identified record synchronously.
            Self.recoverRecordedOrphan()
            state = .stopped
            message = "No managed Appium process."
            return
        }

        self.managedProcess = nil
        Self.terminateAndReap(managedProcess)
        Self.clearPidfile(matching: managedProcess.record.instanceID)
        try? managedProcess.logFileHandle.close()
        state = .stopped
        message = "Managed Appium process stopped."
    }

    private func activateShutdownGate() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        lifecycleGeneration &+= 1
        statusRevision &+= 1

        readinessTask?.cancel()
        readinessTask = nil
        ensureOperation?.task.cancel()
        ensureOperation = nil
        checkOperation?.task.cancel()
        checkOperation = nil
        startOperation?.task.cancel()
        startOperation = nil
        stopOperation?.task.cancel()
        stopOperation = nil
        // Keep the handle as the serialization predecessor for the final stop,
        // but cancellation plus the generation check prevents its queued start
        // operation from ever being entered.
        lifecycleTail?.cancel()
    }

    private func performEnsureRunning(serverURL: String) async -> Bool {
        guard !isShuttingDown else { return false }
        if await checkNow(serverURL: serverURL) {
            return true
        }
        guard !Task.isCancelled, !isShuttingDown else { return false }
        guard canStartLocally else {
            statusRevision &+= 1
            state = .missing
            message = "Appium is not installed. Run `make setup-appium`."
            return false
        }

        let start = queueStart(serverURL: serverURL)
        await start.value
        guard !Task.isCancelled, !isShuttingDown, managedProcess != nil else { return false }

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, !isShuttingDown else { return false }
            if await checkNow(serverURL: serverURL) {
                return true
            }
        }
        return false
    }

    private func queueStart(serverURL: String) -> Task<Void, Never> {
        guard !isShuttingDown else { return Task {} }
        if let operation = startOperation, operation.key == serverURL {
            return operation.task
        }

        // A later stop must queue behind this new start, rather than de-duping
        // against a previous stop that happens to still be unwinding.
        stopOperation = nil
        let id = UUID()
        let task = enqueueLifecycle { manager in
            await manager.performStart(serverURL: serverURL)
        }
        startOperation = (serverURL, id, task)
        Task { [weak self] in
            await task.value
            guard let self, self.startOperation?.id == id else { return }
            self.startOperation = nil
        }
        return task
    }

    private func queueStop() -> Task<Void, Never> {
        if let operation = stopOperation {
            return operation.task
        }

        readinessTask?.cancel()
        readinessTask = nil
        ensureOperation?.task.cancel()
        ensureOperation = nil
        checkOperation?.task.cancel()
        checkOperation = nil
        // A start already in the lifecycle tail still runs, then this stop
        // reaps it. Clearing the de-dup handle permits start-stop-start order.
        startOperation = nil
        statusRevision &+= 1
        message = "Stopping managed Appium..."

        let id = UUID()
        let task = enqueueLifecycle { manager in
            await manager.performStop()
        }
        stopOperation = (id, task)
        Task { [weak self] in
            await task.value
            guard let self, self.stopOperation?.id == id else { return }
            self.stopOperation = nil
        }
        return task
    }

    private func enqueueLifecycle(
        _ operation: @escaping @MainActor (AppiumServiceManager) async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTail
        let recovery = orphanRecoveryTask
        let generation = lifecycleGeneration
        let task = Task { [weak self] in
            let recovered = await recovery.value
            guard !Task.isCancelled else { return }
            if let previous {
                await previous.value
            }
            guard !Task.isCancelled, let self, self.lifecycleGeneration == generation else { return }
            guard recovered else {
                self.statusRevision &+= 1
                self.state = .failed("A previously managed Appium process could not be stopped.")
                self.message = "A previously managed Appium process is still alive; refusing to launch another instance."
                return
            }
            await operation(self)
        }
        lifecycleTail = task
        return task
    }

    private func performStart(serverURL: String) async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        if let managedProcess, managedProcess.process.isRunning {
            statusRevision &+= 1
            state = .running
            message = "Appium is already managed by StupidMirror."
            return
        }

        guard let appiumPath = findExecutable(named: "appium") else {
            statusRevision &+= 1
            state = .missing
            message = "Appium is not installed. Run `make setup-appium`."
            return
        }

        let endpoint = URL(string: serverURL)
        let host = endpoint?.host ?? "127.0.0.1"
        let port = endpoint?.port ?? 4723
        let serverArguments = ["--address", host, "--port", "\(port)"]
        let instanceID = UUID().uuidString

        let launch: AppiumLaunch
        if let bundledRuntime = Self.bundledAppiumRuntime() {
            do {
                launch = try await Task.detached(priority: .utility) {
                    try Self.prepareBundledAppiumLaunch(
                        runtime: bundledRuntime,
                        serverArguments: serverArguments
                    )
                }.value
            } catch {
                statusRevision &+= 1
                state = .failed("Cannot prepare the bundled Appium runtime.")
                message = "Cannot prepare the bundled Appium runtime: \(error.localizedDescription)"
                return
            }
        } else {
            launch = AppiumLaunch(
                executablePath: appiumPath,
                arguments: serverArguments,
                environment: [:]
            )
        }

        let launched = Process()
        launched.executableURL = URL(fileURLWithPath: launch.executablePath)
        launched.arguments = launch.arguments
        launched.environment = ProcessInfo.processInfo.environment
            .merging(launch.environment) { _, new in new }
            .merging(Self.androidToolEnvironment()) { _, new in new }
            .merging([
            "STUPIDMIRROR_SKIP_WDA_ICON_EMBED": "1",
            // Ask the XCUITest driver to use Apple's public devicectl CLI for
            // paired Wi-Fi devices when usbmux does not report the UDID.
            "APPIUM_XCUITEST_PREFER_DEVICECTL": "1",
            ManagedProcessRecord.identityEnvironmentKey: instanceID
        ]) { _, new in new }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StupidMirror-Appium.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            statusRevision &+= 1
            state = .failed("Cannot open the Appium log file.")
            message = "Cannot open the Appium log file at \(logURL.path)."
            return
        }
        _ = try? handle.seekToEnd()
        launched.standardOutput = handle
        launched.standardError = handle

        do {
            try launched.run()
            let pid = launched.processIdentifier
            // Foundation currently creates a private group for Process. Ask
            // explicitly as well, then trust it only when the kernel confirms
            // the child is the group leader.
            _ = setpgid(pid, pid)
            // KERN_PROCARGS2 can briefly be unavailable immediately after a
            // process launch or executable transition. Retry the strong
            // token/UID/start-time/argv verification for a bounded interval
            // instead of treating that normal kernel snapshot race as failure.
            var ownershipRecord: ManagedProcessRecord?
            for _ in 0..<20 where ownershipRecord == nil && launched.isRunning {
                ownershipRecord = Self.makeManagedProcessRecord(
                    pid: pid,
                    instanceID: instanceID,
                    appiumPath: launch.executablePath,
                    expectedArguments: launch.arguments
                )
                if ownershipRecord == nil {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
            guard let record = ownershipRecord else {
                launched.terminate()
                if launched.isRunning {
                    kill(pid, SIGKILL)
                    launched.waitUntilExit()
                }
                try? handle.close()
                statusRevision &+= 1
                state = .failed("Could not establish Appium process ownership.")
                let failureReason = Self.processOwnershipFailureReason(
                    pid: pid,
                    instanceID: instanceID,
                    expectedArguments: launch.arguments
                )
                message = "Appium process verification failed: \(failureReason)"
                return
            }
            do {
                try Self.writePidfile(record)
            } catch {
                let temporary = ManagedProcess(
                    process: launched,
                    record: record,
                    logFileHandle: handle,
                    logURL: logURL
                )
                Self.terminateAndReap(temporary)
                try? handle.close()
                statusRevision &+= 1
                state = .failed(error.localizedDescription)
                message = "Cannot persist Appium ownership metadata: \(error.localizedDescription)"
                return
            }

            let managed = ManagedProcess(
                process: launched,
                record: record,
                logFileHandle: handle,
                logURL: logURL
            )
            managedProcess = managed
            statusRevision &+= 1
            state = .starting
            message = "Starting Appium at http://\(host):\(port)... Log: \(logURL.path)"

            launched.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    self?.handleUnexpectedTermination(
                        process: process,
                        instanceID: instanceID,
                        record: record,
                        logURL: logURL
                    )
                }
            }
        } catch {
            try? handle.close()
            statusRevision &+= 1
            state = .failed(error.localizedDescription)
            message = error.localizedDescription
        }
    }

    private func performStop() async {
        guard let managedProcess else {
            statusRevision &+= 1
            state = .stopped
            message = "No managed Appium process."
            return
        }

        self.managedProcess = nil
        let record = managedProcess.record
        let logHandle = managedProcess.logFileHandle
        await Task.detached(priority: .utility) {
            Self.terminateAndReap(managedProcess)
        }.value
        Self.clearPidfile(matching: record.instanceID)
        try? logHandle.close()
        statusRevision &+= 1
        state = .stopped
        message = "Managed Appium process stopped."
    }

    private func handleUnexpectedTermination(
        process: Process,
        instanceID: String,
        record: ManagedProcessRecord,
        logURL: URL
    ) {
        guard let managedProcess, managedProcess.record.instanceID == instanceID else { return }
        self.managedProcess = nil
        try? managedProcess.logFileHandle.close()
        statusRevision &+= 1
        state = .stopped
        message = "Appium exited with status \(process.terminationStatus). Log: \(logURL.path)"

        Task.detached(priority: .utility) {
            // The root has already exited, but xcodebuild/iproxy descendants
            // can still be alive in the private process group.
            Self.terminateRemainingProcessGroup(record)
            Self.clearPidfile(matching: instanceID)
        }
    }

    // MARK: Strong process ownership and bounded termination

    private nonisolated static func makeManagedProcessRecord(
        pid: Int32,
        instanceID: String,
        appiumPath: String,
        expectedArguments: [String]
    ) -> ManagedProcessRecord? {
        guard let snapshot = processSnapshot(pid: pid),
              snapshot.ownerUID == getuid(),
              snapshot.environment[ManagedProcessRecord.identityEnvironmentKey] == instanceID,
              command(snapshot.arguments, contains: expectedArguments) else {
            return nil
        }
        return ManagedProcessRecord(
            formatVersion: 2,
            pid: pid,
            processGroupID: snapshot.processGroupID == pid ? snapshot.processGroupID : nil,
            ownerUID: snapshot.ownerUID,
            startSeconds: snapshot.startSeconds,
            startMicroseconds: snapshot.startMicroseconds,
            allowedExecutablePaths: allowedExecutablePaths(
                initialExecutablePath: snapshot.executablePath,
                appiumPath: appiumPath
            ),
            commandArguments: snapshot.arguments,
            expectedArguments: expectedArguments,
            launchedAppiumPath: URL(fileURLWithPath: appiumPath).resolvingSymlinksInPath().path,
            instanceID: instanceID
        )
    }

    private nonisolated static func processOwnershipFailureReason(
        pid: Int32,
        instanceID: String,
        expectedArguments: [String]
    ) -> String {
        guard let snapshot = processSnapshot(pid: pid) else {
            return "the child process snapshot was unavailable"
        }
        guard snapshot.ownerUID == getuid() else {
            return "the child process owner did not match"
        }
        guard snapshot.environment[ManagedProcessRecord.identityEnvironmentKey] == instanceID else {
            return "the private instance marker was unavailable"
        }
        guard command(snapshot.arguments, contains: expectedArguments) else {
            return "the child process arguments did not match"
        }
        return "the child process changed while it was being inspected"
    }

    private nonisolated static func allowedExecutablePaths(
        initialExecutablePath: String,
        appiumPath: String
    ) -> [String] {
        let appiumURL = URL(fileURLWithPath: appiumPath).resolvingSymlinksInPath()
        let siblingNode = appiumURL.deletingLastPathComponent()
            .appendingPathComponent("node")
            .resolvingSymlinksInPath().path
        var paths = [initialExecutablePath, appiumURL.path]
        if FileManager.default.isExecutableFile(atPath: siblingNode) {
            paths.append(siblingNode)
        }
        return Array(Set(paths)).sorted()
    }

    private nonisolated static func bundledAppiumRuntime() -> BundledAppiumRuntime? {
        var roots: [URL] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Appium", isDirectory: true) {
            roots.append(bundled)
        }
        roots.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build/appium-runtime", isDirectory: true)
        )
        for root in roots {
            let node = root.appendingPathComponent("bin/node")
            let main = root.appendingPathComponent("node_modules/appium/build/lib/main.js")
            let sourceHome = root.appendingPathComponent("home", isDirectory: true)
            let stamp = root.appendingPathComponent(".stupidmirror-runtime")
            guard FileManager.default.isExecutableFile(atPath: node.path),
                  FileManager.default.fileExists(atPath: main.path),
                  FileManager.default.fileExists(atPath: sourceHome.path),
                  FileManager.default.fileExists(atPath: stamp.path) else {
                continue
            }
            return BundledAppiumRuntime(
                rootPath: root.path,
                nodePath: node.path,
                mainPath: main.path,
                sourceHomePath: sourceHome.path,
                stampPath: stamp.path
            )
        }
        return nil
    }

    private nonisolated static func androidToolEnvironment() -> [String: String] {
        var result: [String: String] = [:]
        let fileManager = FileManager.default
        if let adbPath = AndroidRuntime.adbExecutablePath() {
            let sdkRoot = URL(fileURLWithPath: adbPath)
                .deletingLastPathComponent()
                .deletingLastPathComponent().path
            if fileManager.fileExists(atPath: sdkRoot) {
                result["ANDROID_HOME"] = sdkRoot
                result["ANDROID_SDK_ROOT"] = sdkRoot
            }
        }
        if ProcessInfo.processInfo.environment["JAVA_HOME"] == nil {
            let javaHomes = [
                "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
                "/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home"
            ]
            if let javaHome = javaHomes.first(where: {
                fileManager.isExecutableFile(atPath: "\($0)/bin/java")
            }) {
                result["JAVA_HOME"] = javaHome
            }
        }
        return result
    }

    private nonisolated static func prepareBundledAppiumLaunch(
        runtime: BundledAppiumRuntime,
        serverArguments: [String]
    ) throws -> AppiumLaunch {
        let fileManager = FileManager.default
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let productSupport = supportRoot.appendingPathComponent("StupidMirror", isDirectory: true)
        let destinationHome = productSupport.appendingPathComponent("AppiumHome", isDirectory: true)
        let destinationStamp = destinationHome.appendingPathComponent(".stupidmirror-runtime")
        let sourceStamp = URL(fileURLWithPath: runtime.stampPath)
        let stampMatches = try? Data(contentsOf: sourceStamp) == Data(contentsOf: destinationStamp)

        if stampMatches != true {
            try fileManager.createDirectory(at: productSupport, withIntermediateDirectories: true)
            let staging = productSupport.appendingPathComponent(
                ".AppiumHome-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? fileManager.removeItem(at: staging) }
            try fileManager.copyItem(
                at: URL(fileURLWithPath: runtime.sourceHomePath, isDirectory: true),
                to: staging
            )
            try fileManager.copyItem(at: sourceStamp, to: staging.appendingPathComponent(".stupidmirror-runtime"))
            if fileManager.fileExists(atPath: destinationHome.path) {
                _ = try fileManager.replaceItemAt(destinationHome, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destinationHome)
            }
        }

        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let runtimeBin = URL(fileURLWithPath: runtime.rootPath)
            .appendingPathComponent("bin", isDirectory: true).path
        return AppiumLaunch(
            executablePath: runtime.nodePath,
            arguments: [runtime.mainPath] + serverArguments,
            environment: [
                "APPIUM_HOME": destinationHome.path,
                "PATH": "\(runtimeBin):\(inheritedPath)"
            ]
        )
    }

    private nonisolated static func command(_ actual: [String], contains expected: [String]) -> Bool {
        guard !actual.isEmpty else { return false }
        var searchIndex = actual.startIndex
        for value in expected {
            guard let index = actual[searchIndex...].firstIndex(of: value) else { return false }
            searchIndex = actual.index(after: index)
        }
        return true
    }

    private nonisolated static func processMatches(_ record: ManagedProcessRecord) -> Bool {
        guard record.formatVersion == 2,
              record.pid > 1,
              record.ownerUID == getuid(),
              let snapshot = processSnapshot(pid: record.pid) else {
            return false
        }
        return snapshot.ownerUID == record.ownerUID
            && snapshot.startSeconds == record.startSeconds
            && snapshot.startMicroseconds == record.startMicroseconds
            && record.allowedExecutablePaths.contains(snapshot.executablePath)
            // The bundled launcher starts as bash and then execs the exact
            // sibling Node binary. Accept that one expected transition while
            // requiring the complete launch argv before it or the exact CLI
            // suffix after it.
            && (snapshot.arguments == record.commandArguments
                || Array(snapshot.arguments.suffix(record.expectedArguments.count)) == record.expectedArguments)
            && snapshot.environment[ManagedProcessRecord.identityEnvironmentKey] == record.instanceID
            && (record.processGroupID == nil || snapshot.processGroupID == record.processGroupID)
    }

    private nonisolated static func terminateAndReap(_ managed: ManagedProcess) {
        let process = managed.process
        let record = managed.record
        let descendants = ownedDescendants(of: record.pid)
        if process.isRunning {
            signalOwnedProcess(record, signal: SIGTERM, trustDirectChild: true)
            signalOwnedDescendants(descendants, signal: SIGTERM)
            waitForExit(
                record: record,
                process: process,
                descendants: descendants,
                iterations: 30
            )
        }
        if process.isRunning
            || processGroupExists(record.processGroupID)
            || descendants.contains(where: ownedProcessExists) {
            signalOwnedProcess(record, signal: SIGKILL, trustDirectChild: true)
            signalOwnedDescendants(descendants, signal: SIGKILL)
            waitForExit(
                record: record,
                process: process,
                descendants: descendants,
                iterations: 20
            )
        }
        if process.isRunning {
            // SIGKILL is not ignorable. This is only a reap and is bounded in
            // practice by the kernel having already accepted the signal.
            process.waitUntilExit()
        }
    }

    @discardableResult
    private nonisolated static func recoverRecordedOrphan() -> Bool {
        guard let record = readPidfile() else {
            clearUnreadablePidfile()
            return true
        }

        let rootIsOwned = processMatches(record)
        var ownedMembers = ownedProcessGroupMembers(for: record)
        if rootIsOwned {
            ownedMembers.append(contentsOf: ownedDescendants(of: record.pid))
        }
        ownedMembers = uniqueOwnedProcesses(ownedMembers, excludingPID: record.pid)

        // The Appium root can exit between an app crash and the next launch.
        // Its children retain both the private PGID and our random environment
        // token, which is strong enough to reclaim them without trusting a
        // possibly recycled group identifier by itself.
        guard rootIsOwned || !ownedMembers.isEmpty else {
            clearPidfile(matching: record.instanceID)
            return true
        }

        if rootIsOwned {
            kill(record.pid, SIGTERM)
        }
        signalOwnedDescendants(ownedMembers, signal: SIGTERM)
        waitForRecordedExit(record: record, descendants: ownedMembers, iterations: 30)

        // Re-enumerate token-verified group members after TERM so children
        // created just before their parent stopped are included in escalation.
        ownedMembers.append(contentsOf: ownedProcessGroupMembers(for: record))
        ownedMembers = uniqueOwnedProcesses(ownedMembers, excludingPID: record.pid)
        if processMatches(record) {
            kill(record.pid, SIGKILL)
        }
        signalOwnedDescendants(ownedMembers, signal: SIGKILL)
        waitForRecordedExit(record: record, descendants: ownedMembers, iterations: 20)

        let remainingGroupMembers = ownedProcessGroupMembers(for: record)
        let stopped = !processMatches(record)
            && remainingGroupMembers.isEmpty
            && !ownedMembers.contains(where: ownedProcessExists)
        if stopped {
            clearPidfile(matching: record.instanceID)
        }
        return stopped
    }

    private nonisolated static func terminateRemainingProcessGroup(_ record: ManagedProcessRecord) {
        guard processGroupExists(record.processGroupID) else { return }
        signalProcessGroup(record.processGroupID, signal: SIGTERM)
        for _ in 0..<20 where processGroupExists(record.processGroupID) {
            usleep(100_000)
        }
        if processGroupExists(record.processGroupID) {
            signalProcessGroup(record.processGroupID, signal: SIGKILL)
        }
    }

    private nonisolated static func signalOwnedProcess(
        _ record: ManagedProcessRecord,
        signal: Int32,
        trustDirectChild: Bool
    ) {
        guard trustDirectChild || processMatches(record) else { return }
        if let groupID = record.processGroupID,
           groupID == record.pid,
           (trustDirectChild || getpgid(record.pid) == groupID) {
            kill(-groupID, signal)
        } else {
            kill(record.pid, signal)
        }
    }

    private nonisolated static func signalProcessGroup(_ groupID: Int32?, signal: Int32) {
        guard let groupID, groupID > 1 else { return }
        kill(-groupID, signal)
    }

    private nonisolated static func waitForExit(
        record: ManagedProcessRecord,
        process: Process,
        descendants: [OwnedProcessIdentity],
        iterations: Int
    ) {
        for _ in 0..<iterations {
            guard process.isRunning
                || processGroupExists(record.processGroupID)
                || descendants.contains(where: ownedProcessExists) else {
                return
            }
            usleep(100_000)
        }
    }

    private nonisolated static func waitForRecordedExit(
        record: ManagedProcessRecord,
        descendants: [OwnedProcessIdentity],
        iterations: Int
    ) {
        for _ in 0..<iterations {
            guard processMatches(record)
                || descendants.contains(where: ownedProcessExists) else {
                return
            }
            usleep(100_000)
        }
    }

    private nonisolated static func ownedDescendants(of rootPID: Int32) -> [OwnedProcessIdentity] {
        let estimatedCount = max(proc_listallpids(nil, 0), 0)
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard count > 0 else { return [] }

        var parentByPID: [Int32: Int32] = [:]
        var infoByPID: [Int32: proc_bsdinfo] = [:]
        for pid in pids.prefix(Int(count)) where pid > 1 {
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
                continue
            }
            parentByPID[pid] = Int32(bitPattern: info.pbi_ppid)
            infoByPID[pid] = info
        }

        var descendants: Set<Int32> = []
        var frontier: Set<Int32> = [rootPID]
        while !frontier.isEmpty {
            var next: Set<Int32> = []
            for (pid, parentPID) in parentByPID where frontier.contains(parentPID) && !descendants.contains(pid) {
                descendants.insert(pid)
                next.insert(pid)
            }
            frontier = next
        }

        return descendants.compactMap { pid in
            guard let info = infoByPID[pid] else { return nil }
            return OwnedProcessIdentity(
                pid: pid,
                ownerUID: info.pbi_uid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            )
        }
    }

    private nonisolated static func ownedProcessGroupMembers(
        for record: ManagedProcessRecord
    ) -> [OwnedProcessIdentity] {
        guard let processGroupID = record.processGroupID, processGroupID > 1 else { return [] }
        let estimatedCount = max(proc_listallpids(nil, 0), 0)
        var pids = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard count > 0 else { return [] }

        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize,
                  Int32(bitPattern: info.pbi_pgid) == processGroupID,
                  info.pbi_uid == record.ownerUID,
                  let snapshot = processSnapshot(pid: pid),
                  snapshot.environment[ManagedProcessRecord.identityEnvironmentKey] == record.instanceID else {
                return nil
            }
            return OwnedProcessIdentity(
                pid: pid,
                ownerUID: snapshot.ownerUID,
                startSeconds: snapshot.startSeconds,
                startMicroseconds: snapshot.startMicroseconds
            )
        }
    }

    private nonisolated static func uniqueOwnedProcesses(
        _ processes: [OwnedProcessIdentity],
        excludingPID: Int32
    ) -> [OwnedProcessIdentity] {
        var seen = Set<OwnedProcessIdentity>()
        return processes.filter { process in
            process.pid != excludingPID && seen.insert(process).inserted
        }
    }

    private nonisolated static func signalOwnedDescendants(
        _ descendants: [OwnedProcessIdentity],
        signal: Int32
    ) {
        // Revalidate start time before every signal so a recycled PID can never
        // turn this descendant snapshot into an unrelated kill target.
        for descendant in descendants.reversed() where ownedProcessExists(descendant) {
            kill(descendant.pid, signal)
        }
    }

    private nonisolated static func ownedProcessExists(_ identity: OwnedProcessIdentity) -> Bool {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
            return false
        }
        return info.pbi_uid == identity.ownerUID
            && info.pbi_start_tvsec == identity.startSeconds
            && info.pbi_start_tvusec == identity.startMicroseconds
    }

    private nonisolated static func processGroupExists(_ groupID: Int32?) -> Bool {
        guard let groupID, groupID > 1 else { return false }
        if kill(-groupID, 0) == 0 { return true }
        return errno == EPERM
    }

    private nonisolated static func processSnapshot(pid: Int32) -> ProcessSnapshot? {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize else {
            return nil
        }

        var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            return nil
        }
        let pathBytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let executablePath = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .resolvingSymlinksInPath().path

        guard let command = processArgumentsAndEnvironment(pid: pid) else { return nil }
        return ProcessSnapshot(
            ownerUID: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            processGroupID: Int32(bitPattern: info.pbi_pgid),
            executablePath: executablePath,
            arguments: command.arguments,
            environment: command.environment
        )
    }

    private nonisolated static func processArgumentsAndEnvironment(
        pid: Int32
    ) -> (arguments: [String], environment: [String: String])? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: size_t = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        buffer = Array(buffer.prefix(size))
        let argumentCount: Int32 = buffer.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: Int32.self)
        }
        guard argumentCount >= 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        // Skip the exec path and the NUL padding before argv[0].
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }

        var strings: [String] = []
        while index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            if start < index {
                strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
            }
            while index < buffer.count, buffer[index] == 0 { index += 1 }
        }

        let count = min(Int(argumentCount), strings.count)
        let arguments = Array(strings.prefix(count))
        var environment: [String: String] = [:]
        for value in strings.dropFirst(count) {
            guard let separator = value.firstIndex(of: "=") else { continue }
            environment[String(value[..<separator])] = String(value[value.index(after: separator)...])
        }
        return (arguments, environment)
    }

    // MARK: Ownership record

    private nonisolated static var pidfileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("StupidMirror", isDirectory: true)
            .appendingPathComponent("appium-process.json")
    }

    private nonisolated static func writePidfile(_ record: ManagedProcessRecord) throws {
        try FileManager.default.createDirectory(
            at: pidfileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: pidfileURL, options: .atomic)
    }

    private nonisolated static func readPidfile() -> ManagedProcessRecord? {
        guard let data = try? Data(contentsOf: pidfileURL) else { return nil }
        return try? JSONDecoder().decode(ManagedProcessRecord.self, from: data)
    }

    private nonisolated static func clearPidfile(matching instanceID: String) {
        guard let record = readPidfile(), record.instanceID == instanceID else { return }
        try? FileManager.default.removeItem(at: pidfileURL)
    }

    private nonisolated static func clearUnreadablePidfile() {
        guard FileManager.default.fileExists(atPath: pidfileURL.path) else { return }
        try? FileManager.default.removeItem(at: pidfileURL)
    }

    private func findExecutable(named name: String) -> String? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Appium/bin/\(name)")
            .path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let candidates = [
            "\(FileManager.default.currentDirectoryPath)/.build/appium-runtime/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "\(NSHomeDirectory())/.nvm/versions/node/v22.21.0/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private struct ManagedProcessRecord: Codable, Sendable {
    static let identityEnvironmentKey = "STUPIDMIRROR_APPIUM_INSTANCE_ID"

    let formatVersion: Int
    let pid: Int32
    let processGroupID: Int32?
    let ownerUID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let allowedExecutablePaths: [String]
    let commandArguments: [String]
    let expectedArguments: [String]
    let launchedAppiumPath: String
    let instanceID: String
}

private struct AppiumLaunch: Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

private struct BundledAppiumRuntime: Sendable {
    let rootPath: String
    let nodePath: String
    let mainPath: String
    let sourceHomePath: String
    let stampPath: String
}

private struct ProcessSnapshot: Sendable {
    let ownerUID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let processGroupID: Int32
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

private struct OwnedProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let ownerUID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum AppiumServiceState: Equatable {
    case unknown
    case checking
    case starting
    case running
    case stopped
    case missing
    case failed(String)

    var label: String {
        switch self {
        case .unknown:
            "Unknown"
        case .checking:
            "Checking"
        case .starting:
            "Starting"
        case .running:
            "Running"
        case .stopped:
            "Stopped"
        case .missing:
            "Missing"
        case .failed:
            "Failed"
        }
    }
}
