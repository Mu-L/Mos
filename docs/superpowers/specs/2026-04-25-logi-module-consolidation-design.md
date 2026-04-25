# Logi Module Consolidation — Design Spec

**Date**: 2026-04-25
**Status**: Design (pre-implementation)
**Supersedes**: N/A
**Related**:
- `2026-03-16-logitech-hid-integration-design.md` (original HID++ integration)
- `2026-03-21-logitech-cid-registry-design.md`
- `2026-03-30-hidpp-debug-panel-redesign.md`

## 1. Problem

Logi-specific code is scattered across `Mos/LogitechHID/` and leaks into the rest of the app through three patterns:

1. **Reverse scan of preferences**: `LogitechDeviceSession.collectBoundLogiMosCodes()` walks `Options.shared.buttons.binding`, `Options.shared.scroll.{dash,toggle,block}`, and per-app scroll hotkeys. Logi drives divert by pulling from three sources the module has no business knowing.
2. **Reverse call into ScrollCore**: `LogitechDeviceSession.handleButtonEvent` / `teardown` directly call `ScrollCore.shared.handleScrollHotkeyFromHIDPlusPlus`. Session also calls `ButtonUtils.shared.getBestMatchingBinding` and `InputProcessor.shared.process`, and posts `"LogitechHIDButtonEvent"` for KeyRecorder.
3. **No single API surface**: 20+ call sites outside the dir reach directly into `LogitechHIDManager.shared`, `LogitechCIDRegistry`, `LogitechConflictDetector`. Each preference controller calls `syncDivertWithBindings()` after save.

Symptom felt by users: "按键偏好页说 Back Button 未绑定,但 Debug 面板仍显示 DVRT" — because the scroll panel or per-app panel holds a hidden binding Logi picks up via reverse scan. Symptom felt by maintainers: adding a new Logi feature requires editing 5-10 files across unrelated modules.

## 2. Goals

1. **Single module boundary**: all Logi code lives in `Mos/Logi/`. Module does not import business modules (`ScrollCore`, `ButtonUtils`, `InputProcessor`, `Options`, `PreferencesWindow`).
2. **Single public facade**: `LogiCenter.shared` is the only symbol external code imports. Internal types (`LogiSessionManager`, `LogiDeviceSession`, etc.) are `internal`.
3. **Push-driven usage model**: preference panels declare "this source uses these codes" via `LogiCenter.shared.setUsage(source:codes:)`. Logi does not scan Options.
4. **Inverted external dependencies**: ScrollCore / ButtonUtils / InputProcessor access lives behind a `LogiExternalBridge` protocol implemented outside the Logi module.
5. **Persistence byte-compatible**: `UserDefaults["logitechFeatureCache"]` and all `"HIDDebug.*"` `autosaveName` strings frozen. Zero new persistence keys.
6. **Call overhead optimal**: hot path (per-button-press) adds ≤ 5 ns per event. Coalesced batch for panel-save path replaces N-way synchronous recompute.
7. **Test coverage**: pure logic (Tier 1) + harness tests (Tier 2) + real-device integration tests (Tier 3a/b) + interactive self-test wizard (Tier 3c).

## 3. Non-goals

- Changing HID++ protocol layer or feature action semantics.
- Migrating persistence formats. Schema and UserDefaults keys frozen.
- Changing preference UI layout (button/scroll/application panels keep current shape).
- Unifying scroll-hotkey and button-binding data models. Separation stays.
- Breaking the existing Codex review / dev workflow (two rounds per plan, two rounds per code).

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
│   └── ConflictDetector.swift              # was LogitechConflictDetector
├── Bridge/
│   └── LogiExternalBridge.swift            # protocol + DispatchResult enum
└── Debug/
    ├── LogiDebugPanel.swift                # was LogitechHIDDebugPanel
    ├── BrailleSpinner.swift
    ├── LogiSelfTestWizard.swift            # new (DEBUG only)
    └── LogiSelfTestRunner.swift            # new (DEBUG only)

Mos/Integration/
└── LogiIntegrationBridge.swift             # protocol's production impl; imports ScrollCore/ButtonUtils/InputProcessor
```

### 4.2 LogiCenter public surface

```swift
final class LogiCenter {
    static let shared: LogiCenter

    // Lifecycle
    func start(); func stop()

