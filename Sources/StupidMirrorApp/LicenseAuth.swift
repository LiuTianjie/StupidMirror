import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum LicensePrincipal: String, Codable, Equatable, Sendable {
    case installation
    case account
}

enum LicenseAuthProvider: String, Equatable, Sendable {
    case google
    case github
}

/// OAuth callback + purchase URL alias.
/// Purchase destination is LicensePurchaseURLs.buyURL.
/// Do not redeem iTool IT- codes here.
enum LicensePurchaseLinks {
    static let buyURL = LicensePurchaseURLs.buyURL
    static let callbackScheme = "stupidmirror"
    static let callbackURL = URL(string: "stupidmirror://auth-callback")!
}



struct LicenseAuthSession: Codable, Equatable, Sendable {
    var userID: UUID
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String?
    var provider: String?

    var isExpired: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }
}

enum LicenseAuthError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case cancelled
    case invalidCallback
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Sign-in is not configured in this build."
        case .cancelled:
            "Sign-in was cancelled."
        case .invalidCallback:
            "Sign-in did not return a usable session."
        case let .rejected(message):
            message
        }
    }
}

protocol LicenseAuthSessionStoring: Sendable {
    func load() throws -> LicenseAuthSession?
    func save(_ session: LicenseAuthSession) throws
    func clear() throws
}

protocol LicenseAuthFlowPerforming: Sendable {
    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession
    func signIn(email: String, password: String) async throws -> LicenseAuthSession
    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession
    func signOut(_ session: LicenseAuthSession) async
}

