//
//  ActionDisplayResolver.swift
//  Mos
//
//  Created by Mos on 2026/4/12.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

enum ActionPresentationKind: Equatable {
    case unbound
    case recordingPrompt
    case namedAction
    case keyCombo
}

struct ActionPresentation {
    let kind: ActionPresentationKind
    let title: String
    let symbolName: String?
    let badgeComponents: [String]
    let brand: BrandTagConfig?
}

struct ActionDisplayResolver {

    func resolve(
        shortcut: SystemShortcut.Shortcut?,
        customBindingName: String?,
        isRecording: Bool
    ) -> ActionPresentation {
        if isRecording {
            return ActionPresentation(
                kind: .recordingPrompt,
                title: NSLocalizedString("custom-recording-prompt", comment: ""),
                symbolName: nil,
                badgeComponents: [],
                brand: nil
            )
        }

        if let shortcut {
            return namedActionPresentation(for: shortcut)
        }

        if let customBindingName {
            if let shortcut = SystemShortcut.displayShortcut(matchingBindingName: customBindingName) {
                return namedActionPresentation(for: shortcut)
            }

            if let customPresentation = customBindingPresentation(for: customBindingName) {
                return customPresentation
            }
        }

        return ActionPresentation(
            kind: .unbound,
            title: NSLocalizedString("unbound", comment: ""),
            symbolName: nil,
            badgeComponents: [],
            brand: nil
        )
    }

    private func namedActionPresentation(for shortcut: SystemShortcut.Shortcut) -> ActionPresentation {
        ActionPresentation(
            kind: .namedAction,
            title: shortcut.localizedName,
            symbolName: shortcut.symbolName,
            badgeComponents: [],
            brand: BrandTag.brandForAction(shortcut.identifier)
        )
    }

    private func customBindingPresentation(for customBindingName: String) -> ActionPresentation? {
        guard let (code, modifiers) = ButtonBinding.normalizedCustomBindingPayload(from: customBindingName) else {
            return nil
        }

        let brand = BrandTag.brandForCode(code)
        if let brand, modifiers == 0, LogiCIDDirectory.isLogitechCode(code) {
            return ActionPresentation(
                kind: .namedAction,
                title: LogiCIDDirectory.name(forMosCode: code),
                symbolName: nil,
                badgeComponents: [],
                brand: brand
            )
        }

        let event = InputEvent(
            type: inputType(for: code),
            code: code,
            modifiers: CGEventFlags(rawValue: modifiers),
            phase: .down,
            source: .hidPP,
            device: nil
        )
        let marker = brand.map { "[\($0.name)]" }
        let badgeComponents = event.displayComponents.filter { component in
            guard let marker else { return true }
            return component != marker
        }

        return ActionPresentation(
            kind: .keyCombo,
            title: "",
            symbolName: nil,
            badgeComponents: badgeComponents,
            brand: brand
        )
    }

    private func inputType(for code: UInt16) -> EventType {
        if KeyCode.modifierKeys.contains(code) {
            return .keyboard
        }
        return code >= 0x100 ? .mouse : .keyboard
    }
}
