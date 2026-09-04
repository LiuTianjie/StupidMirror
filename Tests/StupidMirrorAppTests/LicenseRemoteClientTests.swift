@testable import StupidMirrorApp
import Foundation
import XCTest

final class LicenseRemoteClientTests: XCTestCase {
    func testActivateUsesSingleEndpointPublishableHeaderAndExpectedBody() async throws {
        let transport = RecordingLicenseTransport(
            statusCode: 200,
            body: #"{"ok":true,"valid":true,"receipt":"8dc53b7d-1a3c-4fc8-a201-f70c3d88b2e1","server_time":"2033-05-18T03:33:20Z"}"#
        )
        let endpoint = try XCTUnwrap(URL(string: "https://example.supabase.co/functions/v1/stupidmirror-license"))
        let client = SupabaseLicenseRemoteClient(
            configuration: LicenseRemoteConfiguration(
                endpoint: endpoint,
                publishableKey: "sb_publishable_test",
                appVersion: "0.1.6"
            ),
            transport: transport
        )
        let installationID = UUID(uuidString: "8DC53B7D-1A3C-4FC8-A201-F70C3D88B2E1")!

        let result = try await client.activate(code: "SM1ABC", installationID: installationID)

        XCTAssertEqual(result.receipt, "8dc53b7d-1a3c-4fc8-a201-f70c3d88b2e1")
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["action"], "activate")
        XCTAssertEqual(json["installation_id"], installationID.uuidString.lowercased())
        XCTAssertEqual(json["code"], "SM1ABC")
        XCTAssertEqual(json["app_version"], "0.1.6")
    }

    func testValidateSendsReceiptAndKeepsRefreshedReceiptOptional() async throws {
        let transport = RecordingLicenseTransport(
            statusCode: 200,
            body: #"{"ok":true,"valid":true,"receipt":"8dc53b7d-1a3c-4fc8-a201-f70c3d88b2e1","server_time":"2033-05-18T03:33:20.000Z"}"#
        )
        let client = SupabaseLicenseRemoteClient(
            configuration: configuredEndpoint,
            transport: transport
        )

        let validation = try await client.validate(receipt: "cached", installationID: UUID())

        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.refreshedReceipt, "8dc53b7d-1a3c-4fc8-a201-f70c3d88b2e1")
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "validate")
        XCTAssertEqual(json["receipt"] as? String, "cached")
        XCTAssertEqual(json["client_protocol"] as? Int, 2)
    }

    func testRedeemSendsBearerTokenAndDoesNotAcceptMissingLogin() async throws {
        let transport = RecordingLicenseTransport(
            statusCode: 200,
            body: #"{"ok":true,"active":true,"receipt":"8dc53b7d-1a3c-4fc8-a201-f70c3d88b2e1","principal":"account","server_time":"2033-05-18T03:33:20Z"}"#
        )
        let client = SupabaseLicenseRemoteClient(
            configuration: configuredEndpoint,
            transport: transport
        )
        _ = try await client.redeem(
            code: "SM-1ABC-DEFG-HIJK-LMNO-PQRS-TUVW",
            installationID: UUID(),
            accessToken: "user-jwt"
        )
        let captured = await transport.lastRequest()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.supabase.co/rest/v1/rpc/stupidmirror_redeem_for_user"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNotNil(json["p_code_hash"] as? String)
        XCTAssertEqual((json["p_code_hash"] as? String)?.count, 64)
        XCTAssertNil(json["action"])
    }

    func testRevokedResponseMapsStableServerCode() async {
        let transport = RecordingLicenseTransport(
            statusCode: 403,
            body: #"{"ok":false,"code":"license_revoked","message":"Revoked"}"#
        )
        let client = SupabaseLicenseRemoteClient(
            configuration: configuredEndpoint,
            transport: transport
        )

        do {
            _ = try await client.validate(receipt: "old", installationID: UUID())
            XCTFail("Expected a revoked response")
        } catch let error as LicenseServiceError {
            XCTAssertEqual(error, .rejected(code: "license_revoked", message: "Revoked"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidReceiptResponseMapsStableServerCode() async {
        let transport = RecordingLicenseTransport(
            statusCode: 403,
            body: #"{"ok":false,"code":"invalid_receipt","message":"Invalid receipt"}"#
        )
        let client = SupabaseLicenseRemoteClient(
            configuration: configuredEndpoint,
            transport: transport
        )

        do {
            _ = try await client.validate(receipt: "not-a-uuid", installationID: UUID())
            XCTFail("Expected an invalid receipt response")
        } catch let error as LicenseServiceError {
            XCTAssertEqual(error, .rejected(code: "invalid_receipt", message: "Invalid receipt"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingConfigurationFailsWithoutNetworkRequest() async {
        let transport = RecordingLicenseTransport(statusCode: 500, body: "{}")
        let client = SupabaseLicenseRemoteClient(
            configuration: LicenseRemoteConfiguration(endpoint: nil, publishableKey: "", appVersion: "dev"),
            transport: transport
        )

        do {
            _ = try await client.activate(code: "SM1ABC", installationID: UUID())
            XCTFail("Expected not configured")
        } catch let error as LicenseServiceError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let capturedRequest = await transport.lastRequest()
        XCTAssertNil(capturedRequest)
    }

    private var configuredEndpoint: LicenseRemoteConfiguration {
        LicenseRemoteConfiguration(
            endpoint: URL(string: "https://example.supabase.co/functions/v1/stupidmirror-license"),
            publishableKey: "sb_publishable_test",
            appVersion: "0.1.6"
        )
    }
}

private actor RecordingLicenseTransport: LicenseHTTPTransport {
    private let statusCode: Int
    private let body: Data
    private var request: URLRequest?

    init(statusCode: Int, body: String) {
        self.statusCode = statusCode
        self.body = Data(body.utf8)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }

    func lastRequest() -> URLRequest? {
        request
    }
}
