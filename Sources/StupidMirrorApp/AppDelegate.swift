import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var store: DeviceGalleryStore?

    private var signalSources: [DispatchSourceSignal] = []
    private var terminationTask: Task<Void, Never>?
    private var terminationCleanupCompleted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppAppearance.stored.apply()
        installSignalHandlers()
        DockPresence.install()
        AppUpdater.shared.start()
        Task.detached(priority: .background) { ClaudeCodeConnector.refreshInstalledPluginIfStale() }
        guard !CommandLine.arguments.contains("--mcp-background") else { return }
        // Started at login: stay in the menu bar until the user opens it.
        guard !LaunchAtLoginController.launchedAsLoginItem() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let store = Self.store else { return }
            DashboardWindowRegistry.shared.open(store: store)
        }
    }

    /// Opening the app again (Spotlight, Finder, the Dock icon) while it runs
    /// in the menu bar brings back the dashboard instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let store = Self.store {
            DashboardWindowRegistry.shared.open(store: store)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationCleanupCompleted {
            return .terminateNow
        }
        if terminationTask != nil {
            return .terminateLater
        }
        guard let store = Self.store else {
            return .terminateNow
        }

        terminationTask = Task { @MainActor [weak self] in
            await Self.shutdown(store)
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            self.terminationCleanupCompleted = true
            self.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// How long quitting waits for a clean shutdown. Sparkle's "Install and Relaunch" quits
    /// the app and waits for it to exit; an unbounded wait here left the update stuck.
    static let shutdownLimit: Duration = .seconds(4)

    /// The clean shutdown, or after `shutdownLimit` the synchronous process reap, whichever
    /// comes first; the clean one may keep running but no longer holds up quitting.
    @MainActor
    static func shutdown(_ store: DeviceGalleryStore, limit: Duration = shutdownLimit) async {
        let finishedInTime = await firstToFinish(limit: limit) { await store.shutdown() }
        if !finishedInTime {
            store.stopAll()
            store.appiumService.stopForShutdown()
        }
    }

    /// True when `work` ends within `limit`, false when the limit comes first. Does not
    /// wait for `work` after the limit: it may ignore cancellation.
    @MainActor
    static func firstToFinish(limit: Duration, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        let race = ShutdownRace()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            Task { @MainActor in
                await work()
                race.finish(true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                race.finish(false)
            }
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()

        // All normal termination paths await `shutdown()` above. Keep a
        // synchronous last-resort process reap for abnormal AppKit shutdowns.
        guard !terminationCleanupCompleted,
              terminationTask == nil,
              let store = Self.store else {
            return
        }
        store.stopAll()
        store.appiumService.stopForShutdown()
    }

    /// A dispatch signal handler cannot call `NSApp.terminate` directly: that
    /// API enters a nested AppKit run loop before the dispatch callback can
    /// return, so a `.terminateLater` cleanup Task never gets a chance to run.
    /// Finish cleanup first, then ask AppKit to terminate synchronously.
    @MainActor
    private func beginSignalTermination() {
        if terminationCleanupCompleted {
            NSApp.terminate(nil)
            return
        }
        guard terminationTask == nil else { return }
        guard let store = Self.store else {
            terminationCleanupCompleted = true
            NSApp.terminate(nil)
            return
        }

        terminationTask = Task { @MainActor [weak self] in
            await Self.shutdown(store)
            guard let self else {
                NSApp.terminate(nil)
                return
            }
            self.terminationCleanupCompleted = true
            self.terminationTask = nil
            NSApp.terminate(nil)
        }
    }

    // SIGTERM/SIGINT (kill, Ctrl-C when run from a terminal) bypass AppKit's
    // termination path, which would orphan the managed Appium child. Route
    // them into NSApp.terminate so applicationWillTerminate cleanup runs.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.beginSignalTermination()
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

@MainActor
final class ShutdownRace {
    var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ inTime: Bool) {
        continuation?.resume(returning: inTime)
        continuation = nil
    }
}
