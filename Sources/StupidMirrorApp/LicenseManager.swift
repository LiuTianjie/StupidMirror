import AppKit
import Combine
import Foundation
import LocalAuthentication
import Network
import Security

/// The iTool membership tier the server reports for the signed-in account.
enum MembershipTier: String, Codable, Equatable, Sendable {
    case free
    case monthly
    case yearly

    init(serverValue: String?) {
        self = MembershipTier(rawValue: serverValue ?? "") ?? .free
    }
}

/// StupidMirror's multi-device capability is part of the iTool yearly
/// membership. The server decides; these constants only name the product.
enum MembershipProduct {
    static let key = "stupidmirror"
    static let requiredTier = MembershipTier.yearly
}

struct MembershipStatus: Equatable, Sendable {
    var tier: MembershipTier
    /// When StupidMirror's entitlement ends. `nil` means no end date.
    var validUntil: Date?
    var memberUntil: Date? = nil
    var yearlyUntil: Date? = nil
}

enum LicenseState: Equatable, Sendable {
    case checking
    /// No iTool account signed in: the free one-device path.
    case signedOut
    /// Signed in with an active StupidMirror entitlement (yearly member).
    case member(MembershipStatus)
    /// Signed in, and the server said the account is not entitled.
    case notMember(MembershipStatus)
    /// Signed in, but the membership could not be confirmed (offline for
    /// longer than the grace window, clock rollback, or never checked).
    case unverified
    case unavailable(String)

    var isEntitled: Bool {
        if case .member = self { return true }
        return false
    }

    var capabilities: LicenseCapabilities {
        isEntitled ? .activated : .unactivated
    }

    var showsDashboardActivationEntry: Bool {
        switch self {
        case .checking, .member:
            false
        case .signedOut, .notMember, .unverified, .unavailable:
            true
        }
    }
}

struct LicenseCapabilities: Equatable, Sendable {
    let maximumSimultaneousDevices: Int?
    let maximumSimultaneousControls: Int?

    var controlEnabled: Bool {
        maximumSimultaneousControls != 0
    }

    static let unactivated = LicenseCapabilities(
        maximumSimultaneousDevices: 1,
        maximumSimultaneousControls: 1
    )
    static let activated = LicenseCapabilities(
        maximumSimultaneousDevices: nil,
        maximumSimultaneousControls: nil
    )
}

struct MirrorStartPolicyDecision: Equatable, Sendable {
    let allowedIDs: Set<String>
    let blockedIDs: Set<String>
}

enum LicenseCapabilityPolicy {
    nonisolated static func canStartControl(
        capabilities: LicenseCapabilities,
        activeIDs: Set<String>,
        targetID: String
    ) -> Bool {
        if activeIDs.contains(targetID) { return true }
        guard let limit = capabilities.maximumSimultaneousControls else { return true }
        return activeIDs.count < limit
    }

    nonisolated static func mirrorStartDecision(
        capabilities: LicenseCapabilities,
        activeIDs: Set<String>,
        requestedIDs: [String],
        preferredID: String?
    ) -> MirrorStartPolicyDecision {
        let requested = requestedIDs.filter { !activeIDs.contains($0) }
        guard let limit = capabilities.maximumSimultaneousDevices else {
            return MirrorStartPolicyDecision(
                allowedIDs: Set(requestedIDs),
                blockedIDs: []
            )
        }

        let remainingSlots = max(limit - activeIDs.count, 0)
        var ordered = requested
        if let preferredID,
           let preferredIndex = ordered.firstIndex(of: preferredID),
           preferredIndex != ordered.startIndex {
            ordered.remove(at: preferredIndex)
            ordered.insert(preferredID, at: ordered.startIndex)
        }
        let newlyAllowed = Set(ordered.prefix(remainingSlots))
        let alreadyActive = Set(requestedIDs).intersection(activeIDs)
        let allowed = alreadyActive.union(newlyAllowed)
        return MirrorStartPolicyDecision(
            allowedIDs: allowed,
            blockedIDs: Set(requestedIDs).subtracting(allowed)
        )
    }
}

