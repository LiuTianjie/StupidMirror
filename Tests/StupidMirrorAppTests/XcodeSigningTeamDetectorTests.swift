@testable import StupidMirrorApp
import XCTest

final class XcodeSigningTeamDetectorTests: XCTestCase {
    func testParsesDevelopmentTeamsAndDeduplicatesTeamID() {
        let output = #"""
          1) AAA "Apple Development: Person One (ABCDEFGHIJ)"
          2) BBB "Apple Development: Renewed Certificate (ABCDEFGHIJ)"
          3) CCC "Developer ID Application: Example Corp (ZZZZZZZZZZ)"
          4) DDD "Apple Development: Person Two (KLMNOPQRST)"
             4 valid identities found
        """#

        let teams = XcodeSigningTeamDetector.parseIdentities(output)

        XCTAssertEqual(teams.map(\.id), ["KLMNOPQRST", "ABCDEFGHIJ"])
        XCTAssertEqual(teams.count, 2)
    }

    func testIgnoresDistributionAndMalformedIdentities() {
        let output = #"""
          1) AAA "Apple Distribution: Example Corp (ABCDEFGHIJ)"
          2) BBB "Apple Development: Missing Team"
          3) CCC "Apple Development: Wrong Length (ABCDE)"
        """#

        XCTAssertTrue(XcodeSigningTeamDetector.parseIdentities(output).isEmpty)
    }
}
