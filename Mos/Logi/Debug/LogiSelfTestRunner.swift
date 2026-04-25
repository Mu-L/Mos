//
//  LogiSelfTestRunner.swift
//  Mos
//
//  DEBUG-only step runner that drives the Self-Test Wizard. Skeleton —
//  detailed Bolt/BLE step lists per spec §7 Tier 3c land in a later pass.
//

#if DEBUG
import Foundation

/// What kind of action a wizard step performs.
/// Closure-based instead of async/await to stay compatible with
/// macOS 10.13 deployment target.
enum StepKind {
    case automatic(detail: String,
                   run: (@escaping (StepOutcome) -> Void) -> Void)
    case physicalAutoVerified(instruction: String,
                              expectation: String,
                              wait: WaitCondition,
                              timeout: TimeInterval)
    case physicalUserConfirmed(instruction: String,
                               expectation: String,
                               confirmPrompt: String)
}

/// Async wait condition for a `physicalAutoVerified` step. The wizard
/// observes a notification or a session state transition and resolves.
enum WaitCondition {
    case rawButtonEvent(mosCode: UInt16?, cid: UInt16?)
    case sessionConnected(mode: LogiDeviceSession.ConnectionMode)
    case sessionDisconnected
    case divertApplied(cid: UInt16, expectBit0: Bool)
    case dpiChanged(direction: Direction)
}

enum StepOutcome {
    case pass
    case fail(reason: String)
}

/// Read-only description of a session reachable for the wizard.
enum DetectedConnection {
    case bolt(snapshot: LogiDeviceSessionSnapshot, slot: UInt8, name: String)
    case bleDirect(snapshot: LogiDeviceSessionSnapshot, name: String)
}

final class LogiSelfTestRunner {

    /// Inspect the first active session and classify connection mode.
    /// Returns nil when no session is reachable or when mode is unsupported.
    func detectConnection() -> DetectedConnection? {
        guard let snapshot = LogiCenter.shared.activeSessionsSnapshot().first else { return nil }
        switch snapshot.connectionMode {
        case .receiver:
            guard let firstConnected = snapshot.pairedDevices.first(where: { $0.isConnected }) else { return nil }
            return .bolt(snapshot: snapshot, slot: firstConnected.slot, name: firstConnected.name)
        case .bleDirect:
            return .bleDirect(snapshot: snapshot, name: snapshot.deviceInfo.name)
        case .unsupported:
            return nil
        }
    }

    // TODO: buildBoltSuite() / buildBLESuite() / runStep(_:) / handleCancel()
    // Spec §7 Tier 3c enumerates the step lists; implementation is a
    // follow-up after Step 5 lands.
}
#endif