/// One answer from the entitlement endpoint.
struct MembershipEntitlement: Equatable, Sendable {
    let active: Bool
    let tier: MembershipTier
    let validUntil: Date?
    let memberUntil: Date?
    let yearlyUntil: Date?
    let serverTime: Date

    var status: MembershipStatus {
        MembershipStatus(tier: tier, validUntil: validUntil, memberUntil: memberUntil, yearlyUntil: yearlyUntil)
    }
}

/// The last confirmed entitlement, kept in the Keychain so a member can keep
/// using several devices offline for a bounded time.
struct EntitlementCache: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let userID: UUID
    let validUntil: Date?
    /// Server time of the last successful check.
    let checkedAt: Date
    let tier: MembershipTier
    let memberUntil: Date?
    let yearlyUntil: Date?

    init(userID: UUID, entitlement: MembershipEntitlement) {
        self.userID = userID
        validUntil = entitlement.validUntil
        checkedAt = entitlement.serverTime
        tier = entitlement.tier
        memberUntil = entitlement.memberUntil
        yearlyUntil = entitlement.yearlyUntil
    }

    var status: MembershipStatus {
        MembershipStatus(tier: tier, validUntil: validUntil, memberUntil: memberUntil, yearlyUntil: yearlyUntil)
    }

    /// The cache grants multi-device use only to the same account, for at
    /// most `offlineWindow` after the last check, never past `validUntil`,
    /// and never when the local clock reads earlier than the server did at
    /// the last check (allowing `clockTolerance` of ordinary skew).
    func isUsable(
        for userID: UUID,
        now: Date,
        offlineWindow: TimeInterval,
        clockTolerance: TimeInterval
    ) -> Bool {
        guard self.userID == userID else { return false }
        guard now >= checkedAt.addingTimeInterval(-clockTolerance) else { return false }
        guard now.timeIntervalSince(checkedAt) <= offlineWindow else { return false }
        if let validUntil, now >= validUntil { return false }
        return true
    }

    func expiry(offlineWindow: TimeInterval) -> Date {
        let window = checkedAt.addingTimeInterval(offlineWindow)
        guard let validUntil else { return window }
        return min(window, validUntil)
    }
}

protocol EntitlementCacheStoring: Sendable {
    func load() throws -> EntitlementCache?
    func save(_ cache: EntitlementCache) throws
    func clear() throws
}

protocol MembershipEntitlementServicing: Sendable {
    func entitlement(accessToken: String) async throws -> MembershipEntitlement
}

enum MembershipCheckError: Error, Equatable, Sendable {
    case notConfigured
    /// The server rejected the access token.
    case loginRequired
    /// Network failure, 502/503, or an unexpected answer: keep the cache.
    case temporarilyUnavailable
}

protocol LicenseClock: Sendable {
    var now: Date { get }
}

struct SystemLicenseClock: LicenseClock {
    var now: Date { Date() }
}

enum LicenseServiceError: LocalizedError, Equatable, Sendable {
    case requestInProgress
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .requestInProgress:
            "A membership request is already in progress."
        case let .storage(message):
            message
        }
    }
}

/// Why a request beyond the free one-device path was refused.
enum MembershipRequirement: Equatable, Sendable {
    /// No account signed in.
    case signIn
    /// Signed in, but the account is not a yearly member.
    case yearly
    /// Signed in, but the membership could not be confirmed.
    case verification
}

/// Owns the membership state. The free one-device path never needs an
/// account; several devices at once need a signed-in iTool account whose
/// StupidMirror entitlement (the yearly tier) is active.
@MainActor
final class LicenseManager: ObservableObject {
    static let offlineWindow: TimeInterval = 7 * 24 * 60 * 60
    static let revalidationInterval: TimeInterval = 24 * 60 * 60
    static let clockTolerance: TimeInterval = 5 * 60
    /// Minimum spacing for checks the user did not ask for (app activation,
    /// wake, network return), so switching apps does not flood the server.
    static let automaticCheckSpacing: TimeInterval = 30
    static let maximumTimerInterval: TimeInterval = 60 * 60

