import XCTest
@testable import Mos_Debug

final class LogiStandardMouseButtonAliasTests: XCTestCase {

    func testStandardAliasMapsLogiBackToMouseButton3() {
        XCTAssertEqual(LogiStandardMouseButtonAlias.nativeButtonCode(forMosCode: 1006), 3)
    }

    func testStandardButtonsMapToNativeMouseButtons() {
        XCTAssertEqual(LogiCIDDirectory.nativeMouseButton(forCID: 0x0052), 2)
        XCTAssertEqual(LogiCIDDirectory.nativeMouseButton(forCID: 0x0053), 3)
        XCTAssertEqual(LogiCIDDirectory.nativeMouseButton(forCID: 0x0056), 4)
    }

    func testNonStandardButtonsDoNotMapToNativeMouseButtons() {
        XCTAssertNil(LogiCIDDirectory.nativeMouseButton(forCID: 0x00C3))
        XCTAssertNil(LogiCIDDirectory.nativeMouseButton(forCID: 0x00C4))
        XCTAssertNil(LogiCIDDirectory.nativeMouseButton(forCID: 0x00D7))
    }

    func testMosCodeMapsToNativeMouseButton() {
        XCTAssertEqual(LogiCIDDirectory.nativeMouseButton(forMosCode: 1006), 3)
        XCTAssertNil(LogiCIDDirectory.nativeMouseButton(forMosCode: 1000))
    }

    func testRecordedEventConvertsStandardButtonToNativeMouseTrigger() {
        let event = RecordedEvent(
            type: .mouse,
            code: 1006,
            modifiers: 0,
            displayComponents: ["Back Button", "[Logi]"],
            deviceFilter: DeviceFilter(vendorId: 0x046D, productId: 0xB034)
        )

        let converted = event.standardMouseAliasTriggerIfAvailable()

        XCTAssertEqual(converted?.type, .mouse)
        XCTAssertEqual(converted?.code, 3)
        XCTAssertEqual(converted?.modifiers, 0)
        XCTAssertEqual(converted?.displayComponents, ["🖱3"])
        XCTAssertNil(converted?.deviceFilter)
    }

    func testRecordedEventUsesStandardAliasWhenDeliveryUsesNativeEvents() {
        let event = RecordedEvent(
            type: .mouse,
            code: 1006,
            modifiers: 0,
            displayComponents: ["Back Button", "[Logi]"],
            deviceFilter: nil
        )
        let diagnosis = LogiButtonCaptureDiagnosis(
            ownership: .mosOwned,
            delivery: .hidpp,
            ownershipKey: nil,
            nativeMouseButton: 3,
            usesNativeEvents: true
        )

        let normalized = event.normalizedForButtonBinding(diagnosis: diagnosis)

        XCTAssertEqual(normalized.code, 3)
        XCTAssertEqual(normalized.displayComponents, ["🖱3"])
    }

    func testRecordedEventKeepsLogiCodeWhenDeliveryUsesHIDPPEvents() {
        let event = RecordedEvent(
            type: .mouse,
            code: 1006,
            modifiers: 0,
            displayComponents: ["Back Button", "[Logi]"],
            deviceFilter: nil
        )
        let diagnosis = LogiButtonCaptureDiagnosis(
            ownership: .mosOwned,
            delivery: .hidpp,
            ownershipKey: nil,
            nativeMouseButton: 3,
            usesNativeEvents: false
        )

        let normalized = event.normalizedForButtonBinding(diagnosis: diagnosis)

        XCTAssertEqual(normalized.code, 1006)
        XCTAssertEqual(normalized.displayComponents, ["Back Button", "[Logi]"])
    }

    func testRecordedEventDoesNotConvertUnsupportedButton() {
        let event = RecordedEvent(
            type: .mouse,
            code: 1000,
            modifiers: 0,
            displayComponents: ["Mouse Gesture Button", "[Logi]"],
            deviceFilter: nil
        )

        XCTAssertNil(event.standardMouseAliasTriggerIfAvailable())
    }

    func testButtonBindingConversionPreservesActionAndMatchesNativeMouseEvent() {
        let originalEvent = RecordedEvent(
            type: .mouse,
            code: 1007,
            modifiers: UInt(CGEventFlags.maskCommand.rawValue),
            displayComponents: ["Forward Button", "[Logi]"],
            deviceFilter: DeviceFilter(vendorId: 0x046D, productId: 0xB034)
        )
        let binding = ButtonBinding(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            triggerEvent: originalEvent,
            systemShortcutName: "missionControl",
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 123)
        )

        let converted = binding.standardMouseAliasBindingIfAvailable()

        XCTAssertEqual(converted?.id, binding.id)
        XCTAssertEqual(converted?.systemShortcutName, "missionControl")
        XCTAssertEqual(converted?.isEnabled, true)
        XCTAssertEqual(converted?.createdAt, binding.createdAt)
        XCTAssertEqual(converted?.triggerEvent.code, 4)
        XCTAssertNil(converted?.triggerEvent.deviceFilter)

        let nativeEvent = InputEvent(
            type: .mouse,
            code: 4,
            modifiers: .maskCommand,
            phase: .down,
            source: .hidPP,
            device: nil
        )
        XCTAssertEqual(converted?.triggerEvent.matchPriority(for: nativeEvent), 1)
    }

    func testStandardAliasReplacementRemovesExistingNativeDuplicate() {
        let nativeEvent = RecordedEvent(
            type: .mouse,
            code: 3,
            modifiers: 0,
            displayComponents: ["🖱3"],
            deviceFilter: nil
        )
        let existingNative = ButtonBinding(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            triggerEvent: nativeEvent,
            systemShortcutName: "missionControl",
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let logiBack = ButtonBinding(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001006")!,
            triggerEvent: RecordedEvent(
                type: .mouse,
                code: 1006,
                modifiers: 0,
                displayComponents: ["Back Button", "[Logi]"],
                deviceFilter: nil
            ),
            systemShortcutName: "launchpad",
            isEnabled: true,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let replacement = logiBack.standardMouseAliasBindingIfAvailable()!

        let merged = ButtonBindingReplacement.replacing(replacement, in: [existingNative, logiBack])

        XCTAssertEqual(merged.map(\.triggerEvent.code), [3])
        XCTAssertEqual(merged.first?.id, logiBack.id)
        XCTAssertEqual(merged.first?.systemShortcutName, "launchpad")
    }
}
