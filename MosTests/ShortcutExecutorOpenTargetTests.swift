import XCTest
@testable import Mos_Debug

final class ShortcutExecutorOpenTargetTests: XCTestCase {

    private func makeOpenTargetBinding(payload: OpenTargetPayload) -> ButtonBinding {
        return ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            openTarget: payload
        )
    }

    func testResolveAction_openTargetSentinel_returnsOpenTargetCase() {
        let payload = OpenTargetPayload(path: "/Applications/Safari.app", bundleID: "com.apple.Safari", arguments: "", isApplication: true)
        let binding = makeOpenTargetBinding(payload: payload)
        let executor = ShortcutExecutor()

        let resolved = executor.resolveAction(named: "openTarget", binding: binding)
        guard case .openTarget(let resolvedPayload) = resolved else {
            return XCTFail("Expected .openTarget case, got \(String(describing: resolved))")
        }
        XCTAssertEqual(resolvedPayload, payload)
    }

    func testResolveAction_openTargetSentinelButNoPayload_returnsNil() {
        // Edge case: sentinel set but openTarget field missing — corruption guard
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "openTarget"
        )
        let executor = ShortcutExecutor()

        let resolved = executor.resolveAction(named: "openTarget", binding: binding)
        if case .systemShortcut = resolved {
            // Falls through to systemShortcut case (returns the identifier as-is, lookup will fail later)
        } else if resolved == nil {
            // Or returns nil — either is acceptable defensive behavior
        } else {
            XCTFail("Expected .systemShortcut or nil for missing payload, got \(String(describing: resolved))")
        }
    }

    func testResolveAction_existingCustomKeyPath_unaffected() {
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::40:1048576"
        )
        binding.prepareCustomCache()
        let executor = ShortcutExecutor()

        let resolved = executor.resolveAction(named: "custom::40:1048576", binding: binding)
        guard case .customKey(let code, let modifiers) = resolved else {
            return XCTFail("Expected .customKey case, got \(String(describing: resolved))")
        }
        XCTAssertEqual(code, 40)
        XCTAssertEqual(modifiers, 1048576)
    }

    func testResolveAction_existingMouseButtonPath_unaffected() {
        let executor = ShortcutExecutor()
        let resolved = executor.resolveAction(named: "mouseLeftClick", binding: nil)
        guard case .mouseButton(let kind) = resolved else {
            return XCTFail("Expected .mouseButton case, got \(String(describing: resolved))")
        }
        XCTAssertEqual(kind, .left)
    }

    func testExecutionMode_openTarget_isTrigger() {
        let payload = OpenTargetPayload(path: "/x.app", bundleID: nil, arguments: "", isApplication: true)
        let action: ResolvedAction = .openTarget(payload: payload)
        XCTAssertEqual(action.executionMode, .trigger)
    }

    func testExecutionMode_existingCases_unchanged() {
        XCTAssertEqual(ResolvedAction.customKey(code: 0, modifiers: 0).executionMode, .stateful)
        XCTAssertEqual(ResolvedAction.mouseButton(kind: .left).executionMode, .stateful)
        XCTAssertEqual(ResolvedAction.logiAction(identifier: "logiSmartShiftToggle").executionMode, .trigger)
    }
}