    // Usage registration (drives divert)
    func setUsage(source: UsageSource, codes: Set<UInt16>)
    func usages(of code: UInt16) -> [UsageSource]

    // CID directory (read-only)
    func isLogiCode(_ code: UInt16) -> Bool
    func name(forMosCode code: UInt16) -> String?

    // Conflict (for ButtonTableCellView etc.)
    func conflictStatus(forMosCode code: UInt16) -> ConflictStatus

    // Recording
    func beginKeyRecording(); func endKeyRecording()
    var isRecording: Bool { get }

    // Feature actions (called from ShortcutExecutor)
    func executeSmartShiftToggle()
    func executeDPICycle(direction: Direction)

    // Debug panel
    func showDebugPanel()

    // Activity (global busy indicator)
    var isBusy: Bool { get }

    // External bridge wiring
    weak var externalBridge: LogiExternalBridge?

    // Namespaced notifications
    static let sessionChanged:        Notification.Name
    static let discoveryStateChanged: Notification.Name
    static let reportingDidComplete:  Notification.Name
    static let activityChanged:       Notification.Name
    static let conflictChanged:       Notification.Name
    static let buttonEventRelay:      Notification.Name   // for KeyRecorder only
}

extension LogiCenter {
    // Test-injectable constructor (internal)
    internal convenience init(manager: LogiSessionManager,
                              registry: UsageRegistry,
                              clock: Clock = .system)
}
```

Production code uses `.shared` exclusively. Tests construct isolated instances via the internal init with fake manager/registry to avoid cross-test state leaks.

### 4.3 UsageRegistry

```swift
enum UsageSource: Hashable {
    case buttonBinding                                   // aggregated button panel
    case globalScroll(ScrollRole)                        // global scroll panel
    case appScroll(bundleId: String, role: ScrollRole)   // per-app
}
enum ScrollRole: Hashable { case dash, toggle, block }

final class UsageRegistry {
    // Session provider injected at init time so the registry does not depend on a
    // concrete session manager type (keeps Tier 2 harness tests trivial).
    private let sessionProvider: () -> [LogiDeviceSession]
    init(sessionProvider: @escaping () -> [LogiDeviceSession]) {
        self.sessionProvider = sessionProvider
    }

    private var sources: [UsageSource: Set<UInt16>] = [:]
    private var aggregatedCache: Set<UInt16> = []
    private var aggregatedDirty: Bool = true
    private var lastApplied: Set<UInt16> = []
    private var recomputeScheduled: Bool = false
    // main-thread-only; no locks
}

// Production wiring (inside LogiCenter):
//   self.registry = UsageRegistry(sessionProvider: { [weak manager] in
//       manager?.activeSessions ?? []
//   })
```

**Push API** (the only mutator):
```swift
func setUsage(source: UsageSource, codes: Set<UInt16>) {
    if sources[source] == codes { return }          // idempotent short-circuit
    sources[source] = codes
    aggregatedDirty = true
    scheduleRecompute()
}
```

**Coalesced recompute** — multiple `setUsage` in the same runloop tick collapse to one apply:
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
    if aggregatedCache == lastApplied { return }
    let added   = aggregatedCache.subtracting(lastApplied)
    let removed = lastApplied.subtracting(aggregatedCache)
    lastApplied = aggregatedCache
    for session in sessionProvider() where session.isHIDPPCandidate {
        session.applyUsageDiff(added: added, removed: removed)
    }
}
```

**Session prime** — new sessions pull current aggregate immediately on first-ready, not through coalesced path:
```swift
// LogiDeviceSession.divertBoundControls (refactored):
registry.primeSession(self)     // session.applyInitialUsage(aggregatedCache) synchronously
```

`lastApplied` is **registry-wide, not per-session** because each session's `divertedCIDs` provides its own idempotency via `DivertPlanner`.

Diagnostic API:
```swift
func usages(of code: UInt16) -> [UsageSource] {
    sources.compactMap { $0.value.contains(code) ? $0.key : nil }
}
```

### 4.4 LogiExternalBridge

**Protocol (lives inside Logi):**
```swift
protocol LogiExternalBridge: AnyObject {
    func handleLogiScrollHotkey(code: UInt16, phase: InputPhase)
    func dispatchLogiButtonEvent(_ event: InputEvent) -> LogiDispatchResult
}
enum LogiDispatchResult: Equatable { case consumed; case unhandled }
```

