import Darwin
import Foundation

/// A per-launch local connection, shared by the app and its signed MCP helper.
/// Never include this file in plugin packages, diagnostics, or tool results.
public struct MCPConnectionRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let endpoint: URL
    public let bearerToken: String
    public let instanceID: UUID
    public let processID: Int32

    public init(endpoint: URL, bearerToken: String, instanceID: UUID = UUID(), processID: Int32 = getpid()) {
        self.schemaVersion = 1
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.instanceID = instanceID
        self.processID = processID
    }

    public func validate() throws {
        guard schemaVersion == 1,
              endpoint.scheme == "http", endpoint.host == "127.0.0.1",
              let port = endpoint.port, (1_024...65_535).contains(port),
              endpoint.path == "/mcp", endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil,
              !bearerToken.isEmpty, !bearerToken.contains(where: { $0.isWhitespace }),
              processID > 0 else {
            throw MCPConnectionFileError.invalidRecord
        }
    }

    public var processIsRunning: Bool { kill(processID, 0) == 0 }
}

public enum MCPConnectionFileError: LocalizedError {
    case invalidRecord
    case unsafePermissions

    public var errorDescription: String? {
        switch self {
        case .invalidRecord: "Invalid StupidMirror local MCP connection. Open StupidMirror Settings → MCP."
        case .unsafePermissions: "StupidMirror MCP connection must be a private file owned by the current user."
        }
    }
}

public struct MCPConnectionFile: Sendable {
    public let url: URL

    public init(url: URL = defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/StupidMirror/MCP/connection.json")
    }

    public func read() throws -> MCPConnectionRecord {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0 else {
            throw MCPConnectionFileError.unsafePermissions
        }
        let record = try JSONDecoder().decode(MCPConnectionRecord.self, from: Data(contentsOf: url))
        try record.validate()
        return record
    }

    public func write(_ record: MCPConnectionRecord) throws {
        try record.validate()
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw MCPConnectionFileError.unsafePermissions
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // The temporary file is inside a 0700 directory throughout the atomic write.
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func remove(ifOwnedBy instanceID: UUID) {
        guard let record = try? read(), record.instanceID == instanceID else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
