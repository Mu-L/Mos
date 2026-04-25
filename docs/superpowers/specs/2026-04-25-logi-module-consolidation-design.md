# Logi Module Consolidation — Design Spec

**Date**: 2026-04-25
**Status**: Design v2 (post Codex review × 2)
**Supersedes**: N/A
**Related**:
- `2026-03-16-logitech-hid-integration-design.md` (original HID++ integration)
- `2026-03-21-logitech-cid-registry-design.md`
- `2026-03-30-hidpp-debug-panel-redesign.md`

## Revision history

- **v1 (initial)**: brainstormed surface — single facade, push-driven UsageRegistry, two-method bridge, full rename. Two rounds of Codex review (gpt-5.5 + xhigh) surfaced 27 findings (12 H, 11 M, 4 L).
- **v2 (this doc)**: folds all 27 findings. Material changes:
  - Bridge protocol redesigned to return `LogiDispatchResult` enum that includes `.logiAction(name:)`, removing the need for the Logi module to know `ButtonUtils` while keeping logi* fast-path execution in the originating session (F1).
  - Convergence model switched from registry-wide `lastApplied` to per-session `lastApplied`, eliminating reconnect-no-diff failures (F4).
  - Performance budget rewritten with measured numbers from `swiftc -O` micro-bench (F7) and a new Step 0 to remove the per-input-report `Array` heap allocation in `inputReportCallback` (F11).
  - Startup `LogiUsageBootstrap` added so release builds divert before the user opens Preferences (F2).
  - Recording invariant explicit: bridge consumes recording events before any other routing (F3).
  - `reportingDidComplete` empty-controls path bug fixed as part of Step 0 (F8); new `rawButtonEvent` notification added for deterministic raw-event observers (F9).
  - Bridge wiring is mandatory before `start()` and stored as a strong, non-optional reference (F7, F10).
  - `ConflictDetector` updated to suppress Mos-owned divert (F6, consistent with commit 195908a).
  - Persistence canary uses an independent hard-coded golden list (F22).
  - Tier 2 fakes model `divertedCIDs` / `divertableCIDs` / planner idempotency (F23); Tier 3a runs a `0 → 1 → 0` baseline transition test to prove Mos is the actor (F24); wizard registers per-step cancellation tokens for session liveness (F25).
  - Migration plan reordered: Step 0 (HID alloc + reportingDidComplete fix), then Rename → Facade (no UsageRegistry reference) → UsageRegistry → Bridge → Tidy + Wizard.
  - Acceptance includes a CI symbol-denylist lint rule because same-target `internal` is not a module boundary (F5).
  - Performance acceptance gates are operational (no new heap allocs / no new NotificationCenter / no new DispatchQueue.async on hot path) instead of a non-verifiable "≤ 5 ns" claim (F27).

The 27 findings are tagged inline as `(F#)` where each fix is applied.

## 1. Problem

Logi-specific code is scattered across `Mos/LogitechHID/` and leaks into the rest of the app through three patterns:

1. **Reverse scan of preferences**: `LogitechDeviceSession.collectBoundLogiMosCodes()` walks `Options.shared.buttons.binding`, `Options.shared.scroll.{dash,toggle,block}`, and per-app scroll hotkeys. Logi drives divert by pulling from three sources the module has no business knowing.
2. **Reverse call into ScrollCore / ButtonUtils / InputProcessor / Toast**: `LogitechDeviceSession.handleButtonEvent` / `teardown` directly call `ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus`, `ButtonUtils.shared.getBestMatchingBinding`, `InputProcessor.shared.process`. `LogitechDeviceSession.showFeatureNotAvailable()` calls `Toast.show`. Module posts the magic-string `"LogitechHIDButtonEvent"` for KeyRecorder.
3. **No single API surface**: 20+ call sites outside the dir reach directly into `LogitechHIDManager.shared`, `LogitechCIDRegistry`, `LogitechConflictDetector`, `LogitechHIDDebugPanel`. Each preference controller calls `syncDivertWithBindings()` after save.

Symptom felt by users: "按键偏好页说 Back Button 未绑定,但 Debug 面板仍显示 DVRT" — because the scroll panel or per-app panel holds a hidden binding Logi picks up via reverse scan. Symptom felt by maintainers: adding a new Logi feature requires editing 5–10 files across unrelated modules.

## 2. Goals

1. **Single module boundary**: all Logi code lives in `Mos/Logi/`. Module does not import business modules (`ScrollCore`, `ButtonUtils`, `InputProcessor`, `Options`, `PreferencesWindow`, `Toast`).
2. **Single public facade**: `LogiCenter.shared` is the only Logi class external code references. Internal types (`LogiSessionManager`, `LogiDeviceSession`, etc.) are `internal` and additionally enforced by a CI symbol denylist (F5).
3. **Push-driven usage model**: preference panels and a startup bootstrap declare "this source uses these codes" via `LogiCenter.shared.setUsage(source:codes:)`. Logi does not scan Options.
4. **Inverted external dependencies**: ScrollCore / ButtonUtils / InputProcessor / Toast access lives behind a `LogiExternalBridge` protocol implemented outside the Logi module. Bridge is strong-referenced (not weak) and required to be installed before `start()`.
5. **Persistence byte-compatible**: `UserDefaults["logitechFeatureCache"]` and the `"HIDDebug.FeaturesControls.v3"` `autosaveName` literal frozen. Zero new persistence keys.
6. **Per-event hot path stays cheap**: no new heap allocations, no new `NotificationCenter.post`, no new `DispatchQueue.*` on the input-report → button-dispatch path. (Step 0 also removes an *existing* per-report `Array` allocation that the v1 spec ignored.)
7. **Per-session convergence guaranteed**: every session readiness / state-reset path applies the current usage aggregate via prime, not via `lastApplied` diffs that can be skipped.
8. **Test coverage**: pure logic (Tier 1) + harness tests (Tier 2 with realistic fakes) + real-device integration (Tier 3a/b with `0 → 1 → 0` baseline) + interactive Self-Test Wizard (Tier 3c with per-step cancellation).

## 3. Non-goals

- Changing HID++ protocol layer or feature action semantics.
- Migrating persistence formats. Schema and UserDefaults keys frozen.
- Changing preference UI layout (button/scroll/application panels keep current shape).
- Unifying scroll-hotkey and button-binding data models. Separation stays.
- Breaking the existing Codex review / dev workflow (two rounds per plan, two rounds per code, gpt-5.5 + xhigh).
- Migrating `Application` persistence identity from `path` to `bundleId`. Stays as-is; `UsageSource.appScroll(key:)` accepts the existing stable identity (F15).

## 4. Architecture

### 4.1 Directory

