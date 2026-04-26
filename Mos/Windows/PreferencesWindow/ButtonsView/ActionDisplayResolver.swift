//
//  ActionDisplayResolver.swift
//  Mos
//

import Cocoa

enum ActionPresentationKind: Equatable {
    case unbound
    case recordingPrompt
    case namedAction
    case keyCombo
    case openTarget
}

struct ActionPresentation {
    let kind: ActionPresentationKind
    let title: String
    let symbolName: String?
    let image: NSImage?
    let badgeComponents: [String]
    let brand: BrandTagConfig?

    init(
        kind: ActionPresentationKind,
        title: String,
        symbolName: String? = nil,
        image: NSImage? = nil,
        badgeComponents: [String] = [],
        brand: BrandTagConfig? = nil
    ) {
        self.kind = kind
        self.title = title
        self.symbolName = symbolName
        self.image = image
        self.badgeComponents = badgeComponents
        self.brand = brand
    }
}

struct ActionDisplayResolver {

    func resolve(
        shortcut: SystemShortcut.Shortcut?,
        customBindingName: String?,
        isRecording: Bool,
        openTarget: OpenTargetPayload? = nil
    ) -> ActionPresentation {
        if isRecording {
            return ActionPresentation(
                kind: .recordingPrompt,
                title: NSLocalizedString("custom-recording-prompt", comment: "")
            )
        }

        if let openTarget {
            return openTargetPresentation(for: openTarget)
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
            title: NSLocalizedString("unbound", comment: "")
        )
    }

    private func namedActionPresentation(for shortcut: SystemShortcut.Shortcut) -> ActionPresentation {
        ActionPresentation(
            kind: .namedAction,
            title: shortcut.localizedName,
            symbolName: shortcut.symbolName,
            brand: BrandTag.brandForAction(shortcut.identifier)
        )
    }

    private func openTargetPresentation(for payload: OpenTargetPayload) -> ActionPresentation {
        let workspace = NSWorkspace.shared
        let resolvedURL: URL? = {
            if let bundleID = payload.bundleID,
               let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
            let url = URL(fileURLWithPath: payload.path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }()

        let title: String
        let icon: NSImage?
        if let url = resolvedURL {
            if payload.isApplication, let bundle = Bundle(url: url) {
                title = bundle.localizedDisplayName
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
            } else {
                title = url.lastPathComponent
            }
            icon = workspace.icon(forFile: url.path)
        } else {
            // Stale path: show filename + unavailable marker
            let basename = (payload.path as NSString).lastPathComponent
            let staleTag = NSLocalizedString("open-target-placeholder-stale", comment: "")
            title = basename.isEmpty ? staleTag : "\(basename) \(staleTag)"
            icon = nil
        }

        return ActionPresentation(
            kind: .openTarget,
            title: title,
            symbolName: nil,
            image: icon
        )
    }

    private func customBindingPresentation(for customBindingName: String) -> ActionPresentation? {
        guard let (code, modifiers) = ButtonBinding.normalizedCustomBindingPayload(from: customBindingName) else {
            return nil
        }

        let brand = BrandTag.brandForCode(code)
        if let brand, modifiers == 0, LogiCenter.shared.isLogiCode(code) {
            return ActionPresentation(
                kind: .namedAction,
                title: (LogiCenter.shared.name(forMosCode: code) ?? ""),
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

extension Bundle {
    var localizedDisplayName: String? {
        return localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? localizedInfoDictionary?["CFBundleName"] as? String
    }
}