    enum RevalidationTrigger: Sendable {
        case launch
        case user
        case wake
        case network
        case activation
        case periodic
    }

    @Published private(set) var state: LicenseState = .checking
    @Published private(set) var isSigningIn = false
    @Published private(set) var isChecking = false
    @Published private(set) var authSession: LicenseAuthSession?
    /// Set when the last check could not reach the server.
    @Published private(set) var lastCheckFailed = false

    private let cacheStore: any EntitlementCacheStoring
    private let remote: any MembershipEntitlementServicing
    private let clock: any LicenseClock
    private let authStore: any LicenseAuthSessionStoring
    private let authFlow: any LicenseAuthFlowPerforming

    private var cache: EntitlementCache?
    private var didBootstrap = false
    private var checkTask: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pathMonitor: NWPathMonitor?
    private var timerTask: Task<Void, Never>?

    init(
        cacheStore: any EntitlementCacheStoring,
        remote: any MembershipEntitlementServicing,
        clock: any LicenseClock = SystemLicenseClock(),
        authStore: any LicenseAuthSessionStoring = MemoryLicenseAuthStore(),
        authFlow: any LicenseAuthFlowPerforming = UnavailableLicenseAuthFlow()
    ) {
        self.cacheStore = cacheStore
        self.remote = remote
        self.clock = clock
        self.authStore = authStore
        self.authFlow = authFlow
    }

    static func live(bundle: Bundle = .main) -> LicenseManager {
        let configuration = LicenseRemoteConfiguration.from(bundle: bundle)
        return LicenseManager(
            cacheStore: KeychainEntitlementStore(),
            remote: MembershipEntitlementClient(configuration: configuration),
            authStore: KeychainLicenseAuthStore(),
            authFlow: SupabaseLicenseAuthClient(configuration: configuration)
        )
    }

    var showsDashboardActivationEntry: Bool {
        state.showsDashboardActivationEntry
    }

    var isSignedIn: Bool {
        authSession != nil
    }

    var membershipRequirement: MembershipRequirement {
        guard authSession != nil else { return .signIn }
        if case .notMember = state { return .yearly }
        return .verification
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        do {
            cache = try cacheStore.load()
        } catch {
            state = .unavailable(storageMessage(for: error))
            return
        }
        authSession = try? authStore.load()
        didBootstrap = true

        guard let session = authSession else {
            // Signing out clears the cache; a stray one grants nothing.
            clearCache()
            state = .signedOut
            return
        }
        if let cache, cache.userID != session.userID {
            clearCache()
        }
        if let status = usableCacheStatus() {
            state = .member(status)
        } else {
            state = .checking
        }
        revalidate(.launch)
    }

    // MARK: Sign-in

    func signIn(provider: LicenseAuthProvider) async throws {
        try await performSignIn { try await self.authFlow.signIn(provider: provider) }
    }

    func signIn(email: String, password: String) async throws {
        try await performSignIn { try await self.authFlow.signIn(email: email, password: password) }
    }

    private func performSignIn(_ flow: () async throws -> LicenseAuthSession) async throws {
        await bootstrap()
        guard !isSigningIn else { throw LicenseServiceError.requestInProgress }
        isSigningIn = true
        defer { isSigningIn = false }
        let session = try await flow()
        try authStore.save(session)
        if cache?.userID != session.userID {
            clearCache()
        }
        checkTask?.cancel()
        checkTask = nil
        authSession = session
        lastAttemptAt = nil
        if let status = usableCacheStatus() {
            state = .member(status)
        } else {
            state = .checking
        }
        revalidate(.user)
        await checkTask?.value
    }

    func signOut() async {
        if let session = authSession {
            await authFlow.signOut(session)
        }
        signOutLocally()
    }

    private func signOutLocally() {
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
        try? authStore.clear()
        authSession = nil
        clearCache()
        lastCheckFailed = false
        state = .signedOut
    }

    // MARK: Revalidation

    /// Checks the entitlement now (the Refresh button) and waits for it.
    func checkNow() async {
        await bootstrap()
        revalidate(.user)
        await checkTask?.value
    }

