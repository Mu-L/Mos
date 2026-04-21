//
//  LogitechHIDDebugPanel.swift
//  Mos
//  Logitech HID++ 综合调试面板
//  Created by Mos on 2026/3/16.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa
import IOKit
import IOKit.hid

// MARK: - Log Entry

enum LogEntryType: String, CaseIterable {
    case info = "Info"
    case tx = "TX"
    case rx = "RX"
    case error = "Error"
    case buttonEvent = "Button"
    case warning = "Warning"
}

struct LogEntry {
    let timestamp: String
    let deviceName: String
    let type: LogEntryType
    let message: String
    let decoded: String?
    let rawBytes: [UInt8]?
    var isExpanded: Bool = false
}

// MARK: - HID++ Protocol Dictionaries

struct HIDPPInfo {
    static let featureNames: [UInt16: (String, String)] = [
        0x0000: ("IRoot", "Feature discovery root"),
        0x0001: ("IFeatureSet", "Enumerate all features"),
        0x0003: ("DeviceFWVersion", "Firmware version info"),
        0x0005: ("DeviceNameType", "Device name and type"),
        0x0020: ("ConfigChange", "Config change notification"),
        0x1000: ("BatteryStatus", "Battery level and status"),
        0x1001: ("BatteryVoltage", "Battery voltage reading"),
        0x1004: ("UnifiedBattery", "Unified battery reporting"),
        0x1814: ("ChangeHost", "Multi-host switching"),
        0x1815: ("HostsInfo", "Connected host info"),
        0x1B04: ("ReprogControlsV4", "Button reprog and divert"),
        0x1D4B: ("WirelessStatus", "Wireless connection status"),
        0x2110: ("SmartShift", "Scroll wheel mode"),
        0x2111: ("SmartShiftV2", "SmartShift v2"),
        0x2121: ("HiResWheel", "Hi-res scroll wheel"),
        0x2150: ("ThumbWheel", "Thumb wheel control"),
        0x2200: ("MouseButtonSpy", "Mouse button spy"),
        0x2201: ("AdjustableDPI", "DPI adjustment"),
        0x2205: ("PointerSpeed", "Pointer speed control"),
        0x4521: ("HiResWheel", "Hi-res scroll wheel"),
    ]

    static let controlFlagBits: [(bit: Int, short: String, desc: String)] = [
        (0, "Mouse", "Mouse button group"),
        (1, "FKey", "F-key group"),
        (2, "HotKey", "Hotkey"),
        (3, "FnToggle", "Fn toggle affected"),
        (4, "Reprog", "Reprogrammable"),
        (5, "Divert", "Divertable to SW"),
        (6, "Persist", "Persistent divert"),
        (7, "Virtual", "Virtual button"),
        (8, "RawXY", "Raw XY capable"),
        (9, "ForceXY", "Force raw XY"),
    ]

    static func flagsDescription(_ flags: UInt16) -> String {
        return controlFlagBits
            .filter { (flags >> $0.bit) & 1 != 0 }
            .map { $0.short }
            .joined(separator: ",")
    }

    static let errorNames: [UInt8: String] = [
        0x00: "NoError", 0x01: "Unknown", 0x02: "InvalidArgument",
        0x03: "OutOfRange", 0x04: "HWError", 0x05: "LogitechInternal",
        0x06: "InvalidFeatureIndex", 0x07: "InvalidFunctionID",
        0x08: "Busy", 0x09: "Unsupported",
    ]
}

// MARK: - Feature Action Definitions

struct HIDPPFeatureAction {
    let name: String
    let functionId: UInt8
    enum ParamType { case none, index, hex }
    let paramType: ParamType
    let defaultParams: [UInt8]
}

