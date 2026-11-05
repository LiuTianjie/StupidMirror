@testable import StupidMirrorApp
import Foundation
import LocalAuthentication
import Security
import XCTest

@MainActor
final class LicenseManagerTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private let userID = UUID()

    // MARK: Free path

    func testSignedOutInstallKeepsFreeOneDevicePathWithoutAnyRequest() async {
        let remote = FakeEntitlementRemote()
        let authFlow = FakeLicenseAuthFlow(session: session())
        let manager = LicenseManager(
            cacheStore: MemoryEntitlementStore(),
            remote: remote,
            clock: TestLicenseClock(now: baseDate),
            authStore: MemoryLicenseAuthStore(),
            authFlow: authFlow
        )

        await manager.bootstrap()
        manager.revalidate(.periodic)
        manager.revalidate(.wake)
        await manager.checkNow()

        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertEqual(manager.state.capabilities, .unactivated)
        XCTAssertEqual(manager.state.capabilities.maximumSimultaneousDevices, 1)
        XCTAssertEqual(manager.state.capabilities.maximumSimultaneousControls, 1)
        XCTAssertTrue(manager.state.capabilities.controlEnabled)
        XCTAssertEqual(manager.membershipRequirement, .signIn)
        let calls = await remote.callCount()
        XCTAssertEqual(calls, 0)
        let refreshes = await authFlow.refreshCount()
        XCTAssertEqual(refreshes, 0)
    }

    func testStrayCacheWithoutSignInGrantsNothingAndIsCleared() async throws {
        let store = MemoryEntitlementStore(cache: cache(checkedAt: baseDate))
        let manager = makeManager(store: store, signedIn: false)

        await manager.bootstrap()

        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(try store.load())
    }

    func testFreeCapabilitiesAllowOneDeviceAndOneControl() {
        let decision = LicenseCapabilityPolicy.mirrorStartDecision(
            capabilities: .unactivated,
            activeIDs: [],
            requestedIDs: ["iphone-a", "iphone-b"],
            preferredID: "iphone-b"
        )
        XCTAssertEqual(decision.allowedIDs, ["iphone-b"])
        XCTAssertEqual(decision.blockedIDs, ["iphone-a"])

        let second = LicenseCapabilityPolicy.mirrorStartDecision(
            capabilities: .unactivated,
            activeIDs: ["iphone-a"],
            requestedIDs: ["iphone-b"],
            preferredID: "iphone-b"
        )
        XCTAssertTrue(second.allowedIDs.isEmpty)
        XCTAssertEqual(second.blockedIDs, ["iphone-b"])

        XCTAssertTrue(LicenseCapabilityPolicy.canStartControl(capabilities: .unactivated, activeIDs: [], targetID: "a"))
        XCTAssertTrue(LicenseCapabilityPolicy.canStartControl(capabilities: .unactivated, activeIDs: ["a"], targetID: "a"))
        XCTAssertFalse(LicenseCapabilityPolicy.canStartControl(capabilities: .unactivated, activeIDs: ["a"], targetID: "b"))
    }

    func testMemberCapabilitiesAllowEveryDeviceAndControl() {
        let decision = LicenseCapabilityPolicy.mirrorStartDecision(
            capabilities: .activated,
            activeIDs: ["iphone-a"],
            requestedIDs: ["iphone-b", "iphone-c"],
            preferredID: nil
        )
        XCTAssertEqual(decision.allowedIDs, ["iphone-b", "iphone-c"])
        XCTAssertTrue(decision.blockedIDs.isEmpty)
        XCTAssertTrue(LicenseCapabilityPolicy.canStartControl(capabilities: .activated, activeIDs: ["a", "b"], targetID: "c"))
    }

    // MARK: Online checks

    func testYearlyMemberGetsMultipleDevicesAndCacheIsSaved() async throws {
        let store = MemoryEntitlementStore()
        let remote = FakeEntitlementRemote(results: [.success(entitlement(active: true))])
        let manager = makeManager(store: store, remote: remote)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        guard case let .member(status) = manager.state else {
            return XCTFail("Expected member, got \(manager.state)")
        }
        XCTAssertEqual(status.tier, .yearly)
        XCTAssertEqual(manager.state.capabilities, .activated)
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.userID, userID)
        XCTAssertEqual(saved.checkedAt, baseDate)
        XCTAssertEqual(saved.validUntil, baseDate.addingTimeInterval(300 * day))
    }

    func testMonthlyMemberIsSignedInButNotEntitled() async throws {
        let store = MemoryEntitlementStore()
        let remote = FakeEntitlementRemote(results: [
            .success(entitlement(active: false, tier: .monthly, openEnded: true))
        ])
        let manager = makeManager(store: store, remote: remote)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertEqual(manager.state, .notMember(MembershipStatus(
            tier: .monthly,
            validUntil: nil,
            memberUntil: baseDate.addingTimeInterval(20 * day)
        )))
        XCTAssertEqual(manager.state.capabilities, .unactivated)
        XCTAssertEqual(manager.membershipRequirement, .yearly)
        XCTAssertNil(try store.load())
    }

    func testExplicitInactiveAnswerRevokesACachedMemberImmediately() async throws {
        let store = MemoryEntitlementStore(cache: cache(checkedAt: baseDate.addingTimeInterval(-1 * 60 * 60)))
        let remote = FakeEntitlementRemote(results: [.success(entitlement(active: false, tier: .free, openEnded: true))])
        let manager = makeManager(store: store, remote: remote)

        await manager.bootstrap()
        XCTAssertTrue(manager.state.isEntitled, "A fresh cache starts as member before the check finishes")
        await manager.waitForBackgroundValidation()

        XCTAssertEqual(manager.state.capabilities, .unactivated)
        guard case .notMember = manager.state else {
            return XCTFail("Expected notMember, got \(manager.state)")
        }
        XCTAssertNil(try store.load())
    }

    func testActiveAnswerWithPastValidUntilIsNotEntitled() async {
        let remote = FakeEntitlementRemote(results: [
            .success(entitlement(active: true, validUntil: baseDate.addingTimeInterval(-60)))
        ])
        let manager = makeManager(remote: remote)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertFalse(manager.state.isEntitled)
    }

    func testOpenEndedGrantIsEntitledAndCachedWithoutEnd() async throws {
        let store = MemoryEntitlementStore()
        let remote = FakeEntitlementRemote(results: [.success(entitlement(active: true, openEnded: true))])
        let manager = makeManager(store: store, remote: remote)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertTrue(manager.state.isEntitled)
        XCTAssertNil(try XCTUnwrap(store.load()).validUntil)
    }

    // MARK: Offline window

    func testCachedMemberWorksOfflineWithinSevenDays() async {
        let checkedAt = baseDate.addingTimeInterval(-6 * day)
        let remote = FakeEntitlementRemote(results: [.failure(.temporarilyUnavailable)])
        let manager = makeManager(
            store: MemoryEntitlementStore(cache: cache(checkedAt: checkedAt)),
            remote: remote
        )

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertTrue(manager.state.isEntitled)
        XCTAssertTrue(manager.lastCheckFailed)
        let calls = await remote.callCount()
        XCTAssertEqual(calls, 1, "Launch always revalidates")
    }

    func testOfflineWindowEndsAfterSevenDays() async {
        let checkedAt = baseDate.addingTimeInterval(-7 * day - 60)
        let remote = FakeEntitlementRemote(results: [.failure(.temporarilyUnavailable)])
        let manager = makeManager(
            store: MemoryEntitlementStore(cache: cache(checkedAt: checkedAt)),
            remote: remote
        )

        await manager.bootstrap()
        XCTAssertEqual(manager.state, .checking)
        await manager.waitForBackgroundValidation()

        XCTAssertEqual(manager.state, .unverified)
        XCTAssertEqual(manager.state.capabilities, .unactivated)
        XCTAssertEqual(manager.membershipRequirement, .verification)
    }

    func testRunningMemberLosesMultiDeviceWhenOfflineWindowRunsOut() async {
        let clock = TestLicenseClock(now: baseDate)
        let remote = FakeEntitlementRemote(results: [
            .success(entitlement(active: true)),
            .failure(.temporarilyUnavailable)
        ])
        let manager = makeManager(remote: remote, clock: clock)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()
        XCTAssertTrue(manager.state.isEntitled)

        clock.set(baseDate.addingTimeInterval(6 * day))
        manager.reevaluateCachedState()
        XCTAssertTrue(manager.state.isEntitled)

        clock.set(baseDate.addingTimeInterval(7 * day + 1))
        manager.revalidate(.periodic)
        XCTAssertEqual(manager.state, .unverified, "The cache stops granting before the network answers")
        await manager.waitForBackgroundValidation()
        XCTAssertEqual(manager.state, .unverified)
    }

    func testOfflineCacheNeverOutlivesValidUntil() async {
        let checkedAt = baseDate.addingTimeInterval(-1 * day)
        let staleCache = cache(checkedAt: checkedAt, validUntil: baseDate.addingTimeInterval(-60))
        let remote = FakeEntitlementRemote(results: [.failure(.temporarilyUnavailable)])
        let manager = makeManager(store: MemoryEntitlementStore(cache: staleCache), remote: remote)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertFalse(manager.state.isEntitled)
    }

    func testClockRollbackRequiresAFreshCheck() async {
        // The last server time is two days after the Mac's clock.
        let checkedAt = baseDate.addingTimeInterval(2 * day)
        let remote = FakeEntitlementRemote(results: [.failure(.temporarilyUnavailable)])
        let manager = makeManager(
            store: MemoryEntitlementStore(cache: cache(checkedAt: checkedAt)),
            remote: remote
        )

        await manager.bootstrap()
        XCTAssertEqual(manager.state, .checking)
        await manager.waitForBackgroundValidation()

        XCTAssertEqual(manager.state, .unverified)
    }

    func testSmallClockSkewIsTolerated() {
        let entry = cache(checkedAt: baseDate.addingTimeInterval(60))
        XCTAssertTrue(entry.isUsable(
            for: userID,
            now: baseDate,
            offlineWindow: LicenseManager.offlineWindow,
            clockTolerance: LicenseManager.clockTolerance
        ))
        XCTAssertFalse(entry.isUsable(
            for: UUID(),
            now: baseDate,
            offlineWindow: LicenseManager.offlineWindow,
            clockTolerance: LicenseManager.clockTolerance
        ), "A cache belongs to one account")
    }

    func testCacheForAnotherAccountIsDiscarded() async throws {
        let store = MemoryEntitlementStore(cache: EntitlementCache(
            userID: UUID(),
            entitlement: entitlement(active: true)
        ))
        let remote = FakeEntitlementRemote(results: [.failure(.temporarilyUnavailable)])
        let manager = makeManager(store: store, remote: remote)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertFalse(manager.state.isEntitled)
        XCTAssertNil(try store.load())
    }

    // MARK: Token refresh

    func testLoginRequiredRefreshesTokenAndRetriesOnce() async {
        let remote = FakeEntitlementRemote(results: [
            .failure(.loginRequired),
            .success(entitlement(active: true))
        ])
        let authFlow = FakeLicenseAuthFlow(session: session(), refreshedToken: "fresh-token")
        let manager = makeManager(remote: remote, authFlow: authFlow)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertTrue(manager.state.isEntitled)
        let tokens = await remote.tokens()
        XCTAssertEqual(tokens, ["token", "fresh-token"])
        let refreshes = await authFlow.refreshCount()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(manager.authSession?.accessToken, "fresh-token")
    }

    func testSecondLoginRequiredSignsOutAndClearsCache() async throws {
        let store = MemoryEntitlementStore(cache: cache(checkedAt: baseDate.addingTimeInterval(-60)))
        let authStore = MemoryLicenseAuthStore(session: session())
        let remote = FakeEntitlementRemote(results: [.failure(.loginRequired), .failure(.loginRequired)])
        let manager = makeManager(store: store, remote: remote, authStore: authStore)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(manager.authSession)
        XCTAssertNil(try authStore.load())
        XCTAssertNil(try store.load())
        let calls = await remote.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testRefusedRefreshTokenSignsOut() async {
        let remote = FakeEntitlementRemote(results: [.failure(.loginRequired)])
        let authFlow = FakeLicenseAuthFlow(session: session(), refreshError: LicenseAuthError.rejected("revoked"))
        let manager = makeManager(remote: remote, authFlow: authFlow)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertEqual(manager.state, .signedOut)
    }

    func testRefreshOutageKeepsTheCachedMember() async {
        let expired = session(expiresAt: Date().addingTimeInterval(-60))
        let remote = FakeEntitlementRemote()
        let authFlow = FakeLicenseAuthFlow(session: expired, refreshError: MembershipCheckError.temporarilyUnavailable)
        let manager = makeManager(
            store: MemoryEntitlementStore(cache: cache(checkedAt: baseDate.addingTimeInterval(-day))),
            remote: remote,
            authStore: MemoryLicenseAuthStore(session: expired),
            authFlow: authFlow
        )

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertTrue(manager.state.isEntitled)
        XCTAssertNotNil(manager.authSession)
        let calls = await remote.callCount()
        XCTAssertEqual(calls, 0)
    }

    // MARK: Sign-in and sign-out

    func testSignInChecksEntitlementBeforeReturning() async {
        let remote = FakeEntitlementRemote(results: [.success(entitlement(active: true))])
        let manager = makeManager(remote: remote, authStore: MemoryLicenseAuthStore())

        await manager.bootstrap()
        XCTAssertEqual(manager.state, .signedOut)
        try? await manager.signIn(provider: .github)

        XCTAssertTrue(manager.state.isEntitled)
    }

    func testSignOutClearsSessionAndCache() async throws {
        let store = MemoryEntitlementStore()
        let authStore = MemoryLicenseAuthStore(session: session())
        let remote = FakeEntitlementRemote(results: [.success(entitlement(active: true))])
        let manager = makeManager(store: store, remote: remote, authStore: authStore)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()
        XCTAssertNotNil(try store.load())

        await manager.signOut()

        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertNil(try store.load())
        XCTAssertNil(try authStore.load())
    }

    // MARK: Revalidation triggers

    func testActivationDoesNotRecheckAFreshMember() async {
        let clock = TestLicenseClock(now: baseDate)
        let remote = FakeEntitlementRemote(results: [.success(entitlement(active: true))])
        let manager = makeManager(remote: remote, clock: clock)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()
        clock.set(baseDate.addingTimeInterval(60 * 60))
        manager.revalidate(.activation)
        manager.revalidate(.periodic)
        await manager.waitForBackgroundValidation()

        let calls = await remote.callCount()
        XCTAssertEqual(calls, 1)
    }

    func testActivationRechecksANonMemberSoAPaymentIsPickedUp() async {
        let clock = TestLicenseClock(now: baseDate)
        let remote = FakeEntitlementRemote(results: [
            .success(entitlement(active: false, tier: .free, openEnded: true)),
            .success(entitlement(active: true))
        ])
        let manager = makeManager(remote: remote, clock: clock)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()
        XCTAssertFalse(manager.state.isEntitled)

        clock.set(baseDate.addingTimeInterval(5 * 60))
        manager.revalidate(.activation)
        await manager.waitForBackgroundValidation()

        XCTAssertTrue(manager.state.isEntitled)
    }

    func testAutomaticChecksAreSpacedButTheRefreshButtonIsNot() async {
        let clock = TestLicenseClock(now: baseDate)
        let remote = FakeEntitlementRemote(results: Array(
            repeating: .success(entitlement(active: false, tier: .free, openEnded: true)),
            count: 4
        ))
        let manager = makeManager(remote: remote, clock: clock)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()
        clock.set(baseDate.addingTimeInterval(5))
        manager.revalidate(.activation)
        manager.revalidate(.wake)
        manager.revalidate(.network)
        await manager.waitForBackgroundValidation()
        var calls = await remote.callCount()
        XCTAssertEqual(calls, 1)

        await manager.checkNow()
        calls = await remote.callCount()
        XCTAssertEqual(calls, 2)
    }

    func testDailyPeriodicRecheck() async {
        let clock = TestLicenseClock(now: baseDate)
        let remote = FakeEntitlementRemote(results: [
            .success(entitlement(active: true)),
            .success(entitlement(active: true, serverTime: baseDate.addingTimeInterval(day + 60)))
        ])
        let manager = makeManager(remote: remote, clock: clock)

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()
        clock.set(baseDate.addingTimeInterval(day + 60))
        manager.revalidate(.periodic)
        await manager.waitForBackgroundValidation()

        let calls = await remote.callCount()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(manager.state.isEntitled)
    }

    func testBootstrapRetriesAfterATemporaryKeychainFailure() async {
        let store = FlakyEntitlementStore(failuresRemaining: 1)
        let manager = makeManager(store: store, signedIn: false)

        await manager.bootstrap()
        XCTAssertEqual(manager.state, .unavailable("temporary Keychain failure"))
        XCTAssertEqual(manager.state.capabilities, .unactivated)

        await manager.bootstrap()
        XCTAssertEqual(manager.state, .signedOut)
    }

    func testReleaseCompatibleKeychainQueryIsNonInteractiveAndDoesNotRequireAccessGroupEntitlements() {
        let identity = KeychainEntitlementStore.itemIdentity
        XCTAssertNil(identity[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(identity[kSecAttrAccessible as String])
        XCTAssertNil(identity[kSecAttrSynchronizable as String])

        let query = KeychainEntitlementStore.nonInteractiveQuery
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
    }

    // MARK: Helpers

    private func session(token: String = "token", expiresAt: Date? = nil) -> LicenseAuthSession {
        LicenseAuthSession(
            userID: userID,
            accessToken: token,
            refreshToken: "refresh",
            expiresAt: expiresAt ?? Date().addingTimeInterval(3_600),
            email: "name@example.com",
            provider: "github"
        )
    }

    private func entitlement(
        active: Bool,
        tier: MembershipTier = .yearly,
        validUntil: Date? = nil,
        openEnded: Bool = false,
        serverTime: Date? = nil
    ) -> MembershipEntitlement {
        let until: Date? = openEnded ? nil : (validUntil ?? baseDate.addingTimeInterval(300 * day))
        return MembershipEntitlement(
            active: active,
            tier: tier,
            validUntil: until,
            memberUntil: tier == .free ? nil : baseDate.addingTimeInterval(tier == .monthly ? 20 * day : 300 * day),
            yearlyUntil: tier == .yearly ? until : nil,
            serverTime: serverTime ?? baseDate
        )
    }

    private func cache(checkedAt: Date, validUntil: Date? = nil) -> EntitlementCache {
        EntitlementCache(userID: userID, entitlement: MembershipEntitlement(
            active: true,
            tier: .yearly,
            validUntil: validUntil ?? checkedAt.addingTimeInterval(300 * day),
            memberUntil: nil,
            yearlyUntil: nil,
            serverTime: checkedAt
        ))
    }

    private func makeManager(
        store: any EntitlementCacheStoring = MemoryEntitlementStore(),
        remote: FakeEntitlementRemote = FakeEntitlementRemote(),
        clock: TestLicenseClock? = nil,
        authStore: MemoryLicenseAuthStore? = nil,
        signedIn: Bool = true,
        authFlow: FakeLicenseAuthFlow? = nil
    ) -> LicenseManager {
        let initialSession: LicenseAuthSession? = signedIn ? self.session() : nil
        return LicenseManager(
            cacheStore: store,
            remote: remote,
            clock: clock ?? TestLicenseClock(now: baseDate),
            authStore: authStore ?? MemoryLicenseAuthStore(session: initialSession),
            authFlow: authFlow ?? FakeLicenseAuthFlow(session: self.session())
        )
    }
}

private final class FlakyEntitlementStore: EntitlementCacheStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int
    private var cache: EntitlementCache?

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func load() throws -> EntitlementCache? {
        lock.lock()
        defer { lock.unlock() }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw LicenseServiceError.storage("temporary Keychain failure")
        }
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

final class TestLicenseClock: LicenseClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ date: Date) {
        lock.lock()
        value = date
        lock.unlock()
    }
}