```
Mos/Logi/                                   # pure Logi module, zero business imports
├── LogiCenter.swift                        # the only public facade
├── Core/
│   ├── LogiDeviceSession.swift             # was LogitechDeviceSession
│   ├── LogiSessionManager.swift            # was LogitechHIDManager (internal)
│   ├── LogiCIDDirectory.swift              # was LogitechCIDRegistry
│   ├── LogiReceiverCatalog.swift           # was LogitechReceiverRegistry
│   └── SessionActivityStatus.swift         # already present
├── Usage/
│   ├── UsageRegistry.swift                 # new
│   └── UsageSource.swift                   # new
├── Divert/
│   ├── DivertPlanner.swift                 # was LogitechDivertPlanner
│   └── ConflictDetector.swift              # was LogitechConflictDetector (semantics fix from 195908a folded in)
├── Bridge/
│   ├── LogiExternalBridge.swift            # protocol + LogiDispatchResult enum
│   └── LogiNoOpBridge.swift                # default before integration is wired (DEBUG fails fast)
└── Debug/
    ├── LogiDebugPanel.swift                # was LogitechHIDDebugPanel
    ├── BrailleSpinner.swift
    ├── LogiSelfTestWizard.swift            # new (DEBUG only)
    └── LogiSelfTestRunner.swift            # new (DEBUG only)

Mos/Integration/
├── LogiIntegrationBridge.swift             # protocol's production impl; imports ScrollCore/ButtonUtils/InputProcessor/Toast
└── LogiUsageBootstrap.swift                # new — pushes initial usage from Options before LogiCenter.start()
```

### 4.2 LogiCenter public surface

```swift
final class LogiCenter {
    static let shared: LogiCenter

    // --- Lifecycle ---
    /// Bridge MUST be installed before start(). Production: AppDelegate calls
    /// installBridge(LogiIntegrationBridge.shared) then start(). DEBUG asserts.
    func installBridge(_ bridge: LogiExternalBridge)
    func start()
    func stop()

    // --- Usage registration (drives divert) ---
    func setUsage(source: UsageSource, codes: Set<UInt16>)
    func usages(of code: UInt16) -> [UsageSource]

    // --- CID directory (read-only; replaces external LogitechCIDRegistry references) ---
    func isLogiCode(_ code: UInt16) -> Bool
    func name(forMosCode code: UInt16) -> String?

    // --- Conflict (for ButtonTableCellView etc.) ---
    func conflictStatus(forMosCode code: UInt16) -> ConflictStatus

    // --- Recording ---
    func beginKeyRecording()
    func endKeyRecording()
    var isRecording: Bool { get }

    // --- Feature actions (called from ShortcutExecutor) ---
    func executeSmartShiftToggle()
    func executeDPICycle(direction: Direction)

    // --- Reporting refresh (called from PreferencesWindow / PreferencesButtons) ---
    /// Coalesced re-query of GetControlReporting on all sessions, used to refresh
    /// conflict indicators when the user opens preferences. Internal throttle preserved.
    func refreshReportingStatesIfNeeded()

    // --- Debug panel ---
    func showDebugPanel()

    // --- Activity (global busy indicator) ---
    var isBusy: Bool { get }
    var currentActivitySummary: SessionActivityStatus { get }   // for PreferencesButtonsViewController

    // --- Snapshots (debug + wizard) ---
    func activeSessionsSnapshot() -> [LogiDeviceSessionSnapshot]
    // Note: LogiDeviceSessionSnapshot is a value-type read-only view of session state,
    // not the live class. External code never holds a session reference.

    // --- Namespaced notifications ---
    static let sessionChanged:        Notification.Name
    static let discoveryStateChanged: Notification.Name
    static let reportingDidComplete:  Notification.Name
    static let activityChanged:       Notification.Name
    static let conflictChanged:       Notification.Name

    /// (F9) Deterministic raw button-event observer: ALL Logi button events fire this
    /// before any dispatch decision (recording / consumed / unhandled / logiAction).
    /// Use this for self-test wizard and debug panel observers that need a guaranteed
    /// "saw a press" signal regardless of routing outcome.
    static let rawButtonEvent:        Notification.Name

    /// Existing relay: posted only in (a) recording mode (b) non-consumed events.
    /// Kept for KeyRecorder backward compatibility. NOT a guaranteed raw signal.
    static let buttonEventRelay:      Notification.Name
}

// Public value-type surface (referenced by external code per acceptance §11)
public enum UsageSource: Hashable { /* see 4.3 */ }
public enum ScrollRole: Hashable { case dash, toggle, block }
public enum ConflictStatus { case clear, conflict, mosOwned, unknown }
public protocol LogiExternalBridge: AnyObject { /* see 4.4 */ }
public enum LogiDispatchResult: Equatable { /* see 4.4 */ }
public enum Direction { case up, down }
public struct LogiDeviceSessionSnapshot { /* read-only view */ }
public struct SessionActivityStatus { /* already exists */ }

extension LogiCenter {
    // Test-injectable constructor (internal). Only used by Tier 2 harness tests.
    internal convenience init(manager: LogiSessionManager,
                              registry: UsageRegistry,
                              bridge: LogiExternalBridge,
                              clock: Clock = .system)
}
```

Production code uses `.shared` exclusively. Tests construct isolated instances via the internal init with fake manager/registry/bridge to avoid cross-test state leaks.

### 4.3 UsageRegistry

```swift
public enum UsageSource: Hashable {
    case buttonBinding                                          // aggregated button panel
    case globalScroll(ScrollRole)                               // global scroll panel
    /// (F15) `key` is the stable identity used by Mos for the per-app entry —
    /// currently `Application.path`. Spec does not require migration to bundleId.
    /// When an app entry is deleted from preferences, the panel MUST call
    /// `setUsage(source: .appScroll(key:role:), codes: [])` for each role to
    /// drop the source from the registry.
    case appScroll(key: String, role: ScrollRole)
}

final class UsageRegistry {
    // (F4) Per-session convergence: registry stores aggregate, sessions store
    // their own lastApplied. Reconnects + slot switches re-prime against the
    // current aggregate without depending on a registry-wide diff.
    private let sessionProvider: () -> [LogiDeviceSession]
    init(sessionProvider: @escaping () -> [LogiDeviceSession]) {
        self.sessionProvider = sessionProvider
    }

    private var sources: [UsageSource: Set<UInt16>] = [:]
    private var aggregatedCache: Set<UInt16> = []
    private var aggregatedDirty: Bool = true
    private var recomputeScheduled: Bool = false
    // main-thread-only; no locks (precondition asserted in DEBUG)
}
```

**Push API** (the only mutator, F21):

```swift
func setUsage(source: UsageSource, codes: Set<UInt16>) {
    #if DEBUG
    precondition(Thread.isMainThread, "LogiCenter is main-thread-only")
    #endif
    let existing = sources[source]
    if existing == codes { return }                         // idempotent short-circuit
    if codes.isEmpty {
        sources.removeValue(forKey: source)                 // (F21) drop empty sources, not store empty Set
    } else {
        sources[source] = codes
    }
    aggregatedDirty = true
    scheduleRecompute()
}
```

