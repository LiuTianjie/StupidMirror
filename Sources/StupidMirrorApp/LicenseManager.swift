import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum LicenseState: Equatable, Sendable {
    case checking
    case unlicensed
    case licensed(lastValidatedAt: Date?)
    case unavailable(String)

    var isActivated: Bool {
        if case .licensed = self { return true }
        return false
    }

    var capabilities: LicenseCapabilities {
        isActivated ? .activated : .unactivated
    }

    var showsDashboardActivationEntry: Bool {
        switch self {
        case .checking, .licensed:
            false
        case .unlicensed, .unavailable:
            true
        }
    }
}

enum LicenseClientProtocol {
    static let accountBound = 2
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

struct LocalLicenseRecord: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let installationID: UUID
    var trialStartedAt: Date?
    var lastTrustedTime: Date?
    var activationReceipt: String?
    var lastValidatedAt: Date?
    var licensePrincipal: LicensePrincipal?
    var claimedUserID: UUID?
    var claimDeadline: Date?

    init(installationID: UUID = UUID()) {
        self.installationID = installationID
    }

    var principal: LicensePrincipal {
        licensePrincipal ?? .installation
    }
}

struct LicenseActivation: Equatable, Sendable {
    let receipt: String
    let serverTime: Date
}

struct LicenseValidation: Equatable, Sendable {
    let isValid: Bool
    let refreshedReceipt: String?
    let serverTime: Date
    var principal: LicensePrincipal = .installation
    var needsClaim: Bool = false
    var claimDeadline: Date? = nil
}

enum LicenseReceiptFormat {
    /// Mirrors the Edge Function's UUID contract: canonical 8-4-4-4-12 hex,
    /// UUID version 1...8, and RFC 4122 variant bits.
    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36,
              bytes[8] == 45, bytes[13] == 45, bytes[18] == 45, bytes[23] == 45,
              (49...56).contains(bytes[14]),
              [56, 57, 65, 66, 97, 98].contains(bytes[19]) else {
            return false
        }

        for (index, byte) in bytes.enumerated() where ![8, 13, 18, 23].contains(index) {
            let isDigit = (48...57).contains(byte)
            let isLowerHex = (97...102).contains(byte)
            let isUpperHex = (65...70).contains(byte)
            guard isDigit || isLowerHex || isUpperHex else { return false }
        }
        return UUID(uuidString: value) != nil
    }
}

protocol LicenseRecordStoring: Sendable {
    func load() throws -> LocalLicenseRecord?
    func save(_ record: LocalLicenseRecord) throws
}

protocol LicenseRemoteServicing: Sendable {
    func activate(code: String, installationID: UUID) async throws -> LicenseActivation
    func validate(receipt: String, installationID: UUID) async throws -> LicenseValidation
    func redeem(code: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation
    func claim(receipt: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation
    func validateAccount(installationID: UUID, accessToken: String) async throws -> LicenseValidation
}

protocol LicenseClock: Sendable {
    var now: Date { get }
}

struct SystemLicenseClock: LicenseClock {
    var now: Date { Date() }
}

enum LicenseServiceError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case emptyCode
    case requestInProgress
    case invalidResponse
    case loginRequired
    case iToolCodeNotAccepted
    case rejected(code: String, message: String)
    case storage(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "License activation is not configured in this build."
        case .emptyCode:
            "Enter an activation code."
        case .requestInProgress:
            "A license request is already in progress."
        case .invalidResponse:
            "The license server returned an invalid response."
        case .loginRequired:
            "Sign in with Google, GitHub, or email to buy, redeem, or claim a license."
        case .iToolCodeNotAccepted:
            "iTool Pro codes cannot be redeemed in StupidMirror. Use an SM- activation code."
        case let .rejected(_, message):
            message
        case let .storage(message):
            message
        }
    }
}

/// Owns the app-wide license state. It intentionally has no timer or long-lived
/// process: activated installations work from their cached receipt immediately,
/// and a stale receipt is validated in one coalesced background request.
@MainActor
final class LicenseManager: ObservableObject {
    static let validationInterval: TimeInterval = 24 * 60 * 60
    static let maximumServerClockSkew: TimeInterval = 5 * 60

