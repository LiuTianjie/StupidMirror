@testable import StupidMirrorApp
import XCTest

final class ScreenObservationTests: XCTestCase {
    func testParserCreatesStableSemanticElementsFromWDASource() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <AppiumAUT>
          <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Demo">
            <XCUIElementTypeButton type="XCUIElementTypeButton" name="settings" label="设置" enabled="true" visible="true" x="20" y="40" width="80" height="44" />
            <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" value="登录成功" enabled="true" visible="true" x="20" y="100" width="120" height="30" />
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """

        let first = ScreenElementParser.parse(xml)
        let second = ScreenElementParser.parse(xml)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 3)

        let settings = try XCTUnwrap(first.first { $0.label == "设置" })
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(settings.visible)
        XCTAssertEqual(settings.source, .accessibility)
        XCTAssertEqual(settings.frame, ScreenElementFrame(x: 20, y: 40, width: 80, height: 44))
        XCTAssertTrue(settings.searchableText.contains("settings"))
        XCTAssertTrue(settings.searchableText.contains("设置"))
    }

    func testParserPreservesSemanticHierarchyAndNormalizedFrames() throws {
        let xml = """
        <AppiumAUT>
          <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Demo">
            <XCUIElementTypeOther type="XCUIElementTypeOther" name="panel" x="0" y="20" width="200" height="300">
              <XCUIElementTypeButton type="XCUIElementTypeButton" label="继续" x="20" y="100" width="80" height="40" />
            </XCUIElementTypeOther>
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """

        let elements = ScreenElementParser.parse(
            xml,
            screenSize: DeviceScreenSize(width: 200, height: 400)
        )
        let application = try XCTUnwrap(elements.first { $0.name == "Demo" })
        let panel = try XCTUnwrap(elements.first { $0.name == "panel" })
        let button = try XCTUnwrap(elements.first { $0.label == "继续" })

        XCTAssertNil(application.parentID)
        XCTAssertEqual(application.depth, 0)
        XCTAssertEqual(application.childrenIDs, [panel.id])
        XCTAssertEqual(panel.parentID, application.id)
        XCTAssertEqual(panel.childrenIDs, [button.id])
        XCTAssertEqual(button.parentID, panel.id)
        XCTAssertEqual(button.depth, 2)
        XCTAssertEqual(button.path, "/0/0/0/0")
        try assertFrame(
            button.normalizedFrame,
            ScreenElementFrame(x: 0.1, y: 0.25, width: 0.4, height: 0.1)
        )
        XCTAssertEqual(button.frameSpace, .screenPoints)
    }

    func testParserDisambiguatesDuplicateElements() {
        let xml = """
        <AppiumAUT>
          <XCUIElementTypeButton type="XCUIElementTypeButton" label="确定" x="1" y="2" width="3" height="4" />
          <XCUIElementTypeButton type="XCUIElementTypeButton" label="确定" x="1" y="2" width="3" height="4" />
        </AppiumAUT>
        """
        let elements = ScreenElementParser.parse(xml)
        XCTAssertEqual(elements.count, 2)
        XCTAssertNotEqual(elements[0].id, elements[1].id)
    }

    func testParserRejectsExternalEntities() {
        let xml = """
        <!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <AppiumAUT><XCUIElementTypeStaticText value="&xxe;" /></AppiumAUT>
        """
        let elements = ScreenElementParser.parse(xml)
        XCTAssertTrue(elements.isEmpty || elements.allSatisfy { !$0.searchableText.contains("root:") })
    }

    func testVisionCoordinatesBecomeTopLeftNormalizedCoordinates() {
        let converted = ScreenOCRGeometry.topLeftNormalizedFrame(
            fromVisionBoundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )
        XCTAssertEqual(converted.x, 0.1, accuracy: 0.0001)
        XCTAssertEqual(converted.y, 0.4, accuracy: 0.0001)
        XCTAssertEqual(converted.width, 0.3, accuracy: 0.0001)
        XCTAssertEqual(converted.height, 0.4, accuracy: 0.0001)
    }

    func testOCRElementsExposeConfidenceAndBothCoordinateSpaces() throws {
        let recognized = [RecognizedScreenText(
            text: "确认支付",
            confidence: 0.92,
            normalizedFrame: ScreenElementFrame(x: 0.1, y: 0.4, width: 0.3, height: 0.1)
        )]
        let elements = ScreenOCRElementFactory.makeElements(
            from: recognized,
            screenSize: DeviceScreenSize(width: 200, height: 400),
            imageWidth: 1179,
            imageHeight: 2556
        )
        let element = try XCTUnwrap(elements.first)
        XCTAssertEqual(element.source, .ocr)
        XCTAssertEqual(element.label, "确认支付")
        XCTAssertEqual(element.confidence, 0.92)
        try assertFrame(element.frame, ScreenElementFrame(x: 20, y: 160, width: 60, height: 40))
        XCTAssertEqual(element.frameSpace, .screenPoints)
        try assertFrame(element.normalizedFrame, recognized[0].normalizedFrame)
    }

    func testFusionPrefersAccessibilityWhenOCRDuplicatesTheSameTextAndRegion() {
        let normalizedFrame = ScreenElementFrame(x: 0.1, y: 0.2, width: 0.4, height: 0.1)
        let native = ScreenElement(
            id: "native",
            type: "XCUIElementTypeButton",
            name: "login",
            label: "登录",
            value: nil,
            enabled: true,
            visible: true,
            frame: ScreenElementFrame(x: 20, y: 80, width: 80, height: 40),
            frameSpace: .screenPoints,
            normalizedFrame: normalizedFrame
        )
        let duplicateOCR = ScreenElement(
            id: "ocr-duplicate",
            source: .ocr,
            type: "OCRText",
            name: nil,
            label: "登录",
            value: nil,
            enabled: true,
            visible: true,
            confidence: 0.9,
            frame: ScreenElementFrame(x: 20, y: 80, width: 80, height: 40),
            frameSpace: .screenPoints,
            normalizedFrame: normalizedFrame
        )
        let otherOCR = ScreenElement(
            id: "ocr-other",
            source: .ocr,
            type: "OCRText",
            name: nil,
            label: "仅画面可见",
            value: nil,
            enabled: true,
            visible: true,
            confidence: 0.8,
            frame: ScreenElementFrame(x: 20, y: 200, width: 80, height: 40),
            frameSpace: .screenPoints,
            normalizedFrame: ScreenElementFrame(x: 0.1, y: 0.5, width: 0.4, height: 0.1)
        )

        XCTAssertEqual(
            ScreenElementFusion.merge(accessibility: [native], ocr: [duplicateOCR, otherOCR]).map(\.id),
            ["native", "ocr-other"]
        )
    }

    func testNativeLocatorEscapesPredicateAndChoosesClosestDuplicate() throws {
        let element = ScreenElement(
            id: "save",
            type: "XCUIElementTypeButton",
            name: "save'now",
            label: "保存",
            value: nil,
            enabled: true,
            visible: true,
            frame: ScreenElementFrame(x: 20, y: 100, width: 80, height: 40)
        )
        let locators = AppiumSemanticElementResolver.locators(for: element)
        XCTAssertTrue(locators.first?.value.contains("save\\'now") == true)
        XCTAssertEqual(locators.last, AppiumSemanticLocator(using: "accessibility id", value: "save'now"))

        let selected = AppiumSemanticElementResolver.bestMatch(
            among: [
                AppiumResolvedElement(id: "far", frame: ScreenElementFrame(x: 20, y: 400, width: 80, height: 40)),
                AppiumResolvedElement(id: "near", frame: ScreenElementFrame(x: 22, y: 102, width: 80, height: 40))
            ],
            observedFrame: element.frame
        )
        XCTAssertEqual(selected?.id, "near")
    }

    func testAutomationVisualizationClampsGeometryToPhoneBounds() throws {
        let action = AutomationActionVisualization(
            kind: .tap,
            label: "AI · Tap",
            normalizedTargetFrame: ScreenElementFrame(x: -0.1, y: 0.9, width: 0.4, height: 0.3),
            normalizedPoint: CGPoint(x: 1.2, y: -0.2)
        )
        try assertFrame(
            action.normalizedTargetFrame,
            ScreenElementFrame(x: 0, y: 0.9, width: 0.3, height: 0.1)
        )
        XCTAssertEqual(action.normalizedPoint, CGPoint(x: 1, y: 0))
    }

    private func assertFrame(
        _ actual: ScreenElementFrame?,
        _ expected: ScreenElementFrame,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001, file: file, line: line)
    }
}
