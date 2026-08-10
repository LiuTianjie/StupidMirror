import Foundation

struct XcodeSigningTeam: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

enum XcodeSigningTeamDetector {
    static func detect() async -> [XcodeSigningTeam] {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-identity", "-v", "-p", "codesigning"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard data.count <= 256 * 1024,
                      let text = String(data: data, encoding: .utf8) else { return [] }
                return parseIdentities(text)
            } catch {
                return []
            }
        }.value
    }

    static func parseIdentities(_ output: String) -> [XcodeSigningTeam] {
        let pattern = #"\"((?:Apple Development|iPhone Developer):[^\"]*?)\s*\(([A-Z0-9]{10})\)\""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var teamsByID: [String: XcodeSigningTeam] = [:]

        for match in expression.matches(in: output, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: output),
                  let idRange = Range(match.range(at: 2), in: output) else { continue }
            let id = String(output[idRange])
            let name = String(output[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            teamsByID[id] = XcodeSigningTeam(id: id, name: name)
        }

        return teamsByID.values.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