    func revalidate(_ trigger: RevalidationTrigger) {
        guard didBootstrap, authSession != nil, checkTask == nil else { return }
        let now = clock.now

        switch trigger {
        case .launch, .user:
            break
        case .wake, .network:
            if isRecentAttempt(now) { return }
        case .activation:
            if isFreshlyChecked(now) || isRecentAttempt(now) { return }
        case .periodic:
            reevaluateCachedState()
            if isFreshlyChecked(now) || isRecentAttempt(now) { return }
        }

        lastAttemptAt = now
        isChecking = true
        checkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCheck()
            if !Task.isCancelled {
                self.checkTask = nil
                self.isChecking = false
            }
        }
    }

    func waitForBackgroundValidation() async {
        await checkTask?.value
    }

    /// Re-applies the offline rule to the cached entitlement. A member whose
    /// grace window ran out, whose entitlement ended, or whose clock went
    /// backwards loses multi-device use until the next successful check.
    func reevaluateCachedState() {
        guard didBootstrap else { return }
        guard authSession != nil else {
            state = .signedOut
            return
        }
        if let status = usableCacheStatus() {
            state = .member(status)
        } else if state.isEntitled {
            state = .unverified
        }
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        isChecking = false
        stopAutomaticRevalidation()
    }

    private func isRecentAttempt(_ now: Date) -> Bool {
        guard let lastAttemptAt else { return false }
        let elapsed = now.timeIntervalSince(lastAttemptAt)
        return elapsed >= 0 && elapsed < Self.automaticCheckSpacing
    }

    private func isFreshlyChecked(_ now: Date) -> Bool {
        guard state.isEntitled, let cache else { return false }
        let age = now.timeIntervalSince(cache.checkedAt)
        return age >= -Self.clockTolerance && age < Self.revalidationInterval
    }

    private func usableCacheStatus() -> MembershipStatus? {
        guard let session = authSession, let cache,
              cache.isUsable(
                  for: session.userID,
                  now: clock.now,
                  offlineWindow: Self.offlineWindow,
                  clockTolerance: Self.clockTolerance
              ) else {
            return nil
        }
        return cache.status
    }

    private enum CheckOutcome: Error {
        case signedOut
        case unavailable
    }

    private func performCheck() async {
        guard let session = authSession else { return }
        let userID = session.userID
        do {
            let entitlement = try await fetchEntitlement(for: session)
            guard !Task.isCancelled, authSession?.userID == userID else { return }
            apply(entitlement, userID: userID)
        } catch CheckOutcome.signedOut {
            guard !Task.isCancelled, authSession?.userID == userID else { return }
            signOutLocally()
        } catch {
            guard !Task.isCancelled, authSession?.userID == userID else { return }
            keepCachedState()
        }
    }

    /// One request; on `login_required` the token is refreshed and the
    /// request retried once. A second rejection means the account is gone.
    private func fetchEntitlement(for session: LicenseAuthSession) async throws -> MembershipEntitlement {
        var session = session
        var refreshed = false
        if session.isExpired {
            session = try await refresh(session)
            refreshed = true
        }
        do {
            return try await requestEntitlement(session.accessToken)
        } catch CheckOutcome.signedOut {
            guard !refreshed else { throw CheckOutcome.signedOut }
            session = try await refresh(session)
            return try await requestEntitlement(session.accessToken)
        }
    }

    private func requestEntitlement(_ accessToken: String) async throws -> MembershipEntitlement {
        do {
            return try await remote.entitlement(accessToken: accessToken)
        } catch MembershipCheckError.loginRequired {
            throw CheckOutcome.signedOut
        } catch {
            throw CheckOutcome.unavailable
        }
    }

    private func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        let refreshed: LicenseAuthSession
        do {
            refreshed = try await authFlow.refresh(session)
        } catch LicenseAuthError.rejected {
            // The refresh token itself was refused: the sign-in is over.
            throw CheckOutcome.signedOut
        } catch {
            // Network failure while refreshing: keep what is cached.
            throw CheckOutcome.unavailable
        }
        guard authSession?.userID == session.userID else { throw CheckOutcome.unavailable }
        try? authStore.save(refreshed)
        authSession = refreshed
        return refreshed
    }

    private func apply(_ entitlement: MembershipEntitlement, userID: UUID) {
        lastCheckFailed = false
        let stillValid = entitlement.validUntil.map { $0 > entitlement.serverTime } ?? true
        guard entitlement.active, stillValid else {
            // An explicit "not active" revokes immediately.
            clearCache()
            state = .notMember(entitlement.status)
            return
        }
        let newCache = EntitlementCache(userID: userID, entitlement: entitlement)
        // A Keychain failure keeps the entitlement for this run only.
        try? cacheStore.save(newCache)
        cache = newCache
        state = .member(entitlement.status)
    }

    private func keepCachedState() {
        lastCheckFailed = true
        if let status = usableCacheStatus() {
            state = .member(status)
            return
        }
        switch state {
        case .notMember:
            // The server's last explicit answer still stands.
            break
        default:
            state = .unverified
        }
    }

    private func clearCache() {
        if cache != nil {
            try? cacheStore.clear()
        }
        cache = nil
    }

    private func storageMessage(for error: Error) -> String {
        if let error = error as? LicenseServiceError {
            return error.localizedDescription
        }
        return "Could not read the saved membership state: \(error.localizedDescription)"
    }

    // MARK: System events

    /// Revalidates on wake, network return, app activation (returning from
    /// the browser after paying), and on a timer that also ends the offline
    /// window exactly when it runs out.
    func startAutomaticRevalidation() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.revalidate(.wake) }
        }))
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.revalidate(.activation) }
        }))

        let monitor = NWPathMonitor()
        let tracker = NetworkReturnTracker()
        monitor.pathUpdateHandler = { [weak self] path in
            guard tracker.returned(satisfied: path.status == .satisfied) else { return }
            Task { @MainActor in self?.revalidate(.network) }
        }
        monitor.start(queue: DispatchQueue(label: "com.gaojiua.StupidMirror.membership.network"))
        pathMonitor = monitor

        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = self?.nextTimerDelay() ?? Self.maximumTimerInterval
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.revalidate(.periodic)
            }
        }
    }

    private func stopAutomaticRevalidation() {
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
        observers.removeAll()
        pathMonitor?.cancel()
        pathMonitor = nil
        timerTask?.cancel()
        timerTask = nil
    }

    private func nextTimerDelay() -> TimeInterval {
        guard state.isEntitled, let cache else { return Self.maximumTimerInterval }
        let untilExpiry = cache.expiry(offlineWindow: Self.offlineWindow).timeIntervalSince(clock.now)
        return min(Self.maximumTimerInterval, max(1, untilExpiry + 1))
    }
}