final class KeychainLicenseAuthStore: LicenseAuthSessionStoring, @unchecked Sendable {
    static let service = "com.gaojiua.StupidMirror.auth.v1"
    private static let account = "supabase-session"
    private static let interactionLock = NSLock()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() throws -> LicenseAuthSession? {
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
                throw LicenseServiceError.storage("Could not access the saved sign-in session.")
            }
            do {
                return try decoder.decode(LicenseAuthSession.self, from: data)
            } catch {
                throw LicenseServiceError.storage("The saved sign-in session is damaged and was not reset.")
            }
        }
    }

    func save(_ session: LicenseAuthSession) throws {
        let data = try encoder.encode(session)
        try withoutLegacyKeychainInteraction {
            let updateStatus = SecItemUpdate(
                Self.nonInteractiveQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            if updateStatus == errSecSuccess {
                return
            }
            guard updateStatus == errSecItemNotFound else {
                throw LicenseServiceError.storage("Could not save the sign-in session.")
            }

            var attributes = Self.itemIdentity
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw LicenseServiceError.storage("Could not save the sign-in session.")
            }
        }
    }

    func clear() throws {
        try withoutLegacyKeychainInteraction {
            let status = SecItemDelete(Self.nonInteractiveQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LicenseServiceError.storage("Could not clear the sign-in session.")
            }
        }
    }

    static var itemIdentity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }

    static var nonInteractiveQuery: [String: Any] {
        var query = itemIdentity
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private func withoutLegacyKeychainInteraction<Value>(_ operation: () throws -> Value) throws -> Value {
        Self.interactionLock.lock()
        defer { Self.interactionLock.unlock() }

        var wasAllowed = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard readStatus == errSecSuccess else {
            throw LicenseServiceError.storage("Could not access the saved sign-in session.")
        }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else {
            throw LicenseServiceError.storage("Could not access the saved sign-in session.")
        }
        defer { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return try operation()
    }
}

struct SupabaseLicenseAuthClient: LicenseAuthFlowPerforming {
    private let configuration: LicenseRemoteConfiguration
    private let transport: any LicenseHTTPTransport
    private let browser: any LicenseOAuthBrowsing

    init(
        configuration: LicenseRemoteConfiguration,
        transport: any LicenseHTTPTransport = URLSessionLicenseTransport(),
        browser: any LicenseOAuthBrowsing = SystemLicenseOAuthBrowser()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.browser = browser
    }

    func signIn(provider: LicenseAuthProvider) async throws -> LicenseAuthSession {
        guard let authBase = configuration.authBaseURL,
              !configuration.publishableKey.isEmpty else {
            throw LicenseAuthError.notConfigured
        }

        let verifier = Self.makeCodeVerifier()
        let challenge = Self.makeCodeChallenge(verifier)
        var components = URLComponents(
            url: authBase.appending(path: "authorize"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: LicensePurchaseLinks.callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
            URLQueryItem(name: "apikey", value: configuration.publishableKey)
        ]
        guard let authorizeURL = components?.url else {
            throw LicenseAuthError.notConfigured
        }

        let callbackURL = try await browser.open(authorizeURL, callbackScheme: LicensePurchaseLinks.callbackScheme)
        let authCode = try Self.authCode(from: callbackURL)
        return try await exchange(authCode: authCode, codeVerifier: verifier, authBase: authBase)
    }

    func signIn(email: String, password: String) async throws -> LicenseAuthSession {
        guard let authBase = configuration.authBaseURL,
              !configuration.publishableKey.isEmpty else {
            throw LicenseAuthError.notConfigured
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else {
            throw LicenseAuthError.rejected("Enter an email and password.")
        }

        var tokenURL = authBase.appending(path: "token")
        var tokenComponents = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)
        tokenComponents?.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        tokenURL = tokenComponents?.url ?? tokenURL
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": trimmedEmail,
            "password": password
        ])

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (payload?["error_description"] as? String)
                ?? (payload?["msg"] as? String)
                ?? (payload?["error"] as? String)
                ?? "Email sign-in failed."
            throw LicenseAuthError.rejected(message)
        }
        return try Self.decodeSession(from: data, fallbackProvider: "email")
    }

    func refresh(_ session: LicenseAuthSession) async throws -> LicenseAuthSession {
        guard let authBase = configuration.authBaseURL,
              !configuration.publishableKey.isEmpty else {
            throw LicenseAuthError.notConfigured
        }

        var tokenURL = authBase.appending(path: "token")
        var tokenComponents = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)
        tokenComponents?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        tokenURL = tokenComponents?.url ?? tokenURL
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "refresh_token": session.refreshToken
        ])

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LicenseAuthError.rejected("Could not refresh the sign-in session.")
        }
        return try Self.decodeSession(from: data, fallbackProvider: session.provider)
    }

    func signOut(_ session: LicenseAuthSession) async {
        guard let authBase = configuration.authBaseURL,
              !configuration.publishableKey.isEmpty else {
            return
        }
        var request = URLRequest(url: authBase.appending(path: "logout"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        _ = try? await transport.data(for: request)
    }

    private func exchange(
        authCode: String,
        codeVerifier: String,
        authBase: URL
    ) async throws -> LicenseAuthSession {
        var tokenURL = authBase.appending(path: "token")
        var tokenComponents = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)
        tokenComponents?.queryItems = [URLQueryItem(name: "grant_type", value: "pkce")]
        tokenURL = tokenComponents?.url ?? tokenURL
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "auth_code": authCode,
            "code_verifier": codeVerifier
        ])

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw LicenseAuthError.rejected("Sign-in did not complete.")
        }
        return try Self.decodeSession(from: data, fallbackProvider: nil)
    }

    private static func decodeSession(from data: Data, fallbackProvider: String?) throws -> LicenseAuthSession {
        let payload = try JSONSerialization.jsonObject(with: data)
        guard let json = payload as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              !accessToken.isEmpty,
              !refreshToken.isEmpty else {
            throw LicenseAuthError.invalidCallback
        }

        let expiresIn = (json["expires_in"] as? Int) ?? 3600
        let user = json["user"] as? [String: Any]
        let userIDString = user?["id"] as? String
        guard let userIDString, let userID = UUID(uuidString: userIDString) else {
            throw LicenseAuthError.invalidCallback
        }
        let identities = user?["identities"] as? [[String: Any]]
        let provider = (identities?.first?["provider"] as? String) ?? fallbackProvider
        return LicenseAuthSession(
            userID: userID,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            email: user?["email"] as? String,
            provider: provider
        )
    }

    private static func authCode(from callbackURL: URL) throws -> String {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            if error == "access_denied" {
                throw LicenseAuthError.cancelled
            }
            throw LicenseAuthError.rejected(error)
        }
        if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return code
        }
        throw LicenseAuthError.invalidCallback
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func makeCodeChallenge(_ verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

protocol LicenseOAuthBrowsing: Sendable {
    func open(_ url: URL, callbackScheme: String) async throws -> URL
}

struct SystemLicenseOAuthBrowser: LicenseOAuthBrowsing {
    func open(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackScheme
                ) { callbackURL, error in
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                        return
                    }
                    if let error = error as? ASWebAuthenticationSessionError,
                       error.code == .canceledLogin {
                        continuation.resume(throwing: LicenseAuthError.cancelled)
                        return
                    }
                    continuation.resume(throwing: error ?? LicenseAuthError.invalidCallback)
                }
                session.presentationContextProvider = LicenseOAuthPresentationAnchor.shared
                session.prefersEphemeralWebBrowserSession = false
                if !session.start() {
                    continuation.resume(throwing: LicenseAuthError.invalidCallback)
                }
            }
        }
    }
}

private final class LicenseOAuthPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = LicenseOAuthPresentationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.windows.first(where: \.isVisible)
            ?? NSApp.keyWindow
            ?? NSApp.windows.first
            ?? ASPresentationAnchor()
    }
}
