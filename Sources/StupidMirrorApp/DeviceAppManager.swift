import Foundation

/// An app installed on a device, as `list_apps` reports it.
struct InstalledApp: Codable, Equatable, Sendable {
    let bundleID: String
    let name: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name, version
    }
}

/// Installs, removes and lists apps through the host's own tools, so none of
/// it needs a control session: `devicectl` for an iPhone, `simctl` for an iOS
/// Simulator, `adb` for Android devices and emulators.
enum DeviceAppManager {
    enum Target: Equatable, Sendable {
        case iPhone(udid: String)
        case iOSSimulator(udid: String)
        case android(serial: String)
    }

    enum Failure: LocalizedError, Equatable {
        case toolUnavailable(String)
        case packageNotFound(String)
        case wrongPackageType(String)
        case commandFailed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case let .toolUnavailable(message), let .commandFailed(message), let .timedOut(message):
                message
            case let .packageNotFound(path):
                "No app package exists at '\(path)'."
            case let .wrongPackageType(message):
                message
            }
        }
    }

    static let installTimeout: TimeInterval = 180
    static let queryTimeout: TimeInterval = 30

    // MARK: Install

    static func install(packageAt path: String, on target: Target) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.packageNotFound(path)
        }
        try validatePackage(url, for: target)
        switch target {
        case let .iPhone(udid):
            try xcrun(
                ["devicectl", "device", "install", "app", "--device", udid, url.path],
                timeout: installTimeout
            )
        case let .iOSSimulator(udid):
            try xcrun(["simctl", "install", udid, url.path], timeout: installTimeout)
        case let .android(serial):
            // -r keeps the app's data across a reinstall, -t allows test builds.
            let result = try adb(["-s", serial, "install", "-r", "-t", url.path], timeout: installTimeout)
            try requireADBSuccess(result)
        }
    }

    /// iOS takes an `.app` bundle (and, on a phone, an `.ipa`); Android an `.apk`.
    static func validatePackage(_ url: URL, for target: Target) throws {
        let ext = url.pathExtension.lowercased()
        switch target {
        case .iPhone:
            guard ext == "app" || ext == "ipa" else {
                throw Failure.wrongPackageType("An iPhone installs a signed .app bundle or .ipa file.")
            }
        case .iOSSimulator:
            guard ext == "app" else {
                throw Failure.wrongPackageType("An iOS Simulator installs a .app bundle built for the simulator.")
            }
        case .android:
            guard ext == "apk" else {
                throw Failure.wrongPackageType("An Android device installs an .apk file.")
            }
        }
    }

    // MARK: Uninstall

    static func uninstall(_ bundleID: String, on target: Target) throws {
        switch target {
        case let .iPhone(udid):
            try xcrun(
                ["devicectl", "device", "uninstall", "app", "--device", udid, bundleID],
                timeout: queryTimeout
            )
        case let .iOSSimulator(udid):
            try xcrun(["simctl", "uninstall", udid, bundleID], timeout: queryTimeout)
        case let .android(serial):
            let result = try adb(["-s", serial, "uninstall", bundleID], timeout: queryTimeout)
            try requireADBSuccess(result)
        }
    }

    // MARK: List

    static func listApps(on target: Target, includeSystem: Bool) throws -> [InstalledApp] {
        let apps: [InstalledApp]
        switch target {
        case let .iPhone(udid):
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("stupidmirror-apps-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: output) }
            var arguments = ["devicectl", "device", "info", "apps", "--device", udid, "--json-output", output.path]
            if includeSystem {
                arguments += ["--include-default-apps"]
            }
            try xcrun(arguments, timeout: queryTimeout)
            apps = try parseDeviceCTLApps(Data(contentsOf: output))
        case let .iOSSimulator(udid):
            let result = try xcrun(["simctl", "listapps", udid], timeout: queryTimeout)
            apps = try parseSimctlApps(result.stdout, includeSystem: includeSystem)
        case let .android(serial):
            var arguments = ["-s", serial, "shell", "pm", "list", "packages"]
            if !includeSystem { arguments.append("-3") }
            let result = try adb(arguments, timeout: queryTimeout)
            guard result.status == 0 else { throw Failure.commandFailed(result.message) }
            apps = parseAndroidPackages(String(decoding: result.stdout, as: UTF8.self))
        }
        return apps.sorted { $0.bundleID < $1.bundleID }
    }

    static func parseDeviceCTLApps(_ data: Data) throws -> [InstalledApp] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let apps = result["apps"] as? [[String: Any]] else {
            throw Failure.commandFailed("devicectl returned an unexpected app list.")
        }
        return apps.compactMap { app in
            guard let bundleID = app["bundleIdentifier"] as? String else { return nil }
            return InstalledApp(
                bundleID: bundleID,
                name: app["name"] as? String,
                version: app["version"] as? String
            )
        }
    }

    /// `simctl listapps` prints an old-style property list keyed by bundle id.
    static func parseSimctlApps(_ data: Data, includeSystem: Bool) throws -> [InstalledApp] {
        guard let apps = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: [String: Any]] else {
            throw Failure.commandFailed("simctl returned an unexpected app list.")
        }
        return apps.compactMap { bundleID, info in
            if !includeSystem, info["ApplicationType"] as? String != "User" { return nil }
            return InstalledApp(
                bundleID: bundleID,
                name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
                version: info["CFBundleShortVersionString"] as? String
            )
        }
    }

    static func parseAndroidPackages(_ output: String) -> [InstalledApp] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("package:") else { return nil }
            let package = String(value.dropFirst("package:".count))
            return package.isEmpty ? nil : InstalledApp(bundleID: package, name: nil, version: nil)
        }
    }

    // MARK: Open URL

    /// Opens a URL in whichever app handles it. An iPhone opens URLs through
    /// its control session instead (WebDriverAgent's `/url`), so it is not a
    /// target here.
    static func openURL(_ url: String, on target: Target) throws {
        switch target {
        case .iPhone:
            throw Failure.toolUnavailable("Open a URL on an iPhone through its control session.")
        case let .iOSSimulator(udid):
            try xcrun(["simctl", "openurl", udid, url], timeout: queryTimeout)
        case let .android(serial):
            // `adb shell` hands its arguments to the device shell as one
            // command line, so the URL is quoted for that shell.
            let result = try adb(
                ["-s", serial, "shell", "am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", shellQuoted(url)],
                timeout: queryTimeout
            )
            let output = String(decoding: result.stdout, as: UTF8.self)
            guard result.status == 0, !output.contains("Error:") else {
                throw Failure.commandFailed(output.isEmpty ? result.message : output)
            }
        }
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Accepts any URL with a scheme, deep links included, but nothing that
    /// could reach the device shell or simctl as an option.
    static func validateURL(_ value: String) throws -> String {
        let url = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, url.count <= 4_096,
              !url.hasPrefix("-"),
              !url.contains(where: \.isNewline),
              let scheme = URLComponents(string: url)?.scheme, !scheme.isEmpty else {
            throw DeviceAutomationError.invalidArgument("url must be an absolute URL such as https://example.com or myapp://path.")
        }
        return url
    }

    // MARK: Tools

    @discardableResult
    private static func xcrun(_ arguments: [String], timeout: TimeInterval) throws -> HostCommand.Result {
        let result: HostCommand.Result
        do {
            result = try HostCommand.run("/usr/bin/xcrun", arguments: arguments, timeout: timeout)
        } catch HostCommand.Failure.launchFailed(let message) {
            throw Failure.toolUnavailable("Xcode command-line tools are unavailable: \(message)")
        } catch HostCommand.Failure.timedOut {
            throw Failure.timedOut("\(arguments.first ?? "xcrun") did not finish within \(Int(timeout)) seconds.")
        }
        guard result.status == 0 else { throw Failure.commandFailed(result.message) }
        return result
    }

    private static func adb(_ arguments: [String], timeout: TimeInterval) throws -> HostCommand.Result {
        guard let adb = AndroidRuntime.adbExecutablePath() else {
            throw Failure.toolUnavailable(AndroidADBError.adbUnavailable.localizedDescription)
        }
        do {
            return try AndroidADBService.run(adb: adb, arguments: arguments, timeout: timeout)
        } catch AndroidADBError.timedOut {
            throw Failure.timedOut("adb did not finish within \(Int(timeout)) seconds.")
        } catch {
            throw Failure.commandFailed(error.localizedDescription)
        }
    }

    /// `adb install` and `adb uninstall` can exit 0 while printing a failure.
    private static func requireADBSuccess(_ result: HostCommand.Result) throws {
        let output = String(decoding: result.stdout, as: UTF8.self)
        guard result.status == 0, output.contains("Success") else {
            throw Failure.commandFailed(output.isEmpty ? result.message : output)
        }
    }
}