/// Reports the moment the network comes back after being unavailable.
private final class NetworkReturnTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var wasSatisfied: Bool?

    func returned(satisfied: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let returned = satisfied && wasSatisfied == false
        wasSatisfied = satisfied
        return returned
    }
}

// MARK: - Keychain

final class KeychainEntitlementStore: EntitlementCacheStoring, @unchecked Sendable {
    static let service = "com.gaojiua.StupidMirror.membership.v1"
    private static let account = "entitlement"
    private static let interactionLock = NSLock()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() throws -> EntitlementCache? {
        try withoutLegacyKeychainInteraction {
            var query = Self.nonInteractiveQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                return nil
            }
            guard status == errSecSuccess, let data = result as? Data else {
                throw keychainError(status)
            }
            // A damaged cache only means the next check decides.
            return try? decoder.decode(EntitlementCache.self, from: data)
        }
    }

    func save(_ cache: EntitlementCache) throws {
        let data = try encoder.encode(cache)
        try withoutLegacyKeychainInteraction {
            let updateStatus = SecItemUpdate(
                Self.nonInteractiveQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecSuccess {
                return
            }
            guard updateStatus == errSecItemNotFound else {
                throw keychainError(updateStatus)
            }

            var attributes = Self.itemIdentity
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(addStatus)
            }
        }
    }

    func clear() throws {
        try withoutLegacyKeychainInteraction {
            let status = SecItemDelete(Self.nonInteractiveQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(status)
            }
        }
    }

    /// Developer ID releases are signed directly and do not embed the
    /// provisioning profile/application-identifier entitlement required by
    /// macOS's Data Protection Keychain. Use the traditional login Keychain so
    /// the distributed app does not fail with errSecMissingEntitlement.
    static var itemIdentity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }

    /// Never let an ACL mismatch turn a background check into a Keychain
    /// password dialog. Official releases keep a stable Developer ID
    /// designated requirement, so normal reads and updates remain silent.
    static var nonInteractiveQuery: [String: Any] {
        var query = itemIdentity
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    /// `LAContext.interactionNotAllowed` covers modern authentication, while
    /// the file-based Keychain has a separate legacy UI switch for unlock and
    /// ACL dialogs. Toggle it only around the synchronous operation and restore
    /// the process-wide value immediately afterwards.
    private func withoutLegacyKeychainInteraction<Value>(_ operation: () throws -> Value) throws -> Value {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }

        var wasAllowed = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard readStatus == errSecSuccess else { throw keychainError(readStatus) }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { throw keychainError(disableStatus) }
        defer { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return try operation()
    }

    private func keychainError(_ status: OSStatus) -> LicenseServiceError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error \(status)"
        return .storage("Could not access the saved membership state: \(message)")
    }
}

