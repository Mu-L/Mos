//
//  LogiStandardMouseButtonAlias.swift
//  Mos
//

import Cocoa

/// Standard HID++ mouse controls that can be treated as stable macOS mouse
/// button triggers.
enum LogiStandardMouseButtonAlias {
    static func nativeButtonCode(forMosCode code: UInt16) -> UInt16? {
        return LogiCenter.shared.nativeMouseButton(forMosCode: code)
    }

    static func convertedRecordedEvent(from event: RecordedEvent) -> RecordedEvent? {
        guard event.type == .mouse else {
            return nil
        }
        guard let nativeCode = nativeButtonCode(forMosCode: event.code) else {
            return nil
        }

        return RecordedEvent(
            type: .mouse,
            code: nativeCode,
            modifiers: event.modifiers,
            displayComponents: displayComponents(code: nativeCode, modifiers: event.modifiers),
            deviceFilter: nil
        )
    }

    static func convertedBinding(from binding: ButtonBinding) -> ButtonBinding? {
        guard let nativeTrigger = convertedRecordedEvent(from: binding.triggerEvent) else {
            return nil
        }
        return binding.replacingTriggerEvent(nativeTrigger)
    }

    private static func displayComponents(code: UInt16, modifiers: UInt) -> [String] {
        var modSymbols: [String] = []
        if modifiers & UInt(CGEventFlags.maskShift.rawValue) != 0 { modSymbols.append("⇧") }
        if modifiers & UInt(CGEventFlags.maskSecondaryFn.rawValue) != 0 { modSymbols.append("Fn") }
        if modifiers & UInt(CGEventFlags.maskControl.rawValue) != 0 { modSymbols.append("⌃") }
        if modifiers & UInt(CGEventFlags.maskAlternate.rawValue) != 0 { modSymbols.append("⌥") }
        if modifiers & UInt(CGEventFlags.maskCommand.rawValue) != 0 { modSymbols.append("⌘") }

        var components: [String] = []
        if !modSymbols.isEmpty {
            components.append(modSymbols.joined(separator: " "))
        }
        components.append(KeyCode.mouseMap[code] ?? "Mouse(\(code))")
        return components
    }
}