    @Published private(set) var state: LicenseState = .checking
    @Published private(set) var isActivating = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var needsClaim = false
    @Published private(set) var principal: LicensePrincipal = .installation
    @Published private(set) var authSession: LicenseAuthSession?

    private let store: any LicenseRecordStoring
    private let remote: any LicenseRemoteServicing
    private let clock: any LicenseClock
    private let validationInterval: TimeInterval
    private let authStore: any LicenseAuthSessionStoring
    private let authFlow: any LicenseAuthFlowPerforming

    private var record: LocalLicenseRecord?
    private var didBootstrap = false
    private var validationTask: Task<Void, Never>?

    init(
        store: any LicenseRecordStoring,
        remote: any LicenseRemoteServicing,
        clock: any LicenseClock = SystemLicenseClock(),
        validationInterval: TimeInterval = LicenseManager.validationInterval,
        authStore: any LicenseAuthSessionStoring = MemoryLicenseAuthStore(),
        authFlow: any LicenseAuthFlowPerforming = UnavailableLicenseAuthFlow()
    ) {
        self.store = store
        self.remote = remote
        self.clock = clock
        self.validationInterval = validationInterval
        self.authStore = authStore
        self.authFlow = authFlow
    }

    static func live(bundle: Bundle = .main) -> LicenseManager {
        let configuration = LicenseRemoteConfiguration.from(bundle: bundle)
        return LicenseManager(
            store: KeychainLicenseStore(),
            remote: SupabaseLicenseRemoteClient(configuration: configuration),
            authStore: KeychainLicenseAuthStore(),
            authFlow: SupabaseLicenseAuthClient(configuration: configuration)
        )
    }

    var installationID: UUID? {
        record?.installationID
    }

    var showsDashboardActivationEntry: Bool {
        needsClaim || state.showsDashboardActivationEntry
    }

    func bootstrap() async {
        guard !didBootstrap else { return }

        do {
            if let existing = try store.load() {
                record = existing
            } else {
                let created = LocalLicenseRecord()
                try store.save(created)
                record = created
            }
            try invalidateMalformedLocalReceiptIfNeeded()
            authSession = try? authStore.load()
            refreshStateFromLocalRecord()
            didBootstrap = true
            validateInBackgroundIfNeeded()
        } catch {
            didBootstrap = false
            state = .unavailable(storageMessage(for: error))
        }
    }

    func activate(code: String) async throws {
        await bootstrap()
        guard !isActivating else { throw LicenseServiceError.requestInProgress }
        guard var record else { throw LicenseServiceError.storage(unavailableStateMessage) }

        if Self.isIToolCode(code) { throw LicenseServiceError.iToolCodeNotAccepted }
        let normalizedCode = Self.normalize(code: code)
        guard !normalizedCode.isEmpty else { throw LicenseServiceError.emptyCode }

        isActivating = true
        defer { isActivating = false }

        let activation = try await remote.activate(
            code: normalizedCode,
            installationID: record.installationID
        )
        guard LicenseReceiptFormat.isValid(activation.receipt) else {
            throw LicenseServiceError.invalidResponse
        }
        let validatedAt = boundedValidationTime(activation.serverTime)
        record.activationReceipt = activation.receipt
        record.lastValidatedAt = validatedAt
        record.lastTrustedTime = max(record.lastTrustedTime ?? validatedAt, validatedAt)
        record.licensePrincipal = .installation
        record.claimedUserID = nil
        record.claimDeadline = LicenseManager.defaultClaimDeadline
        try save(record)
        principal = .installation
        needsClaim = true
        state = .licensed(lastValidatedAt: validatedAt)
    }

    func redeem(code: String) async throws {
        await bootstrap()
        try await refreshAuthSessionIfNeeded()
        guard authSession != nil else { throw LicenseServiceError.loginRequired }
        guard !isActivating else { throw LicenseServiceError.requestInProgress }
        guard var record else { throw LicenseServiceError.storage(unavailableStateMessage) }
        if Self.isIToolCode(code) { throw LicenseServiceError.iToolCodeNotAccepted }
        let normalizedCode = Self.normalize(code: code)
        guard !normalizedCode.isEmpty else { throw LicenseServiceError.emptyCode }

        isActivating = true
        defer { isActivating = false }

        let accessToken = try await validAccessToken()
        let activation = try await remote.redeem(
            code: normalizedCode,
            installationID: record.installationID,
            accessToken: accessToken
        )
        try persistAccountActivation(activation, on: &record)
    }