**Session call site (refactored `handleButtonEvent`):**
```swift
let bridge = LogiCenter.shared.externalBridge
bridge?.handleLogiScrollHotkey(code: e.code, phase: e.phase)
let result = bridge?.dispatchLogiButtonEvent(e) ?? .unhandled
if result == .consumed { return }
// logi* fast path preserved inside session (device isolation)
if e.phase == .down, let action = findLogiFastPath(e) {
    executeLogiAction(action)
}
```

**Teardown** — clear ScrollCore hotkey state when session disconnects / slot switches:
```swift
for cid in lastActiveCIDs {
    let mosCode = LogiCIDDirectory.toMosCode(cid)
    LogiCenter.shared.externalBridge?.handleLogiScrollHotkey(code: mosCode, phase: .up)
}
```

**Production impl (`Mos/Integration/LogiIntegrationBridge.swift`):**
```swift
final class LogiIntegrationBridge: LogiExternalBridge {
    static let shared = LogiIntegrationBridge()

    func handleLogiScrollHotkey(code: UInt16, phase: InputPhase) {
        ScrollCore.shared.handleScrollHotkey(code: code, phase: phase)
        // ScrollCore's method renamed: handleScrollHotkeyFromHIDPlusPlus → handleScrollHotkey
    }

    func dispatchLogiButtonEvent(_ event: InputEvent) -> LogiDispatchResult {
        if LogiCenter.shared.isRecording {
            NotificationCenter.default.post(
                name: LogiCenter.buttonEventRelay,
                object: nil, userInfo: ["event": event])
            return .consumed
        }
        // Probe only (do not execute): if a logi* binding exists, yield control back
        // to the session so executeLogiAction runs in the originating session's
        // device-isolated context. The lookup cost is O(bindings for this code) and
        // is amortized against the existing ButtonUtils cache.
        if event.phase == .down,
           ButtonUtils.shared.getBestMatchingBinding(
               for: event,
               where: { $0.systemShortcutName.hasPrefix("logi") }) != nil {
            return .unhandled
        }
        let result = InputProcessor.shared.process(event)
        if result == .consumed { return .consumed }
        NotificationCenter.default.post(
            name: LogiCenter.buttonEventRelay,
            object: nil, userInfo: ["event": event])
        return .unhandled
    }
}
```

**Startup wiring (AppDelegate):**
```swift
LogiCenter.shared.externalBridge = LogiIntegrationBridge.shared
LogiCenter.shared.start()
```

## 5. Persistence invariants (frozen)

| Key / name | Location | Notes |
|---|---|---|
| `UserDefaults["logitechFeatureCache"]` | `LogiDeviceSession.featureCacheKey` | JSON `[String(productId): [FeatureID: Index]]`. **Literal string preserved** even after class rename. |
| `NSSplitView.autosaveName = "HIDDebug.FeaturesControls.v3"` | Debug panel | AppKit autosave (UserDefaults). Literal preserved. |
| All other `"HIDDebug.*"` autosave names | Debug panel | Literal preserved. |

External persistence Logi touches but does not own (all frozen by design):
- `Options.shared.buttons.binding`
- `Options.shared.scroll.*`
- `Options.shared.application.applications[*].scroll.*`

Zero new persistence keys introduced. `UsageRegistry.sources` and `lastApplied` are in-memory only; panels re-push usage on app launch via their existing `viewDidLoad` / initialization paths.

Persistence freeze is enforced by a canary test (`LogiPersistenceCanaryTests`):
```swift
XCTAssertEqual(LogiDeviceSession.featureCacheKeyForTests, "logitechFeatureCache")
// Exact autosaveName list enumerated at Step 1 implementation time by grepping
// the renamed debug panel file for `.autosaveName = "`. Snapshot committed.
XCTAssertEqual(LogiDebugPanel.autosaveNamesSnapshotForTests,
               LogiDebugPanel.autosaveNameSnapshot)
