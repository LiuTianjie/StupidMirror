@testable import StupidMirrorApp
import Foundation
import LocalAuthentication
import Security
import XCTest

@MainActor
final class LicenseManagerTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 2_000_000_000)
    private let receipt1 = "8dc53b7d-1a3c-4fc8-a201-f70c3d88b2e1"
    private let receipt2 = "5e7dbd7e-6717-4cde-9db1-c8f910c5108e"

    func testUnactivatedInstallAllowsOneDeviceAndOneControl() async throws {
        let store = MemoryLicenseStore()
        let manager = LicenseManager(
            store: store,
            remote: FakeLicenseRemote(),
            clock: TestLicenseClock(now: baseDate)
        )

        await manager.bootstrap()

        XCTAssertEqual(manager.state, .unlicensed)
        XCTAssertEqual(manager.state.capabilities.maximumSimultaneousDevices, 1)
        XCTAssertEqual(manager.state.capabilities.maximumSimultaneousControls, 1)
        XCTAssertTrue(manager.state.capabilities.controlEnabled)
    }

    func testBootstrapRetriesAfterATemporaryKeychainFailure() async {
        let store = FlakyLicenseStore(failuresRemaining: 1)
        let manager = LicenseManager(
            store: store,
            remote: FakeLicenseRemote(),
            clock: TestLicenseClock(now: baseDate)
        )

        await manager.bootstrap()
        XCTAssertEqual(manager.state, .unavailable("temporary Keychain failure"))

        await manager.bootstrap()
        XCTAssertEqual(manager.state, .unlicensed)
    }

    func testLegacyTrialTimestampsDoNotRestrictMirroringCapabilities() async throws {
        var record = LocalLicenseRecord(installationID: UUID())
        record.trialStartedAt = baseDate
        record.lastTrustedTime = baseDate.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        let store = MemoryLicenseStore(record: record)
        let manager = LicenseManager(store: store, remote: FakeLicenseRemote())

        await manager.bootstrap()

        XCTAssertEqual(manager.state, .unlicensed)
        XCTAssertEqual(manager.state.capabilities, .unactivated)
    }

    func testUnactivatedMirrorPolicyAllowsOnlyOneRequestedDevice() {
        let decision = LicenseCapabilityPolicy.mirrorStartDecision(
            capabilities: .unactivated,
            activeIDs: [],
            requestedIDs: ["iphone-a", "iphone-b"],
            preferredID: "iphone-b"
        )

        XCTAssertEqual(decision.allowedIDs, ["iphone-b"])
        XCTAssertEqual(decision.blockedIDs, ["iphone-a"])
    }

    func testUnactivatedMirrorPolicyBlocksSecondActiveDevice() {
        let decision = LicenseCapabilityPolicy.mirrorStartDecision(
            capabilities: .unactivated,
            activeIDs: ["iphone-a"],
            requestedIDs: ["iphone-b"],
            preferredID: "iphone-b"
        )

        XCTAssertTrue(decision.allowedIDs.isEmpty)
        XCTAssertEqual(decision.blockedIDs, ["iphone-b"])
    }

    func testActivatedMirrorPolicyAllowsAllDevicesAndControl() {
        let decision = LicenseCapabilityPolicy.mirrorStartDecision(
            capabilities: .activated,
            activeIDs: ["iphone-a"],
            requestedIDs: ["iphone-b", "iphone-c"],
            preferredID: nil
        )

        XCTAssertEqual(decision.allowedIDs, ["iphone-b", "iphone-c"])
        XCTAssertTrue(decision.blockedIDs.isEmpty)
        XCTAssertTrue(LicenseCapabilities.activated.controlEnabled)
    }

    func testUnactivatedControlPolicyAllowsFirstControlAndBlocksSecond() {
        XCTAssertTrue(LicenseCapabilityPolicy.canStartControl(
            capabilities: .unactivated,
            activeIDs: [],
            targetID: "iphone-a"
        ))
        XCTAssertTrue(LicenseCapabilityPolicy.canStartControl(
            capabilities: .unactivated,
            activeIDs: ["iphone-a"],
            targetID: "iphone-a"
        ))
        XCTAssertFalse(LicenseCapabilityPolicy.canStartControl(
            capabilities: .unactivated,
            activeIDs: ["iphone-a"],
            targetID: "iphone-b"
        ))
    }

    func testActivatedControlPolicyAllowsMultipleControls() {
        XCTAssertTrue(LicenseCapabilityPolicy.canStartControl(
            capabilities: .activated,
            activeIDs: ["iphone-a", "iphone-b"],
            targetID: "iphone-c"
        ))
    }

    func testActivationNormalizesCodeAndPersistsReceipt() async throws {
        let remote = FakeLicenseRemote(
            activation: LicenseActivation(receipt: receipt1, serverTime: baseDate)
        )
        let store = MemoryLicenseStore()
        let manager = LicenseManager(
            store: store,
            remote: remote,
            clock: TestLicenseClock(now: baseDate)
        )

        try await manager.activate(code: " sm1-ab cd ")

        let call = await remote.lastActivationCall()
        XCTAssertEqual(call?.code, "SM1ABCD")
        XCTAssertEqual(try store.load()?.activationReceipt, receipt1)
        XCTAssertEqual(manager.state, .licensed(lastValidatedAt: baseDate))
        XCTAssertEqual(manager.state.capabilities, .activated)
    }

    func testActivatedReceiptAllowsOfflineStartWhileValidationFails() async {
        var record = LocalLicenseRecord(installationID: UUID())
        record.activationReceipt = receipt1
        record.lastValidatedAt = nil
        let remote = FakeLicenseRemote(validationError: .rejected(code: "temporarily_unavailable", message: "offline"))
        let manager = LicenseManager(
            store: MemoryLicenseStore(record: record),
            remote: remote,
            clock: TestLicenseClock(now: baseDate)
        )

        await manager.bootstrap()
        XCTAssertEqual(manager.state, .licensed(lastValidatedAt: nil))
    }

    func testBackgroundValidationRequestsAreCoalesced() async throws {
        var record = LocalLicenseRecord(installationID: UUID())
        record.activationReceipt = receipt1
        let remote = FakeLicenseRemote(validationDelayNanoseconds: 100_000_000)
        let manager = LicenseManager(
            store: MemoryLicenseStore(record: record),
            remote: remote,
            clock: TestLicenseClock(now: baseDate)
        )

        await manager.bootstrap()
        manager.validateInBackgroundIfNeeded(force: true)
        manager.validateInBackgroundIfNeeded(force: true)
        try await Task.sleep(nanoseconds: 20_000_000)

        let callCount = await remote.validationCallCount()
        XCTAssertEqual(callCount, 1)
        manager.cancel()
    }

    func testInvalidReceiptClearsOfflineEntitlement() async throws {
        var record = LocalLicenseRecord(installationID: UUID())
        record.trialStartedAt = baseDate
        record.activationReceipt = receipt1
        let store = MemoryLicenseStore(record: record)
        let remote = FakeLicenseRemote(
            validationError: .rejected(code: "invalid_receipt", message: "Invalid receipt")
        )
        let manager = LicenseManager(
            store: store,
            remote: remote,
            clock: TestLicenseClock(now: baseDate)
        )

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        XCTAssertNil(try store.load()?.activationReceipt)
        XCTAssertEqual(manager.state, .unlicensed)
    }

    func testMalformedLocalReceiptIsInvalidatedBeforeItCanAuthorizeAStart() async throws {
        var record = LocalLicenseRecord(installationID: UUID())
        record.trialStartedAt = baseDate
        record.activationReceipt = "forged-or-damaged"
        record.lastValidatedAt = baseDate
        let store = MemoryLicenseStore(record: record)
        let remote = FakeLicenseRemote()
        let manager = LicenseManager(
            store: store,
            remote: remote,
            clock: TestLicenseClock(now: baseDate)
        )

        await manager.bootstrap()

        XCTAssertEqual(manager.state, .unlicensed)
        XCTAssertNil(try store.load()?.activationReceipt)
        XCTAssertNil(try store.load()?.lastValidatedAt)
        let validationCallCount = await remote.validationCallCount()
        XCTAssertEqual(validationCallCount, 0)
    }

    func testFutureValidationTimestampCannotSuppressBackgroundValidation() async throws {
        var record = LocalLicenseRecord(installationID: UUID())
        record.trialStartedAt = baseDate
        record.activationReceipt = receipt1
        record.lastValidatedAt = baseDate.addingTimeInterval(365 * 24 * 60 * 60)
        let store = MemoryLicenseStore(record: record)
        let remote = FakeLicenseRemote(
            validationError: .rejected(code: "invalid_receipt", message: "Invalid receipt")
        )
        let manager = LicenseManager(store: store, remote: remote, clock: TestLicenseClock(now: baseDate))

        await manager.bootstrap()
        await manager.waitForBackgroundValidation()

        let validationCallCount = await remote.validationCallCount()
        XCTAssertEqual(validationCallCount, 1)
        XCTAssertNil(try store.load()?.activationReceipt)
    }

    func testStaleValidationCannotRevokeANewActivationReceipt() async throws {
        var record = LocalLicenseRecord(installationID: UUID())
        record.activationReceipt = receipt1
        let store = MemoryLicenseStore(record: record)
        let remote = FakeLicenseRemote(
            activation: LicenseActivation(receipt: receipt2, serverTime: baseDate),
            validationError: .rejected(code: "invalid_receipt", message: "Old receipt"),
            validationDelayNanoseconds: 50_000_000
        )
        let manager = LicenseManager(store: store, remote: remote, clock: TestLicenseClock(now: baseDate))

        await manager.bootstrap()
        try await manager.activate(code: "SM1-ABCD")
        await manager.waitForBackgroundValidation()

        XCTAssertEqual(try store.load()?.activationReceipt, receipt2)
        XCTAssertEqual(manager.state, .licensed(lastValidatedAt: baseDate))
    }

    func testServerTimeIsBoundedForValidationScheduling() async throws {
        let farFuture = baseDate.addingTimeInterval(365 * 24 * 60 * 60)
        let store = MemoryLicenseStore()
        let manager = LicenseManager(
            store: store,
            remote: FakeLicenseRemote(
                activation: LicenseActivation(receipt: receipt1, serverTime: farFuture)
            ),
            clock: TestLicenseClock(now: baseDate)
        )

        try await manager.activate(code: "SM1-ABCD")

        let record = try XCTUnwrap(store.load())
        let boundedTime = baseDate.addingTimeInterval(LicenseManager.maximumServerClockSkew)
        XCTAssertEqual(record.lastValidatedAt, boundedTime)
        XCTAssertEqual(record.lastTrustedTime, boundedTime)
    }

    func testCodeNormalizationRemovesSeparatorsAndPreservesLettersAndDigits() {
        XCTAssertEqual(LicenseManager.normalize(code: " sm1-a2_c 3 "), "SM1A2C3")
    }

    func testReceiptFormatMatchesServerUUIDContract() {
        XCTAssertTrue(LicenseReceiptFormat.isValid(receipt1))
        XCTAssertTrue(LicenseReceiptFormat.isValid(receipt2.uppercased()))
        XCTAssertFalse(LicenseReceiptFormat.isValid("forged-or-damaged"))
        XCTAssertFalse(LicenseReceiptFormat.isValid("00000000-0000-0000-0000-000000000000"))
        XCTAssertFalse(LicenseReceiptFormat.isValid("8dc53b7d1a3c4fc8a201f70c3d88b2e1"))
    }

    func testLoggedOutInstallKeepsFreeOneDeviceMirror() async {
        let manager = LicenseManager(
            store: MemoryLicenseStore(),
            remote: FakeLicenseRemote(),
            clock: TestLicenseClock(now: baseDate)
        )
        await manager.bootstrap()
        XCTAssertNil(manager.authSession)
        XCTAssertEqual(manager.state, .unlicensed)
        XCTAssertEqual(manager.state.capabilities.maximumSimultaneousDevices, 1)
        XCTAssertTrue(manager.state.capabilities.controlEnabled)
    }

    func testOldReceiptIsHonoredWithoutLoginUntilClaim() async {
        var record = LocalLicenseRecord(installationID: UUID())
        record.activationReceipt = receipt1
        record.licensePrincipal = .installation
        record.claimDeadline = baseDate.addingTimeInterval(86_400)
        let manager = LicenseManager(
            store: MemoryLicenseStore(record: record),
            remote: FakeLicenseRemote(
                validation: LicenseValidation(
                    isValid: true,
                    refreshedReceipt: receipt1,
                    serverTime: baseDate,
                    principal: .installation,
                    needsClaim: true,
                    claimDeadline: baseDate.addingTimeInterval(86_400)
                )
            ),
            clock: TestLicenseClock(now: baseDate)
        )
        await manager.bootstrap()
        XCTAssertNil(manager.authSession)
        XCTAssertEqual(manager.state, .licensed(lastValidatedAt: nil))
        XCTAssertTrue(manager.needsClaim)
        XCTAssertEqual(manager.state.capabilities, .activated)
    }

    func testExpiredUnclaimedReceiptDoesNotGrantPaidFeatures() async throws {
        var record = LocalLicenseRecord(installationID: UUID())
        record.activationReceipt = receipt1
        record.licensePrincipal = .installation
        record.claimDeadline = baseDate.addingTimeInterval(-1)
        let store = MemoryLicenseStore(record: record)
        let manager = LicenseManager(
            store: store,
            remote: FakeLicenseRemote(),
            clock: TestLicenseClock(now: baseDate)
        )
        await manager.bootstrap()
        XCTAssertEqual(manager.state, .unlicensed)
        XCTAssertTrue(manager.needsClaim)
        XCTAssertEqual(manager.state.capabilities, .unactivated)
        XCTAssertNotNil(manager.installationID)
        XCTAssertEqual(try store.load()?.activationReceipt, receipt1)
    }

    func testRedeemRequiresSignIn() async {
        let manager = LicenseManager(
            store: MemoryLicenseStore(),
            remote: FakeLicenseRemote(),
            clock: TestLicenseClock(now: baseDate)
        )
        do {
            try await manager.redeem(code: "SM-2345-6789-ABCD-EFGH-JKLM-NPQR")
            XCTFail("Expected loginRequired")
        } catch LicenseServiceError.loginRequired {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRedeemToAccountPersistsAccountPrincipal() async throws {
        let session = LicenseAuthSession(
            userID: UUID(),
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: baseDate.addingTimeInterval(3_600),
            email: "alex@example.com",
            provider: "google"
        )
        let remote = FakeLicenseRemote(
            redeemResult: LicenseActivation(receipt: receipt2, serverTime: baseDate)
        )
        let store = MemoryLicenseStore()
        let manager = LicenseManager(
            store: store,
            remote: remote,
            clock: TestLicenseClock(now: baseDate),
            authStore: MemoryLicenseAuthStore(session: session),
            authFlow: FakeLicenseAuthFlow(session: session)
        )
        try await manager.redeem(code: " sm-2345 ")
        XCTAssertEqual(try store.load()?.activationReceipt, receipt2)
        XCTAssertEqual(try store.load()?.licensePrincipal, .account)
        XCTAssertEqual(manager.principal, .account)
        XCTAssertFalse(manager.needsClaim)
        XCTAssertEqual(manager.state, .licensed(lastValidatedAt: baseDate))
        let redeem = await remote.lastRedeemCall()
        XCTAssertEqual(redeem?.code, "SM2345")
    }

    func testClaimBindsOldReceiptToSignedInAccount() async throws {
        var record = LocalLicenseRecord(installationID: UUID())
        record.activationReceipt = receipt1
        record.licensePrincipal = .installation
        let session = LicenseAuthSession(
            userID: UUID(),
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: baseDate.addingTimeInterval(3_600)
        )
        let remote = FakeLicenseRemote(
            claimResult: LicenseActivation(receipt: receipt1, serverTime: baseDate)
        )
        let store = MemoryLicenseStore(record: record)
        let manager = LicenseManager(
            store: store,
            remote: remote,
            clock: TestLicenseClock(now: baseDate),
            authStore: MemoryLicenseAuthStore(session: session),
            authFlow: FakeLicenseAuthFlow(session: session)
        )
        try await manager.claimFromReceipt()
        XCTAssertEqual(try store.load()?.licensePrincipal, .account)
        XCTAssertEqual(try store.load()?.claimedUserID, session.userID)
        XCTAssertFalse(manager.needsClaim)
        let claims = await remote.claimCallCount()
        XCTAssertEqual(claims, 1)
    }

    func testDoubleEntitlementRedeemIsRejected() async {
        let session = LicenseAuthSession(
            userID: UUID(),
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: baseDate.addingTimeInterval(3_600)
        )
        let manager = LicenseManager(
            store: MemoryLicenseStore(),
            remote: FakeLicenseRemote(
                redeemError: .rejected(code: "already_licensed", message: "already")
            ),
            clock: TestLicenseClock(now: baseDate),
            authStore: MemoryLicenseAuthStore(session: session),
            authFlow: FakeLicenseAuthFlow(session: session)
        )
        do {
            try await manager.redeem(code: "SM2345")
            XCTFail("Expected already_licensed")
        } catch let LicenseServiceError.rejected(code, _) {
            XCTAssertEqual(code, "already_licensed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(manager.state, .unlicensed)
    }

    func testClaimedReceiptWithoutSessionDoesNotGrantPaidFeatures() async {
        var record = LocalLicenseRecord(installationID: UUID())
        record.activationReceipt = receipt1
        record.licensePrincipal = .account
        record.claimedUserID = UUID()
        let manager = LicenseManager(
            store: MemoryLicenseStore(record: record),
            remote: FakeLicenseRemote(),
            clock: TestLicenseClock(now: baseDate)
        )
        await manager.bootstrap()
        XCTAssertEqual(manager.state, .unlicensed)
        XCTAssertEqual(manager.state.capabilities, .unactivated)
    }

    func testIToolCodesAreRejectedWithoutRemoteCall() async {
        let remote = FakeLicenseRemote()
        let manager = LicenseManager(
            store: MemoryLicenseStore(),
            remote: remote,
            clock: TestLicenseClock(now: baseDate)
        )
        do {
            try await manager.activate(code: "IT-PRO-CODE")
            XCTFail("Expected iTool rejection")
        } catch LicenseServiceError.iToolCodeNotAccepted {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let activationCall = await remote.lastActivationCall()
        XCTAssertNil(activationCall)
    }

    func testReleaseCompatibleKeychainQueryIsNonInteractiveAndDoesNotRequireAccessGroupEntitlements() {
        let identity = KeychainLicenseStore.itemIdentity
        XCTAssertNil(identity[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(identity[kSecAttrAccessible as String])
        XCTAssertNil(identity[kSecAttrSynchronizable as String])

        let query = KeychainLicenseStore.nonInteractiveQuery
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        XCTAssertEqual(context?.interactionNotAllowed, true)
    }
}

private final class MemoryLicenseStore: LicenseRecordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var record: LocalLicenseRecord?

    init(record: LocalLicenseRecord? = nil) {
        self.record = record
    }

    func load() throws -> LocalLicenseRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func save(_ record: LocalLicenseRecord) throws {
        lock.lock()
        self.record = record
        lock.unlock()
    }
}

private final class FlakyLicenseStore: LicenseRecordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int
    private var record: LocalLicenseRecord?

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func load() throws -> LocalLicenseRecord? {
        lock.lock()
        defer { lock.unlock() }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw LicenseServiceError.storage("temporary Keychain failure")
        }
        return record
    }

    func save(_ record: LocalLicenseRecord) throws {
        lock.lock()
        self.record = record
        lock.unlock()
    }
}

private final class TestLicenseClock: LicenseClock, @unchecked Sendable {
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

private actor FakeLicenseRemote: LicenseRemoteServicing {
    struct ActivationCall: Sendable {
        let code: String
        let installationID: UUID
    }

    private let activation: LicenseActivation
    private let validation: LicenseValidation
    private let redeemResult: LicenseActivation
    private let claimResult: LicenseActivation
    private let accountValidation: LicenseValidation
    private let activationError: LicenseServiceError?
    private let validationError: LicenseServiceError?
    private let redeemError: LicenseServiceError?
    private let claimError: LicenseServiceError?
    private let accountValidationError: LicenseServiceError?
    private let validationDelayNanoseconds: UInt64
    private var activationCalls: [ActivationCall] = []
    private var redeemCalls: [ActivationCall] = []
    private var claimCalls = 0
    private var validationCalls = 0
    private var accountValidationCalls = 0

    init(
        activation: LicenseActivation = LicenseActivation(
            receipt: "8dc53b7d-1a3c-4fc8-a201-f70c3d88b2e1",
            serverTime: Date(timeIntervalSince1970: 2_000_000_000)
        ),
        validation: LicenseValidation = LicenseValidation(
            isValid: true,
            refreshedReceipt: nil,
            serverTime: Date(timeIntervalSince1970: 2_000_000_000),
            principal: .installation,
            needsClaim: true
        ),
        redeemResult: LicenseActivation? = nil,
        claimResult: LicenseActivation? = nil,
        accountValidation: LicenseValidation? = nil,
        activationError: LicenseServiceError? = nil,
        validationError: LicenseServiceError? = nil,
        redeemError: LicenseServiceError? = nil,
        claimError: LicenseServiceError? = nil,
        accountValidationError: LicenseServiceError? = nil,
        validationDelayNanoseconds: UInt64 = 0
    ) {
        self.activation = activation
        self.validation = validation
        self.redeemResult = redeemResult ?? activation
        self.claimResult = claimResult ?? activation
        self.accountValidation = accountValidation ?? LicenseValidation(
            isValid: true,
            refreshedReceipt: activation.receipt,
            serverTime: activation.serverTime,
            principal: .account,
            needsClaim: false
        )
        self.activationError = activationError
        self.validationError = validationError
        self.redeemError = redeemError
        self.claimError = claimError
        self.accountValidationError = accountValidationError
        self.validationDelayNanoseconds = validationDelayNanoseconds
    }

    func activate(code: String, installationID: UUID) async throws -> LicenseActivation {
        activationCalls.append(ActivationCall(code: code, installationID: installationID))
        if let activationError { throw activationError }
        return activation
    }

    func validate(receipt: String, installationID: UUID) async throws -> LicenseValidation {
        validationCalls += 1
        if validationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: validationDelayNanoseconds)
        }
        if let validationError { throw validationError }
        return validation
    }

    func redeem(code: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation {
        redeemCalls.append(ActivationCall(code: code, installationID: installationID))
        if let redeemError { throw redeemError }
        return redeemResult
    }

    func claim(receipt: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation {
        claimCalls += 1
        if let claimError { throw claimError }
        return claimResult
    }

    func validateAccount(installationID: UUID, accessToken: String) async throws -> LicenseValidation {
        accountValidationCalls += 1
        if let accountValidationError { throw accountValidationError }
        return accountValidation
    }

    func lastActivationCall() -> ActivationCall? {
        activationCalls.last
    }

    func lastRedeemCall() -> ActivationCall? {
        redeemCalls.last
    }

    func claimCallCount() -> Int {
        claimCalls
    }

    func validationCallCount() -> Int {
        validationCalls
    }
}

private actor FakeLicenseAuthFlow: LicenseAuthFlowPerforming {
    var session: LicenseAuthSession
    var signInError: LicenseAuthError?

    init(session: LicenseAuthSession, signInError: LicenseAuthError? = nil) {
        self.session = session
        self.signInError = signInError
    }

    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession {
        if let signInError { throw signInError }
        return session
    }

    func signIn(email: String, password: String) async throws -> LicenseAuthSession {
        if let signInError { throw signInError }
        return session
    }

    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        session
    }

    func signOut(_ session: LicenseAuthSession) async {}
}
