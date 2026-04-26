//
//  LogiSelfTestWizard.swift
//  Mos
//
//  DEBUG-only AppKit window hosting the Logi Self-Test Wizard. Skeleton:
//  opens a minimal placeholder window. Full step UI lands in a follow-up.
//

#if DEBUG
import Cocoa

final class LogiSelfTestWizard {

    static let shared = LogiSelfTestWizard()
    private init() {}

    private var window: NSWindow?
    private let runner = LogiSelfTestRunner()

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Logi Self-Test"
        win.center()

        let content = NSView(frame: win.contentRect(forFrameRect: win.frame))
        let label = NSTextField(labelWithString: detectionSummary())
        label.frame = content.bounds.insetBy(dx: 20, dy: 20)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.autoresizingMask = [.width, .height]
        content.addSubview(label)
        win.contentView = content

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func detectionSummary() -> String {
        guard let detected = runner.detectConnection() else {
            return "No Logi HID++ session reachable.\n\nConnect a Logi mouse via Bolt receiver or BLE and re-open this wizard."
        }
        switch detected {
        case let .bolt(snapshot, slot, name):
            return "Detected Bolt connection.\n\nDevice: \(name)\nSlot: \(slot)\nConnection: \(snapshot.connectionMode)\n\n(Step suite implementation pending.)"
        case let .bleDirect(snapshot, name):
            return "Detected BLE direct connection.\n\nDevice: \(name)\nConnection: \(snapshot.connectionMode)\n\n(Step suite implementation pending.)"
        }
    }
}
#endif
