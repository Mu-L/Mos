//
//  ShortcutExecutor.swift
//  Mos
//  系统快捷键执行器 - 发送快捷键事件
//  Created by Claude on 2025/8/10.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

enum MouseButtonActionKind {
    case left
    case right
    case middle
    case back
    case forward

    init?(shortcutIdentifier: String) {
        switch shortcutIdentifier {
        case "mouseLeftClick":
            self = .left
        case "mouseRightClick":
            self = .right
        case "mouseMiddleClick":
            self = .middle
        case "mouseBackClick":
            self = .back
        case "mouseForwardClick":
            self = .forward
        default:
            return nil
        }
    }
}

enum ResolvedAction {
    case customKey(code: UInt16, modifiers: UInt64)
    case mouseButton(kind: MouseButtonActionKind)
    case systemShortcut(identifier: String)
    case logiAction(identifier: String)
    case openTarget(payload: OpenTargetPayload)

    var executionMode: ActionExecutionMode {
        switch self {
        case .customKey, .mouseButton:
            return .stateful
        case .logiAction, .openTarget:
            return .trigger
        case .systemShortcut(let identifier):
            return SystemShortcut.getShortcut(named: identifier)?.executionMode ?? .trigger
        }
    }
}

struct ActionExecutionResult {
    let mouseSessionID: UUID?

    static let none = ActionExecutionResult(mouseSessionID: nil)
}

class ShortcutExecutor {

    // 单例
    static let shared = ShortcutExecutor()
    init() {
        NSLog("Module initialized: ShortcutExecutor")
    }

    private var testingMouseEventObserver: ((CGEvent) -> Void)?

    // MARK: - 执行快捷键 (统一接口)

    /// 执行快捷键 (底层接口, 使用原始flags)
    /// - Parameters:
    ///   - code: 虚拟键码
    ///   - flags: 修饰键flags (UInt64原始值)
    ///   - preserveFlagsOnKeyUp: KeyUp 时是否保留修饰键 flags (默认 false)
    func execute(code: CGKeyCode, flags: UInt64, preserveFlagsOnKeyUp: Bool = false) {
        // 创建事件源
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return
        }