struct HIDPPFeatureActions {
    static let knownActions: [UInt16: [HIDPPFeatureAction]] = [
        0x0000: [
            HIDPPFeatureAction(name: "Ping", functionId: 0x01, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetFeature", functionId: 0x00, paramType: .hex, defaultParams: [0x00, 0x01]),
        ],
        0x0001: [
            HIDPPFeatureAction(name: "GetCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetFeatureID", functionId: 0x01, paramType: .index, defaultParams: []),
        ],
        0x0003: [
            HIDPPFeatureAction(name: "GetEntityCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetFWVersion", functionId: 0x01, paramType: .index, defaultParams: []),
        ],
        0x0005: [
            HIDPPFeatureAction(name: "GetCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetName", functionId: 0x01, paramType: .index, defaultParams: []),
            HIDPPFeatureAction(name: "GetType", functionId: 0x02, paramType: .none, defaultParams: []),
        ],
        0x1000: [
            HIDPPFeatureAction(name: "GetLevel", functionId: 0x00, paramType: .none, defaultParams: []),
        ],
        0x1004: [
            HIDPPFeatureAction(name: "GetStatus", functionId: 0x00, paramType: .none, defaultParams: []),
        ],
        0x1B04: [
            HIDPPFeatureAction(name: "GetCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetInfo", functionId: 0x01, paramType: .index, defaultParams: []),
            HIDPPFeatureAction(name: "GetReporting", functionId: 0x02, paramType: .hex, defaultParams: [0x00, 0x50]),
            HIDPPFeatureAction(name: "SetReporting", functionId: 0x03, paramType: .hex, defaultParams: [0x00, 0x50, 0x03]),
        ],
        0x2110: [
            HIDPPFeatureAction(name: "GetStatus", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "SetStatus", functionId: 0x01, paramType: .hex, defaultParams: [0x02]),
        ],
        0x2121: [
            HIDPPFeatureAction(name: "GetCapability", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetMode", functionId: 0x01, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "SetMode", functionId: 0x02, paramType: .hex, defaultParams: [0x00]),
        ],
        0x2201: [
            HIDPPFeatureAction(name: "GetSensorCount", functionId: 0x00, paramType: .none, defaultParams: []),
            HIDPPFeatureAction(name: "GetDPI", functionId: 0x01, paramType: .index, defaultParams: []),
            HIDPPFeatureAction(name: "SetDPI", functionId: 0x02, paramType: .hex, defaultParams: [0x00, 0x00, 0x03, 0x20]),
            HIDPPFeatureAction(name: "GetDPIList", functionId: 0x03, paramType: .index, defaultParams: []),
        ],
    ]

    static func actions(for featureId: UInt16) -> [HIDPPFeatureAction] {
        if let known = knownActions[featureId] { return known }
        return (0...15).map { funcId in
            HIDPPFeatureAction(name: "Func \(funcId)", functionId: UInt8(funcId), paramType: .hex, defaultParams: [])
        }
    }
}

// MARK: - Debug Panel

class LogitechHIDDebugPanel: NSObject {

    static let shared = LogitechHIDDebugPanel()
    static let logNotification = NSNotification.Name("LogitechHIDDebugLog")

    // MARK: - Layout Constants

    private struct L {
        static let defaultWidth: CGFloat = 1100
        static let defaultHeight: CGFloat = 750
        static let minWidth: CGFloat = 1100
        static let minHeight: CGFloat = 600
        static let sidebarWidth: CGFloat = 180
        static let actionsWidth: CGFloat = 160
        static let gap: CGFloat = 8
        static let pad: CGFloat = 8
        static let btnH: CGFloat = 24
        static let btnGap: CGFloat = 4
        // Min height for Actions panel context area. Fits worst-known feature (ReprogControlsV4: 4 action buttons + params field + index stepper ≈ 168pt) with slack.
        static let ctxMinH: CGFloat = 180
        static let topRatio: CGFloat = 0.4
        static let devInfoH: CGFloat = 140
        static let logToolbarH: CGFloat = 28
        static let rawInputH: CGFloat = 30
        static let sectionHdrH: CGFloat = 20
    }

    // MARK: - Window

    private var window: NSPanel?

    // MARK: - Sidebar

    private var outlineView: NSOutlineView!
    private var deviceInfoLabels: [(key: NSTextField, value: NSTextField)] = []
    private var moreInfoLabels: [(key: NSTextField, value: NSTextField)] = []

    // MARK: - Tables

    private var featureTableView: NSTableView!
    private var controlsTableView: NSTableView!

    // MARK: - Actions Panel

    private var contextActionsContainer: NSView!
    private var paramInputField: NSTextField?
    private var indexStepper: NSStepper?
    private var indexStepperLabel: NSTextField?

    // MARK: - Log

    private var logTableView: NSTableView!
    private var filterButtons: [LogEntryType: NSButton] = [:]
    private var rawInputField: NSTextField!
    private var reportTypeControl: NSSegmentedControl!

    // MARK: - State

    private var currentSession: LogitechDeviceSession?
    private var logTypeFilter: Set<LogEntryType> = Set(LogEntryType.allCases)
    static var logBuffer: [LogEntry] = []
    static let maxLogLines = 500
    private var logObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?
    private var reportingCompleteObserver: NSObjectProtocol?

    // MARK: - Sidebar Data

    private class DeviceNode {
        let session: LogitechDeviceSession
        var isReceiver: Bool { session.connectionMode == .receiver }
        init(session: LogitechDeviceSession) { self.session = session }
    }

    private class SlotNode {
        let session: LogitechDeviceSession
        let slot: UInt8
        init(session: LogitechDeviceSession, slot: UInt8) { self.session = session; self.slot = slot }
    }

    private enum SidebarSelection {
        case device(sessionID: ObjectIdentifier)
        case slot(sessionID: ObjectIdentifier, slot: UInt8)
    }

    private var deviceNodes: [DeviceNode] = []

    // MARK: - Feature/Control Data

    private var featureRows: [(index: String, featureId: UInt16, featureIdHex: String, name: String)] = []
    private var controlRows: [LogitechDeviceSession.ControlInfo] = []
    private var selectedFeatureId: UInt16?
    private var selectedControlCID: UInt16?

    // MARK: - Logging API

    class func log(_ message: String) {
        let entry = LogEntry(timestamp: timestamp(), deviceName: "", type: .info, message: message, decoded: nil, rawBytes: nil)
        appendToBuffer(entry)
    }

    class func log(device: String, type: LogEntryType, message: String, decoded: String? = nil, rawBytes: [UInt8]? = nil) {
        let entry = LogEntry(timestamp: timestamp(), deviceName: device, type: type, message: message, decoded: decoded, rawBytes: rawBytes)
        appendToBuffer(entry)
    }

    // Note: existing callers that pass (device:type:message:decoded:) without rawBytes
    // will use the default rawBytes: nil from the method above.

    private class func appendToBuffer(_ entry: LogEntry) {
        logBuffer.append(entry)
        if logBuffer.count > maxLogLines { logBuffer.removeFirst(logBuffer.count - maxLogLines) }
        NotificationCenter.default.post(name: logNotification, object: entry)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    // MARK: - Show / Hide

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshAll()
            startObserving()
            return
        }
        let w = buildWindow()
        window = w
        refreshAll()
        startObserving()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build Window

    private func buildWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: L.defaultWidth, height: L.defaultHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Logitech HID++ Debug"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.minSize = NSSize(width: L.minWidth, height: L.minHeight)
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        effectView.autoresizingMask = [.width, .height]
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        panel.appearance = NSAppearance(named: .vibrantDark)
        if #available(macOS 10.14, *) {
            effectView.material = .hudWindow
        } else {
            effectView.material = .dark
        }
        panel.contentView = effectView

        let topInset = resolvedTopInset(for: panel)
        buildContent(in: effectView, topInset: topInset)

        return panel
    }

    private func resolvedTopInset(for panel: NSPanel) -> CGFloat {
        let titlebarH = panel.frame.height - panel.contentLayoutRect.height
        return max(L.pad, titlebarH + 4)
    }

    // Flipped view for containers with manually-positioned dynamic content
    private final class FlippedView: NSView {
        override var isFlipped: Bool { return true }
    }
    // Flipped NSSplitView so first subview = top
    private final class TopFirstSplitView: NSSplitView {
        override var isFlipped: Bool { return true }
        override var dividerThickness: CGFloat { return 8 }
        override func drawDivider(in rect: NSRect) {
            // Draw nothing — gap between rounded-corner sections is the visual divider
        }
    }

    // MARK: - Build Content (Auto Layout)

    private func buildContent(in container: NSView, topInset: CGFloat) {
        // --- Sidebar ---
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sidebar)
        buildSidebar(in: sidebar)

        // --- Main split: top area / log area ---
        let split = TopFirstSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(split)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            sidebar.widthAnchor.constraint(equalToConstant: L.sidebarWidth),