**Coalesced apply** — multiple `setUsage` in the same main-queue task collapse to one apply (F20 — semantics: "after current main-queue item returns", not "next runloop tick"):

```swift
private func scheduleRecompute() {
    if recomputeScheduled { return }
    recomputeScheduled = true
    DispatchQueue.main.async { [weak self] in self?.runRecompute() }
}

private func runRecompute() {
    recomputeScheduled = false
    if aggregatedDirty {
        aggregatedCache = sources.values.reduce(into: Set<UInt16>()) { $0.formUnion($1) }
        aggregatedDirty = false
    }
    // (F4) Always push current aggregate to every ready session. Per-session
    // applyUsageDiff computes its own diff vs its own lastApplied. This means
    //  - a session that joined after the last setUsage and missed all earlier
    //    diffs still converges to the current aggregate
    //  - a session that disconnects + reconnects with no usage change also
    //    converges, because its lastApplied is empty after teardown
    //  - registry no longer maintains lastApplied; equivalent semantics, simpler
    for session in sessionProvider() where session.isHIDPPCandidate {
        session.applyUsage(aggregatedCache)
    }
}
```

**Session prime hooks** (F4 convergence contract):

`LogiDeviceSession.applyUsage(_ aggregate: Set<UInt16>)` must be called at:

| Trigger | Effect |
|---|---|
| Session becomes ready (`divertBoundControls`) | apply current aggregate |
| `rediscoverFeatures` (debug or auto) | reset session state, re-apply on next ready |
| `setTargetSlot` (slot switch) | reset session state, re-apply on next ready |
| `restoreDivertToBindings` (recording end) | apply current aggregate |
| `redivertAllControls` (debug action) | clear divertedCIDs, then apply |
| Each `setUsage` → `runRecompute` | apply to all currently-ready sessions |

Internally `applyUsage` computes its own diff against `self.lastApplied`:

```swift
internal func applyUsage(_ aggregate: Set<UInt16>) {
    guard let reprogIdx = featureIndex[Self.featureReprogV4] else { return }
    let target = aggregate.intersection(divertableCIDs)
    let toDivert = target.subtracting(self.lastApplied)
    let toUndivert = self.lastApplied.subtracting(target)
    for cid in toDivert { setControlReporting(featureIndex: reprogIdx, cid: cid, divert: true) }
    for cid in toUndivert { setControlReporting(featureIndex: reprogIdx, cid: cid, divert: false) }
    self.lastApplied = target
}
```

Diagnostic API:
```swift
func usages(of code: UInt16) -> [UsageSource] {
    sources.compactMap { $0.value.contains(code) ? $0.key : nil }
}
```

### 4.4 LogiExternalBridge

**Protocol (lives inside Logi):**

```swift
public protocol LogiExternalBridge: AnyObject {

    /// (F3 recording invariant) Called by session for every Logi button event.
    /// Bridge MUST handle recording mode internally and return `.consumed` to
    /// short-circuit all other routing — recording must not trigger ScrollCore
    /// or InputProcessor (current behavior).
    ///
    /// (F1) `.logiAction(name:)` returns the resolved logi* shortcut name so
    /// the session can run executeLogiAction(name:) in its own device-isolated
    /// context. Logi does NOT import ButtonUtils.
    func dispatchLogiButtonEvent(_ event: InputEvent) -> LogiDispatchResult

    /// Side path: called by session for non-recording events (after dispatch).
    /// phase == .up is also used by session teardown to release any held
    /// scroll-hotkey state in ScrollCore.
    func handleLogiScrollHotkey(code: UInt16, phase: InputPhase)

    /// (F12) Toast surface for "feature not available" etc.
    func showLogiToast(_ message: String, severity: LogiToastSeverity)
}

public enum LogiDispatchResult: Equatable {
    case consumed                          // bridge fully handled (recording / non-logi binding consumed)
    case unhandled                         // not consumed; bridge made no decision
    case logiAction(name: String)          // bridge resolved a logi* binding; session executes
}

public enum LogiToastSeverity { case info, warning, error }
```

**Session call site (refactored `handleButtonEvent`):**

```swift
private func handleButtonEvent(_ event: InputEvent, isDown: Bool) {
    // (F9) Always post raw event first — deterministic for wizard + debug observers.
    NotificationCenter.default.post(
        name: LogiCenter.rawButtonEvent, object: nil, userInfo: ["event": event])

    let bridge = LogiCenter.shared.externalBridge   // (F7) strong, non-optional, ~0.9 ns

    // (F3) Recording short-circuit: bridge returns .consumed in recording mode.
    if LogiCenter.shared.isRecording {
        _ = bridge.dispatchLogiButtonEvent(event)
        return
    }

    // Non-recording: scroll hotkey fires regardless of binding outcome (preserves
    // current behavior at LogitechDeviceSession.swift:1736).
    bridge.handleLogiScrollHotkey(code: event.code, phase: event.phase)

    // Main routing.
    switch bridge.dispatchLogiButtonEvent(event) {
    case .logiAction(let name) where event.phase == .down:
        executeLogiAction(name)             // device-isolated, in this session
    case .consumed, .unhandled, .logiAction:
        break
    }
}
```

**Teardown (F4 ordering invariant):**

Before clearing `lastActiveCIDs`, switching slots, rediscovering, stopping, or removing a session, emit `.up` through the bridge while ScrollCore is still alive:

```swift
internal func teardown() {
    let bridge = LogiCenter.shared.externalBridge
    for cid in lastActiveCIDs {
        let mosCode = LogiCIDDirectory.toMosCode(cid)
        bridge.handleLogiScrollHotkey(code: mosCode, phase: .up)
    }
    lastActiveCIDs.removeAll()
    self.lastApplied.removeAll()             // (F4) reset per-session convergence state
    // ... existing HID release logic ...
}
```

**Production impl (`Mos/Integration/LogiIntegrationBridge.swift`):**

```swift
final class LogiIntegrationBridge: LogiExternalBridge {
    static let shared = LogiIntegrationBridge()

    func dispatchLogiButtonEvent(_ event: InputEvent) -> LogiDispatchResult {
        // (F3) Recording: post relay, consume.
        if LogiCenter.shared.isRecording {
            NotificationCenter.default.post(
                name: LogiCenter.buttonEventRelay,
                object: nil, userInfo: ["event": event])
            return .consumed
        }
        // (F1) Probe for logi* binding: return name for session to execute.
        if event.phase == .down,
           let binding = ButtonUtils.shared.getBestMatchingBinding(
               for: event,
               where: { $0.systemShortcutName.hasPrefix("logi") }) {
            return .logiAction(name: binding.systemShortcutName)
        }
        // Generic binding: run InputProcessor.
        let result = InputProcessor.shared.process(event)
        if result == .consumed { return .consumed }
        // Not consumed: post relay (KeyRecorder + observer compatibility).
        NotificationCenter.default.post(
            name: LogiCenter.buttonEventRelay,
            object: nil, userInfo: ["event": event])
        return .unhandled
    }

    func handleLogiScrollHotkey(code: UInt16, phase: InputPhase) {
        ScrollCore.shared.handleScrollHotkey(code: code, phase: phase)
        // ScrollCore method renamed: handleScrollHotkeyFromHIDPlusPlus → handleScrollHotkey
    }

    func showLogiToast(_ message: String, severity: LogiToastSeverity) {
        Toast.show(message: message, severity: severity.toastSeverity)
    }
}

final class LogiNoOpBridge: LogiExternalBridge {
    static let shared = LogiNoOpBridge()
    func dispatchLogiButtonEvent(_ event: InputEvent) -> LogiDispatchResult { .unhandled }
    func handleLogiScrollHotkey(code: UInt16, phase: InputPhase) {}
    func showLogiToast(_ message: String, severity: LogiToastSeverity) {}
}
```