actor FakeEntitlementRemote: MembershipEntitlementServicing {
    private var results: [Result<MembershipEntitlement, MembershipCheckError>]
    private var receivedTokens: [String] = []

    init(results: [Result<MembershipEntitlement, MembershipCheckError>] = []) {
        self.results = results
    }

    func entitlement(accessToken: String) async throws -> MembershipEntitlement {
        receivedTokens.append(accessToken)
        guard !results.isEmpty else { throw MembershipCheckError.temporarilyUnavailable }
        return try results.removeFirst().get()
    }

    func callCount() -> Int {
        receivedTokens.count
    }

    func tokens() -> [String] {
        receivedTokens
    }
}

actor FakeLicenseAuthFlow: LicenseAuthFlowPerforming {
    private let session: LicenseAuthSession
    private let refreshedToken: String
    private let refreshError: Error?
    private var refreshes = 0

    init(session: LicenseAuthSession, refreshedToken: String = "refreshed-token", refreshError: Error? = nil) {
        self.session = session
        self.refreshedToken = refreshedToken
        self.refreshError = refreshError
    }

    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession {
        session
    }

    func signIn(email: String, password: String) async throws -> LicenseAuthSession {
        session
    }

    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        refreshes += 1
        if let refreshError { throw refreshError }
        var next = session
        next.accessToken = refreshedToken
        next.expiresAt = Date().addingTimeInterval(3_600)
        return next
    }

    func signOut(_ session: LicenseAuthSession) async {}

    func refreshCount() -> Int {
        refreshes
    }
}