            split.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: L.gap),
            split.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        // NSSplitView subviews — managed by split, NOT by constraints
        let topContainer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 280))
        buildTopArea(in: topContainer)
        split.addSubview(topContainer)

        let logContainer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 420))
        buildLogArea(in: logContainer)
        split.addSubview(logContainer)
    }

    // MARK: - Build Sidebar (Auto Layout + NSSplitView for draggable device info)

    private func buildSidebar(in sidebar: NSView) {
        // Draggable split between device tree and device info
        let sidebarSplit = TopFirstSplitView()
        sidebarSplit.isVertical = false
        sidebarSplit.dividerStyle = .thin
        sidebarSplit.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarSplit)

        NSLayoutConstraint.activate([
            sidebarSplit.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarSplit.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarSplit.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarSplit.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
        ])

        // Top section: device tree with header inside the rounded block
        let treeContainer = FlippedView(frame: NSRect(x: 0, y: 0, width: L.sidebarWidth, height: 200))
        let treeBg = makeSectionBg()
        treeBg.autoresizingMask = [.width, .height]
        treeBg.frame = treeContainer.bounds
        treeContainer.addSubview(treeBg)

        let header = makeSectionHeader("DEVICES")
        header.frame = NSRect(x: L.pad, y: 4, width: L.sidebarWidth - L.pad * 2, height: 16)
        header.autoresizingMask = [.width]
        treeContainer.addSubview(header)

        let treeScroll = NSScrollView()
        treeScroll.frame = NSRect(x: 4, y: L.sectionHdrH, width: L.sidebarWidth - 8, height: 200 - L.sectionHdrH - 4)
        treeScroll.autoresizingMask = [.width, .height]
        configureDarkScroll(treeScroll)

        let outline = NSOutlineView()
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .regular
        outline.indentationPerLevel = 14
        outline.rowHeight = 22
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.delegate = self
        outline.dataSource = self
        outline.target = self
        outline.action = #selector(outlineViewClicked(_:))
        treeScroll.documentView = outline
        self.outlineView = outline
        treeContainer.addSubview(treeScroll)
        sidebarSplit.addSubview(treeContainer)

        // Bottom section: device info with its own rounded bg
        let infoContainer = NSView(frame: NSRect(x: 0, y: 0, width: L.sidebarWidth, height: 250))
        let infoBg = makeSectionBg()
        infoBg.autoresizingMask = [.width, .height]
        infoBg.frame = infoContainer.bounds
        infoContainer.addSubview(infoBg)

        let infoScroll = NSScrollView()
        infoScroll.autoresizingMask = [.width, .height]
        infoScroll.frame = infoContainer.bounds
        configureDarkScroll(infoScroll)

        let allKeys = ["VID", "PID", "Protocol", "Transport", "Dev Index", "Conn Mode", "Opened",
                        "UsagePage", "Usage", "HID++ Cand", "Init Done", "Dvrt CIDs"]
        let contentH: CGFloat = CGFloat(allKeys.count) * 16 + L.pad
        let infoDoc = FlippedView(frame: NSRect(x: 0, y: 0, width: L.sidebarWidth, height: contentH))
        var iy: CGFloat = L.pad
        let keyW: CGFloat = 65
        let valX: CGFloat = keyW + 4
        deviceInfoLabels.removeAll()
        moreInfoLabels.removeAll()
        for (i, keyText) in allKeys.enumerated() {
            let kl = makeLabel(text: keyText, fontSize: 9, weight: .medium, color: .tertiaryLabelColor)
            kl.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
            kl.frame = NSRect(x: L.pad, y: iy, width: keyW, height: 14)
            infoDoc.addSubview(kl)
            let vl = makeLabel(text: "--", fontSize: 9, color: .secondaryLabelColor)
            vl.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            vl.frame = NSRect(x: valX, y: iy, width: L.sidebarWidth - valX - L.pad, height: 14)
            infoDoc.addSubview(vl)
            if i < 7 { deviceInfoLabels.append((key: kl, value: vl)) }
            else { moreInfoLabels.append((key: kl, value: vl)) }
            iy += 16
        }
        infoScroll.documentView = infoDoc
        infoContainer.addSubview(infoScroll)
        sidebarSplit.addSubview(infoContainer)
    }

    @objc private func outlineViewClicked(_ sender: Any?) {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        let item = outlineView.item(atRow: row)

        if let node = item as? DeviceNode {
            currentSession = node.session
            selectedFeatureId = nil
            selectedControlCID = nil
            refreshRightPanels()
        } else if let slot = item as? SlotNode {
            // Validate slot is online
            let paired = slot.session.debugReceiverPairedDevices
            let idx = Int(slot.slot) - 1
            guard idx >= 0, idx < paired.count, paired[idx].isConnected else { return }
            currentSession = slot.session
            slot.session.setTargetSlot(slot: slot.slot)
            refreshRightPanelsLoading()
            slot.session.rediscoverFeatures()
        }
    }

    // MARK: - Build Top Area (Auto Layout)

    private func buildTopArea(in parent: NSView) {
        let fCol = NSView()
        let cCol = NSView()
        let aCol = NSView()
        for v in [fCol, cCol, aCol] { v.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(v) }

        NSLayoutConstraint.activate([
            // Feature column: left, top, bottom
            fCol.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            fCol.topAnchor.constraint(equalTo: parent.topAnchor),
            fCol.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            // Controls column: after features, same top/bottom, same width
            cCol.leadingAnchor.constraint(equalTo: fCol.trailingAnchor, constant: L.gap),
            cCol.topAnchor.constraint(equalTo: parent.topAnchor),
            cCol.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            cCol.widthAnchor.constraint(equalTo: fCol.widthAnchor),
            // Actions column: after controls, right edge, fixed width
            aCol.leadingAnchor.constraint(equalTo: cCol.trailingAnchor, constant: L.gap),
            aCol.topAnchor.constraint(equalTo: parent.topAnchor),
            aCol.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            aCol.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            aCol.widthAnchor.constraint(equalToConstant: L.actionsWidth),
        ])

        buildTableColumn(in: fCol, headerTag: 100, headerText: "FEATURES (0)", tableTag: 200,
                          columns: [("fIdx", 36), ("fId", 50), ("fName", 0)],
                          action: #selector(featureTableClicked(_:)), isFeature: true)
        buildTableColumn(in: cCol, headerTag: 101, headerText: "CONTROLS (0)", tableTag: 201,
                          columns: [("cCid", 50), ("cName", 0), ("cFlags", 40), ("cStatus", 50)],
                          action: #selector(controlsTableClicked(_:)), isFeature: false)
        buildActionsPanel(in: aCol)
    }

    /// Build a table column section: bg + header + scrollView with table
    private func buildTableColumn(in parent: NSView, headerTag: Int, headerText: String,
                                   tableTag: Int, columns: [(String, CGFloat)],
                                   action: Selector, isFeature: Bool) {
        let bg = makeSectionBg()
        bg.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(bg)

        let header = makeSectionHeader(headerText)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.tag = headerTag
        parent.addSubview(header)

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        configureDarkScroll(sv)
        parent.addSubview(sv)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            bg.topAnchor.constraint(equalTo: parent.topAnchor),
            bg.bottomAnchor.constraint(equalTo: parent.bottomAnchor),

            header.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: L.pad),
            header.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -L.pad),
            header.topAnchor.constraint(equalTo: parent.topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 16),

            sv.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 4),
            sv.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -4),
            sv.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            sv.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -4),
        ])

        let table = NSTableView()
        table.backgroundColor = .clear
        table.headerView = nil
        table.selectionHighlightStyle = .regular
        table.rowHeight = 20
        table.tag = tableTag
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = action
        table.columnAutoresizingStyle = isFeature ? .lastColumnOnlyAutoresizingStyle : .uniformColumnAutoresizingStyle

        for (id, w) in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            if w > 0 { c.width = w; c.resizingMask = isFeature ? [] : [] }
            else { c.width = 100; c.resizingMask = .autoresizingMask }
            table.addTableColumn(c)
        }
        sv.documentView = table
        table.sizeLastColumnToFit()

        if isFeature { self.featureTableView = table }
        else { self.controlsTableView = table }
    }

    // MARK: - Actions Panel (Auto Layout)

    private func buildActionsPanel(in parent: NSView) {
        let bg = makeSectionBg()
        bg.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(bg)

        let header = makeSectionHeader("ACTIONS")
        header.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(header)

        let ctxC = FlippedView()
        ctxC.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(ctxC)
        self.contextActionsContainer = ctxC

        let placeholder = makeLabel(text: "Select a feature\nor control", fontSize: 10, color: .tertiaryLabelColor)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 2
        ctxC.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: ctxC.leadingAnchor, constant: L.pad),
            placeholder.trailingAnchor.constraint(equalTo: ctxC.trailingAnchor, constant: -L.pad),
            placeholder.topAnchor.constraint(equalTo: ctxC.topAnchor, constant: L.pad),
        ])

        let sep = makeSep()
        sep.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(sep)

        let globalC = FlippedView()
        globalC.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(globalC)

        let globalH: CGFloat = CGFloat(5) * L.btnH + CGFloat(4) * L.btnGap + L.pad

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            bg.topAnchor.constraint(equalTo: parent.topAnchor),
            bg.bottomAnchor.constraint(equalTo: parent.bottomAnchor),

            header.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: L.pad),
            header.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -L.pad),
            header.topAnchor.constraint(equalTo: parent.topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 16),

            ctxC.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            ctxC.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            ctxC.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            ctxC.bottomAnchor.constraint(equalTo: sep.topAnchor),
            ctxC.heightAnchor.constraint(greaterThanOrEqualToConstant: L.ctxMinH),

            sep.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: L.pad),
            sep.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -L.pad),
            sep.heightAnchor.constraint(equalToConstant: 1),

            globalC.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            globalC.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            globalC.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: L.pad),
            globalC.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            globalC.heightAnchor.constraint(equalToConstant: globalH),
        ])

        let btnW = L.actionsWidth - L.pad * 2
        var by: CGFloat = 0
        for (title, action) in [("Re-Discover", #selector(rediscoverClicked)),
                                 ("Re-Divert", #selector(redivertClicked)),
                                 ("Undivert All", #selector(undivertClicked)),
                                 ("Enumerate", #selector(enumerateClicked)),
                                 ("Clear Log", #selector(clearLogClicked))] {
            let btn = makeActionBtn(title: title, action: action)
            btn.frame = NSRect(x: L.pad, y: by, width: btnW, height: L.btnH)
            globalC.addSubview(btn)
            by += L.btnH + L.btnGap
        }
    }

    // MARK: - Build Log Area (Auto Layout)

    private func buildLogArea(in parent: NSView) {
        let bg = makeLogBg()
        bg.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(bg)

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(toolbar)
        buildLogToolbar(in: toolbar)

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        configureDarkScroll(sv)
        parent.addSubview(sv)

        let table = NSTableView()
        table.backgroundColor = .clear
        table.headerView = nil
        table.selectionHighlightStyle = .none
        table.rowHeight = 18
        table.tag = 300
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(logRowClicked(_:))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let logCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("log"))
        logCol.resizingMask = .autoresizingMask
        table.addTableColumn(logCol)
        sv.documentView = table
        table.sizeLastColumnToFit()
        self.logTableView = table

        let rawBar = NSView()
        rawBar.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(rawBar)
        buildRawInputBar(in: rawBar)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            bg.topAnchor.constraint(equalTo: parent.topAnchor),
            bg.bottomAnchor.constraint(equalTo: parent.bottomAnchor),

            toolbar.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: parent.topAnchor, constant: 4),
            toolbar.heightAnchor.constraint(equalToConstant: L.logToolbarH),

            sv.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            sv.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            sv.bottomAnchor.constraint(equalTo: rawBar.topAnchor, constant: -4),

            rawBar.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            rawBar.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            rawBar.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            rawBar.heightAnchor.constraint(equalToConstant: L.rawInputH),
        ])
    }

    private func buildLogToolbar(in toolbar: NSView) {
        let logLabel = makeSectionHeader("PROTOCOL LOG")
        logLabel.frame = NSRect(x: L.pad, y: 6, width: 100, height: 16)
        logLabel.autoresizingMask = []
        toolbar.addSubview(logLabel)

        let chipColors: [(LogEntryType, String, NSColor)] = [
            (.tx, "TX", NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)),
            (.rx, "RX", NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)),
            (.error, "ERR", NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)),
            (.buttonEvent, "BTN", NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)),
            (.warning, "WARN", NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)),
            (.info, "INFO", NSColor(calibratedWhite: 0.75, alpha: 1.0)),
        ]
        var fx: CGFloat = 110
        for (i, (entryType, label, color)) in chipColors.enumerated() {
            let btn = NSButton(title: label, target: self, action: #selector(filterChipClicked(_:)))
            btn.isBordered = false
            btn.wantsLayer = true
            btn.layer?.backgroundColor = color.withAlphaComponent(0.3).cgColor
            btn.layer?.cornerRadius = 3
            btn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            if #available(macOS 10.14, *) { btn.contentTintColor = color }
            btn.tag = i
            btn.frame = NSRect(x: fx, y: 4, width: 38, height: 20)
            btn.autoresizingMask = []
            toolbar.addSubview(btn)
            filterButtons[entryType] = btn
            fx += 42
        }

        let clearBtn = makeActionBtn(title: "Clear", action: #selector(clearLogClicked))
        clearBtn.frame = NSRect(x: 0, y: 4, width: 42, height: 20)
        clearBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        clearBtn.autoresizingMask = [.minXMargin]
        toolbar.addSubview(clearBtn)
        // Pin to right with constraints
        clearBtn.translatesAutoresizingMaskIntoConstraints = true
        clearBtn.autoresizingMask = [.minXMargin]

        let exportBtn = makeActionBtn(title: "Export", action: #selector(exportLogClicked))
        exportBtn.frame = NSRect(x: 0, y: 4, width: 46, height: 20)
        exportBtn.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        exportBtn.autoresizingMask = [.minXMargin]
        toolbar.addSubview(exportBtn)

        // Position clear/export from right using frame + autoresizingMask
        // Will be repositioned after layout
        toolbar.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: toolbar, queue: .main) { _ in
            let w = toolbar.bounds.width
            clearBtn.frame.origin.x = w - 50
            exportBtn.frame.origin.x = w - 100
        }
    }

    private func buildRawInputBar(in container: NSView) {
        let sep = makeSep()
        sep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep)

        let rawLabel = makeLabel(text: "RAW:", fontSize: 10, weight: .medium, color: .tertiaryLabelColor)
        rawLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rawLabel)

        let segCtrl = NSSegmentedControl(labels: ["Short 7B", "Long 20B"], trackingMode: .selectOne, target: nil, action: nil)
        segCtrl.selectedSegment = 1
        segCtrl.translatesAutoresizingMaskIntoConstraints = false
        segCtrl.font = NSFont.systemFont(ofSize: 9)
        container.addSubview(segCtrl)
        self.reportTypeControl = segCtrl

        let inputField = NSTextField()
        inputField.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        inputField.placeholderString = "11 FF 00 01 1B 04 00 ..."
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.wantsLayer = true
        inputField.layer?.cornerRadius = 3
        inputField.textColor = .labelColor
        inputField.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.06)
        inputField.isBezeled = false
        container.addSubview(inputField)
        self.rawInputField = inputField

        let sendBtn = makeActionBtn(title: "Send", action: #selector(sendRawClicked),
                                    color: NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0))
        sendBtn.translatesAutoresizingMaskIntoConstraints = false
        sendBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        container.addSubview(sendBtn)

        NSLayoutConstraint.activate([
            sep.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: L.pad),
            sep.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -L.pad),
            sep.topAnchor.constraint(equalTo: container.topAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            rawLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: L.pad),
            rawLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            rawLabel.widthAnchor.constraint(equalToConstant: 35),

            segCtrl.leadingAnchor.constraint(equalTo: rawLabel.trailingAnchor, constant: 4),
            segCtrl.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            segCtrl.widthAnchor.constraint(equalToConstant: 120),

            inputField.leadingAnchor.constraint(equalTo: segCtrl.trailingAnchor, constant: 8),
            inputField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            inputField.trailingAnchor.constraint(equalTo: sendBtn.leadingAnchor, constant: -8),
            inputField.heightAnchor.constraint(equalToConstant: 20),

            sendBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -L.pad),
            sendBtn.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            sendBtn.widthAnchor.constraint(equalToConstant: 42),
            sendBtn.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Table Click Handlers

    @objc private func featureTableClicked(_ sender: Any?) {
        let row = featureTableView.selectedRow
        controlsTableView?.deselectAll(nil)
        selectedControlCID = nil
        guard row >= 0, row < featureRows.count else { selectedFeatureId = nil; updateContextActions(); return }
        selectedFeatureId = featureRows[row].featureId
        updateContextActions()
    }

    @objc private func controlsTableClicked(_ sender: Any?) {
        let row = controlsTableView.selectedRow
        featureTableView?.deselectAll(nil)
        selectedFeatureId = nil
        guard row >= 0, row < controlRows.count else { selectedControlCID = nil; updateContextActions(); return }
        selectedControlCID = controlRows[row].cid
        updateContextActions()
    }

    private func updateContextActions() {
        guard let container = contextActionsContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        let w = container.bounds.width - L.pad * 2
        var by: CGFloat = 0

        if let featureId = selectedFeatureId {
            let actions = HIDPPFeatureActions.actions(for: featureId)
            for action in actions {
                let btn = makeActionBtn(title: action.name, action: #selector(featureActionClicked(_:)))
                btn.tag = Int(action.functionId)
                btn.frame = NSRect(x: L.pad, y: by, width: w, height: L.btnH)
                container.addSubview(btn)
                by += L.btnH + L.btnGap
            }
            by += 4
            let pf = NSTextField()
            pf.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            pf.placeholderString = "params (hex)"
            pf.frame = NSRect(x: L.pad, y: by, width: w, height: 22)
            pf.wantsLayer = true
            pf.layer?.cornerRadius = 3
            pf.textColor = .labelColor
            pf.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.08)
            pf.isBezeled = false
            container.addSubview(pf)
            self.paramInputField = pf
            by += 26

            let sl = makeLabel(text: "Index: 0", fontSize: 10, color: .secondaryLabelColor)
            sl.frame = NSRect(x: L.pad, y: by, width: 60, height: 18)
            container.addSubview(sl)
            self.indexStepperLabel = sl

            let stepper = NSStepper()
            stepper.minValue = 0
            stepper.maxValue = 255
            stepper.integerValue = 0
            stepper.target = self
            stepper.action = #selector(indexStepperChanged(_:))
            stepper.frame = NSRect(x: L.pad + 62, y: by, width: 19, height: 18)
            container.addSubview(stepper)
            self.indexStepper = stepper

        } else if let cid = selectedControlCID {
            let isDiverted = currentSession?.debugDivertedCIDs.contains(cid) ?? false
            let divertBtn = makeActionBtn(title: isDiverted ? "Undivert" : "Divert", action: #selector(toggleDivertClicked))
            divertBtn.frame = NSRect(x: L.pad, y: by, width: w, height: L.btnH)
            container.addSubview(divertBtn)
            by += L.btnH + L.btnGap

            let queryBtn = makeActionBtn(title: "Query Reporting", action: #selector(queryReportingClicked))
            queryBtn.frame = NSRect(x: L.pad, y: by, width: w, height: L.btnH)
            container.addSubview(queryBtn)
            by += L.btnH + L.btnGap + 4

            // Show current flags and target CID
            if let ctrl = controlRows.first(where: { $0.cid == cid }) {
                let flagsText = "Flags: \(HIDPPInfo.flagsDescription(ctrl.flags))"
                let fl = makeLabel(text: flagsText, fontSize: 9, color: .secondaryLabelColor)
                fl.frame = NSRect(x: L.pad, y: by, width: w, height: 14)
                container.addSubview(fl)
                by += 16

                if ctrl.targetCID != 0 && ctrl.targetCID != ctrl.cid {
                    let targetText = "Target: \(String(format: "0x%04X", ctrl.targetCID))"
                    let tl = makeLabel(text: targetText, fontSize: 9, color: .secondaryLabelColor)
                    tl.frame = NSRect(x: L.pad, y: by, width: w, height: 14)
                    container.addSubview(tl)
                }
            }
        } else {
            let ph = makeLabel(text: "Select a feature\nor control", fontSize: 10, color: .tertiaryLabelColor)
            ph.translatesAutoresizingMaskIntoConstraints = false
            ph.alignment = .center
            ph.maximumNumberOfLines = 2
            container.addSubview(ph)
            NSLayoutConstraint.activate([
                ph.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: L.pad),
                ph.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -L.pad),
                ph.topAnchor.constraint(equalTo: container.topAnchor, constant: L.pad),
            ])
        }
    }

    @objc private func indexStepperChanged(_ sender: NSStepper) {
        indexStepperLabel?.stringValue = "Index: \(sender.integerValue)"
    }

    // MARK: - Global Actions

    @objc private func rediscoverClicked() {
        currentSession?.rediscoverFeatures()
        refreshRightPanelsLoading()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.refreshRightPanels() }
    }

    @objc private func redivertClicked() {
        currentSession?.redivertAllControls()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshControls() }
    }

    @objc private func undivertClicked() {
        currentSession?.undivertAllControls()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshControls() }
    }

    @objc private func enumerateClicked() {
        currentSession?.enumerateReceiverDevices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.refreshSidebar()
            self?.refreshRightPanels()
        }
    }

    @objc private func clearLogClicked() {
        LogitechHIDDebugPanel.logBuffer.removeAll()
        logTableView?.reloadData()
    }

    // MARK: - Feature Actions

    @objc private func featureActionClicked(_ sender: NSButton) {
        guard let session = currentSession, let featureId = selectedFeatureId else { return }
        guard let featureIdx = session.debugFeatureIndex[featureId] else {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .warning,
                                      message: "Feature 0x\(String(format: "%04X", featureId)) not indexed")
            return
        }
        let functionId = UInt8(sender.tag)
        var params = [UInt8](repeating: 0, count: 16)

        let actions = HIDPPFeatureActions.actions(for: featureId)
        if let action = actions.first(where: { $0.functionId == functionId }) {
            switch action.paramType {
            case .none: break
            case .index:
                params[0] = UInt8(indexStepper?.integerValue ?? 0)
            case .hex:
                if let hexStr = paramInputField?.stringValue, !hexStr.isEmpty {
                    let bytes = hexStr.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                    for (i, b) in bytes.prefix(16).enumerated() { params[i] = b }
                } else {
                    for (i, b) in action.defaultParams.prefix(16).enumerated() { params[i] = b }
                }
            }
        }
        sendDebugPacket(session: session, featureIndex: featureIdx, functionId: functionId, params: params)
    }

    @objc private func toggleDivertClicked() {
        guard let session = currentSession, let cid = selectedControlCID else { return }
        session.toggleDivert(cid: cid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshControls()
            self?.updateContextActions()
        }
    }

    @objc private func queryReportingClicked() {
        guard let session = currentSession, let cid = selectedControlCID else { return }
        guard let reprogIdx = session.debugFeatureIndex[0x1B04] else { return }
        let params: [UInt8] = [UInt8(cid >> 8), UInt8(cid & 0xFF)] + [UInt8](repeating: 0, count: 14)
        sendDebugPacket(session: session, featureIndex: reprogIdx, functionId: 2, params: params)
    }

    private func sendDebugPacket(session: LogitechDeviceSession, featureIndex: UInt8, functionId: UInt8, params: [UInt8]) {
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = 0x11
        report[1] = session.debugDeviceIndex
        report[2] = featureIndex
        report[3] = (functionId << 4) | 0x01
        for (i, p) in params.prefix(16).enumerated() { report[4 + i] = p }

        let hex = report.map { String(format: "%02X", $0) }.joined(separator: " ")
        LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .tx, message: "TX: \(hex)", rawBytes: report)

        let result = IOHIDDeviceSetReport(session.hidDevice, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
        if result != kIOReturnSuccess {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .error,
                                      message: "IOHIDDeviceSetReport failed: \(String(format: "0x%08X", result))")
        }
    }

    // MARK: - Log Actions

    @objc private func filterChipClicked(_ sender: NSButton) {
        let chipOrder: [LogEntryType] = [.tx, .rx, .error, .buttonEvent, .warning, .info]
        guard sender.tag >= 0, sender.tag < chipOrder.count else { return }
        let type = chipOrder[sender.tag]
        if logTypeFilter.contains(type) {
            logTypeFilter.remove(type)
            sender.layer?.opacity = 0.3
        } else {
            logTypeFilter.insert(type)
            sender.layer?.opacity = 1.0
        }
        logTableView?.reloadData()
    }

    @objc private func logRowClicked(_ sender: Any?) {
        let row = logTableView.clickedRow
        let filtered = filteredLogEntries()
        guard row >= 0, row < filtered.count else { return }
        let bufferIdx = filtered[row].0
        LogitechHIDDebugPanel.logBuffer[bufferIdx].isExpanded.toggle()
        logTableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        logTableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    @objc private func exportLogClicked() {
        guard let win = window else { return }
        let panel = NSSavePanel()
        let dateStr: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd-HHmmss"
            return fmt.string(from: Date())
        }()
        panel.nameFieldStringValue = "hidpp-debug-\(dateStr).log"
        panel.beginSheetModal(for: win) { response in
            guard response == .OK, let url = panel.url else { return }
            var output = ""
            for entry in LogitechHIDDebugPanel.logBuffer {
                let dev = entry.deviceName.isEmpty ? "" : "[\(entry.deviceName)] "
                output += "[\(entry.timestamp)] \(dev)[\(entry.type.rawValue)] \(entry.message)\n"
                if let decoded = entry.decoded { output += "  > \(decoded)\n" }
                if let raw = entry.rawBytes {
                    output += "  HEX: \(raw.map { String(format: "%02X", $0) }.joined(separator: " "))\n"
                }
            }
            try? output.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func sendRawClicked() {
        guard let session = currentSession else { return }
        guard session.debugDeviceOpened else {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .warning, message: "Device not opened")
            return
        }
        let hexStr = rawInputField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !hexStr.isEmpty else { return }
        let bytes = hexStr.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty else {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .warning, message: "Invalid hex input")
            return
        }

        let isLong = reportTypeControl.selectedSegment == 1
        let reportLen = isLong ? 20 : 7
        var report = [UInt8](repeating: 0, count: reportLen)
        report[0] = isLong ? 0x11 : 0x10
        let srcBytes: [UInt8] = (bytes.first == 0x10 || bytes.first == 0x11) ? Array(bytes.dropFirst()) : bytes
        for (i, b) in srcBytes.prefix(reportLen - 1).enumerated() { report[1 + i] = b }

        let hex = report.map { String(format: "%02X", $0) }.joined(separator: " ")
        LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .tx, message: "TX: \(hex)", rawBytes: report)

        let result = IOHIDDeviceSetReport(session.hidDevice, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count)
        if result != kIOReturnSuccess {
            LogitechHIDDebugPanel.log(device: session.deviceInfo.name, type: .error,
                                      message: "IOHIDDeviceSetReport failed: \(String(format: "0x%08X", result))")
        }
    }

    private func filteredLogEntries() -> [(Int, LogEntry)] {
        return LogitechHIDDebugPanel.logBuffer.enumerated().filter { logTypeFilter.contains($0.element.type) }
    }

    // MARK: - Refresh

    private func refreshAll() {
        refreshSidebar()
        refreshDeviceInfo()
        refreshFeatureTable()
        refreshControls()
        updateContextActions()
        logTableView?.reloadData()
    }

    private func refreshRightPanels() {
        refreshDeviceInfo()
        refreshFeatureTable()
        refreshControls()
        updateContextActions()
    }

    private func refreshRightPanelsLoading() {
        featureRows.removeAll()
        controlRows.removeAll()
        featureTableView?.reloadData()
        controlsTableView?.reloadData()
        updateHeaderLabel(tag: 100, text: "FEATURES (...)")
        updateHeaderLabel(tag: 101, text: "CONTROLS (...)")
        updateContextActions()
    }

    private func currentSidebarSelection() -> SidebarSelection? {
        guard let outlineView = outlineView else { return nil }
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        if let node = outlineView.item(atRow: row) as? DeviceNode {
            return .device(sessionID: ObjectIdentifier(node.session))
        }
        if let node = outlineView.item(atRow: row) as? SlotNode {
            return .slot(sessionID: ObjectIdentifier(node.session), slot: node.slot)
        }
        return nil
    }

    private func row(for selection: SidebarSelection, in outlineView: NSOutlineView) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? DeviceNode {
                if case let .device(sessionID) = selection, ObjectIdentifier(node.session) == sessionID {
                    return row
                }
                continue
            }
            if let node = outlineView.item(atRow: row) as? SlotNode,
               case let .slot(sessionID, slot) = selection,
               ObjectIdentifier(node.session) == sessionID,
               node.slot == slot {
                return row
            }
        }
        return nil
    }

    private func refreshSidebar() {
        let sessions = LogitechHIDManager.shared.activeSessions
        let previousSessionIDs = Set(deviceNodes.map { ObjectIdentifier($0.session) })
        let expandedSessionIDs: Set<ObjectIdentifier>
        let selectedItem = currentSidebarSelection()
        if let outlineView = outlineView {
            expandedSessionIDs = Set(deviceNodes.compactMap { node in
                outlineView.isItemExpanded(node) ? ObjectIdentifier(node.session) : nil
            })
        } else {
            expandedSessionIDs = []
        }
        deviceNodes = sessions
            .filter { $0.connectionMode != .unsupported }
            .map { DeviceNode(session: $0) }
        outlineView?.reloadData()
        for node in deviceNodes where node.isReceiver {
            let sessionID = ObjectIdentifier(node.session)
            if expandedSessionIDs.contains(sessionID) || !previousSessionIDs.contains(sessionID) {
                outlineView?.expandItem(node)
            }
        }
        // If current session disconnected, select first remaining device and clear selection state
        if let cs = currentSession, !sessions.contains(where: { $0 === cs }) {
            currentSession = deviceNodes.first?.session
            selectedFeatureId = nil
            selectedControlCID = nil
        }
        if currentSession == nil {
            currentSession = deviceNodes.first?.session
            selectedFeatureId = nil
            selectedControlCID = nil
        }
        if let outlineView = outlineView {
            if let selectedItem = selectedItem, let row = row(for: selectedItem, in: outlineView) {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else if let currentSession = currentSession,
                      let row = row(for: .device(sessionID: ObjectIdentifier(currentSession)), in: outlineView) {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                outlineView.deselectAll(nil)
            }
        }
    }

    private func refreshDeviceInfo() {
        guard let s = currentSession else {
            for pair in deviceInfoLabels { pair.value.stringValue = "--" }
            for pair in moreInfoLabels { pair.value.stringValue = "--" }
            return
        }
        let vals: [String] = [
            String(format: "0x%04X", s.deviceInfo.vendorId),
            String(format: "0x%04X", s.deviceInfo.productId),
            s.debugFeatureIndex.isEmpty ? "--" : "4.x",
            s.transport,
            String(format: "0x%02X", s.debugDeviceIndex),
            s.debugConnectionMode,
            s.debugDeviceOpened ? "\u{2713}" : "\u{2717}",
        ]
        for (i, val) in vals.enumerated() where i < deviceInfoLabels.count {
            deviceInfoLabels[i].value.stringValue = val
        }
        let moreVals: [String] = [
            String(format: "0x%04X", s.usagePage),
            String(format: "0x%04X", s.usage),
            s.isHIDPPCandidate ? "Yes" : "No",
            s.debugReprogInitComplete ? "Yes" : "No",
            "\(s.debugDivertedCIDs.count)",
        ]
        for (i, val) in moreVals.enumerated() where i < moreInfoLabels.count {
            moreInfoLabels[i].value.stringValue = val
        }
    }

    private func refreshFeatureTable() {
        guard let s = currentSession else {
            featureRows.removeAll()
            featureTableView?.reloadData()
            return
        }
        featureRows = s.debugFeatureIndex.sorted(by: { $0.value < $1.value }).map { (featureId, index) in
            let name = HIDPPInfo.featureNames[featureId]?.0 ?? "Unknown"
            return (index: String(format: "0x%02X", index), featureId: featureId,
                    featureIdHex: String(format: "0x%04X", featureId), name: name)
        }
        featureTableView?.reloadData()
        updateHeaderLabel(tag: 100, text: "FEATURES (\(featureRows.count))")
    }

    private func refreshControls() {
        guard let s = currentSession else {
            controlRows.removeAll()
            controlsTableView?.reloadData()
            return
        }
        controlRows = s.debugDiscoveredControls
        controlsTableView?.reloadData()
        updateHeaderLabel(tag: 101, text: "CONTROLS (\(controlRows.count))")
    }

    private func updateHeaderLabel(tag: Int, text: String) {
        func find(in view: NSView) -> NSTextField? {
            if let tf = view as? NSTextField, tf.tag == tag { return tf }
            for sub in view.subviews { if let f = find(in: sub) { return f } }
            return nil
        }
        if let cv = window?.contentView, let lbl = find(in: cv) { lbl.stringValue = text }
    }

    // MARK: - Observers

    private func startObserving() {
        stopObserving()
        logObserver = NotificationCenter.default.addObserver(
            forName: LogitechHIDDebugPanel.logNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.logTableView?.reloadData()
            // Auto-scroll only if user is near the bottom
            if let sv = self.logTableView?.enclosingScrollView {
                let visibleH = sv.contentView.bounds.height
                let contentH = self.logTableView?.frame.height ?? 0
                let scrollY = sv.contentView.bounds.origin.y
                let isNearBottom = (contentH - scrollY - visibleH) < 40
                if isNearBottom {
                    let count = self.filteredLogEntries().count
                    if count > 0 { self.logTableView?.scrollRowToVisible(count - 1) }
                }
            }
            if let entry = notification.object as? LogEntry,
               entry.type == .buttonEvent || entry.message.contains("divert") {
                self.refreshControls()
            }
        }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: LogitechHIDManager.sessionChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshAll() }
        reportingCompleteObserver = NotificationCenter.default.addObserver(
            forName: LogitechHIDManager.reportingQueryDidCompleteNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshRightPanels() }
    }

    private func stopObserving() {
        if let o = logObserver { NotificationCenter.default.removeObserver(o); logObserver = nil }
        if let o = sessionObserver { NotificationCenter.default.removeObserver(o); sessionObserver = nil }
        if let o = reportingCompleteObserver {
            NotificationCenter.default.removeObserver(o)
            reportingCompleteObserver = nil
        }
        // Layout observers (frame change) are not tracked here — they're tied to the views
        // and auto-removed when the views are deallocated.
    }

    // MARK: - Helpers

    private func makeLabel(text: String, fontSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        l.textColor = color
        l.backgroundColor = .clear
        l.isBezeled = false
        l.isEditable = false
        l.isSelectable = false
        return l
    }

    private func makeCenteredTableCell(in tableView: NSTableView,
                                       identifier: NSUserInterfaceItemIdentifier,
                                       font: NSFont) -> NSTableCellView {
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let view = NSTableCellView()
            view.identifier = identifier

            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.backgroundColor = .clear
            label.isBezeled = false
            label.isEditable = false
            label.isSelectable = false
            view.textField = label
            view.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])

            return view
        }()

        let label = cell.textField ?? NSTextField(labelWithString: "")
        label.font = font
        return cell
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        return makeLabel(text: title, fontSize: 10, weight: .medium, color: .tertiaryLabelColor)
    }

    private func makeActionBtn(title: String, action: Selector,
                               color: NSColor = NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        btn.layer?.borderColor = color.withAlphaComponent(0.3).cgColor
        btn.layer?.borderWidth = 1
        btn.layer?.cornerRadius = 4
        btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        if #available(macOS 10.14, *) { btn.contentTintColor = .labelColor }
        return btn
    }

    private func configureDarkScroll(_ sv: NSScrollView) {
        sv.scrollerStyle = .overlay
        sv.scrollerKnobStyle = .light
        sv.hasVerticalScroller = true
        sv.borderType = .noBorder
        sv.drawsBackground = false
    }

    private func makeSep() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.1).cgColor
        return v
    }

    private var blockCornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 10 }
        return 5
    }

    private func makeSectionBg() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.05).cgColor
        v.layer?.cornerRadius = blockCornerRadius
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor
        return v
    }

    private func makeLogBg() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0.4).cgColor
        v.layer?.cornerRadius = blockCornerRadius
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor
        return v
    }

    private func logColor(for type: LogEntryType) -> NSColor {
        switch type {
        case .tx: return NSColor(calibratedRed: 0.4, green: 0.6, blue: 1.0, alpha: 1.0)
        case .rx: return NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)
        case .error: return NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 1.0)
        case .buttonEvent: return NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
        case .warning: return NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)
        case .info: return NSColor(calibratedWhite: 0.75, alpha: 1.0)
        }
    }
}

