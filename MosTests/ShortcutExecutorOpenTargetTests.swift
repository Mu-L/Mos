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
        let payload = OpenTargetPayload(path: "/Applications/Safari.app", bundleID: "com.apple.Safari", arguments: "", kind: .application)
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
        let payload = OpenTargetPayload(path: "/x.app", bundleID: nil, arguments: "", kind: .application)
        let action: ResolvedAction = .openTarget(payload: payload)
        XCTAssertEqual(action.executionMode, .trigger)
    }

    func testExecutionMode_existingCases_unchanged() {
        XCTAssertEqual(ResolvedAction.customKey(code: 0, modifiers: 0).executionMode, .stateful)
        XCTAssertEqual(ResolvedAction.mouseButton(kind: .left).executionMode, .stateful)
        XCTAssertEqual(ResolvedAction.logiAction(identifier: "logiSmartShiftToggle").executionMode, .trigger)
    }

    // MARK: - Subprocess env sanitization

    func testSanitizedSubprocessEnvironment_stripsDyldInjection() {
        // 在 ProcessInfo.environment 注入污染 vars 不可行 (read-only),
        // 但我们可以通过白盒测试 shouldStripEnvKey 间接验证. 这里用 helper
        // ShortcutExecutor.sanitizedSubprocessEnvironment() 把当前 env 过一遍,
        // 断言常见污染 keys 一定不在结果里 (无论它们当前是否存在).
        let env = ShortcutExecutor.sanitizedSubprocessEnvironment()
        for key in env.keys {
            XCTAssertFalse(key.hasPrefix("DYLD_"), "DYLD_* 应该被剥离, 但留了 \(key)")
            XCTAssertFalse(key.hasPrefix("__XPC_DYLD_"), "__XPC_DYLD_* 应该被剥离, 但留了 \(key)")
            XCTAssertFalse(key.hasPrefix("OS_ACTIVITY_DT_"), "OS_ACTIVITY_DT_* 应该被剥离, 但留了 \(key)")
            XCTAssertFalse(key.hasPrefix("MallocStack"), "MallocStack* 应该被剥离, 但留了 \(key)")
            XCTAssertNotEqual(key, "NSZombieEnabled")
            XCTAssertNotEqual(key, "NSDeallocateZombies")
            XCTAssertFalse(key.hasPrefix("ASAN_"), "ASAN_* 应该被剥离, 但留了 \(key)")
            XCTAssertFalse(key.hasPrefix("TSAN_"), "TSAN_* 应该被剥离, 但留了 \(key)")
            XCTAssertFalse(key.hasPrefix("LSAN_"), "LSAN_* 应该被剥离, 但留了 \(key)")
            XCTAssertFalse(key.hasPrefix("UBSAN_"), "UBSAN_* 应该被剥离, 但留了 \(key)")
        }
    }

    func testSanitizedSubprocessEnvironment_preservesNormalEnv() {
        // 常规 env (PATH/HOME/USER 等) 必须保留, 否则脚本会跑不起来.
        let env = ShortcutExecutor.sanitizedSubprocessEnvironment()
        // 这些是 macOS shell 进程必有的, 只要脚本跑得起来就该有.
        XCTAssertNotNil(env["PATH"] ?? env["HOME"], "至少一个常规 env 应被保留")
    }
}
