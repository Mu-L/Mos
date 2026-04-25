import XCTest
@testable import Mos_Debug

/// Tier 2 scaffolding for LogiExternalBridge dispatch routing.
/// Comprehensive end-to-end coverage lives in Tier 3a (Task 4.4) where a real
/// LogiDeviceSession can drive the bridge; here we only verify the test
/// double's recording semantics.
final class LogiBridgeDispatchTests: XCTestCase {

    func testFakeBridgeRecordsCalls() {
        let fake = FakeLogiExternalBridge()
        let event = InputEvent(
            type: .mouse,
            code: 1006,
            modifiers: [],
            phase: .down,
            source: .hidPP,
            device: nil
        )
        fake.dispatchReturn = .logiAction(name: "logiSmartShiftToggle")
        let result = fake.dispatchLogiButtonEvent(event)
        XCTAssertEqual(result, .logiAction(name: "logiSmartShiftToggle"))
        XCTAssertEqual(fake.calls.count, 1)
        if case .dispatch(let recorded) = fake.calls[0] {
            XCTAssertEqual(recorded.code, 1006)
            XCTAssertEqual(recorded.phase, .down)
        } else {
            XCTFail("Expected .dispatch call, got \(fake.calls[0])")
        }
    }

    func testFakeBridgeScrollHotkey_recordsCallWithPhase() {
        let fake = FakeLogiExternalBridge()
        fake.handleLogiScrollHotkey(code: 1006, phase: .down)
        fake.handleLogiScrollHotkey(code: 1006, phase: .up)
        XCTAssertEqual(fake.calls.count, 2)
        if case .scrollHotkey(_, let phase0) = fake.calls[0] {
            XCTAssertEqual(phase0, .down)
        } else {
            XCTFail("Expected .scrollHotkey call at index 0")
        }
        if case .scrollHotkey(_, let phase1) = fake.calls[1] {
            XCTAssertEqual(phase1, .up)
        } else {
            XCTFail("Expected .scrollHotkey call at index 1")
        }
    }

    func testFakeBridgeToast_recordsSeverityAndMessage() {
        let fake = FakeLogiExternalBridge()
        fake.showLogiToast("hi", severity: .warning)
        XCTAssertEqual(fake.calls.count, 1)
        if case .toast(let message, let severity) = fake.calls[0] {
            XCTAssertEqual(message, "hi")
            if case .warning = severity {
                // ok
            } else {
                XCTFail("Expected .warning severity")
            }
        } else {
            XCTFail("Expected .toast call")
        }
    }
}
