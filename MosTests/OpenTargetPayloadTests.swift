import XCTest
@testable import Mos_Debug

final class OpenTargetPayloadTests: XCTestCase {

    // MARK: - OpenTargetPayload

    func testCodableRoundtrip_app() {
        let original = OpenTargetPayload(
            path: "/Applications/Safari.app",
            bundleID: "com.apple.Safari",
            arguments: "https://example.com",
            isApplication: true
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(OpenTargetPayload.self, from: data)
        XCTAssertEqual(decoded.path, "/Applications/Safari.app")
        XCTAssertEqual(decoded.bundleID, "com.apple.Safari")
        XCTAssertEqual(decoded.arguments, "https://example.com")
        XCTAssertTrue(decoded.isApplication)
    }

    func testCodableRoundtrip_script() {
        let original = OpenTargetPayload(
            path: "/usr/local/bin/deploy.sh",
            bundleID: nil,
            arguments: "--port=3000",
            isApplication: false
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(OpenTargetPayload.self, from: data)
        XCTAssertEqual(decoded.path, "/usr/local/bin/deploy.sh")
        XCTAssertNil(decoded.bundleID)
        XCTAssertFalse(decoded.isApplication)
    }

    func testEquatable() {
        let a = OpenTargetPayload(path: "/a", bundleID: nil, arguments: "", isApplication: false)
        let b = OpenTargetPayload(path: "/a", bundleID: nil, arguments: "", isApplication: false)
        let c = OpenTargetPayload(path: "/a", bundleID: nil, arguments: "x", isApplication: false)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testJSONShape_isFlatAndReadable() {
        // Must produce keys path / bundleID / arguments / isApplication directly, no _0 wrapping.
        let payload = OpenTargetPayload(path: "/x", bundleID: "y", arguments: "z", isApplication: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(data: try! encoder.encode(payload), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"path\":\"\\/x\""))
        XCTAssertTrue(json.contains("\"bundleID\":\"y\""))
        XCTAssertTrue(json.contains("\"arguments\":\"z\""))
        XCTAssertTrue(json.contains("\"isApplication\":true"))
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