**Storage (F7 strong reference):**

```swift
final class LogiCenter {
    private(set) var externalBridge: LogiExternalBridge = LogiNoOpBridge.shared

    func installBridge(_ bridge: LogiExternalBridge) {
        #if DEBUG
        precondition(Thread.isMainThread)
        #endif
        externalBridge = bridge
    }

    func start() {
        #if DEBUG
        precondition(!(externalBridge is LogiNoOpBridge),
                     "LogiCenter.installBridge must be called before start()")
        #endif
        // ... existing manager.start() logic
    }
}
```

`externalBridge` is a strong, non-optional reference. `LogiIntegrationBridge.shared` is a permanent singleton; no retain-cycle risk because the bridge holds no Logi references. Per Round 2 micro-bench: strong existential call ≈ 0.892 ns/op vs. weak optional existential ≈ 37 ns/op.

**Startup wiring (AppDelegate):**

```swift
// 1. Bridge installed first (mandatory before start)
LogiCenter.shared.installBridge(LogiIntegrationBridge.shared)
// 2. (F2) Bootstrap initial usage from Options
LogiUsageBootstrap.refreshAll()
// 3. Now start
LogiCenter.shared.start()
```

### 4.5 LogiUsageBootstrap (F2)

`Mos/Integration/LogiUsageBootstrap.swift` reads the current state of `Options.shared.*` once at app launch and pushes initial usage to `LogiCenter`. This guarantees a release build diverts correctly without the user opening Preferences.

```swift
enum LogiUsageBootstrap {
    /// Push current state of all Logi-relevant Options to LogiCenter.
    /// Idempotent: subsequent panel saves push their own slice.
    static func refreshAll() {
        // 1. Button bindings (mouse-typed, Logi codes only)
        let buttonCodes = Set(
            ButtonUtils.shared.getButtonBindings()
                .filter { $0.isEnabled && $0.triggerEvent.type == .mouse }
                .map { $0.triggerEvent.code }
                .filter { LogiCenter.shared.isLogiCode($0) }
        )
        LogiCenter.shared.setUsage(source: .buttonBinding, codes: buttonCodes)

        // 2. Global scroll
        for role in ScrollRole.allCases {
            let codes = collectGlobalScrollCodes(for: role)
            LogiCenter.shared.setUsage(source: .globalScroll(role), codes: codes)
        }

        // 3. App scroll (each !inherit app, each role)
        let apps = Options.shared.application.applications
        for i in 0..<apps.count {
            guard let app = apps.get(by: i), !app.inherit else { continue }
            for role in ScrollRole.allCases {
                let codes = collectAppScrollCodes(for: app, role: role)
                LogiCenter.shared.setUsage(source: .appScroll(key: app.path, role: role), codes: codes)
            }
        }
    }
}
```

Preference panels' save paths still call `setUsage(...)` per-source, identical to bootstrap output for that source.

### 4.6 ConflictDetector update (F6)

The conflict detector's existing input set is `(reportingFlags, targetCID, cid, reportingQueried)`. As of commit `195908a`, the rule "device reportingFlags non-zero ⇒ third-party" is wrong because Mos's own divert bit also reads back. New input adds `mosOwnsDivert: Bool`:

```swift
public enum ConflictStatus { case clear, conflict, mosOwned, unknown }

enum ConflictDetector {
    static func status(reportingFlags: UInt8,
                       targetCID: UInt16,
                       cid: UInt16,
                       reportingQueried: Bool,
                       mosOwnsDivert: Bool) -> ConflictStatus {
        guard reportingQueried else { return .unknown }
        if mosOwnsDivert { return .mosOwned }
        if reportingFlags == 0 && (targetCID == 0 || targetCID == cid) { return .clear }
        return .conflict
    }
}
```

The Status column rendering in `LogiDebugPanel` already implements the equivalent at `LogiDebugPanel.swift:2089–2099` via `isMosDivert` exclusion (commit `195908a`); this section migrates the logic into `ConflictDetector` so all consumers share one rule.

### 4.7 Boundary enforcement (F5)

Same-Xcode-target `internal` does NOT prevent non-facade Logi symbols from being referenced outside `Mos/Logi/`. To enforce the boundary, a CI pre-commit hook / lint rule:

```bash
# scripts/lint-logi-boundary.sh
ALLOWED_SYMBOLS=(LogiCenter UsageSource ScrollRole ConflictStatus
                 LogiExternalBridge LogiDispatchResult LogiToastSeverity Direction
                 LogiDeviceSessionSnapshot SessionActivityStatus)
# grep for any 'Logi*' or 'Logitech*' symbol referenced outside Mos/Logi/ and
# Mos/Integration/, fail if it's not in ALLOWED_SYMBOLS.
```

Test plan also includes a unit test that loads the Mos source tree and asserts no forbidden symbol references exist outside the allowed dirs.

## 5. Persistence invariants (frozen)

| Key / name | Location | Notes |
|---|---|---|
| `UserDefaults["logitechFeatureCache"]` | `LogiDeviceSession.featureCacheKey` | JSON `[String(productId): [FeatureID: Index]]`. **Literal string preserved** even after class rename. |
| `NSSplitView.autosaveName = "HIDDebug.FeaturesControls.v3"` | Debug panel `LogiDebugPanel.swift:566` | AppKit autosave (UserDefaults). Literal preserved. |

External persistence Logi touches but does not own:
- `Options.shared.buttons.binding`
- `Options.shared.scroll.*`
- `Options.shared.application.applications[*].scroll.*`

Zero new persistence keys introduced. `UsageRegistry.sources` and per-session `lastApplied` are in-memory only; `LogiUsageBootstrap.refreshAll()` re-populates from Options at app launch.

**Persistence canary (F22 — independent hard-coded golden list):**