// MARK: - NSOutlineViewDataSource & Delegate

extension LogitechHIDDebugPanel: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return deviceNodes.count }
        if let node = item as? DeviceNode, node.isReceiver {
            return node.session.debugReceiverPairedDevices.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return deviceNodes[index] }
        if let node = item as? DeviceNode, node.isReceiver {
            let paired = node.session.debugReceiverPairedDevices[index]
            return SlotNode(session: node.session, slot: paired.slot)
        }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        return (item as? DeviceNode)?.isReceiver ?? false
    }
}

extension LogitechHIDDebugPanel: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cellId = NSUserInterfaceItemIdentifier("DeviceCell")
        let cell = makeCenteredTableCell(in: outlineView, identifier: cellId, font: NSFont.systemFont(ofSize: 11))
        guard let label = cell.textField else { return cell }

        if let node = item as? DeviceNode {
            let prefix = node.isReceiver ? "[R]" : "[M]"
            let session = node.session

            // 根据 usagePage/usage 推出接口角色 (区分同 receiver 下的多个 HID 接口)
            let role: String
            switch (session.usagePage, session.usage) {
            case (0x0001, 0x0002): role = "mouse"
            case (0x0001, 0x0006): role = "kbd"
            case (0x0001, 0x0001): role = "pointer"
            case (0x0001, 0x0080): role = "sys"
            case (0x000C, _):      role = "consumer"
            case (0xFF00, _), (0xFF43, _), (0xFFC0, _): role = "vendor"
            default: role = String(format: "%04X/%02X", session.usagePage, session.usage)
            }

            let nameFont = NSFont.systemFont(ofSize: 11)
            let badgeFont = NSFont.systemFont(ofSize: 10)
            let badgeFontBold = NSFont.systemFont(ofSize: 10, weight: .medium)

            let primaryText = node.isReceiver ? prefix : "\(prefix) \(session.deviceInfo.name)"
            let attr = NSMutableAttributedString(
                string: primaryText,
                attributes: [.foregroundColor: NSColor.labelColor, .font: nameFont]
            )
            attr.append(NSAttributedString(
                string: "  \(role)",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: badgeFont]
            ))
            if session.isHIDPPCandidate {
                attr.append(NSAttributedString(
                    string: " · ",
                    attributes: [.foregroundColor: NSColor.quaternaryLabelColor, .font: badgeFont]
                ))
                attr.append(NSAttributedString(
                    string: "HID++",
                    attributes: [.foregroundColor: NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.0, alpha: 0.9),
                                 .font: badgeFontBold]
                ))
            }
            attr.append(NSAttributedString(string: " "))
            attr.append(NSAttributedString(
                string: "\u{25CF}",
                attributes: [.foregroundColor: NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0),
                             .font: NSFont.systemFont(ofSize: 8)]
            ))
            label.attributedStringValue = attr
        } else if let slot = item as? SlotNode {
            let paired = slot.session.debugReceiverPairedDevices
            let idx = Int(slot.slot) - 1
            guard idx >= 0, idx < paired.count else {
                label.stringValue = "Slot \(slot.slot): --"
                label.textColor = .tertiaryLabelColor
                return cell
            }
            let dev = paired[idx]
            if dev.isConnected {
                label.stringValue = dev.name.isEmpty ? "Slot \(dev.slot)" : dev.name
                label.textColor = .labelColor
            } else {
                label.stringValue = "Slot \(dev.slot): empty"
                label.textColor = .tertiaryLabelColor
            }
        }
        return cell
    }
}

