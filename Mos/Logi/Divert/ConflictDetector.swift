//
//  ConflictDetector.swift
//  Mos
//

import Foundation

/// 5-state Logi CID conflict status (Round 4 H2: precedence foreign > remap > mos > clear).
/// Backed by device-truth (reportingFlags + targetCID) plus Mos's own divertedCIDs set.
public enum ConflictStatus: Equatable {
    case clear
    case foreignDivert
    case remapped
    case mosOwned
    case unknown

    /// Legacy adapter for callers that previously checked `== .conflict`.
    /// Conflict = a status the user should be alerted to (foreign divert + foreign remap).
    public var isConflict: Bool {
        switch self {
        case .foreignDivert, .remapped: return true
        case .clear, .mosOwned, .unknown: return false
        }
    }
}

/// Status detector for one Logi CID.
/// Precedence (matches LogiDebugPanel cStatus column visual order):
///   foreign-divert > remap > mos-owned > clear
struct LogiConflictDetector {
    static func status(reportingFlags: UInt8,
                       targetCID: UInt16,
                       cid: UInt16,
                       reportingQueried: Bool,
                       mosOwnsDivert: Bool) -> ConflictStatus {
        guard reportingQueried else { return .unknown }
        // Foreign divert: device-side reporting bit set AND not by Mos.
        let isForeignDivert = reportingFlags != 0 && !mosOwnsDivert
        if isForeignDivert { return .foreignDivert }
        // Remap: targetCID set to a different CID (self-remap is identity, not a remap).
        let isRemapped = targetCID != 0 && targetCID != cid
        if isRemapped { return .remapped }
        // Mos owns the divert: bit set by Mos's own setControlReporting.
        if mosOwnsDivert { return .mosOwned }
        return .clear
    }
}