    func claimFromReceipt() async throws {
        await bootstrap()
        try await refreshAuthSessionIfNeeded()
        guard authSession != nil else { throw LicenseServiceError.loginRequired }
        guard !isActivating else { throw LicenseServiceError.requestInProgress }
        guard var record else { throw LicenseServiceError.storage(unavailableStateMessage) }
        guard let receipt = record.activationReceipt, LicenseReceiptFormat.isValid(receipt) else {
            throw LicenseServiceError.rejected(code: "invalid_receipt", message: "There is no local license to claim.")
        }

        isActivating = true
        defer { isActivating = false }

        let accessToken = try await validAccessToken()
        let activation = try await remote.claim(
            receipt: receipt,
            installationID: record.installationID,
            accessToken: accessToken
        )
        try persistAccountActivation(activation, on: &record)
    }

    func signIn(provider: LicenseAuthProvider) async throws {
        await bootstrap()
        guard !isSigningIn else { throw LicenseServiceError.requestInProgress }
        isSigningIn = true
        defer { isSigningIn = false }
        let session = try await authFlow.signIn(provider: provider)
        try authStore.save(session)
        authSession = session
        refreshStateFromLocalRecord()
        validateInBackgroundIfNeeded(force: true)
    }

    func signIn(email: String, password: String) async throws {
        await bootstrap()
        guard !isSigningIn else { throw LicenseServiceError.requestInProgress }
        isSigningIn = true
        defer { isSigningIn = false }
        let session = try await authFlow.signIn(email: email, password: password)
        try authStore.save(session)
        authSession = session
        refreshStateFromLocalRecord()
        validateInBackgroundIfNeeded(force: true)
    }

    func signOut() async {
        if let session = authSession {
            await authFlow.signOut(session)
        }
        try? authStore.clear()
        authSession = nil
        refreshStateFromLocalRecord()
    }

