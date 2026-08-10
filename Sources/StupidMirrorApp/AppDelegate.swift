import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var store: DeviceGalleryStore?

    private var signalSources: [DispatchSourceSignal] = []
    private var terminationTask: Task<Void, Never>?
    private var terminationCleanupCompleted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installSignalHandlers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let store = Self.store else { return }
            DashboardWindowRegistry.shared.open(store: store)
        }
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
            await store.shutdown()
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
            await store.shutdown()
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
