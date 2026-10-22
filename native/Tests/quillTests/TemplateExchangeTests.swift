import Foundation
import XCTest
@testable import quill

final class TemplateExchangeTests: XCTestCase {
    func testRoundTripPreservesInstructionsButImportsAsNewDraft() throws {
        var original = NoteTemplate.defaults[0]
        original.name = "Décisions and coaching"
        original.context = "Two lines\nNo external actions."
        let data = try TemplateExchange.encode(original)
        let copy = try TemplateExchange.decode(data)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, original.name)
        XCTAssertEqual(copy.context, original.context)
        XCTAssertEqual(copy.sections, original.sections)
    }
    func testClosedFormatRejectsExtraFieldsInvalidHeadingsAndOversizedInput() throws {
        let data = try TemplateExchange.encode(NoteTemplate.defaults[0])
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["audio"] = "forbidden"
        XCTAssertThrowsError(try TemplateExchange.decode(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "audio"); object["schemaVersion"] = 2
        XCTAssertThrowsError(try TemplateExchange.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try TemplateExchange.decode(Data(repeating: 32, count: TemplateExchange.maximumBytes + 1)))
        var bad = NoteTemplate.defaults[0]; bad.sections[0].title = "Summary\nImpersonated heading"
        XCTAssertThrowsError(try TemplateExchange.encode(bad))
    }
    func testExportCannotReplaceAnotherFileAndImportRejectsLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("template.json")
        try TemplateExchange.write(NoteTemplate.defaults[0], to: output)
        let before = try Data(contentsOf: output)
        XCTAssertThrowsError(try TemplateExchange.write(NoteTemplate.defaults[1], to: output))
        XCTAssertEqual(try Data(contentsOf: output), before)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        XCTAssertThrowsError(try TemplateExchange.read(link))
    }
}
