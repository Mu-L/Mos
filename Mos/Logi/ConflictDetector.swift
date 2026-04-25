//
//  LogiConflictDetector.swift
//  Mos
//  判定某 Logi CID 当前 reporting 状态是否表明被第三方 (例如 Logitech Options+) 接管.
//  Created by Mos on 2026/4/20.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Foundation

/// Logitech HID++ CID 冲突判定
///
/// 前提 (方案 B): `reportingFlags` 与 `targetCID` 永远反映 **设备 GetControlReporting 响应** 的真值,
/// 不受 Mos 自身 `setControlReporting` 操作污染. Mos 视角的 divert 状态由 `divertedCIDs` 集合单独表达.
///
/// 规则: 只要设备响应里 `reportingFlags` 或 `targetCID` 有任何非零位, 就说明接管前已被第三方设置 ->
/// 冲突. 反之为 clear. 查询未完成返回 unknown.
struct LogiConflictDetector {

    enum Status: Equatable {
        case unknown
        case clear
        case conflict
    }

    static func status(
        reportingFlags: UInt8,
        targetCID: UInt16,
        cid: UInt16,
        reportingQueried: Bool
    ) -> Status {
        guard reportingQueried else { return .unknown }
        // reportingFlags 非零 -> 第三方 tmpDivert / persistDivert
        if reportingFlags != 0 { return .conflict }
        // targetCID != 0 且 != cid -> 第三方真实 remap (排除 Logitech 默认的 self-remap identity mapping)
        if targetCID != 0 && targetCID != cid { return .conflict }
        return .clear
    }
}
