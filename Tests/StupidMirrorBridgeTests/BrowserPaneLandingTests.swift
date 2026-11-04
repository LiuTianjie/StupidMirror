import Foundation
import StupidMirrorBridgeCore
import XCTest

final class BrowserPaneLandingTests: XCTestCase {
    private func request(_ line: String, host: String? = "localhost:17374") -> Data {
        var text = line + "\r\n"
        if let host { text += "Host: \(host)\r\n" }
        return Data((text + "Accept: */*\r\n\r\n").utf8)
    }

    func testParsesArguments() {
        XCTAssertEqual(BrowserPaneLanding.port(fromArguments: ["--browser-pane"]), 17_374)
        XCTAssertEqual(BrowserPaneLanding.port(fromArguments: ["--browser-pane", "--port", "18000"]), 18_000)
        XCTAssertEqual(BrowserPaneLanding.port(fromArguments: ["--browser-pane", "-p", "18001"]), 18_001)
        XCTAssertNil(BrowserPaneLanding.port(fromArguments: ["--browser-pane", "--port", "80"]))
        XCTAssertNil(BrowserPaneLanding.port(fromArguments: ["--browser-pane", "--port"]))
        XCTAssertNil(BrowserPaneLanding.port(fromArguments: ["--app", "/Applications/StupidMirror.app"]))
    }

    func testServesOnlyTheStaticPageToLoopbackNames() {
        let page = BrowserPaneLanding.response(forRequest: request("GET / HTTP/1.1"), port: 17_374)
        XCTAssertEqual(page.statusCode, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("StupidMirror"))
        XCTAssertTrue(page.headers.contains { $0.0 == "Content-Security-Policy" && $0.1.contains("default-src 'none'") })
        let serialized = String(decoding: page.serialized, as: UTF8.self)
        XCTAssertTrue(serialized.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(serialized.contains("Content-Length: \(page.body.count)\r\n"))

        XCTAssertEqual(BrowserPaneLanding.response(forRequest: request("GET /?x=1 HTTP/1.1", host: "127.0.0.1:17374"), port: 17_374).statusCode, 200)
        XCTAssertTrue(BrowserPaneLanding.response(forRequest: request("HEAD / HTTP/1.1"), port: 17_374).body.isEmpty)
        XCTAssertEqual(BrowserPaneLanding.response(forRequest: request("GET /viewer HTTP/1.1"), port: 17_374).statusCode, 404)
        XCTAssertEqual(BrowserPaneLanding.response(forRequest: request("POST / HTTP/1.1"), port: 17_374).statusCode, 405)
        XCTAssertEqual(BrowserPaneLanding.response(forRequest: request("GET / HTTP/1.1", host: "evil.example:17374"), port: 17_374).statusCode, 403)
        XCTAssertEqual(BrowserPaneLanding.response(forRequest: request("GET / HTTP/1.1", host: nil), port: 17_374).statusCode, 403)
        XCTAssertEqual(BrowserPaneLanding.response(forRequest: request("GET / HTTP/1.1", host: "localhost:9999"), port: 17_374).statusCode, 403)
        XCTAssertEqual(BrowserPaneLanding.response(forRequest: Data("garbage\r\n\r\n".utf8), port: 17_374).statusCode, 400)
    }
}
