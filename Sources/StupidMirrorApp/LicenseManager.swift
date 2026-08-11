import Combine
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

    init(installationID: UUID = UUID()) {
        self.installationID = installationID
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

    private let store: any LicenseRecordStoring
    private let remote: any LicenseRemoteServicing
    private let clock: any LicenseClock
    private let validationInterval: TimeInterval

    private var record: LocalLicenseRecord?
    private var didBootstrap = false
    private var validationTask: Task<Void, Never>?

    init(
        store: any LicenseRecordStoring,
        remote: any LicenseRemoteServicing,
        clock: any LicenseClock = SystemLicenseClock(),
        validationInterval: TimeInterval = LicenseManager.validationInterval
    ) {
        self.store = store
        self.remote = remote
        self.clock = clock
        self.validationInterval = validationInterval
    }

    static func live(bundle: Bundle = .main) -> LicenseManager {
        LicenseManager(
            store: KeychainLicenseStore(),
            remote: SupabaseLicenseRemoteClient(configuration: .from(bundle: bundle))
        )
    }

    var installationID: UUID? {
        record?.installationID
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
        try save(record)
        state = .licensed(lastValidatedAt: validatedAt)
    }

    func validateInBackgroundIfNeeded(force: Bool = false) {
        guard validationTask == nil,
              let record,
              let receipt = record.activationReceipt,
              LicenseReceiptFormat.isValid(receipt) else {
            return
        }

        if !force,
           let lastValidatedAt = record.lastValidatedAt,
           clock.now.timeIntervalSince(lastValidatedAt) >= 0 {
            let age = clock.now.timeIntervalSince(lastValidatedAt)
            if age < validationInterval { return }
        }

        let installationID = record.installationID
        validationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.validationTask = nil }
            do {
                let validation = try await self.remote.validate(
                    receipt: receipt,
                    installationID: installationID
                )
                guard !Task.isCancelled else { return }
                self.apply(validation: validation, originalReceipt: receipt)
            } catch {
                // Offline or a transient server failure must not interrupt an
                // already activated user. Only terminal receipt failures clear
                // the local entitlement.
                guard !Task.isCancelled else { return }
                if case let LicenseServiceError.rejected(code, _) = error,
                   ["license_revoked", "invalid_receipt"].contains(code) {
                    self.revokeLocalReceipt(matching: receipt)
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

    private func apply(validation: LicenseValidation, originalReceipt: String) {
        guard var record else { return }
        // An older validation request must never overwrite or revoke a receipt
        // installed by a newer activation request.
        guard record.activationReceipt == originalReceipt else { return }
        guard validation.isValid else {
            revokeLocalReceipt(matching: originalReceipt)
            return
        }

        let receipt = validation.refreshedReceipt ?? originalReceipt
        guard LicenseReceiptFormat.isValid(receipt) else {
            revokeLocalReceipt(matching: originalReceipt)
            return
        }
        let validatedAt = boundedValidationTime(validation.serverTime)
        record.activationReceipt = receipt
        record.lastValidatedAt = validatedAt
        record.lastTrustedTime = max(record.lastTrustedTime ?? validatedAt, validatedAt)
        do {
            try save(record)
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
            return
        }
        if let receipt = record.activationReceipt, LicenseReceiptFormat.isValid(receipt) {
            state = .licensed(lastValidatedAt: record.lastValidatedAt)
            return
        }
        state = .unlicensed
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
        guard wire.valid != false,
              let receipt = wire.receipt?.trimmingCharacters(in: .whitespacesAndNewlines),
              LicenseReceiptFormat.isValid(receipt),
              let serverTime = Self.parseDate(wire.serverTime) else {
            throw LicenseServiceError.invalidResponse
        }
        return LicenseActivation(receipt: receipt, serverTime: serverTime)
    }

    func validate(receipt: String, installationID: UUID) async throws -> LicenseValidation {
        let wire = try await request(
            ValidateRequest(
                action: "validate",
                installationID: installationID.uuidString.lowercased(),
                receipt: receipt,
                appVersion: configuration.appVersion
            )
        )
        guard let serverTime = Self.parseDate(wire.serverTime) else {
            throw LicenseServiceError.invalidResponse
        }
        let refreshedReceipt = wire.receipt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard refreshedReceipt.map(LicenseReceiptFormat.isValid) ?? true else {
            throw LicenseServiceError.invalidResponse
        }
        return LicenseValidation(
            isValid: wire.valid ?? wire.ok ?? false,
            refreshedReceipt: refreshedReceipt,
            serverTime: serverTime
        )
    }

    private func request<Request: Encodable>(_ payload: Request) async throws -> WireResponse {
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

        enum CodingKeys: String, CodingKey {
            case action, receipt
            case installationID = "installation_id"
            case appVersion = "app_version"
        }
    }

    private struct WireResponse: Decodable {
        let ok: Bool?
        let valid: Bool?
        let receipt: String?
        let serverTime: String?
        let code: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case ok, valid, receipt, code, message
            case serverTime = "server_time"
        }
    }
}
