import XCTest
@testable import Mos_Debug

class LogiDeviceIntegrationBase: XCTestCase {
    static var hasDevice: Bool {
        ProcessInfo.processInfo.environment["LOGI_REAL_DEVICE"] == "1"
    }
    override func setUpWithError() throws {
        try XCTSkipUnless(Self.hasDevice, "requires LOGI_REAL_DEVICE=1")
    }
}

final class LogiCenterDeviceIntegrationTests: LogiDeviceIntegrationBase {

    /// Round 4 / spec §7 Tier 3a — 0 → 1 → 0 baseline transition.
    /// Asserts that Mos is the actor: bit0 starts 0, becomes 1 under setUsage,
    /// returns to 0 after setUsage([]).
    func testBaselineTransition_BackButton() throws {
        // 1. Wait for first session ready
        let sessionExp = expectation(forNotification: LogiCenter.reportingDidComplete, object: nil)
        LogiCenter.shared.start()
        wait(for: [sessionExp], timeout: 30)

        // 2. Assert baseline bit0 == 0
        guard let snapshot = LogiCenter.shared.activeSessionsSnapshot().first else {
            throw XCTSkip("No active session")
        }
        let cidBack: UInt16 = 0x0053
        let baseline = readReportingBit0(snapshot: snapshot, cid: cidBack)
        try XCTSkipIf(baseline == true, "Third party owns CID 0x0053; cannot assert Mos transition")
        XCTAssertEqual(baseline, false)

        // 3. Apply Mos divert
        let onExp = expectation(forNotification: LogiCenter.reportingDidComplete, object: nil)
        LogiCenter.shared.setUsage(source: .buttonBinding, codes: [1006])  // MosCode for Back
        wait(for: [onExp], timeout: 30)
        XCTAssertEqual(readReportingBit0(snapshot: snapshot, cid: cidBack), true)

        // 4. Clear
        let offExp = expectation(forNotification: LogiCenter.reportingDidComplete, object: nil)
        LogiCenter.shared.setUsage(source: .buttonBinding, codes: [])
        wait(for: [offExp], timeout: 30)
        XCTAssertEqual(readReportingBit0(snapshot: snapshot, cid: cidBack), false)
    }

    private func readReportingBit0(snapshot: LogiDeviceSessionSnapshot, cid: UInt16) -> Bool {
        guard let ctrl = snapshot.discoveredControls.first(where: { $0.cid == cid }) else { return false }
        return (ctrl.reportingFlags & 0x01) != 0
    }
}
