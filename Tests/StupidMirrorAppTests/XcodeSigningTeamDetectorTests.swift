@testable import StupidMirrorApp
import XCTest

final class XcodeSigningTeamDetectorTests: XCTestCase {
    func testParsesDevelopmentTeamsAndDeduplicatesTeamID() {
        let identities = [
            DevelopmentSigningIdentity(commonName: "Apple Development: Person One (CERTID0001)", organizationalUnit: "ABCDEFGHIJ"),
            DevelopmentSigningIdentity(commonName: "Apple Development: Renewed Certificate (CERTID0002)", organizationalUnit: "ABCDEFGHIJ"),
            DevelopmentSigningIdentity(commonName: "Developer ID Application: Example Corp", organizationalUnit: "ZZZZZZZZZZ"),
            DevelopmentSigningIdentity(commonName: "Apple Development: Person Two (CERTID0003)", organizationalUnit: "KLMNOPQRST")
        ]

        let teams = XcodeSigningTeamDetector.teams(from: identities)

        XCTAssertEqual(teams.map(\.id), ["KLMNOPQRST", "ABCDEFGHIJ"])
        XCTAssertEqual(teams.count, 2)
    }

    func testIgnoresDistributionAndMalformedIdentities() {
        let identities = [
            DevelopmentSigningIdentity(commonName: "Apple Distribution: Example Corp", organizationalUnit: "ABCDEFGHIJ"),
            DevelopmentSigningIdentity(commonName: "Apple Development: Missing Team", organizationalUnit: ""),
            DevelopmentSigningIdentity(commonName: "Apple Development: Wrong Length", organizationalUnit: "ABCDE")
        ]

        XCTAssertTrue(XcodeSigningTeamDetector.teams(from: identities).isEmpty)
    }

    func testFindsOnlyValidDevelopmentIdentityNames() {
        let output = #"""
          1) AAA "Apple Development: Person One (CERTID0001)"
          2) BBB "Apple Distribution: Example Corp (ABCDEFGHIJ)"
          3) CCC "iPhone Developer: Legacy Person (CERTID0002)"
          4) DDD "Apple Development: Person One (CERTID0001)"
        """#

        XCTAssertEqual(
            XcodeSigningTeamDetector.validDevelopmentIdentityNames(in: output),
            ["Apple Development: Person One (CERTID0001)", "iPhone Developer: Legacy Person (CERTID0002)"]
        )
    }

    func testExtractsTeamIDFromRFC2253CertificateSubject() {
        XCTAssertEqual(
            XcodeSigningTeamDetector.certificateTeamID(
                inRFC2253Subject: "subject=C=CN,O=Example Corp\\, Ltd.,OU=L95PYLFT86,CN=Redacted"
            ),
            "L95PYLFT86"
        )
        XCTAssertNil(
            XcodeSigningTeamDetector.certificateTeamID(
                inRFC2253Subject: "subject=C=CN,O=Example Corp,CN=Redacted"
            )
        )
    }

    func testPrefersAValidSavedTeamThenTheSignedApplicationTeam() {
        let teams = [
            XcodeSigningTeam(id: "ABCDEFGHIJ", name: "Apple Development: One"),
            XcodeSigningTeam(id: "KLMNOPQRST", name: "Apple Development: Two")
        ]

        XCTAssertEqual(
            XcodeSigningTeamDetector.preferredTeamID(
                savedID: "KLMNOPQRST",
                applicationTeamID: "ABCDEFGHIJ",
                teams: teams
            ),
            "KLMNOPQRST"
        )
        XCTAssertEqual(
            XcodeSigningTeamDetector.preferredTeamID(
                savedID: "CERTID0001",
                applicationTeamID: "ABCDEFGHIJ",
                teams: teams
            ),
            "ABCDEFGHIJ"
        )
    }
}