```swift
final class LogiPersistenceCanaryTests: XCTestCase {
    private static let frozenAutosaveNames: [String] = [
        "HIDDebug.FeaturesControls.v3",
        // If a new autosaveName is introduced, this list MUST be updated by hand.
        // Do NOT generate it from production code; that would defeat the canary.
    ]

    func test_userDefaultsKey_unchanged() {
        XCTAssertEqual(LogiDeviceSession.featureCacheKeyForTests, "logitechFeatureCache")
    }

    func test_autosaveNames_match_golden() {
        // collectAutosaveNamesFromCodebase() reflects production literals.
        // Test fails when production drifts from the hard-coded golden above,
        // forcing a deliberate update to frozenAutosaveNames.
        XCTAssertEqual(LogiDebugPanel.collectAutosaveNamesFromCodebase().sorted(),
                       Self.frozenAutosaveNames.sorted())
    }
}
```

## 6. Migration plan (6 commits)

Per-commit requirements: Tier 1 + Tier 2 green, Tier 3 green on dev machine when device attached, build clean, Codex plan + code review × 2 at gpt-5.5 xhigh.

### Step 0 — HID alloc + reportingDidComplete cleanup (pre-refactor, isolated)

Two existing bugs the spec stumbled across that should land before the refactor:

- **(F11) Remove per-input-report `Array(UnsafeBufferPointer(...))` allocation** at `LogitechDeviceSession.swift:319–322`. Change `handleInputReport(_ data: [UInt8])` to take `UnsafeBufferPointer<UInt8>` and decode in place. Immediate hot-path win; orders of magnitude larger than anything the v1 spec was budgeting in nanoseconds.
- **(F8) Fix `reportingDidComplete` empty-controls path.** At `LogitechDeviceSession.swift:1529`, when the discovered controls list is empty, the path calls `divertBoundControls()` then returns without posting `reportingQueryDidCompleteNotification`. Wizard step `wait reportingDidComplete` would hang. Post the notification on every terminal path.

Risk: very low. Both are localized to existing code, no API change, no rename. Tier 2 / Tier 3a tests added in Step 3 will rely on (F8).

### Step 1 — Rename (mechanical, zero semantic change)

- Dir: `Mos/LogitechHID/` → `Mos/Logi/` (flat during this step; subdirs in Step 5)
- Classes: `LogitechHID*` / `Logitech*` → `Logi*` (Xcode Refactor → Rename)
- ScrollCore method: `handleScrollHotkeyFromHIDPlusPlus` → `handleScrollHotkey`
- Notification static-let names and string values: `"LogitechHID*"` → `"Logi*"` (in-process only, safe)
- KeyRecorder's literal `"LogitechHIDButtonEvent"` subscription renamed to match
- Frozen: `"logitechFeatureCache"` UserDefaults key; `"HIDDebug.FeaturesControls.v3"` autosave name
- Tests added: `LogiPersistenceCanaryTests`, `LogiCIDDirectoryTests`

Risk: near zero. Compiler catches missed call sites; canary tests catch persistence drift.

### Step 2 — LogiCenter facade (no UsageRegistry yet)

- New `LogiCenter.swift` that delegates to `LogiSessionManager.shared`.
- `LogiSessionManager` demoted to `internal`.
- All external call sites rewritten to `LogiCenter.shared.xxx`. Concrete inventory:
  - `AppDelegate.swift` (start/stop)
  - `Shortcut/ShortcutExecutor.swift` (executeSmartShiftToggle / executeDPICycle)
  - `Managers/StatusItemManager.swift:107` (showDebugPanel) (F19)
  - `Windows/PreferencesWindow/PreferencesWindowController.swift:35` (refreshReportingStatesIfNeeded) (F16)
  - `Windows/PreferencesWindow/ButtonsView/PreferencesButtonsViewController.swift` (refreshReportingStatesIfNeeded, isBusy, currentActivitySummary, activityStateDidChange notification) (F16)
  - `Windows/PreferencesWindow/ButtonsView/ButtonTableCellView.swift` (conflictStatus + sessionChanged + reportingDidComplete notifications)
  - `InputEvent/InputEvent.swift`, `Components/BrandTag.swift`, `Windows/PreferencesWindow/ButtonsView/RecordedEvent.swift`, `Windows/PreferencesWindow/ButtonsView/ActionDisplayResolver.swift`, `Windows/PreferencesWindow/ScrollingView/PreferencesScrollingViewController.swift` — all `LogitechCIDRegistry.{isLogitechCode,name(forMosCode:)}` calls rewritten to `LogiCenter.shared.{isLogiCode,name(forMosCode:)}` (F18)
  - `Keys/KeyRecorder.swift:131,521` — `temporarilyDivertAll` / `restoreDivertToBindings` rewritten to `LogiCenter.shared.beginKeyRecording()` / `endKeyRecording()`. The session-internal helpers are kept private inside `LogiDeviceSession`.
- (F17 sequencing) `LogiCenter` test-injectable `internal init(manager:bridge:clock:)` added — **without** `registry` parameter; UsageRegistry is introduced in Step 3 and the init grows a `registry:` parameter then. Step 2 facade remains buildable in isolation.
- `LogiExternalBridge` protocol + `LogiNoOpBridge` declared with bodies stubbed.
- `installBridge(_:)` API exposed; AppDelegate calls it with `LogiNoOpBridge.shared` for now.
- Tests added: `LogiCenterPublicSurfaceTests` (Tier 1), `LogiCenterHarnessTests` (Tier 2, no UsageRegistry coverage yet).

Risk: low. No HID behavior change. `internal` boundary not yet enforced by lint; that lands at Step 5.

### Step 3 — UsageRegistry + LogiUsageBootstrap + preference panel migration

- `UsageRegistry.swift` + `UsageSource.swift` created.
- `LogiCenter` init grows `registry:` parameter; `setUsage(source:codes:)` + `usages(of:)` added.
- `LogiDeviceSession.applyUsage(_:)` added; `lastApplied` per-session field added.
- Five preference VC call sites rewritten to `LogiCenter.shared.setUsage(...)`:
  - `PreferencesButtonsViewController.syncViewWithOptions`
  - `PreferencesScrollingViewController` (lines 99, 110, 121, 182, 368)
  - `PreferencesScrollingWithApplicationViewController` (line 67)
  - `PreferencesApplicationViewController` (line 89)
- (F2) `LogiUsageBootstrap.refreshAll()` called from `AppDelegate` before `LogiCenter.shared.start()`.
- Deleted: `LogiSessionManager.syncDivertWithBindings()`, `LogiDeviceSession.collectBoundLogiMosCodes()`.
- (F13) `LogiSessionManager.refreshReportingStatesIfNeeded()` rewritten: instead of scanning Options to decide whether any Logi binding exists, it short-circuits on `registry.aggregatedCacheIsEmpty`.
- (F14) `LogiDeviceSession`'s state-reset paths integrated with prime hooks per §4.3:
  - `divertBoundControls()` → schedules `applyUsage(registry.aggregate)` after first ready
  - `setTargetSlot(slot:)` → resets `lastApplied`; `applyUsage` re-runs after rediscovery
  - `rediscoverFeatures()` → same
  - `redivertAllControls()` → clears `divertedCIDs` then `applyUsage(registry.aggregate)`
  - `restoreDivertToBindings()` → `applyUsage(registry.aggregate)`
