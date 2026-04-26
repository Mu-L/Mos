import XCTest
@testable import Mos_Debug

final class OpenTargetPayloadTests: XCTestCase {

    // MARK: - OpenTargetPayload

    func testCodableRoundtrip_app() {
        let original = OpenTargetPayload(
            path: "/Applications/Safari.app",
            bundleID: "com.apple.Safari",
            arguments: "https://example.com",
            kind: .application
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(OpenTargetPayload.self, from: data)
        XCTAssertEqual(decoded.path, "/Applications/Safari.app")
        XCTAssertEqual(decoded.bundleID, "com.apple.Safari")
        XCTAssertEqual(decoded.arguments, "https://example.com")
        XCTAssertEqual(decoded.kind, .application)
    }

    func testCodableRoundtrip_script() {
        let original = OpenTargetPayload(
            path: "/usr/local/bin/deploy.sh",
            bundleID: nil,
            arguments: "--port=3000",
            kind: .script
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(OpenTargetPayload.self, from: data)
        XCTAssertEqual(decoded.path, "/usr/local/bin/deploy.sh")
        XCTAssertNil(decoded.bundleID)
        XCTAssertEqual(decoded.kind, .script)
    }

    func testCodableRoundtrip_file() {
        let original = OpenTargetPayload(
            path: "/Users/x/photo.png",
            bundleID: nil,
            arguments: "",
            kind: .file
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(OpenTargetPayload.self, from: data)
        XCTAssertEqual(decoded.path, "/Users/x/photo.png")
        XCTAssertEqual(decoded.kind, .file)
    }

    func testCodableLegacy_isApplicationTrue_mapsToApplication() {
        let legacyJSON = """
        {"path":"/x.app","bundleID":"com.x","arguments":"","isApplication":true}
        """.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(OpenTargetPayload.self, from: legacyJSON)
        XCTAssertEqual(decoded.kind, .application)
    }

    func testCodableLegacy_isApplicationFalse_mapsToScript() {
        let legacyJSON = """
        {"path":"/run.sh","bundleID":null,"arguments":"","isApplication":false}
        """.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(OpenTargetPayload.self, from: legacyJSON)
        XCTAssertEqual(decoded.kind, .script)
    }

    func testEquatable() {
        let a = OpenTargetPayload(path: "/a", bundleID: nil, arguments: "", kind: .file)
        let b = OpenTargetPayload(path: "/a", bundleID: nil, arguments: "", kind: .file)
        let c = OpenTargetPayload(path: "/a", bundleID: nil, arguments: "x", kind: .file)
        let d = OpenTargetPayload(path: "/a", bundleID: nil, arguments: "", kind: .script)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    func testJSONShape_isFlatAndReadable() {
        // Must produce keys path / bundleID / arguments / kind directly, no _0 wrapping.
        // Must NOT write legacy isApplication anymore (avoid double-source-of-truth).
        let payload = OpenTargetPayload(path: "/x", bundleID: "y", arguments: "z", kind: .application)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(data: try! encoder.encode(payload), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"path\":\"\\/x\""))
        XCTAssertTrue(json.contains("\"bundleID\":\"y\""))
        XCTAssertTrue(json.contains("\"arguments\":\"z\""))
        XCTAssertTrue(json.contains("\"kind\":\"application\""))
        XCTAssertFalse(json.contains("isApplication"))
        XCTAssertFalse(json.contains("_0"))
    }

    // MARK: - ArgumentSplitter

    func testArgumentSplitter_emptyString() {
        XCTAssertEqual(ArgumentSplitter.split(""), [])
    }

    func testArgumentSplitter_whitespaceOnly() {
        XCTAssertEqual(ArgumentSplitter.split("   "), [])
    }

    func testArgumentSplitter_simpleSpaceSeparated() {
        XCTAssertEqual(ArgumentSplitter.split("--port 3000"), ["--port", "3000"])
    }

    func testArgumentSplitter_doubleQuotedGroups() {
        XCTAssertEqual(
            ArgumentSplitter.split("--name \"hello world\" --port 3000"),
            ["--name", "hello world", "--port", "3000"]
        )
    }

    func testArgumentSplitter_backslashEscape() {
        XCTAssertEqual(
            ArgumentSplitter.split("a\\ b"),
            ["a b"]
        )
    }

    func testArgumentSplitter_escapedQuoteInsideQuotes() {
        XCTAssertEqual(
            ArgumentSplitter.split("\"foo \\\"bar\\\" baz\""),
            ["foo \"bar\" baz"]
        )
    }

    func testArgumentSplitter_unclosedQuote_treatsAsEOF() {
        // Defensive: don't crash, take whatever's there
        XCTAssertEqual(ArgumentSplitter.split("--name \"hello"), ["--name", "hello"])
    }

    func testArgumentSplitter_consecutiveWhitespace() {
        XCTAssertEqual(ArgumentSplitter.split("a    b"), ["a", "b"])
    }
}