        // 发送按键按下事件
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
            keyDown.flags = CGEventFlags(rawValue: flags)
            keyDown.post(tap: .cghidEventTap)
        }

        // 发送按键抬起事件
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
            if preserveFlagsOnKeyUp {
                keyUp.flags = CGEventFlags(rawValue: flags)
            }
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// 执行系统快捷键 (从SystemShortcut.Shortcut对象)
    /// - Parameter shortcut: SystemShortcut.Shortcut对象
    func execute(_ shortcut: SystemShortcut.Shortcut) {
        execute(code: shortcut.code, flags: UInt64(shortcut.modifiers.rawValue), preserveFlagsOnKeyUp: shortcut.preserveFlagsOnKeyUp)
    }

    /// 执行系统快捷键 (从名称解析, 支持动态读取系统配置)
    /// - Parameters:
    ///   - shortcutName: 快捷键名称
    ///   - phase: 事件阶段 (down/up), 默认 .down
    ///   - binding: 可选的 ButtonBinding (用于访问预解析的 custom cache)
    func execute(named shortcutName: String, phase: InputPhase = .down, binding: ButtonBinding? = nil, inputModifiers: CGEventFlags? = nil) {
        guard let action = resolveAction(named: shortcutName, binding: binding) else { return }
        _ = execute(action: action, phase: phase, inputModifiers: inputModifiers)
    }

    @discardableResult
    func execute(
        action: ResolvedAction,
        phase: InputPhase,
        mouseSessionID: UUID? = nil,
        inputModifiers: CGEventFlags? = nil
    ) -> ActionExecutionResult {
        switch action {
        case .customKey(let code, let modifiers):
            executeCustom(code: code, modifiers: modifiers, phase: phase)
            return .none
        case .mouseButton(let kind):
            return ActionExecutionResult(
                mouseSessionID: executeMouseButton(
                    kind,
                    phase: phase,
                    mouseSessionID: mouseSessionID,
                    inputModifiers: inputModifiers
                )
            )
        case .logiAction(let identifier):
            guard phase == .down else { return .none }
            executeLogiAction(identifier)
            return .none
        case .openTarget(let payload):
            guard phase == .down else { return .none }
            executeOpenTarget(payload)
            return .none
        case .systemShortcut(let identifier):
            guard phase == .down else { return .none }
            executeResolvedSystemShortcut(named: identifier)
            return .none
        }
    }

    func resolveAction(named shortcutName: String, binding: ButtonBinding? = nil) -> ResolvedAction? {
        // 优先: 结构化 payload (在 cachedCustomCode 之前判定, 避免命名冲突)
        if let payload = binding?.openTarget,
           shortcutName == ButtonBinding.openTargetSentinel {
            return .openTarget(payload: payload)
        }
        if let code = binding?.cachedCustomCode {
            let modifiers = binding?.cachedCustomModifiers ?? 0
            return .customKey(code: code, modifiers: modifiers)
        }
        if let code = SystemShortcut.predefinedModifierCode(for: shortcutName) {
            return .customKey(code: code, modifiers: 0)
        }
        if let kind = MouseButtonActionKind(shortcutIdentifier: shortcutName) {
            return .mouseButton(kind: kind)
        }
        if shortcutName.hasPrefix("logi") {
            return .logiAction(identifier: shortcutName)
        }
        guard !shortcutName.isEmpty else { return nil }
        return .systemShortcut(identifier: shortcutName)
    }

    private func executeResolvedSystemShortcut(named shortcutName: String) {
        // 优先使用系统实际配置 (对于Mission Control相关快捷键)
        if let resolved = SystemShortcut.resolveSystemShortcut(shortcutName) {
            execute(code: resolved.code, flags: resolved.modifiers)
            return
        }

        // Fallback到内置快捷键定义
        guard let shortcut = SystemShortcut.getShortcut(named: shortcutName) else {
            return
        }

        execute(shortcut)
    }

    // MARK: - Custom Binding Execution

    /// 执行自定义绑定 (1:1 down/up 映射)
    private func executeCustom(code: UInt16, modifiers: UInt64, phase: InputPhase) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let isModifierKey = KeyCode.modifierKeys.contains(code)

        if isModifierKey {
            // 修饰键: 使用 flagsChanged 事件类型
            guard let event = CGEvent(source: source) else { return }
            event.type = .flagsChanged
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            if phase == .down {
                // 按下: 设置所有修饰键 flags (自身 + 附加修饰键)
                let keyMask = KeyCode.getKeyMask(code)
                event.flags = CGEventFlags(rawValue: modifiers | keyMask.rawValue)
            } else {
                // 松开: 清除所有 flags (释放全部修饰键)
                event.flags = CGEventFlags(rawValue: 0)
            }
            // 标记为 Mos 合成事件, 避免被 ScrollCore/ButtonCore/KeyRecorder 误处理
            event.setIntegerValueField(.eventSourceUserData, value: MosEventMarker.syntheticCustom)
            event.post(tap: .cghidEventTap)
        } else {
            // 普通键: 使用 keyDown/keyUp
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: phase == .down) else { return }
            event.flags = CGEventFlags(rawValue: modifiers)
            // 标记为 Mos 合成事件
            event.setIntegerValueField(.eventSourceUserData, value: MosEventMarker.syntheticCustom)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Mouse Actions

    /// 执行鼠标按键动作 (1:1 down/up 映射)
    private func executeMouseButton(
        _ kind: MouseButtonActionKind,
        phase: InputPhase,
        mouseSessionID: UUID?,
        inputModifiers: CGEventFlags?
    ) -> UUID? {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        let location = NSEvent.mouseLocation
        // 转换坐标: NSEvent 用左下角原点, CGEvent 用左上角原点
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let point = CGPoint(x: location.x, y: screenHeight - location.y)
        let spec = mouseEventSpec(for: kind, phase: phase)
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: spec.type,
            mouseCursorPosition: point,
            mouseButton: spec.button
        ) else {
            return nil
        }

        let createdSessionID: UUID?
        if phase == .down {
            createdSessionID = MouseInteractionSessionController.shared.beginSession(target: syntheticTarget(for: kind))
        } else {
            createdSessionID = nil
            if let mouseSessionID {
                MouseInteractionSessionController.shared.endSession(id: mouseSessionID)
            } else {
                MouseInteractionSessionController.shared.clearAllSessions()
            }
        }

        if let buttonNumber = spec.buttonNumber {
            event.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumber)
        }
        event.flags = InputProcessor.shared.combinedModifierFlags(physicalModifiers: inputModifiers)
        event.setIntegerValueField(.eventSourceUserData, value: MosEventMarker.syntheticCustom)
        notifyOrPostMouseEvent(event)
        return createdSessionID
    }

    func setTestingMouseEventObserver(_ observer: @escaping (CGEvent) -> Void = { _ in }) {
        testingMouseEventObserver = observer
    }

    func clearTestingMouseEventObserver() {
        testingMouseEventObserver = nil
    }

    private func syntheticTarget(for kind: MouseButtonActionKind) -> SyntheticMouseTarget {
        switch kind {
        case .left:
            return .left
        case .right:
            return .right
        case .middle:
            return .other(buttonNumber: 2)
        case .back:
            return .other(buttonNumber: 3)
        case .forward:
            return .other(buttonNumber: 4)
        }
    }

    private func mouseEventSpec(for kind: MouseButtonActionKind, phase: InputPhase) -> (type: CGEventType, button: CGMouseButton, buttonNumber: Int64?) {
        switch kind {
        case .left:
            return (phase == .down ? .leftMouseDown : .leftMouseUp, .left, nil)
        case .right:
            return (phase == .down ? .rightMouseDown : .rightMouseUp, .right, nil)
        case .middle:
            return (phase == .down ? .otherMouseDown : .otherMouseUp, .center, 2)
        case .back:
            return (phase == .down ? .otherMouseDown : .otherMouseUp, .center, 3)
        case .forward:
            return (phase == .down ? .otherMouseDown : .otherMouseUp, .center, 4)
        }
    }

    // MARK: - Logi HID++ Actions

    /// 执行 Logitech HID++ 动作
    private func executeLogiAction(_ name: String) {
        switch name {
        case "logiSmartShiftToggle":
            LogiCenter.shared.executeSmartShiftToggle()
        case "logiDPICycleUp":
            LogiCenter.shared.executeDPICycle(direction: .up)
        case "logiDPICycleDown":
            LogiCenter.shared.executeDPICycle(direction: .down)
        default:
            break
        }
    }

    // MARK: - Open Target Actions

    private func executeOpenTarget(_ payload: OpenTargetPayload) {
        if payload.isApplication {
            launchApplication(payload)
        } else {
            runScript(payload)
        }
    }

    private func launchApplication(_ payload: OpenTargetPayload) {
        let workspace = NSWorkspace.shared
        let resolvedURL: URL? = {
            if let bundleID = payload.bundleID,
               let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
            let url = URL(fileURLWithPath: payload.path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }()

        guard let url = resolvedURL else {
            let appName = (payload.path as NSString).lastPathComponent
            Toast.show(
                String(format: NSLocalizedString("openTargetAppNotFound", comment: ""), appName),
                style: .error
            )
            NSLog("OpenTarget: cannot resolve application path=\(payload.path) bundleID=\(payload.bundleID ?? "-")")
            return
        }

        let arguments = ArgumentSplitter.split(payload.arguments)
        if #available(macOS 10.15, *) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.activates = true
            workspace.openApplication(at: url, configuration: configuration) { _, error in
                if let error = error {
                    let appName = url.deletingPathExtension().lastPathComponent
                    Toast.show(
                        String(format: NSLocalizedString("openTargetAppLaunchFailed", comment: ""), appName),
                        style: .error
                    )
                    NSLog("OpenTarget: launch failed: \(error.localizedDescription)")
                }
            }
        } else {
            let configuration: [NSWorkspace.LaunchConfigurationKey: Any] = [
                .arguments: arguments
            ]
            guard let launched = try? workspace.launchApplication(
                at: url,
                options: [.default, .async],
                configuration: configuration
            ) else {
                let appName = url.deletingPathExtension().lastPathComponent
                Toast.show(
                    String(format: NSLocalizedString("openTargetAppLaunchFailed", comment: ""), appName),
                    style: .error
                )
                NSLog("OpenTarget: legacy launch failed for path=\(url.path)")
                return
            }
            launched.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func runScript(_ payload: OpenTargetPayload) {
        let url = URL(fileURLWithPath: payload.path)
        let scriptName = url.lastPathComponent

        guard FileManager.default.fileExists(atPath: url.path) else {
            Toast.show(
                String(format: NSLocalizedString("openTargetScriptNotFound", comment: ""), scriptName),
                style: .error
            )
            NSLog("OpenTarget: script not found: \(payload.path)")
            return
        }

        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            Toast.show(
                String(format: NSLocalizedString("openTargetScriptNotExecutable", comment: ""), scriptName),
                style: .warning
            )
            NSLog("OpenTarget: script not executable: \(payload.path)")
            return
        }

        let process = Process()
        process.executableURL = url
        process.arguments = ArgumentSplitter.split(payload.arguments)
        do {
            try process.run()
        } catch {
            Toast.show(
                String(format: NSLocalizedString("openTargetScriptFailed", comment: ""), scriptName),
                style: .error
            )
            NSLog("OpenTarget: script execution failed: \(error.localizedDescription)")
        }
    }

    private func notifyOrPostMouseEvent(_ event: CGEvent) {
        if let testingMouseEventObserver {
            testingMouseEventObserver(event)
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