- (F15) `Application` deletion path in preferences calls `setUsage(.appScroll(key: app.path, role: .dash), codes: [])` for each role to drop the source from the registry; since `setUsage` removes empty sources (F21), the registry stays clean.
- Tests added: `UsageRegistryTests` (Tier 1), extended `LogiDivertPlannerTests` (Tier 1), `UsageRegistryEndToEndTests` (Tier 2 with realistic FakeLogiDeviceSession per F23), `LogiCenterDeviceIntegrationTests` (Tier 3a with 0 → 1 → 0 baseline per F24).

Risk: medium. Semantic change — divert driver switches from synchronous scan to coalesced async + per-session prime. Tier 2 covers reconnect-no-diff (F4 regression test). Tier 3a baseline (F24) proves Mos is the actor.

### Step 4 — Bridge inversion (full protocol)

- `LogiExternalBridge` filled out: `dispatchLogiButtonEvent` returns `LogiDispatchResult`, plus `handleLogiScrollHotkey` and `showLogiToast`.
- New `Mos/Integration/LogiIntegrationBridge.swift` as production impl.
- `LogiDeviceSession.handleButtonEvent` rewritten to §4.4 form (raw event post first, recording short-circuit, side-path scroll hotkey, main routing switch).
- `LogiDeviceSession.teardown` ScrollCore clear-path rewritten via bridge.
- `LogiDeviceSession.showFeatureNotAvailable()` calls `bridge.showLogiToast(...)` (F12).
- All Logi imports of `ScrollCore` / `ButtonUtils` / `InputProcessor` / `Toast` removed.
- `AppDelegate` swaps `LogiNoOpBridge.shared` for `LogiIntegrationBridge.shared` via `installBridge`.
- `LogiCenter.rawButtonEvent` notification name added; session posts unconditionally before dispatch (F9).
- Tests added: `LogiBridgeDispatchTests` (Tier 2 — recording short-circuit, .logiAction routing, .consumed paths), `LogiTeardownTests` (Tier 2), `LogiFeatureActionDeviceTests` (Tier 3b), `LogiBridgeDeviceTests` (Tier 3a).

Risk: medium. Hot path. Tier 2 covers routing sequence; Tier 3 covers real-device round-trip.

### Step 5 — Subdirectory tidy + Self-Test Wizard + lint enforcement

- Flat files inside `Mos/Logi/` moved into `Core/` / `Usage/` / `Divert/` / `Bridge/` / `Debug/` per 4.1.
- New `LogiSelfTestWizard.swift` + `LogiSelfTestRunner.swift` (DEBUG-only, ~500 LOC).
- Status bar menu item "Logi Self-Test..." (DEBUG build only) added.
- (F5) `scripts/lint-logi-boundary.sh` added; pre-commit hook + CI run it.
- (F5 test) `LogiBoundaryEnforcementTests.swift` greps the source tree and asserts no forbidden Logi symbols outside `Mos/Logi/` + `Mos/Integration/`.
- `ConflictDetector.status(...)` extended with `mosOwnsDivert:` parameter (F6); `LogiDebugPanel` Status column rewired to call detector; equivalent rule preserved.

Risk: very low. File moves + new debug-only feature + lint script.

## 7. Test plan

### Tier 1 — pure logic (always runs)

| File | Coverage |
|---|---|
| `LogiPersistenceCanaryTests.swift` | UserDefaults key + autosave name match independent golden list (F22) |
| `LogiCIDDirectoryTests.swift` | `toCID` / `toMosCode` bidirectional symmetry |
| `UsageRegistryTests.swift` | diff algorithm, coalescing guard, idempotent short-circuit, empty-codes removeValue (F21), `appScroll(key:)` deletion clears source (F15) |
| `LogiDivertPlannerTests.swift` (extend) | multi-source same-CID, source-deletion semantics |
| `LogiConflictDetectorTests.swift` | new `mosOwnsDivert` axis (F6); cases: (mosOwnsDivert=true, flags!=0) → mosOwned; (mosOwnsDivert=false, flags!=0) → conflict; (clear) → clear |
| `LogiBoundaryEnforcementTests.swift` | grep source tree, fail if non-allowed Logi symbol referenced outside permitted dirs (F5) |

### Tier 2 — harness (always runs, fake session/bridge)

`MosTests/LogiTestDoubles/`:
- `FakeLogiSessionManager`
- `FakeLogiDeviceSession` (F23 — full model: `divertedCIDs: Set<UInt16>`, `divertableCIDs: Set<UInt16>`, planner-equivalent `applyUsage(_:)`, `lastApplied: Set<UInt16>`, slot-switch / rediscover / teardown simulation)
- `FakeLogiExternalBridge` (records call sequence, programmable return values)

| File | Coverage |
|---|---|
| `LogiCenterHarnessTests.swift` | Injectable init, `installBridge` precondition, `start()` after install, start/stop idempotency, notification contracts |
| `UsageRegistryEndToEndTests.swift` | Multiple `setUsage` same main-queue task → single `runRecompute` call; aggregated diff applied to all ready FakeLogiDeviceSessions; **(F4 reconnect)** S1 applies A → S1 disconnects (lastApplied wiped) → S2 connects → primed with A; **(F4 slot switch)** session.setTargetSlot resets lastApplied → re-prime |
| `LogiBridgeDispatchTests.swift` | (F3) recording → bridge returns .consumed, scroll hotkey NOT called; (F1) non-recording + logi* → bridge returns .logiAction(name), session executes; non-recording + non-logi binding → InputProcessor consumes → bridge returns .consumed; (F9) rawButtonEvent posted in all paths |
| `LogiTeardownTests.swift` | `lastActiveCIDs` teardown emits `handleLogiScrollHotkey(phase: .up)` via bridge before HID release |
| `LogiUsageBootstrapTests.swift` | (F2) `refreshAll()` reads Options state and pushes one setUsage per source; idempotent on re-run |

### Tier 3 — real-device integration (gated by `LOGI_REAL_DEVICE=1`)

Gate base class:

```swift
class LogiDeviceIntegrationBase: XCTestCase {
    static var hasDevice: Bool { ProcessInfo.processInfo.environment["LOGI_REAL_DEVICE"] == "1" }
    override func setUpWithError() throws {
        try XCTSkipUnless(Self.hasDevice, "requires LOGI_REAL_DEVICE=1")
    }
}
```

| File | Coverage |
|---|---|
| `LogiCenterDeviceIntegrationTests.swift` | (F24) **0 → 1 → 0 baseline**: GetControlReporting on chosen CID asserts initial bit0 == 0 (else SKIP "third-party owns this CID"); then setUsage → wait reportingDidComplete → assert bit0 == 1 + divertedCIDs contains it; then setUsage([]) → wait → assert bit0 == 0 |
| `LogiFeatureActionDeviceTests.swift` | `executeDPICycle(.up)` → DPI register change |
| `LogiBridgeDeviceTests.swift` | Scroll hotkey / button event end-to-end through bridge |

