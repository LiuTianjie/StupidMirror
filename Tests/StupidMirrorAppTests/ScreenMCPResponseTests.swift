@testable import StupidMirrorApp
import MCP
import XCTest

final class ScreenMCPResponseTests: XCTestCase {
    func testCompactIsDefaultAndInvalidFormatsFail() throws {
        XCTAssertEqual(try ScreenResponseFormat(arguments: [:]), .compact)
        XCTAssertEqual(try ScreenResponseFormat(arguments: ["response_format": "full"]), .full)
        XCTAssertThrowsError(try ScreenResponseFormat(arguments: ["response_format": "verbose"]))
        XCTAssertThrowsError(try ScreenResponseFormat(arguments: ["response_format": true]))
        XCTAssertTrue(ScreenMCPResponse.defaultIncludeImage)
        XCTAssertTrue(ScreenMCPResponse.defaultIncludeOCR)
    }

    func testCompactOCRPreservesEveryIdentityAndDuplicateLabelPosition() throws {
        let elements = ScreenOCRElementFactory.makeElements(from: [
            RecognizedScreenText(text: "确定", confidence: 0.812345, normalizedFrame: .init(x: 0.111111, y: 0.2, width: 0.2, height: 0.1)),
            RecognizedScreenText(text: "确定", confidence: 1, normalizedFrame: .init(x: 0.6, y: 0.2, width: 0.2, height: 0.1))
        ], screenSize: .init(width: 420, height: 912), imageWidth: 1260, imageHeight: 2736)
        let observation = makeObservation(elements)
        let result = try ScreenMCPResponse.observation(.init(observation: observation, imageData: nil), format: .compact)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["id"]?.stringValue, observation.id.uuidString)
        let compact = try XCTUnwrap(fields["elements"]?.arrayValue)
        XCTAssertEqual(compact.count, 2)
        XCTAssertEqual(compact.map { $0.objectValue?["id"]?.stringValue }, elements.map(\.id))
        XCTAssertEqual(compact[0].objectValue?["center"]?.arrayValue, [.double(0.211), .double(0.25)])
        XCTAssertEqual(compact[1].objectValue?["center"]?.arrayValue, [.double(0.7), .double(0.25)])
        XCTAssertEqual(compact[0].objectValue?["confidence"]?.doubleValue, 0.81)
        XCTAssertNil(compact[0].objectValue?["frame"])
        XCTAssertNil(compact[0].objectValue?["path"])
        XCTAssertEqual(elements[0].normalizedFrame?.x, 0.111111) // source was not rounded
        guard case .text(let text, _, _) = result.content.first else { return XCTFail("Expected text") }
        XCTAssertEqual(Data(text.utf8), try JSONEncoder.stupidMirrorMCP.encode(XCTUnwrap(result.structuredContent)))
        let full = try JSONEncoder().encode(observation)
        XCTAssertLessThan(text.utf8.count, full.count / 2)
    }

    func testNativeControlStatesAndUnlabelledControlsAreNotLost() throws {
        let elements = ScreenElementParser.parse("""
        <root>
          <XCUIElementTypeSwitch type="XCUIElementTypeSwitch" label="画中画" value="1" enabled="false" visible="true" hittable="false" x="0" y="0" width="40" height="20" />
          <node class="android.widget.Switch" resource-id="toggle" checked="false" focused="false" clickable="true" bounds="[0,20][40,40]" />
          <XCUIElementTypeButton type="XCUIElementTypeButton" enabled="true" visible="false" x="0" y="40" width="40" height="20" />
        </root>
        """, screenSize: .init(width: 100, height: 100))
        let compact = elements.map { ScreenMCPResponse.element($0).objectValue! }
        XCTAssertEqual(compact.count, 3)
        XCTAssertEqual(compact[0]["value"]?.stringValue, "1")
        XCTAssertEqual(compact[0]["enabled"]?.boolValue, false)
        XCTAssertEqual(compact[0]["hittable"]?.boolValue, false)
        XCTAssertEqual(compact[1]["selected"]?.boolValue, false)
        XCTAssertEqual(compact[1]["focused"]?.boolValue, false)
        XCTAssertEqual(compact[2]["visible"]?.boolValue, false)
        XCTAssertNotNil(compact[2]["id"])
    }

    func testFullObservationAndImageRemainAvailableAndErrorsSurviveCompact() throws {
        let observation = makeObservation([], error: "No native source")
        let image = Data([1, 2, 3])
        let input = ScreenObservationResult(observation: observation, imageData: image)
        let full = try ScreenMCPResponse.observation(input, format: .full)
        XCTAssertEqual(full.structuredContent, try Value(observation))
        XCTAssertEqual(full.content.count, 2)
        let compact = try ScreenMCPResponse.observation(input, format: .compact)
        XCTAssertEqual(compact.content.count, 2)
        XCTAssertEqual(compact.structuredContent?.objectValue?["accessibilityError"]?.stringValue, "No native source")
        XCTAssertEqual(compact.structuredContent?.objectValue?["ocrAvailable"]?.boolValue, true)
    }

    func testSearchKeepsNoMatchEvidenceAndFullCompatibility() throws {
        let batch = ScreenElementBatchSearchResult(observationID: UUID(), queries: ["通用", "General"], matchedQuery: nil, sourcesChecked: [.ocr, .accessibility], matches: [])
        XCTAssertEqual(try ScreenMCPResponse.search(batch, format: .compact), try Value(batch))
        XCTAssertEqual(try ScreenMCPResponse.search(batch, format: .full), try Value(batch))
        let element = ScreenElement(id: "test", type: "XCUIElementTypeButton", name: "Settings", label: "Settings", value: "Settings", enabled: true, visible: true, frame: .init(x: 1, y: 2, width: 3, height: 4))
        let single = ScreenElementSearchResult(observationID: UUID(), query: "Settings", sourcesChecked: [.accessibility], matches: [element])
        let compact = try ScreenMCPResponse.search(single, format: .compact).objectValue!
        XCTAssertEqual(compact["observationID"]?.stringValue, single.observationID.uuidString)
        XCTAssertNil(compact["matches"]?.arrayValue?[0].objectValue?["name"])
        XCTAssertEqual(try ScreenMCPResponse.search(single, format: .full), try Value(single))
    }

    private func makeObservation(_ elements: [ScreenElement], error: String? = nil) -> ScreenObservation {
        ScreenObservation(id: UUID(), deviceID: "test", capturedAt: Date(), mirrorState: "running", controlState: "ready", imageAvailable: false, imageWidth: 1260, imageHeight: 2736, accessibilityAvailable: false, accessibilityError: error, ocrAvailable: true, ocrError: nil, ocrMode: .accurate, ocrLanguages: ["zh-Hans"], elements: elements)
    }
}
