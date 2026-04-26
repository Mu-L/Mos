import XCTest
@testable import Mos_Debug

final class OptionsButtonsLoaderTests: XCTestCase {

    private func makeBindingJSON(
        id: String = "11111111-1111-1111-1111-111111111111",
        systemShortcutName: String = "copy",
        extraField: String? = nil
    ) -> String {
        var fields = """
        "id": "\(id)",
        "triggerEvent": {
            "type": "mouse",
            "code": 3,
            "modifiers": 0,
            "displayComponents": ["🖱4"],
            "deviceFilter": null
        },
        "systemShortcutName": "\(systemShortcutName)",
        "isEnabled": true,
        "createdAt": 0
        """
        if let extra = extraField {
            fields += ",\n\(extra)"
        }
        return "{\(fields)}"
    }

    func testDecode_emptyArray_returnsEmpty() {
        let data = "[]".data(using: .utf8)!
        XCTAssertEqual(Options.decodeButtonBindings(from: data).count, 0)
    }

    func testDecode_singleValidBinding_decodesIt() {
        let json = "[\(makeBindingJSON())]"
        let data = json.data(using: .utf8)!
        let bindings = Options.decodeButtonBindings(from: data)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings.first?.systemShortcutName, "copy")
    }

    func testDecode_corruptOuterArray_returnsEmpty() {
        // Not a JSON array at all
        let data = "{\"not\":\"array\"}".data(using: .utf8)!
        XCTAssertEqual(Options.decodeButtonBindings(from: data).count, 0)
    }

    func testDecode_oneValidOneCorrupt_keepsValid() {
        let valid = makeBindingJSON(id: "11111111-1111-1111-1111-111111111111")
        let corrupt = """
        {"id": "22222222-2222-2222-2222-222222222222", "missing_required_fields": true}
        """
        let json = "[\(valid),\(corrupt)]"
        let data = json.data(using: .utf8)!
        let bindings = Options.decodeButtonBindings(from: data)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings.first?.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    func testDecode_unknownExtraField_stillDecodesAndIgnores() {
        // Future Mos version added a new field; current Mos must ignore it.
        let json = "[\(makeBindingJSON(extraField: "\"futurePayloadKind\": {\"type\":\"runCommand\"}"))]"
        let data = json.data(using: .utf8)!
        let bindings = Options.decodeButtonBindings(from: data)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings.first?.systemShortcutName, "copy")
    }

    func testDecode_multipleCorruptInArray_keepsAllValid() {
        let valid1 = makeBindingJSON(id: "11111111-1111-1111-1111-111111111111", systemShortcutName: "copy")
        let valid2 = makeBindingJSON(id: "33333333-3333-3333-3333-333333333333", systemShortcutName: "paste")
        let corrupt1 = "{\"garbage\": true}"
        let corrupt2 = "null"
        let json = "[\(corrupt1),\(valid1),\(corrupt2),\(valid2)]"
        let data = json.data(using: .utf8)!
        let bindings = Options.decodeButtonBindings(from: data)
        XCTAssertEqual(bindings.count, 2)
        XCTAssertEqual(bindings.map { $0.systemShortcutName }.sorted(), ["copy", "paste"])
    }
}