Test plans:
- `Debug.xctestplan` → Tier 1 + Tier 2 (CI safe)
- `DebugWithDevice.xctestplan` → all three tiers (dev machine)

### Tier 3c — interactive Self-Test Wizard

DEBUG-only SwiftUI/AppKit wizard accessible from status bar menu "Logi Self-Test...".

**Step kinds:**

```swift
enum StepKind {
    case automatic(detail: String, run: () async throws -> StepOutcome)
    case physicalAutoVerified(instruction: String, expectation: String,
                              wait: WaitCondition, timeout: TimeInterval)
    case physicalUserConfirmed(instruction: String, expectation: String,
                               confirmPrompt: String)
}

enum WaitCondition {
    case rawButtonEvent(cid: UInt16)             // (F9) deterministic raw signal
    case sessionConnected(ConnectionMode)
    case sessionDisconnected
    case divertApplied(cid: UInt16, expectBit0: Bool)
    case dpiChanged(snapshot: LogiDeviceSessionSnapshot, direction: Direction)
}
```

**Per-step liveness (F25):**

Every wait registers a cancellation token for: session disconnect, app teardown, user-pressed Cancel button. Cancellation always wins over timeout; on cancel the step shows "device dropped — retry / skip / abort".

**Connection detection** (first step, deterministic):

```swift
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
```

User guarantees one Logi device at a time. Wizard takes the first connected session and auto-picks the first connected slot. No manual selection.

**Bolt suite (14 steps; 1 user-confirmed):**

1. automatic — `start()`, wait first session
2. automatic — `detectConnection()`, display result
3. automatic — wait `reportingDidComplete` (F8 ensures empty-controls path also fires)
4. automatic — `setUsage(.buttonBinding, [codeBack])` → wait `divertApplied(0x0053, true)`
5. physicalAutoVerified — "press Back Button" / wait `rawButtonEvent(0x0053)` / 5s timeout (F9)
6. **physicalUserConfirmed** — "Did Mos intercept the default Back behavior?"
7. automatic — `setUsage(.buttonBinding, [])` → wait `divertApplied(0x0053, false)`
8. automatic — `executeDPICycle(.up)` → wait `dpiChanged` → assert direction
9. automatic — `executeSmartShiftToggle()` → assert smartShift mode toggled
10. automatic — `beginKeyRecording()` → assert all divertable CIDs in divertedCIDs (per current snapshot)
11. physicalAutoVerified — "press any Logi button in 5s" / wait `rawButtonEvent(any)`
12. automatic — `endKeyRecording()` → assert divertedCIDs back to bound codes
13. physicalAutoVerified — "unplug Bolt receiver" / wait `sessionDisconnected`
14. physicalAutoVerified — "replug Bolt" / wait `sessionConnected(.receiver)` + `reportingDidComplete`

**BLE suite (~9 steps):** same as Bolt minus slot enumeration; plug/unplug replaced with "power off / power on BLE peripheral".

**Reporting:** final summary shows pass/fail counts + log path. Failed steps offer "retry" / "skip and continue" / "abort and export log".

## 8. Performance budget

Numbers from Round 2 micro-bench on Apple M4 Pro, `swiftc -O`. Baseline (`100M ops`):

```
direct final method call           : 0.668 ns/op
existential method call (param)    : 0.892 ns/op
strong-stored existential (outside): 0.891 ns/op
strong-stored existential (inside) : 21.976 ns/op
weak-stored existential (outside)  :  0.895 ns/op
weak-stored existential (inside)   : 37.430 ns/op
```

"inside" = bridge fetched per iteration; "outside" = fetched once before the loop. Hot path fetches once per event, so the relevant numbers are **strong/weak outside ≈ 0.9 ns** — not the inside-loop figures.

### Hot path 1 — per Logi button event (down and up each fire)

| Phase | Before (current code) | After (this design) | Delta |
|---|---|---|---|
| Strong externalBridge load + dispatch | direct `ScrollCore.shared.handleXxx` | strong let + witness dispatch ≈ 0.9 ns | ≈0 |
| Recording short-circuit | `LogitechHIDManager.shared.isRecording` read | same; bridge returns .consumed | 0 |
| Logi* fast-path probe | `ButtonUtils.shared.getBestMatchingBinding` (in session) | same call but in bridge; same complexity | 0 |
| Generic dispatch (`InputProcessor.shared.process`) | direct call | bridge → InputProcessor (1 witness) | +0.9 ns |
| `rawButtonEvent` post (NEW) | not present | 1× `NotificationCenter.post` on every event | +1 μs |
| recording / non-consumed `buttonEventRelay` post | 1× `NotificationCenter.post` | unchanged | 0 |

**Net: +1 μs per event.** This is dominated by the new `rawButtonEvent` post (F9). It is required for deterministic wizard observers and debug panel raw-event display. At a worst-case 50 Hz button rate (sustained mash), 0.005% CPU. Acceptable.

If the rawButtonEvent allocation becomes a problem in the future, two follow-ups: (a) gate it behind `LogiCenter.shared.hasRawObservers` (fast bool check), or (b) replace with a dedicated callback list (no userInfo dict). Out of scope for this refactor.

### Hot path 2 — panel save → divert apply

Before: synchronous `syncDivertWithBindings` per session scans all of `Options.{buttons,scroll,application}`, O(bindings + apps × 3) on the main thread.

After: `setUsage` is O(|codes|) — dict read/write + Set equality + bool flag. `DispatchQueue.main.async` from main schedules `runRecompute` to drain after the current main-queue item returns (F20 — not "next runloop tick"; "after current task"). Multiple `setUsage` calls within the same main-queue task coalesce into one apply; calls across separate tasks (rare) do not coalesce, but each is independently cheap.

`runRecompute` is O(|aggregatedCache| × |sessions|); per session computes diff vs its own `lastApplied`, emits HID IO only for the actual delta. Reconnects naturally re-prime because `lastApplied` was wiped on teardown.

### Step 0 — pre-existing hot-path heap allocation (F11)

`LogitechDeviceSession.swift:319–322`:
```swift
let data = Array(UnsafeBufferPointer(start: report, count: reportLength))
session.handleInputReport(data)
```

Allocates a heap `Array<UInt8>` per HID input report. At ~125 Hz typical input report rate (mouse polling), that is ~125 heap allocations per second per session. Step 0 changes this to:

```swift
let buffer = UnsafeBufferPointer(start: report, count: reportLength)
session.handleInputReport(buffer)
```

`handleInputReport` and downstream parsers updated to take `UnsafeBufferPointer<UInt8>` and use indexed access. Lifetime is bounded by the C callback, so no extension-over-callback hazard. Estimated win: ~125 × ~50 ns = ~6 μs/sec saved per session, plus eliminates allocator pressure.