```
The `autosaveNameSnapshot` static array is populated from the debug panel's own `autosaveName` literals at compile time so renaming them drifts the snapshot constant, which also drifts the test.

## 6. Migration plan (5 commits)

### Step 1 — Rename (mechanical, zero semantic change)
- Dir: `Mos/LogitechHID/` → `Mos/Logi/` (flat during this step; subdirs in Step 5)
- Classes: `LogitechHID*` / `Logitech*` → `Logi*` (Xcode Refactor→Rename)
- ScrollCore method: `handleScrollHotkeyFromHIDPlusPlus` → `handleScrollHotkey`
- Notification static-let names and string values: `"LogitechHID*"` → `"Logi*"` (in-process only, safe)
- KeyRecorder's literal `"LogitechHIDButtonEvent"` subscription renamed to match
- Frozen: `"logitechFeatureCache"` UserDefaults key; all `"HIDDebug.*"` autosave names
- Tests added: `LogiPersistenceCanaryTests`, `LogiCIDDirectoryTests`

Risk: near zero. Compiler catches missed call sites; canary tests catch persistence drift.

### Step 2 — LogiCenter facade
- New `LogiCenter.swift` that delegates to `LogiSessionManager.shared`
- `LogiSessionManager` demoted to `internal`
- All external call sites (≈50) rewritten to `LogiCenter.shared.xxx`
- Test-injectable `internal init(manager:registry:clock:)` added
- `weak var externalBridge` field added (nil-initialized; Step 4 will implement)
- `LogiExternalBridge` protocol placeholder declared
- Tests added: `LogiCenterPublicSurfaceTests` (Tier 1), `LogiCenterHarnessTests` (Tier 2)

Risk: low. No HID behavior change.

### Step 3 — UsageRegistry + preference panel migration
- `UsageRegistry.swift` + `UsageSource.swift` created
- `LogiCenter.setUsage(source:codes:)` + `usages(of:)` added
- Five preference VC call sites rewritten:
  - `PreferencesButtonsViewController.syncViewWithOptions` (line ~100)
  - `PreferencesScrollingViewController` (lines 99, 110, 121, 182, 368)
  - `PreferencesScrollingWithApplicationViewController` (line 67)
  - `PreferencesApplicationViewController` (line 89)
- Deleted: `LogiSessionManager.syncDivertWithBindings()`, `LogiDeviceSession.collectBoundLogiMosCodes()`
- `LogiDeviceSession.divertBoundControls()` switches to `registry.primeSession(self)`
- KeyRecorder `temporarilyDivertAll` / `restoreDivertToBindings` call sites rewritten to `LogiCenter.shared.beginKeyRecording()` / `endKeyRecording()`; internal `temporarilyDivertAll` / `restoreDivertToBindings` on sessions retained as private helpers
- Tests added: `UsageRegistryTests` (Tier 1), extended `LogitechDivertPlannerTests`, `UsageRegistryEndToEndTests` (Tier 2), `LogiCenterDeviceIntegrationTests` (Tier 3a)

Risk: medium. Semantic change: divert driver switches from synchronous scan to coalesced async. Tier 2 + Tier 3a are the core defense.

### Step 4 — Bridge inversion
- Flesh out `LogiExternalBridge` protocol (two methods)
- New `Mos/Integration/LogiIntegrationBridge.swift` as production impl
- `LogiDeviceSession.handleButtonEvent` rewritten to Section 4.4 form
- `LogiDeviceSession.teardown` ScrollCore clear-path rewritten via bridge
- All Logi imports of `ScrollCore` / `ButtonUtils` / `InputProcessor` removed
- `AppDelegate` wires `LogiCenter.shared.externalBridge = LogiIntegrationBridge.shared`
- Tests added: `LogiBridgeDispatchTests` (Tier 2), `LogiTeardownTests` (Tier 2), `LogiFeatureActionDeviceTests` (Tier 3b), `LogiBridgeDeviceTests` (Tier 3a)

Risk: medium. Hot path. Tier 2 covers routing sequence; Tier 3 covers real-device round-trip.

### Step 5 — Subdirectory tidy + Self-Test Wizard
- Flat files inside `Mos/Logi/` moved into `Core/` / `Usage/` / `Divert/` / `Bridge/` / `Debug/` per 4.1
- New `LogiSelfTestWizard.swift` + `LogiSelfTestRunner.swift` (DEBUG-only, ~500 LOC)
- Status bar menu item "Logi Self-Test..." (DEBUG build only) added

Risk: very low. File moves + new debug-only feature.

### Per-commit requirements
- Tier 1 + Tier 2 green
- Tier 3 green on dev machine with `LOGI_REAL_DEVICE=1` (when device present)
- Build clean
- Codex plan review × 2 (model: gpt-5.5, thinking: xhigh)
- Codex code review × 2 (same config)

## 7. Test plan

### Tier 1 — pure logic (always runs)

| File | Coverage |
|---|---|
| `LogiPersistenceCanaryTests.swift` | UserDefaults key + autosave name literal freeze |
| `LogiCIDDirectoryTests.swift` | `toCID` / `toMosCode` bidirectional symmetry |
| `UsageRegistryTests.swift` | diff algorithm, coalescing guard, idempotent short-circuit |
| `LogitechDivertPlannerTests.swift` (extend) | multi-source same-CID, source-deletion semantics, primeSession |
| `LogitechConflictDetectorTests.swift` (review) | confirm `isForeignDivert` exclusion still holds |

### Tier 2 — harness (always runs, fake session/bridge)

| File | Coverage |
|---|---|
| `LogiCenterHarnessTests.swift` | Injectable init, start/stop idempotency, notification contracts |
| `UsageRegistryEndToEndTests.swift` | Multiple `setUsage` same tick → single `applyUsageDiff` call with merged diff |
| `LogiBridgeDispatchTests.swift` | Routing sequence: scroll hotkey always fires; recording consumed; logi* fast-path unhandled |
| `LogiTeardownTests.swift` | `lastActiveCIDs` teardown emits `handleLogiScrollHotkey(phase: .up)` via bridge |

Test doubles live in `MosTests/LogiTestDoubles/`:
- `FakeLogiSessionManager`
- `FakeLogiDeviceSession`
- `FakeLogiExternalBridge`

### Tier 3 — real-device integration (gated by `LOGI_REAL_DEVICE=1`)

| File | Coverage |
|---|---|
| `LogiCenterDeviceIntegrationTests.swift` | setUsage → HID round-trip → reportingFlags bit0 assert |
| `LogiFeatureActionDeviceTests.swift` | `executeDPICycle(.up)` → DPI register change |
| `LogiBridgeDeviceTests.swift` | Scroll hotkey / button event end-to-end through bridge |

Gate base class:
```swift
class LogiDeviceIntegrationBase: XCTestCase {
    static var hasDevice: Bool {
        ProcessInfo.processInfo.environment["LOGI_REAL_DEVICE"] == "1"
    }
    override func setUpWithError() throws {
        try XCTSkipUnless(Self.hasDevice, "requires LOGI_REAL_DEVICE=1")
    }
}
```

Test plans:
- Existing `Debug.xctestplan` → Tier 1 + Tier 2 (CI safe)
- New `DebugWithDevice.xctestplan` → all three tiers (dev machine)

### Tier 3c — interactive self-test wizard

Replaces the originally-planned Markdown checklist. DEBUG-only SwiftUI/AppKit wizard accessible from status bar menu "Logi Self-Test...".

**Architecture:**
```swift
enum StepKind {
    case automatic(detail: String, run: () async throws -> StepOutcome)
    case physicalAutoVerified(instruction: String, expectation: String,
                              wait: WaitCondition, timeout: TimeInterval)
    case physicalUserConfirmed(instruction: String, expectation: String,
                               confirmPrompt: String)
}

