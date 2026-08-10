import Foundation
import Security

struct XcodeSigningTeam: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct DevelopmentSigningIdentity: Hashable, Sendable {
    let commonName: String
    let organizationalUnit: String
}

enum XcodeSigningTeamDetector {
    static func detect() async -> [XcodeSigningTeam] {
        await Task.detached(priority: .userInitiated) {
            teams(from: developmentSigningIdentities())
        }.value
    }

    static func teams(from identities: [DevelopmentSigningIdentity]) -> [XcodeSigningTeam] {
        var teamsByID: [String: XcodeSigningTeam] = [:]
        for identity in identities {
            guard identity.commonName.hasPrefix("Apple Development:")
                    || identity.commonName.hasPrefix("iPhone Developer:") else { continue }
            let teamID = identity.organizationalUnit
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else { continue }
            let name = identity.commonName.trimmingCharacters(in: .whitespacesAndNewlines)
            teamsByID[teamID] = XcodeSigningTeam(id: teamID, name: name)
        }

        return teamsByID.values.sorted {
            if $0.name == $1.name { return $0.id < $1.id }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func preferredTeamID(
        savedID: String,
        applicationTeamID: String?,
        teams: [XcodeSigningTeam]
    ) -> String? {
        let saved = savedID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if teams.contains(where: { $0.id == saved }) {
            return saved
        }
        if let applicationTeamID {
            let applicationTeam = applicationTeamID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if teams.contains(where: { $0.id == applicationTeam }) {
                return applicationTeam
            }
        }
        return teams.count == 1 ? teams[0].id : nil
    }

    static func currentApplicationTeamID() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }

    private static func developmentSigningIdentities() -> [DevelopmentSigningIdentity] {
        guard let identityOutput = runSecurity(["find-identity", "-v", "-p", "codesigning"]),
              let identityText = String(data: identityOutput, encoding: .utf8) else { return [] }
        return validDevelopmentIdentityNames(in: identityText).compactMap { identityName in
            guard let pemData = runSecurity(["find-certificate", "-c", identityName, "-p"]),
                  let subjectData = runProcess(
                    executable: "/usr/bin/openssl",
                    arguments: ["x509", "-noout", "-subject", "-nameopt", "RFC2253"],
                    standardInput: pemData
                  ),
                  let subject = String(data: subjectData, encoding: .utf8),
                  let organizationalUnit = certificateTeamID(inRFC2253Subject: subject) else {
                return nil
            }
            return DevelopmentSigningIdentity(
                commonName: identityName,
                organizationalUnit: organizationalUnit
            )
        }
    }

    static func validDevelopmentIdentityNames(in output: String) -> [String] {
        let pattern = #"\"((?:Apple Development|iPhone Developer):[^\"]+)\""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        var seen = Set<String>()
        return expression.matches(in: output, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: output) else { return nil }
            let name = String(output[range])
            return seen.insert(name).inserted ? name : nil
        }
    }

    private static func runSecurity(_ arguments: [String]) -> Data? {
        runProcess(executable: "/usr/bin/security", arguments: arguments)
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        standardInput: Data? = nil
    ) -> Data? {
        let process = Process()
        let output = Pipe()
        let input = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if let input { process.standardInput = input }
        do {
            try process.run()
            if let standardInput, let input {
                input.fileHandleForWriting.write(standardInput)
                try? input.fileHandleForWriting.close()
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return data.count <= 512 * 1024 ? data : nil
        } catch {
            return nil
        }
    }

    static func certificateTeamID(inRFC2253Subject subject: String) -> String? {
        let pattern = #"(?:^|,)OU=([A-Z0-9]{10})(?:,|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(subject.startIndex..<subject.endIndex, in: subject)
        guard let match = expression.firstMatch(in: subject, range: range),
              let teamRange = Range(match.range(at: 1), in: subject) else { return nil }
        return String(subject[teamRange])
    }
}
