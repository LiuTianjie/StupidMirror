import Foundation
import StupidMirrorConnection
import XCTest

final class MCPConnectionFileTests: XCTestCase {
    func testPrivateAtomicRecordAndOwnerScopedCleanup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = MCPConnectionFile(url: directory.appendingPathComponent("connection.json"))
        let first = MCPConnectionRecord(endpoint: URL(string: "http://127.0.0.1:17373/mcp")!, bearerToken: "first")
        try file.write(first)
        XCTAssertEqual(try file.read(), first)
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryMode?.intValue, 0o700)

        let second = MCPConnectionRecord(endpoint: first.endpoint, bearerToken: "rotated")
        try file.write(second)
        file.remove(ifOwnedBy: first.instanceID)
        XCTAssertEqual(try file.read(), second, "An old app instance must not remove a newer connection")
        file.remove(ifOwnedBy: second.instanceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testRejectsRemoteEndpointsAndExposedCredentials() throws {
        for endpoint in ["https://example.com/mcp", "http://localhost:17373/mcp", "http://127.0.0.1:17373/mcp?token=x", "http://127.0.0.1:17373/other"] {
            XCTAssertThrowsError(try MCPConnectionRecord(endpoint: URL(string: endpoint)!, bearerToken: "private").validate())
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = MCPConnectionFile(url: directory.appendingPathComponent("connection.json"))
        try file.write(MCPConnectionRecord(endpoint: URL(string: "http://127.0.0.1:17373/mcp")!, bearerToken: "private"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path)
        XCTAssertThrowsError(try file.read())
    }
}