// MARK: - NSTableViewDataSource & Delegate

extension LogitechHIDDebugPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView.tag {
        case 200: return featureRows.count
        case 201: return controlRows.count
        case 300: return filteredLogEntries().count
        default: return 0
        }
    }
}

extension LogitechHIDDebugPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch tableView.tag {
        case 200: return featureCell(tableColumn: tableColumn, row: row)
        case 201: return controlCell(tableColumn: tableColumn, row: row)
        case 300: return logCell(row: row)
        default: return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView.tag == 300 {
            let filtered = filteredLogEntries()
            guard row < filtered.count else { return 18 }
            let entry = filtered[row].1
            if entry.isExpanded {
                var lines = 1
                if entry.rawBytes != nil { lines += 1 }
                if entry.decoded != nil { lines += 1 }
                return CGFloat(lines) * 16 + 4
            }
        }
        return tableView.tag == 300 ? 18 : 20
    }

    private func featureCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < featureRows.count else { return nil }
        let item = featureRows[row]
        let cellId = NSUserInterfaceItemIdentifier("fCell")
        let cell = makeCenteredTableCell(
            in: featureTableView,
            identifier: cellId,
            font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        )
        guard let label = cell.textField else { return cell }
        label.textColor = .labelColor

        switch tableColumn?.identifier.rawValue {
        case "fIdx": label.stringValue = item.index
        case "fId": label.stringValue = item.featureIdHex
        case "fName":
            label.stringValue = item.name
            label.textColor = NSColor(calibratedRed: 0.5, green: 0.7, blue: 1.0, alpha: 1.0)
        default: break
        }
        return cell
    }

    private func controlCell(tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < controlRows.count else { return nil }
        let ctrl = controlRows[row]
        let cellId = NSUserInterfaceItemIdentifier("cCell")
        let cell = makeCenteredTableCell(
            in: controlsTableView,
            identifier: cellId,
            font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        )
        guard let label = cell.textField else { return cell }
        label.textColor = .labelColor

        // 方案 B: reportingFlags 永远反映设备响应的真值 (Mos 不污染),
        // 所以 reportingFlags 非零 = 第三方 (Options+ 等) 的 tmpDivert / persistDivert;
        // targetCID != 0 = 第三方 remap (Mos 从不 remap);
        // Mos 自己的 divert 视角通过 divertedCIDs 集合单独表达.
        let isForeignDivert = ctrl.reportingFlags != 0
        // self-remap (targetCID == cid) 是 Logitech 默认的 identity mapping, 不算 remap
        let isRemapped = ctrl.targetCID != 0 && ctrl.targetCID != ctrl.cid
        let isMosDivert = currentSession?.debugDivertedCIDs.contains(ctrl.cid) ?? false

        switch tableColumn?.identifier.rawValue {
        case "cCid": label.stringValue = String(format: "0x%04X", ctrl.cid)
        case "cName": label.stringValue = LogitechCIDRegistry.name(forCID: ctrl.cid)
        case "cFlags":
            label.stringValue = HIDPPInfo.flagsDescription(ctrl.flags)
            label.textColor = .secondaryLabelColor
        case "cStatus":
            if isForeignDivert {
                // 第三方 tmpDivert / persistDivert -> 冲突信号, 红色
                label.stringValue = "3rd-DVRT"
                label.textColor = NSColor(calibratedRed: 1.0, green: 0.3, blue: 0.3, alpha: 0.9)
            } else if isRemapped {
                // 第三方 remap -> 黄色
                label.stringValue = "REMAP"
                label.textColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 0.8)
            } else if isMosDivert {
                // Mos 自己 divert -> 橘色
                label.stringValue = "DVRT"
                label.textColor = NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.0, alpha: 0.8)
            } else {
                label.stringValue = "\u{25CF}"
                label.textColor = NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)
            }
        default: break
        }
        return cell
    }

    private func logCell(row: Int) -> NSView? {
        let filtered = filteredLogEntries()
        guard row < filtered.count else { return nil }
        let entry = filtered[row].1

        let cellId = NSUserInterfaceItemIdentifier("logCell")
        let cell = logTableView.makeView(withIdentifier: cellId, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = cellId
        cell.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cell.backgroundColor = .clear
        cell.isBezeled = false
        cell.isEditable = false
        cell.isSelectable = true
        cell.maximumNumberOfLines = 0
        cell.cell?.wraps = true

        let color = logColor(for: entry.type)
        let arrow = entry.isExpanded ? "\u{25BE}" : "\u{25B8}"
        var text = "\(arrow) [\(entry.timestamp)] \(entry.message)"
        if entry.isExpanded {
            if let raw = entry.rawBytes {
                text += "\n  HEX: \(raw.map { String(format: "%02X", $0) }.joined(separator: " "))"
            }
            if let decoded = entry.decoded { text += "\n  \(decoded)" }
        }
        cell.attributedStringValue = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        ])
        return cell
    }
}
