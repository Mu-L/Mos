//
//  LogitechHIDManager.swift
//  Mos
//  Logitech HID 设备管理器 - 通过 IOKit 枚举和监控 Logitech 设备
//  Created by Mos on 2026/3/16.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Foundation
import IOKit
import IOKit.hid

class LogitechHIDManager {
    static let shared = LogitechHIDManager()
    init() { NSLog("Module initialized: LogitechHIDManager") }

    // MARK: - Constants
    static let logitechVendorId: Int = 0x046D
    static let buttonEventNotification = NSNotification.Name("LogitechHIDButtonEvent")

    // MARK: - State
    private var hidManager: IOHIDManager?
    private var sessions: [IOHIDDevice: LogitechDeviceSession] = [:]
    private(set) var isActive = false

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        LogitechHIDDebugPanel.log("[LogitechHID] Starting")

        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else {
            LogitechHIDDebugPanel.log("[LogitechHID] Failed to create IOHIDManager")
            return
        }

        // 只匹配 Logitech 设备
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: LogitechHIDManager.logitechVendorId
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        // 注册回调 (使用 C 函数指针 + context)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.deviceMatchedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.deviceRemovedCallback, context)

        // Schedule 到 main RunLoop (HID++ 事件低频, 避免线程同步)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            LogitechHIDDebugPanel.log("[LogitechHID] Failed to open IOHIDManager: \(String(format: "0x%08x", result))")
            return
        }

        isActive = true
        LogitechHIDDebugPanel.log("[LogitechHID] Started")
    }

    func stop() {
        guard isActive else { return }
        LogitechHIDDebugPanel.log("[LogitechHID] Stopping")

        // 清理所有设备会话
        for (_, session) in sessions {
            session.teardown()
        }
        sessions.removeAll()

        if let manager = hidManager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        hidManager = nil
        isActive = false
        LogitechHIDDebugPanel.log("[LogitechHID] Stopped")
    }

    // MARK: - Device Callbacks (C function pointers)

    private static let deviceMatchedCallback: IOHIDDeviceCallback = { context, result, sender, device in
        guard let context = context else { return }
        let manager = Unmanaged<LogitechHIDManager>.fromOpaque(context).takeUnretainedValue()
        manager.deviceConnected(device)
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = { context, result, sender, device in
        guard let context = context else { return }
        let manager = Unmanaged<LogitechHIDManager>.fromOpaque(context).takeUnretainedValue()
        manager.deviceDisconnected(device)
    }

    // MARK: - Device Management

    private func deviceConnected(_ device: IOHIDDevice) {
        // 读取设备信息
        let vendorId = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productId = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"

        LogitechHIDDebugPanel.log("[LogitechHID] Device connected: \(productName) (VID: \(String(format: "0x%04X", vendorId)), PID: \(String(format: "0x%04X", productId)))")

        // 避免重复会话
        guard sessions[device] == nil else { return }

        // 创建会话
        let session = LogitechDeviceSession(hidDevice: device)
        sessions[device] = session
        session.setup()
        NotificationCenter.default.post(name: Self.sessionChangedNotification, object: nil)
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        guard let session = sessions.removeValue(forKey: device) else { return }
        LogitechHIDDebugPanel.log("[LogitechHID] Device disconnected: \(session.deviceInfo.name)")
        session.teardown()
        NotificationCenter.default.post(name: Self.sessionChangedNotification, object: nil)
    }

    // MARK: - Query

    /// 获取当前已连接的 Logitech 设备列表
    var connectedDevices: [InputDevice] {
        return sessions.values.map { $0.deviceInfo }
    }

    /// Debug: 暴露活跃的设备会话
    var activeSessions: [LogitechDeviceSession] {
        return Array(sessions.values)
    }

    static let sessionChangedNotification = NSNotification.Name("LogitechHIDSessionChanged")

    /// 某个 session 的 discovery 握手流程开始或结束时触发; UI 据此切换 spinner.
    static let discoveryStateDidChangeNotification = NSNotification.Name("LogitechHIDDiscoveryStateDidChange")

    /// 某个 session 完成 reporting 查询后触发, UI 可据此刷新冲突指示.
    static let reportingQueryDidCompleteNotification = NSNotification.Name("LogitechHIDReportingQueryDidComplete")

    // MARK: - Reporting Refresh Throttle

    /// 最小刷新间隔:避免 UI 事件频繁触发导致 HID++ 协议压力.
    /// 用户的预期场景 (打开面板 / 切分页 / App 激活) 在 30s 内几乎不会产生新的冲突变化,
    /// 取 30s 是响应性 vs HID link 稳定性的折中.
    private static let reportingRefreshMinInterval: TimeInterval = 30

    private var lastReportingRefresh: Date?

    /// Coalesced 入口:刷新所有 HID++ session 的 reporting 状态 (重跑 GetControlReporting).
    /// UI 触发点可随意调用,manager 内部按 `reportingRefreshMinInterval` 防抖.
    /// 同步返回,不阻塞 UI — 实际 HID++ 请求在各自 session 的 input-report 回调里异步处理,
    /// 完成后通过 `reportingQueryDidCompleteNotification` 刷新 indicator.
    func refreshReportingStatesIfNeeded() {
        if let last = lastReportingRefresh,
           Date().timeIntervalSince(last) < Self.reportingRefreshMinInterval { return }
        lastReportingRefresh = Date()
        for session in sessions.values where session.isHIDPPCandidate {
            session.refreshReportingState()
        }
    }

    /// 查询某 Logi MosCode 当前是否被第三方 (如 Logitech Options+) 接管.
    /// 未连接设备 / 未完成 reporting 查询 / 非 Logi code -> unknown.
    func conflictStatus(forMosCode mosCode: UInt16) -> LogitechConflictDetector.Status {
        guard let cid = LogitechCIDRegistry.toCID(mosCode) else { return .unknown }
        for session in sessions.values where session.isHIDPPCandidate {
            if let control = session.control(forCID: cid) {
                return LogitechConflictDetector.status(
                    reportingFlags: control.reportingFlags,
                    targetCID: control.targetCID,
                    cid: cid,
                    reportingQueried: control.reportingQueried
                )
            }
        }
        return .unknown
    }

    // MARK: - Divert Control

    /// 绑定变更后调用: 同步所有会话的 divert 状态
    func syncDivertWithBindings() {
        for (_, session) in sessions where session.isHIDPPCandidate {
            session.syncDivertWithBindings()
        }
    }

    /// 录制模式标志: 录制期间跳过动作执行, 只转发事件给 KeyRecorder
    private(set) var isRecording = false

    /// 录制模式: 临时 divert 所有按键
    func temporarilyDivertAll() {
        isRecording = true
        for (_, session) in sessions where session.isHIDPPCandidate {
            session.temporarilyDivertAll()
        }
    }

    /// 录制结束: 恢复到只 divert 有绑定的按键
    func restoreDivertToBindings() {
        isRecording = false
        for (_, session) in sessions where session.isHIDPPCandidate {
            session.restoreDivertToBindings()
        }
    }

    // MARK: - Logi Action Execution

    enum DPICycleDirection { case up, down }

    /// 获取最佳活跃 session (优先已完成 init 的, 其次 BLE)
    private var primarySession: LogitechDeviceSession? {
        // 优先: 已完成 init 的 session
        if let ready = sessions.values.first(where: { $0.isHIDPPCandidate && $0.debugReprogInitComplete }) {
            return ready
        }
        // 其次: BLE 候选
        if let ble = sessions.values.first(where: { $0.isHIDPPCandidate && $0.debugIsBLE }) {
            return ble
        }
        // 最后: 任意候选
        return sessions.values.first(where: { $0.isHIDPPCandidate })
    }

    /// SmartShift 切换: 读取当前模式, 取反
    func executeSmartShiftToggle() {
        guard let session = primarySession else { return }
        session.executeSmartShiftToggle()
    }

    /// DPI 循环
    func executeDPICycle(direction: DPICycleDirection) {
        guard let session = primarySession else { return }
        session.executeDPICycle(direction: direction)
    }
}
