import XCTest
@testable import Mos_Debug

private final class ShortcutMenuTestTarget: NSObject {
    @objc func noop(_ sender: Any?) {}
}

final class ButtonBindingTests: XCTestCase {

    private func makeResolvedPresentation(
        shortcut: SystemShortcut.Shortcut? = nil,
        customBindingName: String? = nil,
        isRecording: Bool = false
    ) -> ActionPresentation {
        ActionDisplayResolver().resolve(
            shortcut: shortcut,
            customBindingName: customBindingName,
            isRecording: isRecording
        )
    }

    private func makeButtonCell(binding: ButtonBinding) -> ButtonTableCellView {
        let cell = ButtonTableCellView(frame: NSRect(x: 0, y: 0, width: 420, height: 44))
        let keyContainer = NSView(frame: NSRect(x: 0, y: 0, width: 140, height: 44))
        let actionButton = NSPopUpButton(frame: NSRect(x: 180, y: 8, width: 180, height: 28), pullsDown: false)

        cell.keyDisplayContainerView = keyContainer
        cell.actionPopUpButton = actionButton
        cell.addSubview(keyContainer)
        cell.addSubview(actionButton)

        cell.configure(
            with: binding,
            onShortcutSelected: { _ in },
            onCustomShortcutRecorded: { _ in },
            onDeleteRequested: {}
        )

        return cell
    }