### Step 0 — `reportingDidComplete` empty-controls path (F8)

`LogitechDeviceSession.swift:1529` calls `divertBoundControls()` and returns; the post site is at line 1570 inside the non-empty branch. Add a single post in the empty branch so wizard waits and Tier 3a tests do not hang.

### Hot-path constraints (acceptance gates per F27)

The following are **operational** acceptance criteria (verifiable by code review and tests), replacing the v1 spec's non-verifiable "≤ 5 ns" claim:

- **(G1)** `LogiDeviceSession.handleButtonEvent` body must contain at most one `NotificationCenter.post` call per branch (rawButtonEvent always; bridge handles the conditional buttonEventRelay).
- **(G2)** `LogiDeviceSession.handleButtonEvent` body must contain zero `DispatchQueue.*` calls.
- **(G3)** `LogiIntegrationBridge.dispatchLogiButtonEvent` body must contain zero `DispatchQueue.*` calls.
- **(G4)** `LogiDeviceSession.handleInputReport` accepts `UnsafeBufferPointer<UInt8>`, not `[UInt8]`. (Step 0)
- **(G5)** `LogiCenter.externalBridge` is `let`-stored or strong `var` — never `weak`.
- **(G6)** `UsageRegistry.setUsage` body contains zero loops over codes (work is dict + Set + bool).
- **(G7)** `runRecompute` reads `aggregatedCache` (or recomputes from `sources`); never reads `Options.shared.*`.

CI grep enforces G1–G7 in addition to test coverage.

### Memory budget

| Structure | Bound |
|---|---|
| `UsageRegistry.sources` | 1 buttonBinding + 3 globalScroll + 3×N_apps appScroll. Typical N=10 → 34 sources × ≤ 10 codes ≈ 2.7 KB. Ceiling at 100 apps: ~24 KB (F26). |
| `UsageRegistry.aggregatedCache` | union of all source codes; bounded by ~30 distinct Logi mouse codes ≈ 480 B |
| Per-session `lastApplied` | same upper bound × N_sessions; typical 1–2 sessions ≈ < 1 KB |
| **LogiCenter new memory total** | < 30 KB at 100 apps × 3 roles, < 4 KB typical. |

### Main-thread-only guard

```swift
#if DEBUG
func setUsage(source: UsageSource, codes: Set<UInt16>) {
    precondition(Thread.isMainThread, "LogiCenter is main-thread-only")
    // ...
}
#endif
```

Same precondition added at:
- `LogiCenter.installBridge`
- `LogiCenter.start` / `stop`
- `LogiDeviceSession.handleInputReport` (currently no guard despite manager scheduling on main RunLoop)
- `UsageRegistry.runRecompute`

## 9. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Missing a preference save site during Step 3 migration, causing divert to drift | M | After migration `syncDivertWithBindings` symbol is deleted, so any survivor fails compile. Tier 3a baseline test verifies divert end-to-end. |
| Bridge wired late or never (e.g., test target running app fragment) | L | `installBridge` precondition asserts in DEBUG; production path goes through AppDelegate which always installs. |
| Rename breaks persisted UserDefaults via accidental constant change | L | `LogiPersistenceCanaryTests` with hard-coded golden list (F22). |
| Async recompute racing with session teardown | L | Main-thread-only enforced; sessionProvider snapshot taken at recompute time; teardown resets per-session lastApplied so a future reconnect re-primes correctly. |
| Tier 3 tests hang when device drops mid-test | L | All waits use `XCTestExpectation` 30 s timeout AND register cancellation tokens (F25); session liveness checks per step. |
| Self-Test Wizard becomes bitrot-prone | M | DEBUG-only; runs on every significant Logi change; failures immediately visible. CI warning if wizard not run within last N changes (post-refactor follow-up). |
| Per-session `lastApplied` desync if Step 3 misses a reset hook | M | Six prime hooks listed in §4.3 are exhaustive and tested in Tier 2 (`UsageRegistryEndToEndTests` exercises each). |
| Logi* binding probed in bridge but no longer matches in session context | L | `dispatchLogiButtonEvent` returns the resolved name; session executes via its own `executeLogiAction(name:)` switch. ButtonUtils still consulted, but only inside the bridge (which lives in `Mos/Integration/`). |
| `rawButtonEvent` notification overhead (~1 μs/event) | L | Acceptable at sub-100 Hz event rate. Optimization paths documented as out-of-scope follow-ups (§8 Hot path 1). |
| Step 0 `UnsafeBufferPointer` lifetime mishandled | M | Buffer scope is the C callback; `handleInputReport(buffer)` must NOT escape the buffer. Code review gate: search for buffer escape; tests assert decode produces same byte sequence as Array path on a sample. |

## 10. Out-of-scope open questions (deferred, not blocking)

- Whether to expose `UsageSource` diagnostic ("bound by app:Chrome scroll.dash") in the release Debug panel (currently wizard-only). Decision deferred to post-migration UX pass.
- Replacing `rawButtonEvent` NotificationCenter post with a direct callback list to remove the 1 μs/event overhead. Negligible in practice; revisit if profiler ever flags it.
- Future: merging scroll-hotkey and button-binding data models into one storage layer. Not this refactor.
- Future: migrating `Application` persistence identity from `path` to `bundleId`. UsageSource accepts `key:` so the spec is forward-compatible.

## 11. Acceptance criteria

This refactor is complete when:

- [ ] All six migration steps (0–5) committed with Codex plan + code review × 2 (gpt-5.5 xhigh) each
- [ ] `Mos/Logi/` contains all Logi code; no file in that dir imports `ScrollCore`, `ButtonUtils`, `InputProcessor`, `Options`, `PreferencesWindow`, or `Toast`
- [ ] CI lint (F5) passes: outside `Mos/Logi/` and `Mos/Integration/`, only the public surface symbols appear: `LogiCenter`, `UsageSource`, `ScrollRole`, `ConflictStatus`, `LogiExternalBridge`, `LogiDispatchResult`, `LogiToastSeverity`, `Direction`, `LogiDeviceSessionSnapshot`, `SessionActivityStatus`. All other Logi types are `internal`.
- [ ] `syncDivertWithBindings` and `collectBoundLogiMosCodes` symbols are deleted
- [ ] `Debug.xctestplan` all green; `DebugWithDevice.xctestplan` all green with device attached
- [ ] Self-Test Wizard: Bolt suite 14/14 pass on real Bolt receiver; BLE suite all pass on a real BLE peripheral
- [ ] Persistence canary test green; verified that `"logitechFeatureCache"` still loads on upgrade from pre-refactor build
- [ ] Hot-path operational gates G1–G7 (§8) pass on code review
- [ ] Codex code review × 2 at gpt-5.5 xhigh across all six commits: no blocking issues
- [ ] AppDelegate launch order: `installBridge` → `LogiUsageBootstrap.refreshAll` → `LogiCenter.start` (verified by launch test)
