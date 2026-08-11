import Foundation
import Security

struct XcodeSigningTeam: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isFreeProvisioningTeam: Bool?

    init(id: String, name: String, isFreeProvisioningTeam: Bool? = nil) {
        self.id = id
        self.name = name
        self.isFreeProvisioningTeam = isFreeProvisioningTeam
    }
}

struct DevelopmentSigningIdentity: Hashable, Sendable {
    let commonName: String
    let organizationalUnit: String
}

enum XcodeSigningTeamDetector {
    static func detect() async -> [XcodeSigningTeam] {
        await Task.detached(priority: .userInitiated) {
            teams(
                from: developmentSigningIdentities(),
                configuredTeams: configuredSigningTeams()
            )
        }.value
    }

    static func teams(
        from identities: [DevelopmentSigningIdentity],
        configuredTeams: [XcodeSigningTeam] = []
    ) -> [XcodeSigningTeam] {
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

        // Xcode's account preferences are the source of truth for teams the user
        // can provision with. They also cover a freshly signed-in account before
        // Xcode has created a local development certificate. Prefer their clearer
        // team names over certificate common names when both sources contain a team.
        for team in configuredTeams {
            teamsByID[team.id] = team
        }

        return teamsByID.values.sorted {
            if $0.isFreeProvisioningTeam != $1.isFreeProvisioningTeam {
                // Prefer paid organization teams, then certificate-only teams,
                // and finally personal/free provisioning teams.
                let rank: (Bool?) -> Int = { value in
                    switch value {
                    case false: 0
                    case nil: 1
                    case true: 2
                    }
                }
                return rank($0.isFreeProvisioningTeam) < rank($1.isFreeProvisioningTeam)
            }
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
        // Wireless setup promises automatic account selection and has no account
        // picker. A paid team is normally the least restrictive choice; if the
        // user only has personal or certificate-derived teams, use the first
        // deterministic result instead of incorrectly reporting "not signed in".
        return teams.first(where: { $0.isFreeProvisioningTeam == false })?.id
            ?? teams.first?.id
    }

    static func configuredTeams(from provisioningValue: Any?) -> [XcodeSigningTeam] {
        guard let accounts = provisioningValue as? [String: Any] else { return [] }
        var teamsByID: [String: XcodeSigningTeam] = [:]

        for value in accounts.values {
            guard let teams = value as? [[String: Any]] else { continue }
            for team in teams {
                guard let rawID = team["teamID"] as? String else { continue }
                let teamID = rawID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard teamID.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
                    continue
                }
                let teamName = (team["teamName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                teamsByID[teamID] = XcodeSigningTeam(
                    id: teamID,
                    name: teamName?.isEmpty == false ? teamName! : teamID,
                    isFreeProvisioningTeam: team["isFreeProvisioningTeam"] as? Bool
                )
            }
        }

        return Array(teamsByID.values)
    }

    private static func configuredSigningTeams() -> [XcodeSigningTeam] {
        let preferences = UserDefaults.standard.persistentDomain(forName: "com.apple.dt.Xcode")
        return configuredTeams(from: preferences?["IDEProvisioningTeamByIdentifier"])
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
