@testable import StupidMirrorApp
import Foundation
import XCTest

final class LicenseRemoteClientTests: XCTestCase {
    private let activeBody = """
    {"ok":true,"product":"stupidmirror","required_tier":"yearly","active":true,
     "valid_until":"2027-11-05T10:30:26.938123+00:00","tier":"yearly",
     "member_until":"2027-11-05T10:30:26.938123+00:00",
     "yearly_until":"2027-11-05T10:30:26.938123+00:00",
     "server_time":"2026-11-05T10:30:26.938123+00:00"}
    """

    func testWebsiteRequestSendsBearerTokenAndProduct() async throws {
        let transport = RecordingLicenseTransport(responses: [.status(200, activeBody)])
        let client = MembershipEntitlementClient(configuration: configuration, transport: transport)

        let entitlement = try await client.entitlement(accessToken: "user-jwt")

        let request = try await XCTUnwrapAsync(await transport.requests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://itool.tech/api/membership/entitlement?product=stupidmirror")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt")
        XCTAssertNil(request.value(forHTTPHeaderField: "apikey"), "The website route needs no Supabase key")
        XCTAssertTrue(entitlement.active)
        XCTAssertEqual(entitlement.tier, .yearly)
        XCTAssertEqual(entitlement.serverTime, MembershipEntitlementClient.parseDate("2026-11-05T10:30:26.938Z"))
        XCTAssertEqual(entitlement.validUntil, MembershipEntitlementClient.parseDate("2027-11-05T10:30:26.938Z"))
    }

    func testInactiveMonthlyAnswerIsReturnedNotThrown() async throws {
        let body = """
        {"ok":true,"product":"stupidmirror","required_tier":"yearly","active":false,"valid_until":null,
         "tier":"monthly","member_until":"2026-12-05T00:00:00+00:00","yearly_until":null,
         "server_time":"2026-11-05T10:30:26+00:00"}
        """
        let transport = RecordingLicenseTransport(responses: [.status(200, body)])
        let client = MembershipEntitlementClient(configuration: configuration, transport: transport)

        let entitlement = try await client.entitlement(accessToken: "user-jwt")

        XCTAssertFalse(entitlement.active)
        XCTAssertEqual(entitlement.tier, .monthly)
        XCTAssertNil(entitlement.validUntil)
        XCTAssertNotNil(entitlement.memberUntil)
    }

    func testUnauthorizedMapsToLoginRequiredWithoutFallback() async {
        let transport = RecordingLicenseTransport(responses: [.status(401, #"{"ok":false,"code":"login_required"}"#)])
        let client = MembershipEntitlementClient(configuration: configuration, transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.entitlement(accessToken: "old")) { error in
            XCTAssertEqual(error as? MembershipCheckError, .loginRequired)
        }
        let count = await transport.requests().count
        XCTAssertEqual(count, 1)
    }

    func testServiceUnavailableFallsBackToSupabaseRPC() async throws {
        let transport = RecordingLicenseTransport(responses: [
            .status(503, #"{"ok":false,"code":"temporarily_unavailable"}"#),
            .status(200, activeBody)
        ])
        let client = MembershipEntitlementClient(configuration: configuration, transport: transport)

        let entitlement = try await client.entitlement(accessToken: "user-jwt")

        XCTAssertTrue(entitlement.active)
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        let rpc = requests[1]
        XCTAssertEqual(rpc.httpMethod, "POST")
        XCTAssertEqual(rpc.url?.absoluteString, "https://example.supabase.co/rest/v1/rpc/itool_entitlement")
        XCTAssertEqual(rpc.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(rpc.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(rpc.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["p_product": "stupidmirror"])
    }

    func testNetworkFailureOnBothPathsIsTemporarilyUnavailable() async {
        let transport = RecordingLicenseTransport(responses: [.network, .network])
        let client = MembershipEntitlementClient(configuration: configuration, transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.entitlement(accessToken: "user-jwt")) { error in
            XCTAssertEqual(error as? MembershipCheckError, .temporarilyUnavailable)
        }
    }

    func testMalformedAnswerIsTemporarilyUnavailable() async {
        let transport = RecordingLicenseTransport(responses: [
            .status(200, #"{"ok":true,"active":true}"#),
            .status(200, #"{"ok":true,"product":"transeen","active":true,"server_time":"2026-11-05T10:30:26+00:00"}"#)
        ])
        let client = MembershipEntitlementClient(configuration: configuration, transport: transport)

        await XCTAssertThrowsErrorAsync(try await client.entitlement(accessToken: "user-jwt")) { error in
            XCTAssertEqual(error as? MembershipCheckError, .temporarilyUnavailable)
        }
    }

    func testMissingConfigurationFailsWithoutNetworkRequest() async {
        let transport = RecordingLicenseTransport(responses: [])
        let client = MembershipEntitlementClient(
            configuration: LicenseRemoteConfiguration(
                supabaseURL: nil,
                entitlementURL: URL(string: "http://itool.tech/api/membership/entitlement"),
                publishableKey: "",
                appVersion: "0.8.0"
            ),
            transport: transport
        )

        await XCTAssertThrowsErrorAsync(try await client.entitlement(accessToken: "user-jwt")) { error in
            XCTAssertEqual(error as? MembershipCheckError, .notConfigured)
        }
        let count = await transport.requests().count
        XCTAssertEqual(count, 0)
    }

    func testConfigurationDerivesAuthAndRPCFromTheProjectURL() {
        XCTAssertEqual(configuration.authBaseURL?.absoluteString, "https://example.supabase.co/auth/v1")
        XCTAssertEqual(configuration.entitlementRPCURL?.absoluteString, "https://example.supabase.co/rest/v1/rpc/itool_entitlement")
    }

    func testBuyPageIsTheITooMembershipPage() {
        XCTAssertEqual(LicensePurchaseURLs.buyURL.absoluteString, "https://itool.tech/pro?from=stupidmirror")
        XCTAssertEqual(LicensePurchaseURLs.buyURL(chinese: true).absoluteString, "https://itool.tech/zh/pro?from=stupidmirror")
        XCTAssertEqual(LicensePurchaseURLs.buyURL(chinese: false).absoluteString, "https://itool.tech/en/pro?from=stupidmirror")
    }

    func testMembershipErrorsDistinguishSignInFromMissingYearlyTier() {
        XCTAssertEqual(DeviceAutomationError.membershipRequired(.signIn).code, "sign_in_required")
        XCTAssertEqual(DeviceAutomationError.membershipRequired(.yearly).code, "membership_required")
        XCTAssertEqual(DeviceAutomationError.membershipRequired(.verification).code, "membership_required")
        for requirement in [MembershipRequirement.signIn, .yearly, .verification] {
            let message = DeviceAutomationError.membershipRequired(requirement).localizedDescription
            XCTAssertTrue(message.contains("One device at a time stays free"), message)
        }
        XCTAssertTrue(DeviceAutomationError.membershipRequired(.yearly).localizedDescription
            .contains("https://itool.tech/pro?from=stupidmirror"))
    }

    private var configuration: LicenseRemoteConfiguration {
        LicenseRemoteConfiguration(
            supabaseURL: URL(string: "https://example.supabase.co"),
            entitlementURL: URL(string: "https://itool.tech/api/membership/entitlement"),
            publishableKey: "sb_publishable_test",
            appVersion: "0.8.0"
        )
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}

private actor RecordingLicenseTransport: LicenseHTTPTransport {
    enum Response: Sendable {
        case status(Int, String)
        case network
    }

    private var responses: [Response]
    private var recorded: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        switch responses.removeFirst() {
        case .network:
            throw URLError(.notConnectedToInternet)
        case let .status(code, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (Data(body.utf8), response)
        }
    }

    func requests() -> [URLRequest] {
        recorded
    }
}
