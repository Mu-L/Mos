import XCTest
@testable import Mos_Debug

/// 验证 Logi 按键冲突判定: 基于"设备在 Mos 接管前的真实响应数据" (reportingFlags + targetCID).
/// Mos 自己的 divert 操作 *不会* 污染 reportingFlags (见方案 B), 故判定无需 mosDivertedCIDs.
final class LogiConflictDetectorTests: XCTestCase {

    private let cid: UInt16 = 0x0053    // Back Button

    // MARK: - unknown

    func testStatus_notQueried_returnsUnknown() {
        let status = LogiConflictDetector.status(
            reportingFlags: 0x01,
            targetCID: 0,
            cid: cid,
            reportingQueried: false
        )
        XCTAssertEqual(status, .unknown)
    }

    // MARK: - clear

    func testStatus_allZero_returnsClear() {
        let status = LogiConflictDetector.status(
            reportingFlags: 0,
            targetCID: 0,
            cid: cid,
            reportingQueried: true
        )
        XCTAssertEqual(status, .clear)
    }

    func testStatus_selfRemap_returnsClear() {
        // Logitech Options+ 默认对许多按键做 self-remap (identity mapping), 不应算作冲突
        let status = LogiConflictDetector.status(
            reportingFlags: 0,
            targetCID: cid,
            cid: cid,
            reportingQueried: true
        )
        XCTAssertEqual(status, .clear)
    }

    // MARK: - conflict

    func testStatus_reportingFlagsNonZero_returnsConflict() {
        // bit0 (tmpDivert 或其它位布局) 被第三方设过
        let status = LogiConflictDetector.status(
            reportingFlags: 0x01,
            targetCID: 0,
            cid: cid,
            reportingQueried: true
        )
        XCTAssertEqual(status, .conflict)
    }

    func testStatus_anyReportingBitSet_returnsConflict() {
        // 不依赖具体位布局解读, 任何非零位都算冲突
        for bit in 0..<8 {
            let flags: UInt8 = 1 << bit
            let status = LogiConflictDetector.status(
                reportingFlags: flags,
                targetCID: 0,
                cid: cid,
                reportingQueried: true
            )
            XCTAssertEqual(status, .conflict, "reportingFlags=\(String(format: "0x%02X", flags)) should be conflict")
        }
    }

    func testStatus_targetCIDDifferentFromCid_returnsConflict() {
        // Options+ 把按键真实 remap 到另一个 CID
        let status = LogiConflictDetector.status(
            reportingFlags: 0,
            targetCID: 0x0056,   // 不同于 cid=0x0053
            cid: cid,
            reportingQueried: true
        )
        XCTAssertEqual(status, .conflict)
    }

    // MARK: - 方案 B 核心: Mos 的 setControlReporting 不再污染 reportingFlags

    func testStatus_unchangedByMosOperations() {
        // reportingFlags 永远是设备初始查询结果, Mos undivert 不应影响它.
        let firstStatus = LogiConflictDetector.status(
            reportingFlags: 0x01, targetCID: 0, cid: cid, reportingQueried: true
        )
        XCTAssertEqual(firstStatus, .conflict)

        // 录制新按键后 Mos 调 setControlReporting(divert=OFF), reportingFlags 应保持 0x01
        let afterUndivertStatus = LogiConflictDetector.status(
            reportingFlags: 0x01, targetCID: 0, cid: cid, reportingQueried: true
        )
        XCTAssertEqual(afterUndivertStatus, .conflict, "reportingFlags 不应被 Mos 的 undivert 清零, 应保持 conflict")
    }
}