    func validateInBackgroundIfNeeded(force: Bool = false) {
        guard validationTask == nil, let record else { return }

        if !force,
           let lastValidatedAt = record.lastValidatedAt,
           clock.now.timeIntervalSince(lastValidatedAt) >= 0 {
            let age = clock.now.timeIntervalSince(lastValidatedAt)
            if age < validationInterval { return }
        }

        let installationID = record.installationID
        let receipt = record.activationReceipt
        let hasReceipt = receipt.map(LicenseReceiptFormat.isValid) ?? false
        let hasSession = authSession != nil
        if !hasSession && !hasReceipt { return }

        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.validationTask = nil }
            do {
                try await self.refreshAuthSessionIfNeeded()
                let validation: LicenseValidation
                if let session = self.authSession {
                    do {
                        validation = try await self.remote.validateAccount(
                            installationID: installationID,
                            accessToken: session.accessToken
                        )
                    } catch let LicenseServiceError.rejected(code, _) where code == "invalid_receipt" {
                        if let receipt, LicenseReceiptFormat.isValid(receipt) {
                            let fallback = try await self.remote.validate(
                                receipt: receipt,
                                installationID: installationID
                            )
                            guard !Task.isCancelled else { return }
                            self.apply(validation: fallback, originalReceipt: receipt)
                            return
                        }
                        throw LicenseServiceError.rejected(code: code, message: "This account does not have an active StupidMirror license.")
                    }
                } else if let receipt, LicenseReceiptFormat.isValid(receipt) {
                    validation = try await self.remote.validate(
                        receipt: receipt,
                        installationID: installationID
                    )
                } else {
                    return
                }
                guard !Task.isCancelled else { return }
                self.apply(validation: validation, originalReceipt: receipt)
            } catch {
                guard !Task.isCancelled else { return }
                if case let LicenseServiceError.rejected(code, _) = error {
                    if code == "login_required" {
                        try? self.authStore.clear()
                        self.authSession = nil
                        self.refreshStateFromLocalRecord()
                        return
                    }
                    if ["license_revoked", "invalid_receipt", "claim_required"].contains(code) {
                        if code == "claim_required" {
                            self.needsClaim = true
                            self.principal = .installation
                            if var record = self.record {
                                record.claimDeadline = self.clock.now.addingTimeInterval(-1)
                                try? self.save(record)
                            }
                            self.refreshStateFromLocalRecord()
                            return
                        }
                        if let receipt {
                            self.revokeLocalReceipt(matching: receipt)
                        } else {
                            self.refreshStateFromLocalRecord()
                        }
                    }
                }
            }
        }
    }

    func waitForBackgroundValidation() async {
        await validationTask?.value
    }

    func cancel() {
        validationTask?.cancel()
        validationTask = nil
    }

    func checkpointTrustedTime() {
        refreshStateFromLocalRecord()
    }

    static func normalize(code: String) -> String {
        code
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func isIToolCode(_ code: String) -> Bool {
        normalize(code: code).hasPrefix("IT")
    }

    static let defaultClaimDeadline = Date(timeIntervalSince1970: 1_796_169_600)

    private func apply(validation: LicenseValidation, originalReceipt: String?) {
        guard var record else { return }
        // An older validation request must never overwrite or revoke a receipt
        // installed by a newer activation request.
        if let originalReceipt, record.activationReceipt != originalReceipt {
            return
        }
        guard validation.isValid else {
            if let originalReceipt {
                revokeLocalReceipt(matching: originalReceipt)
            } else {
                refreshStateFromLocalRecord()
            }
            return
        }

        let receipt = validation.refreshedReceipt ?? originalReceipt ?? ""
        guard LicenseReceiptFormat.isValid(receipt) else {
            if let originalReceipt {
                revokeLocalReceipt(matching: originalReceipt)
            }
            return
        }
        let validatedAt = boundedValidationTime(validation.serverTime)
        record.activationReceipt = receipt
        record.lastValidatedAt = validatedAt
        record.lastTrustedTime = max(record.lastTrustedTime ?? validatedAt, validatedAt)
        record.licensePrincipal = validation.principal
        record.claimDeadline = validation.claimDeadline
        if validation.principal == .account {
            record.claimedUserID = authSession?.userID
        }
        do {
            try save(record)
            principal = validation.principal
            needsClaim = validation.needsClaim && validation.principal == .installation
            state = .licensed(lastValidatedAt: validatedAt)
        } catch {
            // Keep the in-memory entitlement for this run, but surface the
            // persistence problem instead of pretending it was saved.
            state = .unavailable(storageMessage(for: error))
        }
    }

    private func revokeLocalReceipt(matching expectedReceipt: String) {
        guard var record, record.activationReceipt == expectedReceipt else { return }
        record.activationReceipt = nil
        record.lastValidatedAt = nil
        do {
            try save(record)
            refreshStateFromLocalRecord()
        } catch {
            state = .unavailable(storageMessage(for: error))
        }
    }

    private func refreshStateFromLocalRecord() {
        guard let record else {
            state = .unavailable("License state is unavailable.")
            needsClaim = false
            return
        }

        principal = record.principal
        let hasValidReceipt = record.activationReceipt.map(LicenseReceiptFormat.isValid) ?? false

        if record.principal == .account {
            needsClaim = false
            if authSession != nil, hasValidReceipt {
                state = .licensed(lastValidatedAt: record.lastValidatedAt)
                return
            }
            // After claim, the account is the principal. A Keychain receipt
            // alone must not keep paid features without a session.
            state = .unlicensed
            return
        }

        if hasValidReceipt {
            if let deadline = record.claimDeadline, clock.now >= deadline {
                needsClaim = true
                state = .unlicensed
                return
            }
            needsClaim = record.principal == .installation
            state = .licensed(lastValidatedAt: record.lastValidatedAt)
            return
        }

        needsClaim = false
        state = .unlicensed
    }

    private func persistAccountActivation(
        _ activation: LicenseActivation,
        on record: inout LocalLicenseRecord
    ) throws {
        guard LicenseReceiptFormat.isValid(activation.receipt) else {
            throw LicenseServiceError.invalidResponse
        }
        let validatedAt = boundedValidationTime(activation.serverTime)
        record.activationReceipt = activation.receipt
        record.lastValidatedAt = validatedAt
        record.lastTrustedTime = max(record.lastTrustedTime ?? validatedAt, validatedAt)
        record.licensePrincipal = .account
        record.claimedUserID = authSession?.userID
        record.claimDeadline = nil
        try save(record)
        principal = .account
        needsClaim = false
        state = .licensed(lastValidatedAt: validatedAt)
    }

    private func validAccessToken() async throws -> String {
        try await refreshAuthSessionIfNeeded()
        guard let token = authSession?.accessToken, !token.isEmpty else {
            throw LicenseServiceError.loginRequired
        }
        return token
    }

    private func refreshAuthSessionIfNeeded() async throws {
        guard let session = authSession, session.isExpired else { return }
        do {
            let refreshed = try await authFlow.refresh(session)
            try authStore.save(refreshed)
            authSession = refreshed
        } catch {
            try? authStore.clear()
            authSession = nil
            throw LicenseServiceError.loginRequired
        }
    }

    private func invalidateMalformedLocalReceiptIfNeeded() throws {
        guard var record,
              let receipt = record.activationReceipt,
              !LicenseReceiptFormat.isValid(receipt) else {
            return
        }
        record.activationReceipt = nil
        record.lastValidatedAt = nil
        try save(record)
    }

    private func boundedValidationTime(_ serverTime: Date) -> Date {
        min(serverTime, clock.now.addingTimeInterval(Self.maximumServerClockSkew))
    }

    private func save(_ record: LocalLicenseRecord) throws {
        do {
            try store.save(record)
            self.record = record
        } catch {
            throw LicenseServiceError.storage(storageMessage(for: error))
        }
    }

    private var unavailableStateMessage: String {
        if case let .unavailable(message) = state {
            return message
        }
        return "License state is unavailable."
    }

    private func storageMessage(for error: Error) -> String {
        if let error = error as? LicenseServiceError {
            return error.localizedDescription
        }
        return "Could not securely store the license state: \(error.localizedDescription)"
    }
}