// MARK: - Remote

struct LicenseRemoteConfiguration: Sendable {
    /// The iTool Supabase project (`https://<ref>.supabase.co`): Auth and
    /// the `itool_entitlement` RPC fallback.
    let supabaseURL: URL?
    /// `https://itool.tech/api/membership/entitlement`, reachable where
    /// supabase.co is blocked.
    let entitlementURL: URL?
    let publishableKey: String
    let appVersion: String

    /// Supabase Auth base (`…/auth/v1`).
    var authBaseURL: URL? {
        guard let supabaseURL,
              var components = URLComponents(url: supabaseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        components.path = "/auth/v1"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var entitlementRPCURL: URL? {
        guard let supabaseURL,
              var components = URLComponents(url: supabaseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        components.path = "/rest/v1/rpc/itool_entitlement"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var websiteEntitlementURL: URL? {
        guard let entitlementURL,
              entitlementURL.scheme?.lowercased() == "https",
              var components = URLComponents(url: entitlementURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "product", value: MembershipProduct.key)]
        return components.url
    }

    static func from(bundle: Bundle) -> LicenseRemoteConfiguration {
        func value(_ key: String) -> String {
            (bundle.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return LicenseRemoteConfiguration(
            supabaseURL: URL(string: value("StupidMirrorSupabaseURL")),
            entitlementURL: URL(string: value("StupidMirrorEntitlementURL")),
            publishableKey: value("StupidMirrorLicensePublishableKey"),
            appVersion: version
        )
    }
}

protocol LicenseHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionLicenseTransport: LicenseHTTPTransport {
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MembershipCheckError.temporarilyUnavailable
        }
        return (data, response)
    }
}

/// Asks itool.tech for the StupidMirror entitlement and falls back to the
/// Supabase RPC when itool.tech cannot be reached.
struct MembershipEntitlementClient: MembershipEntitlementServicing {
    private let configuration: LicenseRemoteConfiguration
    private let transport: any LicenseHTTPTransport

    init(
        configuration: LicenseRemoteConfiguration,
        transport: any LicenseHTTPTransport = URLSessionLicenseTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    func entitlement(accessToken: String) async throws -> MembershipEntitlement {
        let canUseRPC = configuration.entitlementRPCURL != nil && !configuration.publishableKey.isEmpty
        guard let websiteURL = configuration.websiteEntitlementURL else {
            guard canUseRPC else { throw MembershipCheckError.notConfigured }
            return try await viaRPC(accessToken)
        }
        do {
            return try await viaWebsite(websiteURL, accessToken)
        } catch MembershipCheckError.temporarilyUnavailable where canUseRPC {
            return try await viaRPC(accessToken)
        }
    }

    private func viaWebsite(_ url: URL, _ accessToken: String) async throws -> MembershipEntitlement {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("StupidMirror/\(configuration.appVersion)", forHTTPHeaderField: "User-Agent")
        return try await send(request)
    }

    private func viaRPC(_ accessToken: String) async throws -> MembershipEntitlement {
        guard let url = configuration.entitlementRPCURL, !configuration.publishableKey.isEmpty else {
            throw MembershipCheckError.notConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Supabase publishable keys belong in `apikey`; the user's JWT is
        // the Bearer credential.
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["p_product": MembershipProduct.key])
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> MembershipEntitlement {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as MembershipCheckError {
            throw error
        } catch {
            throw MembershipCheckError.temporarilyUnavailable
        }
        let wire = try? JSONDecoder().decode(WireResponse.self, from: data)
        if response.statusCode == 401 || response.statusCode == 403 || wire?.code == "login_required" {
            throw MembershipCheckError.loginRequired
        }
        guard (200..<300).contains(response.statusCode), let wire, wire.ok == true,
              let active = wire.active else {
            throw MembershipCheckError.temporarilyUnavailable
        }
        if let product = wire.product, product != MembershipProduct.key {
            throw MembershipCheckError.temporarilyUnavailable
        }
        guard let serverTime = Self.parseDate(wire.serverTime) else {
            throw MembershipCheckError.temporarilyUnavailable
        }
        return MembershipEntitlement(
            active: active,
            tier: MembershipTier(serverValue: wire.tier),
            validUntil: Self.parseDate(wire.validUntil),
            memberUntil: Self.parseDate(wire.memberUntil),
            yearlyUntil: Self.parseDate(wire.yearlyUntil),
            serverTime: serverTime
        )
    }

    /// Postgres timestamps carry up to six fractional digits and a numeric
    /// offset (`2026-11-05T10:30:26.938123+00:00`); ISO8601DateFormatter
    /// accepts at most three.
    static func parseDate(_ value: String?) -> Date? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let dot = value.firstIndex(of: ".") {
            let fractionStart = value.index(after: dot)
            let fractionEnd = value[fractionStart...].firstIndex { !$0.isNumber } ?? value.endIndex
            let digits = value[fractionStart..<fractionEnd]
            if digits.count > 3 {
                value.replaceSubrange(fractionStart..<fractionEnd, with: digits.prefix(3))
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private struct WireResponse: Decodable {
        let ok: Bool?
        let code: String?
        let product: String?
        let active: Bool?
        let tier: String?
        let validUntil: String?
        let memberUntil: String?
        let yearlyUntil: String?
        let serverTime: String?

        enum CodingKeys: String, CodingKey {
            case ok, code, product, active, tier
            case validUntil = "valid_until"
            case memberUntil = "member_until"
            case yearlyUntil = "yearly_until"
            case serverTime = "server_time"
        }
    }
}

final class MemoryLicenseAuthStore: LicenseAuthSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var session: LicenseAuthSession?

    init(session: LicenseAuthSession? = nil) {
        self.session = session
    }

    func load() throws -> LicenseAuthSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func save(_ session: LicenseAuthSession) throws {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        session = nil
        lock.unlock()
    }
}

final class MemoryEntitlementStore: EntitlementCacheStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: EntitlementCache?

    init(cache: EntitlementCache? = nil) {
        self.cache = cache
    }

    func load() throws -> EntitlementCache? {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    func save(_ cache: EntitlementCache) throws {
        lock.lock()
        self.cache = cache
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        cache = nil
        lock.unlock()
    }
}

struct UnavailableLicenseAuthFlow: LicenseAuthFlowPerforming {
    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession {
        throw LicenseAuthError.notConfigured
    }

    func signIn(email: String, password: String) async throws -> LicenseAuthSession {
        throw LicenseAuthError.notConfigured
    }

    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        throw LicenseAuthError.notConfigured
    }

    func signOut(_ session: LicenseAuthSession) async {}
}
