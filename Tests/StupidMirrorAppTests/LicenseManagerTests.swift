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

    func testUnactivatedInstallHasOneDeviceAndNoControl() async throws {
        let store = MemoryLicenseStore()
        let manager = LicenseManager(
            store: store,
            remote: FakeLicenseRemote(),
            clock: TestLicenseClock(now: baseDate)
        )

        await manager.bootstrap()

        XCTAssertEqual(manager.state, .unlicensed)
        XCTAssertEqual(manager.state.capabilities.maximumSimultaneousDevices, 1)
        XCTAssertFalse(manager.state.capabilities.controlEnabled)
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
    private let activationError: LicenseServiceError?
    private let validationError: LicenseServiceError?
    private let validationDelayNanoseconds: UInt64
    private var activationCalls: [ActivationCall] = []
    private var validationCalls = 0

    init(
        activation: LicenseActivation = LicenseActivation(
            receipt: "8dc53b7d-1a3c-4fc8-a201-f70c3d88b2e1",
            serverTime: Date(timeIntervalSince1970: 2_000_000_000)
        ),
        validation: LicenseValidation = LicenseValidation(
            isValid: true,
            refreshedReceipt: nil,
            serverTime: Date(timeIntervalSince1970: 2_000_000_000)
        ),
        activationError: LicenseServiceError? = nil,
        validationError: LicenseServiceError? = nil,
        validationDelayNanoseconds: UInt64 = 0
    ) {
        self.activation = activation
        self.validation = validation
        self.activationError = activationError
        self.validationError = validationError
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

    func lastActivationCall() -> ActivationCall? {
        activationCalls.last
    }

    func validationCallCount() -> Int {
        validationCalls
    }
}
