@testable import StupidMirrorApp
import Foundation
import XCTest

/// GitHub / Google sign-in opens a tab in the person's browser and waits on a loopback listener
/// (LoopbackOAuth.swift). A URLSession request stands in for the browser; nothing opens one.
final class LoopbackOAuthTests: XCTestCase {
    func testAuthorizeURLUsesLoopbackRedirectAndPKCE() throws {
        let url = SupabaseLicenseAuthClient.authorizeURL(
            authBase: URL(string: "https://example.supabase.co/auth/v1")!,
            provider: .github,
            redirect: URL(string: "http://127.0.0.1:5555/linkshell/callback")!,
            challenge: "abc",
            publishableKey: "sb_publishable_x"
        )
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }
        XCTAssertEqual(url.path, "/auth/v1/authorize")
        XCTAssertEqual(value("provider"), "github")
        XCTAssertEqual(value("redirect_to"), "http://127.0.0.1:5555/linkshell/callback")
        XCTAssertEqual(value("code_challenge"), "abc")
        XCTAssertEqual(value("code_challenge_method"), "s256")
        XCTAssertEqual(value("scopes"), "read:user user:email")
    }

    func testCallbackWithCodeReturnsIt() async throws {
        let (url, page) = try await visit("?code=one-time")
        XCTAssertEqual(try SupabaseLicenseAuthClient.authCode(from: url), "one-time")
        XCTAssertTrue(page.contains("已完成授权"))
    }

    func testDenialIsCancel() async throws {
        let (url, _) = try await visit("?error=access_denied&error_description=nope")
        XCTAssertThrowsError(try SupabaseLicenseAuthClient.authCode(from: url)) {
            XCTAssertEqual($0 as? LicenseAuthError, .cancelled)
        }
    }

    func testProviderErrorKeepsItsMessage() async throws {
        let (url, _) = try await visit("?error_code=bad_oauth_state&error_description=State%20expired")
        XCTAssertThrowsError(try SupabaseLicenseAuthClient.authCode(from: url)) {
            XCTAssertEqual($0 as? LicenseAuthError, .rejected("State expired"))
        }
    }

    func testGivesUpWhenNothingComesBack() async {
        do {
            _ = try await LoopbackOAuth.run(productName: "StupidMirror", timeout: 0.3, open: { _ in }) { $0 }
            XCTFail("must time out")
        } catch {
            XCTAssertEqual(error as? LoopbackOAuthError, .timedOut)
        }
    }

    func testCancellingEndsTheWait() async throws {
        let waiting = Task { try await LoopbackOAuth.run(productName: "StupidMirror", timeout: 10, open: { _ in }) { $0 } }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("must cancel")
        } catch {
            XCTAssertEqual(error as? LoopbackOAuthError, .cancelled)
        }
    }

    /// Runs one sign-in and plays the browser: the authorize URL's redirect, plus `suffix`.
    private func visit(_ suffix: String) async throws -> (URL, String) {
        let opened = OpenedURL()
        let flow = Task {
            try await LoopbackOAuth.run(productName: "StupidMirror", timeout: 10, open: { opened.set($0) }) { redirect in
                URL(string: "https://example.test/authorize?redirect_to=\(redirect.absoluteString)")!
            }
        }
        let authorize = try await opened.wait()
        let redirect = try XCTUnwrap(URLComponents(url: authorize, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "redirect_to" }?.value)
        XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(redirect.hasSuffix("/linkshell/callback"))
        let other = URL(string: redirect.replacingOccurrences(of: "/linkshell/callback", with: "/other"))!
        let (_, notFound) = try await URLSession.shared.data(from: other)
        XCTAssertEqual((notFound as? HTTPURLResponse)?.statusCode, 404)
        let (body, response) = try await URLSession.shared.data(from: URL(string: redirect + suffix)!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return (try await flow.value, String(decoding: body, as: UTF8.self))
    }
}

private final class OpenedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func set(_ url: URL) { lock.withLock { self.url = url } }

    func wait() async throws -> URL {
        for _ in 0..<200 {
            if let url = lock.withLock({ self.url }) { return url }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URLError(.timedOut)
    }
}