    private func flushMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    private func advanceMainRunLoop(by interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func makeActionPopupButton() -> NSPopUpButton {
        let actionButton = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 28), pullsDown: false)
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        actionButton.menu = menu
        return actionButton
    }

    func testPrepareCustomCache_regularKey() {
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::40:1048576"
        )
        binding.prepareCustomCache()
        XCTAssertEqual(binding.cachedCustomCode, 40)
        XCTAssertEqual(binding.cachedCustomModifiers, 1048576)
    }

    func testPrepareCustomCache_modifierKey_stripsRedundantFlag() {
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::56:131072"
        )
        binding.prepareCustomCache()
        XCTAssertEqual(binding.cachedCustomCode, 56)
        XCTAssertEqual(binding.cachedCustomModifiers, 0)
    }

    func testPrepareCustomCache_nonCustomBinding() {
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "missionControl"
        )
        binding.prepareCustomCache()
        XCTAssertNil(binding.cachedCustomCode)
        XCTAssertNil(binding.cachedCustomModifiers)
    }

    func testPrepareCustomCache_invalidFormat() {
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::abc:xyz"
        )
        binding.prepareCustomCache()
        XCTAssertNil(binding.cachedCustomCode)
        XCTAssertNil(binding.cachedCustomModifiers)
    }

    func testPrepareCustomCache_masksIrrelevantModifierFlags() {
        let rawModifiers = UInt64(NSEvent.ModifierFlags.command.union(.shift).rawValue) | (1 << 24)
        var binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::21:\(rawModifiers)"
        )

        binding.prepareCustomCache()

        XCTAssertEqual(binding.cachedCustomCode, 21)
        XCTAssertEqual(
            binding.cachedCustomModifiers,
            UInt64(NSEvent.ModifierFlags.command.union(.shift).rawValue)
        )
    }

    func testInit_withCreatedAt_preservesTimestamp() {
        let pastDate = Date(timeIntervalSince1970: 1000000)
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "test",
            createdAt: pastDate
        )
        XCTAssertEqual(binding.createdAt, pastDate)
    }

    func testInit_defaultCreatedAt_usesNow() {
        let before = Date()
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "test"
        )
        let after = Date()
        XCTAssertGreaterThanOrEqual(binding.createdAt, before)
        XCTAssertLessThanOrEqual(binding.createdAt, after)
    }

    func testCodableRoundtrip_preservesFields() {
        let original = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::56:0"
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(ButtonBinding.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.systemShortcutName, "custom::56:0")
        XCTAssertNil(decoded.cachedCustomCode)
    }

    func testEquatable_ignoresTransientCache() {
        var a = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::56:0"
        )
        let b = a
        a.prepareCustomCache()
        XCTAssertEqual(a, b)
    }

    func testPredefinedModifierShortcut_matchesEquivalentCustomBinding() {
        XCTAssertEqual(
            SystemShortcut.predefinedModifierShortcut(matchingCustomBinding: "custom::56:0")?.identifier,
            "modifierShift"
        )
        XCTAssertEqual(
            SystemShortcut.predefinedModifierShortcut(matchingCustomBinding: "custom::56:131072")?.identifier,
            "modifierShift"
        )
        XCTAssertEqual(
            SystemShortcut.predefinedModifierShortcut(matchingCustomBinding: "custom::58:524288")?.identifier,
            "modifierOption"
        )
        XCTAssertNil(SystemShortcut.predefinedModifierShortcut(matchingCustomBinding: "custom::58:131072"))
    }

    func testDisplayShortcut_matchesUniqueCustomBindingEquivalent() {
        let modifiers = UInt64(NSEvent.ModifierFlags.command.union(.shift).rawValue)
        XCTAssertEqual(
            SystemShortcut.displayShortcut(matchingBindingName: "custom::21:\(modifiers)")?.identifier,
            "screenshotSelection"
        )
    }

    func testDisplayShortcut_matchesUniqueCustomBindingEquivalentWithIrrelevantFlags() {
        let modifiers = UInt64(NSEvent.ModifierFlags.command.union(.shift).rawValue) | (1 << 24)
        XCTAssertEqual(
            SystemShortcut.displayShortcut(matchingBindingName: "custom::21:\(modifiers)")?.identifier,
            "screenshotSelection"
        )
    }

    func testDisplayShortcut_returnsNilForAmbiguousCustomBindingEquivalent() {
        let modifiers = UInt64(NSEvent.ModifierFlags.command.rawValue)
        XCTAssertNil(SystemShortcut.displayShortcut(matchingBindingName: "custom::34:\(modifiers)"))
    }

    func testActionDisplayResolver_prioritizesRecordingPromptOverExistingShortcut() {
        let presentation = makeResolvedPresentation(
            shortcut: SystemShortcut.screenshotSelection,
            customBindingName: "custom::1007:0",
            isRecording: true
        )

        XCTAssertEqual(presentation.kind, .recordingPrompt)
        XCTAssertEqual(presentation.title, NSLocalizedString("custom-recording-prompt", comment: ""))
        XCTAssertTrue(presentation.badgeComponents.isEmpty)
        XCTAssertNil(presentation.brand)
    }

    func testActionDisplayResolver_upgradesRecognizedCustomBindingToNamedAction() {
        let modifiers = UInt64(NSEvent.ModifierFlags.command.union(.shift).rawValue)
        let presentation = makeResolvedPresentation(customBindingName: "custom::21:\(modifiers)")

        XCTAssertEqual(presentation.kind, .namedAction)
        XCTAssertEqual(presentation.title, SystemShortcut.screenshotSelection.localizedName)
        XCTAssertEqual(presentation.brand?.name, nil)
    }

    func testActionDisplayResolver_upgradesSingleLogiCustomBindingToBrandedNamedAction() {
        let presentation = makeResolvedPresentation(customBindingName: "custom::1007:0")

        XCTAssertEqual(presentation.kind, .namedAction)
        XCTAssertEqual(presentation.title, "Forward Button")
        XCTAssertTrue(presentation.badgeComponents.isEmpty)
        XCTAssertEqual(presentation.brand?.name, BrandTagConfig.logi.name)
    }

    func testConfiguredButtonCell_showsBrandedNamedDisplayForSingleLogiCustomBinding() {
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::1007:0"
        )

        let cell = makeButtonCell(binding: binding)

        XCTAssertEqual(cell.actionPopUpButton.menu?.items.first?.title, "Forward Button")
        XCTAssertNotNil(cell.actionPopUpButton.menu?.items.first?.image)
    }

    func testActionDisplayResolver_returnsUnboundWhenNoActionExists() {
        let presentation = makeResolvedPresentation()

        XCTAssertEqual(presentation.kind, .unbound)
        XCTAssertEqual(presentation.title, NSLocalizedString("unbound", comment: ""))
    }

    func testActionDisplayRenderer_rendersRecordingPromptWithoutResidualImage() {
        let popupButton = makeActionPopupButton()
        let presentation = ActionPresentation(
            kind: .recordingPrompt,
            title: NSLocalizedString("custom-recording-prompt", comment: ""),
            symbolName: nil,
            badgeComponents: [],
            brand: nil
        )

        ActionDisplayRenderer().render(presentation, into: popupButton)

        XCTAssertEqual(popupButton.menu?.items.first?.title, presentation.title)
        XCTAssertNil(popupButton.menu?.items.first?.image)
    }

    func testActionDisplayRenderer_prefixesBrandTagForNamedActionSymbol() {
        let brandedPopup = makeActionPopupButton()
        let plainPopup = makeActionPopupButton()
        let branded = ActionPresentation(
            kind: .namedAction,
            title: "Forward Button",
            symbolName: "chevron.forward",
            badgeComponents: [],
            brand: .logi
        )
        let plain = ActionPresentation(
            kind: .namedAction,
            title: "Forward Button",
            symbolName: "chevron.forward",
            badgeComponents: [],
            brand: nil
        )

        let renderer = ActionDisplayRenderer()
        renderer.render(branded, into: brandedPopup)
        renderer.render(plain, into: plainPopup)

        guard let brandedImage = brandedPopup.menu?.items.first?.image,
              let plainImage = plainPopup.menu?.items.first?.image else {
            return XCTFail("Expected both render paths to create placeholder images")
        }

        XCTAssertGreaterThan(brandedImage.size.width, plainImage.size.width)
    }

    func testActionDisplayRenderer_rendersKeyComboAsBadgeImage() {
        let popupButton = makeActionPopupButton()
        let presentation = ActionPresentation(
            kind: .keyCombo,
            title: "",
            symbolName: nil,
            badgeComponents: ["⇧ ⌘", "4"],
            brand: nil
        )

        ActionDisplayRenderer().render(presentation, into: popupButton)

        XCTAssertEqual(popupButton.menu?.items.first?.title, "")
        XCTAssertNotNil(popupButton.menu?.items.first?.image)
    }

    func testBuildShortcutMenu_includesModifierCategoryWithSingleModifierShortcuts() {
        let menu = NSMenu()
        let target = ShortcutMenuTestTarget()

        ShortcutManager.buildShortcutMenu(
            into: menu,
            target: target,
            action: #selector(ShortcutMenuTestTarget.noop(_:))
        )

        let modifierCategoryName = SystemShortcut.localizedCategoryName(SystemShortcut.modifierKeysCategory.category)
        let mouseCategoryName = SystemShortcut.localizedCategoryName(SystemShortcut.mouseButtonsCategory.category)

        guard let modifierIndex = menu.items.firstIndex(where: { $0.title == modifierCategoryName }),
              let mouseIndex = menu.items.firstIndex(where: { $0.title == mouseCategoryName }) else {
            return XCTFail("Expected modifier and mouse categories to exist in shortcut menu")
        }

        XCTAssertLessThan(modifierIndex, mouseIndex)

        let modifierItems = menu.items[modifierIndex].submenu?.items.compactMap {
            ($0.representedObject as? SystemShortcut.Shortcut)?.identifier
        }
        XCTAssertEqual(
            modifierItems,
            ["modifierShift", "modifierOption", "modifierControl", "modifierCommand", "modifierFn"]
        )
    }

    func testBuildShortcutMenu_includesOpenTargetEntryAboveCustom() {
        let menu = NSMenu()
        let target = ShortcutMenuTestTarget()

        ShortcutManager.buildShortcutMenu(
            into: menu,
            target: target,
            action: #selector(ShortcutMenuTestTarget.noop(_:))
        )

        guard let openIndex = menu.items.firstIndex(where: {
            ($0.representedObject as? String) == "__open__"
        }) else {
            return XCTFail("Expected '__open__' menu entry to exist")
        }
        guard let customIndex = menu.items.firstIndex(where: {
            ($0.representedObject as? String) == "__custom__"
        }) else {
            return XCTFail("Expected '__custom__' menu entry to exist")
        }
        XCTAssertLessThan(openIndex, customIndex, "Open Application should appear above Custom Shortcut")

        let openItem = menu.items[openIndex]
        XCTAssertEqual(openItem.title, NSLocalizedString("open-target-action", comment: ""))
    }

    func testBuildShortcutMenu_includesEscapeInFunctionKeysCategory() {
        let menu = NSMenu()
        let target = ShortcutMenuTestTarget()

        ShortcutManager.buildShortcutMenu(
            into: menu,
            target: target,
            action: #selector(ShortcutMenuTestTarget.noop(_:))
        )

        let functionCategoryName = SystemShortcut.localizedCategoryName("categoryFunctionKeys")
        guard let functionCategoryIndex = menu.items.firstIndex(where: { $0.title == functionCategoryName }) else {
            return XCTFail("Expected function keys category to exist in shortcut menu")
        }

        let functionItems = menu.items[functionCategoryIndex].submenu?.items.compactMap {
            ($0.representedObject as? SystemShortcut.Shortcut)?.identifier
        } ?? []

        XCTAssertTrue(functionItems.contains("escapeKey"))
    }

    func testPredefinedModifierShortcut_localizedNamesAreSemanticLabels() {
        let symbolFallbacks = [
            "modifierShift": "⇧",
            "modifierOption": "⌥",
            "modifierControl": "⌃",
            "modifierCommand": "⌘",
            "modifierFn": "Fn",
        ]

        for (identifier, symbolFallback) in symbolFallbacks {
            guard let shortcut = SystemShortcut.getShortcut(named: identifier) else {
                return XCTFail("Expected shortcut \(identifier) to exist")
            }
            XCTAssertFalse(shortcut.localizedName.isEmpty)
            XCTAssertNotEqual(shortcut.localizedName, symbolFallback)
        }
    }

    func testEscapeShortcut_localizedNameIsSemanticLabel() {
        guard let shortcut = SystemShortcut.getShortcut(named: "escapeKey") else {
            return XCTFail("Expected escape shortcut to exist")
        }

        XCTAssertEqual(shortcut.localizedName, "Escape")
    }

    func testConfiguredButtonCell_showsNamedShortcutForEquivalentCustomBinding() {
        let modifiers = UInt64(NSEvent.ModifierFlags.command.union(.shift).rawValue)
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::21:\(modifiers)"
        )

        let cell = makeButtonCell(binding: binding)

        XCTAssertEqual(cell.actionPopUpButton.menu?.items.first?.title, SystemShortcut.screenshotSelection.localizedName)
        XCTAssertEqual(cell.actionPopUpButton.titleOfSelectedItem, SystemShortcut.screenshotSelection.localizedName)
    }

    func testConfiguredButtonCell_preservesDirectNamedShortcutForEquivalentConflictingCombo() {
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "getInfo"
        )

        let cell = makeButtonCell(binding: binding)

        XCTAssertEqual(cell.actionPopUpButton.menu?.items.first?.title, SystemShortcut.getInfo.localizedName)
    }

    func testBeginCustomShortcutSelection_showsRecordingPromptWhileAwaitingRecording() {
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "",
            isEnabled: false
        )
        let cell = makeButtonCell(binding: binding)

        cell.beginCustomShortcutSelection(startRecorder: false)
        flushMainQueue()

        XCTAssertEqual(
            cell.actionPopUpButton.menu?.items.first?.title,
            NSLocalizedString("custom-recording-prompt", comment: "")
        )
    }

    func testCustomRecordingDidStop_restoresUnboundDisplayWhenNoKeyRecorded() {
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "",
            isEnabled: false
        )
        let cell = makeButtonCell(binding: binding)

        cell.beginCustomShortcutSelection(startRecorder: false)
        flushMainQueue()
        cell.onRecordingStopped(KeyRecorder(), didRecord: false)
        flushMainQueue()

        XCTAssertEqual(cell.actionPopUpButton.menu?.items.first?.title, NSLocalizedString("unbound", comment: ""))
    }

    func testCustomRecordingDidStop_restoresExistingDisplayWhenNoKeyRecorded() {
        let modifiers = UInt64(NSEvent.ModifierFlags.command.union(.shift).rawValue)
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "custom::21:\(modifiers)"
        )
        let cell = makeButtonCell(binding: binding)

        cell.beginCustomShortcutSelection(startRecorder: false)
        flushMainQueue()
        cell.onRecordingStopped(KeyRecorder(), didRecord: false)
        flushMainQueue()

        XCTAssertEqual(cell.actionPopUpButton.menu?.items.first?.title, SystemShortcut.screenshotSelection.localizedName)
    }

    func testRecordedEquivalentCustomShortcut_updatesSelectedActionDisplayToNamedShortcut() {
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "",
            isEnabled: false
        )
        let cell = makeButtonCell(binding: binding)
        let event = InputEvent(
            type: .keyboard,
            code: 21,
            modifiers: [.maskCommand, .maskShift],
            phase: .down,
            source: .hidPP,
            device: nil
        )

        cell.onEventRecorded(KeyRecorder(), didRecordEvent: event, isDuplicate: false)
        advanceMainRunLoop(by: 0.75)

        XCTAssertEqual(cell.actionPopUpButton.menu?.items.first?.title, SystemShortcut.screenshotSelection.localizedName)
        XCTAssertEqual(cell.actionPopUpButton.titleOfSelectedItem, SystemShortcut.screenshotSelection.localizedName)
    }

    func testRecordedEquivalentCustomShortcut_withIrrelevantFlagsStillDisplaysNamedShortcut() {
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            systemShortcutName: "",
            isEnabled: false
        )
        let cell = makeButtonCell(binding: binding)
        let event = InputEvent(
            type: .keyboard,
            code: 21,
            modifiers: CGEventFlags(rawValue: UInt64(NSEvent.ModifierFlags.command.union(.shift).rawValue) | (1 << 24)),
            phase: .down,
            source: .hidPP,
            device: nil
        )

        cell.onEventRecorded(KeyRecorder(), didRecordEvent: event, isDuplicate: false)
        advanceMainRunLoop(by: 0.75)

        XCTAssertEqual(cell.actionPopUpButton.menu?.items.first?.title, SystemShortcut.screenshotSelection.localizedName)
        XCTAssertEqual(cell.actionPopUpButton.titleOfSelectedItem, SystemShortcut.screenshotSelection.localizedName)
    }

    // MARK: - OpenTarget extension

    func testOpenTargetSentinel_isStableConstant() {
        XCTAssertEqual(ButtonBinding.openTargetSentinel, "openTarget")
    }

    func testInit_withOpenTargetPayload_setsSentinelName() {
        let payload = OpenTargetPayload(
            path: "/Applications/Safari.app",
            bundleID: "com.apple.Safari",
            arguments: "",
            isApplication: true
        )
        let binding = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            openTarget: payload
        )
        XCTAssertEqual(binding.systemShortcutName, "openTarget")
        XCTAssertEqual(binding.openTarget, payload)
    }

    func testCodableRoundtrip_preservesOpenTarget() {
        let payload = OpenTargetPayload(
            path: "/Applications/Safari.app",
            bundleID: "com.apple.Safari",
            arguments: "https://example.com",
            isApplication: true
        )
        let original = ButtonBinding(
            triggerEvent: RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil),
            openTarget: payload
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(ButtonBinding.self, from: data)
        XCTAssertEqual(decoded.systemShortcutName, "openTarget")
        XCTAssertEqual(decoded.openTarget, payload)
    }

    func testCodableRoundtrip_legacyBindingHasNilOpenTarget() {
        // Old JSON format: no openTarget field
        let legacyJSON = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "triggerEvent": {
                "type": "mouse",
                "code": 3,
                "modifiers": 0,
                "displayComponents": ["🖱4"],
                "deviceFilter": null
            },
            "systemShortcutName": "copy",
            "isEnabled": true,
            "createdAt": "2025-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try! decoder.decode(ButtonBinding.self, from: data)
        XCTAssertEqual(decoded.systemShortcutName, "copy")
        XCTAssertNil(decoded.openTarget)
    }

    func testEquatable_distinguishesByOpenTarget() {
        let payloadA = OpenTargetPayload(path: "/a.app", bundleID: nil, arguments: "", isApplication: true)
        let payloadB = OpenTargetPayload(path: "/b.app", bundleID: nil, arguments: "", isApplication: true)
        let trigger = RecordedEvent(type: .mouse, code: 3, modifiers: 0, displayComponents: ["🖱4"], deviceFilter: nil)
        let id = UUID()
        let createdAt = Date(timeIntervalSince1970: 0)

        let a = ButtonBinding(id: id, triggerEvent: trigger, openTarget: payloadA, isEnabled: true, createdAt: createdAt)
        let b = ButtonBinding(id: id, triggerEvent: trigger, openTarget: payloadA, isEnabled: true, createdAt: createdAt)
        let c = ButtonBinding(id: id, triggerEvent: trigger, openTarget: payloadB, isEnabled: true, createdAt: createdAt)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