final class KeychainLicenseStore: LicenseRecordStoring, @unchecked Sendable {
    static let service = "com.gaojiua.StupidMirror.license.v1"
    private static let account = "installation-state"
    private static let interactionLock = NSLock()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() throws -> LocalLicenseRecord? {
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
            do {
                return try decoder.decode(LocalLicenseRecord.self, from: data)
            } catch {
                throw LicenseServiceError.storage("The saved license state is damaged and was not reset.")
            }
        }
    }

    func save(_ record: LocalLicenseRecord) throws {
        let data = try encoder.encode(record)
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

    /// Never let an ACL mismatch turn a background license check into a
    /// Keychain password dialog. Official releases keep a stable Developer ID
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
        return .storage("Could not access the secure license record: \(message)")
    }
}

struct LicenseRemoteConfiguration: Sendable {
    let endpoint: URL?
    let publishableKey: String
    let appVersion: String

    var projectURL: URL? {
        guard let endpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Supabase Auth base (`…/auth/v1`), derived from the license Edge Function URL.
    var authBaseURL: URL? {
        guard let endpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = components.host else {
            return nil
        }
        components.scheme = "https"
        components.host = host
        components.path = "/auth/v1"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func from(bundle: Bundle) -> LicenseRemoteConfiguration {
        let endpointValue = (bundle.object(forInfoDictionaryKey: "StupidMirrorLicenseEndpoint") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (bundle.object(forInfoDictionaryKey: "StupidMirrorLicensePublishableKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        return LicenseRemoteConfiguration(endpoint: URL(string: endpointValue), publishableKey: key, appVersion: version)
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
            throw LicenseServiceError.invalidResponse
        }
        return (data, response)
    }
}

struct SupabaseLicenseRemoteClient: LicenseRemoteServicing {
    private let configuration: LicenseRemoteConfiguration
    private let transport: any LicenseHTTPTransport

    init(
        configuration: LicenseRemoteConfiguration,
        transport: any LicenseHTTPTransport = URLSessionLicenseTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    func activate(code: String, installationID: UUID) async throws -> LicenseActivation {
        let wire = try await request(
            ActivateRequest(
                action: "activate",
                installationID: installationID.uuidString.lowercased(),
                code: code,
                appVersion: configuration.appVersion
            )
        )
        return try Self.makeActivation(from: wire)
    }

    func validate(receipt: String, installationID: UUID) async throws -> LicenseValidation {
        let wire = try await request(
            ValidateRequest(
                action: "validate",
                installationID: installationID.uuidString.lowercased(),
                receipt: receipt,
                appVersion: configuration.appVersion,
                clientProtocol: LicenseClientProtocol.accountBound
            )
        )
        return try Self.makeValidation(from: wire)
    }

    func redeem(code: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation {
        // Account path: PostgREST JWT RPC (not Edge). installationID kept for protocol symmetry.
        _ = installationID
        let wire = try await rpc(
            "stupidmirror_redeem_for_user",
            body: RedeemForUserRequest(pCodeHash: Self.compactCodeHash(code)),
            accessToken: accessToken
        )
        return try Self.makeActivation(from: wire)
    }

    func claim(receipt: String, installationID: UUID, accessToken: String) async throws -> LicenseActivation {
        let wire = try await rpc(
            "stupidmirror_claim_for_user",
            body: ClaimForUserRequest(
                pReceipt: receipt,
                pInstallationHash: Self.installationHash(installationID)
            ),
            accessToken: accessToken
        )
        return try Self.makeActivation(from: wire)
    }

    func validateAccount(installationID: UUID, accessToken: String) async throws -> LicenseValidation {
        _ = installationID
        let wire = try await rpc(
            "stupidmirror_entitlement_for_user",
            body: EmptyRPCRequest(),
            accessToken: accessToken
        )
        if wire.active != true && wire.valid != true {
            throw LicenseServiceError.rejected(
                code: "invalid_receipt",
                message: "This account does not have an active StupidMirror license."
            )
        }
        return try Self.makeValidation(from: wire, defaultPrincipal: .account)
    }

    private static func compactCodeHash(_ normalizedCode: String) -> String {
        sha256Hex(normalizedCode.replacingOccurrences(of: "-", with: ""))
    }

    private static func installationHash(_ installationID: UUID) -> String {
        sha256Hex(installationID.uuidString.lowercased())
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeActivation(from wire: WireResponse) throws -> LicenseActivation {
        guard wire.valid != false,
              wire.active != false,
              let receipt = wire.receipt?.trimmingCharacters(in: .whitespacesAndNewlines),
              LicenseReceiptFormat.isValid(receipt) else {
            throw LicenseServiceError.invalidResponse
        }
        let serverTime = parseDate(wire.serverTime) ?? parseDate(wire.activatedAt) ?? Date()
        return LicenseActivation(receipt: receipt, serverTime: serverTime)
    }

    private static func makeValidation(from wire: WireResponse, defaultPrincipal: LicensePrincipal = .installation) throws -> LicenseValidation {
        let serverTime = parseDate(wire.serverTime) ?? parseDate(wire.activatedAt) ?? Date()
        let refreshedReceipt = wire.receipt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard refreshedReceipt.map(LicenseReceiptFormat.isValid) ?? true else {
            throw LicenseServiceError.invalidResponse
        }
        let principal = LicensePrincipal(rawValue: wire.principal ?? "") ?? defaultPrincipal
        return LicenseValidation(
            isValid: wire.active ?? wire.valid ?? wire.ok ?? false,
            refreshedReceipt: refreshedReceipt,
            serverTime: serverTime,
            principal: principal,
            needsClaim: wire.needsClaim ?? (principal == .installation),
            claimDeadline: parseDate(wire.claimBy)
        )
    }

        private func rpc<Request: Encodable>(
        _ name: String,
        body: Request,
        accessToken: String
    ) async throws -> WireResponse {
        guard let projectURL = configuration.projectURL,
              !configuration.publishableKey.isEmpty else {
            throw LicenseServiceError.notConfigured
        }
        let endpoint = projectURL
            .appendingPathComponent("rest/v1/rpc")
            .appendingPathComponent(name)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await transport.data(for: request)
        let wire = try? JSONDecoder().decode(WireResponse.self, from: data)
        let postgrest = try? JSONDecoder().decode(PostgRESTError.self, from: data)
        guard (200..<300).contains(response.statusCode) else {
            let code = wire?.code ?? postgrest?.code ?? "http_\(response.statusCode)"
            throw LicenseServiceError.rejected(
                code: code,
                message: wire?.message ?? postgrest?.message ?? "License request failed (HTTP \(response.statusCode))."
            )
        }
        // entitlement_for_user may return {ok, active, ...} without rejecting on inactive
        guard let wire else {
            throw LicenseServiceError.invalidResponse
        }
        if wire.ok == false {
            throw LicenseServiceError.rejected(
                code: wire.code ?? "invalid_response",
                message: wire.message ?? "The license server rejected the request."
            )
        }
        return wire
    }

private func request<Request: Encodable>(
        _ payload: Request,
        accessToken: String? = nil
    ) async throws -> WireResponse {
        guard let endpoint = configuration.endpoint,
              endpoint.scheme?.lowercased() == "https",
              !configuration.publishableKey.isEmpty else {
            throw LicenseServiceError.notConfigured
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Supabase's current publishable keys belong in `apikey`; they are not
        // JWTs and must not be sent as a Bearer Authorization credential.
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await transport.data(for: request)
        let wire = try? JSONDecoder().decode(WireResponse.self, from: data)
        guard (200..<300).contains(response.statusCode) else {
            throw LicenseServiceError.rejected(
                code: wire?.code ?? "http_\(response.statusCode)",
                message: wire?.message ?? "License request failed (HTTP \(response.statusCode))."
            )
        }
        guard let wire, wire.ok != false else {
            throw LicenseServiceError.rejected(
                code: wire?.code ?? "invalid_response",
                message: wire?.message ?? "The license server rejected the request."
            )
        }
        return wire
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private struct ActivateRequest: Encodable {
        let action: String
        let installationID: String
        let code: String
        let appVersion: String

        enum CodingKeys: String, CodingKey {
            case action, code
            case installationID = "installation_id"
            case appVersion = "app_version"
        }
    }

    private struct ValidateRequest: Encodable {
        let action: String
        let installationID: String
        let receipt: String
        let appVersion: String
        let clientProtocol: Int

        enum CodingKeys: String, CodingKey {
            case action, receipt
            case installationID = "installation_id"
            case appVersion = "app_version"
            case clientProtocol = "client_protocol"
        }
    }

    private struct AuthenticatedCodeRequest: Encodable {
        let action: String
        let installationID: String
        let code: String
        let appVersion: String
        let clientProtocol: Int

        enum CodingKeys: String, CodingKey {
            case action, code
            case installationID = "installation_id"
            case appVersion = "app_version"
            case clientProtocol = "client_protocol"
        }
    }

    private struct ClaimRequest: Encodable {
        let action: String
        let installationID: String
        let receipt: String
        let appVersion: String
        let clientProtocol: Int

        enum CodingKeys: String, CodingKey {
            case action, receipt
            case installationID = "installation_id"
            case appVersion = "app_version"
            case clientProtocol = "client_protocol"
        }
    }

    private struct AccountValidateRequest: Encodable {
        let action: String
        let installationID: String
        let appVersion: String
        let clientProtocol: Int

        enum CodingKeys: String, CodingKey {
            case action
            case installationID = "installation_id"
            case appVersion = "app_version"
            case clientProtocol = "client_protocol"
        }
    }

    private struct EmptyRPCRequest: Encodable {}

    private struct RedeemForUserRequest: Encodable {
        let pCodeHash: String
        enum CodingKeys: String, CodingKey { case pCodeHash = "p_code_hash" }
    }

    private struct ClaimForUserRequest: Encodable {
        let pReceipt: String
        let pInstallationHash: String
        enum CodingKeys: String, CodingKey {
            case pReceipt = "p_receipt"
            case pInstallationHash = "p_installation_hash"
        }
    }

    private struct PostgRESTError: Decodable {
        let code: String?
        let message: String?
    }

    private struct WireResponse: Decodable {
        let ok: Bool?
        let valid: Bool?
        let active: Bool?
        let receipt: String?
        let serverTime: String?
        let activatedAt: String?
        let code: String?
        let message: String?
        let principal: String?
        let needsClaim: Bool?
        let claimBy: String?

        enum CodingKeys: String, CodingKey {
            case ok, valid, active, receipt, code, message, principal
            case serverTime = "server_time"
            case activatedAt = "activated_at"
            case needsClaim = "needs_claim"
            case claimBy = "claim_by"
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