enum WaitCondition {
    case buttonEventOnCID(UInt16)
    case sessionConnected(ConnectionMode)
    case sessionDisconnected
    case divertApplied(cid: UInt16, expectBit0: Bool)
    case dpiChanged(session: LogiDeviceSession, direction: Direction)
}
```

**Connection detection** (first step of any suite):
```swift
func detectConnection() -> DetectedConnection? {
    guard let session = LogiCenter.shared.activeSessionsSnapshot().first else { return nil }
    switch session.connectionMode {
    case .receiver:
        let paired = session.debugReceiverPairedDevices
        guard let firstConnected = paired.first(where: { $0.isConnected }) else { return nil }
        return .bolt(session: session, slot: firstConnected.slot, name: firstConnected.name)
    case .bleDirect:
        return .bleDirect(session: session, name: session.deviceInfo.name)
    case .unsupported:
        return nil
    }
}
```

The wizard takes the first connected session (user guarantees only one Logi device at a time) and auto-picks the first connected slot for Bolt suites. No user slot selection.

**Bolt suite** (14 steps; 1 is user-confirmed):
1. automatic — `start()`, wait for first session
2. automatic — `detectConnection()`, display result
3. automatic — wait `reportingDidComplete`
4. automatic — `setUsage(.buttonBinding, [codeBack])` → wait divertApplied → assert bit0 set
5. physicalAutoVerified — "press Back Button" / subscribe buttonEventRelay / 5s timeout
6. **physicalUserConfirmed** — "Did Mos intercept the default Back behavior?"
7. automatic — `setUsage(.buttonBinding, [])` → assert bit0 cleared
8. automatic — `executeDPICycle(.up)` → read DPI register assert change
9. automatic — `executeSmartShiftToggle()` → read smartShift assert toggle
10. automatic — `beginKeyRecording()` → assert all divertable CIDs in divertedCIDs
11. physicalAutoVerified — "press any Logi button in 5s" / buttonEventRelay
12. automatic — `endKeyRecording()` → assert divertedCIDs back to bound codes
13. physicalAutoVerified — "unplug Bolt receiver" / sessionDisconnected
14. physicalAutoVerified — "replug Bolt" / sessionConnected / reportingDidComplete

**BLE suite** (~9 steps): same as Bolt minus slot enumeration; plug/unplug replaced by "power off / power on BLE peripheral".

**Reporting**: final summary shows pass/fail counts + log path. Failed steps offer "retry" / "skip and continue" / "abort and export log".

**Rules of automation** (from feedback):
- Anything detectable via LogiCenter state or HID state → automatic.
- Only three categories require user: physical button press, physical plug/unplug, subjective observation (audible, visual).
- Bolt suite: only Step 6 is subjective. 13/14 are fully verified programmatically.

## 8. Performance budget

Numbers assume Apple Silicon + Swift release build. Debug build: expect 2-3× degradation (acceptable).

### Hot path 1 — per Logi button event (down and up each trigger)

| Phase | Before | After | Delta |
|---|---|---|---|
| Weak externalBridge load | — | 1× | +1–2 ns |
| `handleLogiScrollHotkey` dispatch | direct `.shared` access (~5 ns) | witness-table (~2 ns) + same internals | ≈0 |
| `dispatchLogiButtonEvent` dispatch | direct `.shared` access | witness-table + same internals | +2 ns |
| Recording NotificationCenter.post | ~1 μs | unchanged | 0 |
| Non-consumed NotificationCenter.post | ~1 μs | unchanged | 0 |
| `executeLogiAction` | direct switch | preserved in session, unchanged | 0 |

**Net: +3–5 ns per event.** At a theoretical 100 Hz button press rate, < 0.001% CPU increment.

### Hot path constraints (DO NOT add to session or bridge `handleButtonEvent`/`dispatchLogiButtonEvent`)

- No new `NotificationCenter.post` (recording broadcast is the only allowed one, preserved)
- No `DispatchQueue.*` async / sync
- No Swift `throws` paths
- No `String(format:)` / string construction

### Hot path 2 — panel save → divert apply

Before: one save triggers `syncDivertWithBindings` which per session scans `Options.buttons` + `Options.scroll` + `Options.application` (O(bindings + apps × 3)) and emits HID IO synchronously on the main thread.

After: one save triggers `setUsage(source, codes)` which is O(|codes|) dict write + Set equality. A `DispatchQueue.main.async` schedules a single `runRecompute` in the next runloop tick. Multiple `setUsage` calls in one save coalesce into one recompute.

**Net gain**:
- Eliminates repeated `collectBoundLogiMosCodes` scan of Options on each save.
- Coalesces multi-source saves (e.g., application panel changing multiple apps) into one HID IO batch.
- Save → IO latency: ~20–50 ms sync → ~1–16 ms async (next tick) + ~20–50 ms HID IO. UI thread yield is faster; user perception unchanged.

### Registry invariants (testable)

- `setUsage` completes in O(|codes|). Permitted work: dict read/write, Set equality, bool set, one `DispatchQueue.main.async` enqueue.
- `runRecompute` uses `aggregatedCache`, never scans Options.
- `scheduleRecompute` guards against re-entry via `recomputeScheduled: Bool`.
- `runRecompute` short-circuits when `aggregatedCache == lastApplied`.

### Memory budget

| Structure | Bound |
|---|---|
| `UsageRegistry.sources` | ≤ 20 sources × ≤ 10 codes/source ≈ 1.6 KB |
| `UsageRegistry.aggregatedCache` | ≤ 20 codes ≈ 320 B |
| `UsageRegistry.lastApplied` | same ≈ 320 B |
| **LogiCenter new memory total** | **< 4 KB** |

### Main-thread-only guard

```swift
#if DEBUG
func setUsage(source: UsageSource, codes: Set<UInt16>) {
    precondition(Thread.isMainThread, "LogiCenter is main-thread-only")
    // ...
}
#endif
```

The whole module is main-thread-bound (IOHIDManager callbacks on main RunLoop, Options on main, preferences on main). Explicit precondition guards against future drift.

### Codex review checklist

| Check | How to verify |
|---|---|
| Hot path 1 adds no new NotificationCenter/DispatchQueue | Diff of `LogiDeviceSession.handleButtonEvent` + `LogiIntegrationBridge.dispatchLogiButtonEvent` |
| `setUsage` is O(|codes|) | Inspect `UsageRegistry.setUsage` body; no nested loops |
| Coalescing guard fires | `if recomputeScheduled { return }` precedes async enqueue |
| Idempotent short-circuit fires | `if sources[source] == codes { return }` in `setUsage`; `if aggregatedCache == lastApplied { return }` in `runRecompute` |
| Main-thread precondition present | Search for `Thread.isMainThread` in registry + center |

## 9. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Missing a preference save site during Step 3 migration, causing divert to drift | Medium | Exhaustive grep for `syncDivertWithBindings` before/after; after migration that symbol does not exist, so any survivor fails compile. Tier 3a device test verifies divert actually takes effect end-to-end. |
| ScrollCore callback lifecycle: dangling weak reference | Low | `LogiIntegrationBridge.shared` is a real singleton, never deallocated. `externalBridge` is `weak`; even if bridge vanished, session dereferences safely. |
| Rename breaks persisted UserDefaults via accidental constant change | Low | `LogiPersistenceCanaryTests` freezes all literal strings. |
| Async recompute surfaces a race with session state | Low | All touches are main-thread-only (enforced by precondition). Diff is computed from `aggregatedCache` snapshot at recompute time. |
| Tier 3 tests hang when device drops mid-test | Low | All waits use `XCTestExpectation` with 30s timeout; teardown always runs. |
| Self-Test Wizard becomes bitrot-prone | Medium | DEBUG-only; runs on every significant Logi change; failures are immediately visible. |

## 10. Out-of-scope open questions (deferred, not blocking)

- Whether to expose `UsageSource` diagnostic ("bound by app:Chrome scroll.dash") in the release Debug panel (currently wizard-only). Decision deferred to post-migration UX pass.
- Whether per-session `lastApplied` (instead of registry-wide) would provide clearer diffing semantics when sessions come and go mid-update. Current per-session `divertedCIDs` handles this adequately; revisit if `applyUsageDiff` produces surprising output in practice.
- Future: merging scroll-hotkey and button-binding data models into one storage layer. Not this refactor.

## 11. Acceptance criteria

This refactor is complete when:

- [ ] All five migration steps committed with Codex plan+code review × 2 each
- [ ] `Mos/Logi/` contains all Logi code; no file in that dir imports `ScrollCore`, `ButtonUtils`, `InputProcessor`, `Options`, or `PreferencesWindow`
- [ ] Outside `Mos/Logi/`, only the facade surface types are referenced: `LogiCenter` (class), `UsageSource` / `ScrollRole` (value types used in `setUsage`), `ConflictStatus` (return of `conflictStatus(forMosCode:)`), `LogiExternalBridge` + `LogiDispatchResult` (protocol implemented by `LogiIntegrationBridge`). All other Logi internal types are `internal` and not visible outside the module.
- [ ] `syncDivertWithBindings` and `collectBoundLogiMosCodes` symbols are deleted
- [ ] `Debug.xctestplan` all green; `DebugWithDevice.xctestplan` all green with device attached
- [ ] Self-Test Wizard: Bolt suite 14/14 pass on real Bolt receiver; BLE suite all pass on a real BLE peripheral
- [ ] Persistence canary tests green; verified that `"logitechFeatureCache"` still loads on upgrade from pre-refactor build
- [ ] Codex code review × 2 at gpt-5.5 xhigh across all five commits: no blocking issues
