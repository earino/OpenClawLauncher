// GatewayStateMachine.swift — Pure state machine for gateway lifecycle
//
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │                    GATEWAY STATE MACHINE                           │
//  │                                                                    │
//  │  Legend:  ──event──>   transition                                  │
//  │           ──event/guard──>   conditional transition                │
//  │           [effect]   side effect triggered                         │
//  │                                                                    │
//  │   ┌─────────┐  userStart   ┌─────────┐                            │
//  │   │ STOPPED │─────────────>│ PROBING │                            │
//  │   └─────────┘              └────┬────┘                            │
//  │     ^   ^  ^                    │                                  │
//  │     │   │  │         portProbe(open)──────────────┐               │
//  │     │   │  │         portProbe(closed)            │               │
//  │     │   │  │                    │                  │               │
//  │     │   │  │                    v                  v               │
//  │     │   │  │  launchFailed ┌──────────┐      ┌─────────┐         │
//  │     │   │  │  /!wants ───> │LAUNCHING │      │ RUNNING │         │
//  │     │   │  │               └────┬─────┘      └────┬────┘         │
//  │     │   │  │                    │                  │               │
//  │     │   │  │     launchSucceeded: stay (ownership=ours)           │
//  │     │   │  │     portProbe(open): ─────────────────┘              │
//  │     │   │  │     processExited/wants: ─────────────────┐          │
//  │     │   │  │     launchFailed/wants: ──────────────────┤          │
//  │     │   │  │                                           │          │
//  │     │   │  │         userStop                 userStop  │          │
//  │     │   │  │            │                        │      │          │
//  │     │   │  │            v                        v      │          │
//  │     │   │  │       ┌──────────┐            processExited          │
//  │     │   │  │       │ STOPPING │            -> PROBING             │
//  │     │   │  │       └────┬─────┘            [probePort]            │
//  │     │   │  │            │                                         │
//  │     │   │  │    stopCompleted          userRestart                │
//  │     │   │  └────────────┘                   │                     │
//  │     │   │                                   v                     │
//  │     │   │                          ┌─────────────────┐            │
//  │     │   │                          │RESTART_STOPPING │            │
//  │     │   │                          └───────┬─────────┘            │
//  │     │   │                                  │                      │
//  │     │   │                     restartStopCompleted                │
//  │     │   │                        -> PROBING [probePort]           │
//  │     │   │                                                         │
//  │     │   │         ┌────────────────────┐                          │
//  │     │   │         │ WAITING_TO_RESTART │ <── restart logic        │
//  │     │   │         └───────┬────────────┘                          │
//  │     │   │                 │                                       │
//  │     │   │    restartDelayElapsed -> LAUNCHING [launchProcess]     │
//  │     │   │    portProbe(open)/wants -> RUNNING (adopt external)    │
//  │     │   └─── userStop                                             │
//  │     │                                                             │
//  │     └─── (any) + userQuit  [terminateSync]                       │
//  │                                                                    │
//  │  Ownership: .none | .ours | .external                             │
//  │  Generation: bumped on userStart/Stop/Restart/Quit                │
//  │              stale callbacks check gen and self-discard            │
//  └─────────────────────────────────────────────────────────────────────┘

import Foundation

// MARK: - State

struct GatewayState {
    enum Phase {
        case stopped
        case probing
        case launching
        case running
        case stopping
        case restartStopping
        case waitingToRestart
    }

    enum Ownership {
        case none
        case ours
        case external
    }

    var phase: Phase = .stopped
    var userWantsRunning: Bool = false
    var ownership: Ownership = .none
    var restartCount: Int = 0
    var lastSuccessfulLaunch: Date? = nil
    var generation: UInt64 = 0
}

// MARK: - Events

enum GatewayEvent {
    // User commands
    case userStart
    case userStop
    case userRestart
    case userQuit

    // Process lifecycle
    case processExited(exitCode: Int32)

    // Port probe result
    case portProbeResult(open: Bool, killedRogues: Bool)

    // Async completion callbacks
    case restartDelayElapsed
    case stopCompleted
    case restartStopCompleted

    // Launch outcome
    case launchSucceeded
    case launchFailed
}

// MARK: - Side Effects

enum SideEffect: Equatable {
    case probePort
    case launchProcess
    case terminateOurProcess
    case killExternalGateway
    case terminateForRestart
    case killExternalForRestart
    case scheduleRestart(delay: TimeInterval)
    case terminateSync
    case notifyUI(GatewayStatus)
    case log(String)
}

// MARK: - UI Status (derived)

enum GatewayStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
}

extension GatewayState {
    var uiStatus: GatewayStatus {
        switch phase {
        case .stopped:                                return .stopped
        case .probing, .launching, .waitingToRestart: return .starting
        case .running:                                return .running
        case .stopping, .restartStopping:             return .stopping
        }
    }
}

// MARK: - Transition Function

let maxRestartAttempts = 5

func gatewayTransition(
    state: GatewayState,
    event: GatewayEvent,
    enforceOwnership: Bool
) -> (GatewayState, [SideEffect]) {
    var s = state
    var fx: [SideEffect] = []

    switch (state.phase, event) {

    // ─── userStart ───────────────────────────────────────────────

    case (.stopped, .userStart):
        s.generation += 1
        s.userWantsRunning = true
        s.restartCount = 0
        s.phase = .probing
        fx.append(.probePort)
        fx.append(.notifyUI(.starting))

    case (_, .userStart):
        fx.append(.log("[FSM] userStart ignored in \(state.phase)"))

    // ─── userStop ────────────────────────────────────────────────

    case (.running, .userStop):
        s.generation += 1
        s.userWantsRunning = false
        s.phase = .stopping
        fx.append(.notifyUI(.stopping))
        switch state.ownership {
        case .ours:   fx.append(.terminateOurProcess)
        case .external: fx.append(.killExternalGateway)
        case .none:   fx.append(.terminateOurProcess)
        }

    case (.probing, .userStop), (.launching, .userStop):
        s.generation += 1
        s.userWantsRunning = false
        s.phase = .stopping
        fx.append(.notifyUI(.stopping))
        switch state.ownership {
        case .ours:   fx.append(.terminateOurProcess)
        case .external: fx.append(.killExternalGateway)
        case .none:
            // Nothing to kill in probing phase
            s.phase = .stopped
            s.ownership = .none
            fx.removeLast() // remove notifyUI(.stopping)
            fx.append(.notifyUI(.stopped))
        }

    case (.waitingToRestart, .userStop):
        s.generation += 1
        s.userWantsRunning = false
        s.phase = .stopped
        s.ownership = .none
        fx.append(.notifyUI(.stopped))

    case (.stopped, .userStop):
        s.userWantsRunning = false
        fx.append(.log("[FSM] userStop ignored: already stopped"))

    case (_, .userStop):
        fx.append(.log("[FSM] userStop ignored in \(state.phase)"))

    // ─── userRestart ─────────────────────────────────────────────

    case (.running, .userRestart):
        s.generation += 1
        s.userWantsRunning = true
        s.restartCount = 0
        s.phase = .restartStopping
        fx.append(.notifyUI(.stopping))
        switch state.ownership {
        case .ours:     fx.append(.terminateForRestart)
        case .external: fx.append(.killExternalForRestart)
        case .none:     fx.append(.terminateForRestart)
        }

    case (.launching, .userRestart), (.probing, .userRestart):
        s.generation += 1
        s.userWantsRunning = true
        s.restartCount = 0
        s.phase = .restartStopping
        fx.append(.notifyUI(.stopping))
        switch state.ownership {
        case .ours:   fx.append(.terminateForRestart)
        case .external: fx.append(.killExternalForRestart)
        case .none:
            // Nothing running yet, go straight to probing
            s.phase = .probing
            s.ownership = .none
            fx.removeLast() // remove notifyUI(.stopping)
            fx.append(.notifyUI(.starting))
            fx.append(.probePort)
        }

    case (_, .userRestart):
        fx.append(.log("[FSM] userRestart ignored in \(state.phase)"))

    // ─── userQuit ────────────────────────────────────────────────

    case (_, .userQuit):
        s.generation += 1
        s.userWantsRunning = false
        if state.ownership == .ours {
            fx.append(.terminateSync)
        }
        s.phase = .stopped
        s.ownership = .none

    // ─── portProbeResult ─────────────────────────────────────────

    case (.probing, .portProbeResult(let open, let killedRogues)):
        if open {
            if killedRogues {
                // Killed rogues but port still open — something else there, adopt if external
                s.ownership = .external
            } else {
                // Port open, no rogues killed — external gateway
                s.ownership = .external
            }
            s.phase = .running
            s.restartCount = 0
            fx.append(.notifyUI(.running))
        } else {
            s.phase = .launching
            fx.append(.launchProcess)
        }

    case (.launching, .portProbeResult(let open, let killedRogues)):
        if open {
            s.phase = .running
            s.restartCount = 0
            fx.append(.notifyUI(.running))
        } else if killedRogues && state.ownership == .external {
            // We adopted an external gateway and it was killed as a rogue.
            // Port is now closed, attempt restart.
            let (newState, restartFx) = applyRestartLogic(state: s, enforceOwnership: enforceOwnership)
            s = newState
            fx.append(contentsOf: restartFx)
        }
        // else: our process is launching, port not yet open — wait for next poll

    case (.running, .portProbeResult(let open, let killedRogues)):
        if open {
            // All good, gateway is up
            if killedRogues {
                fx.append(.log("[FSM] killed rogues, our gateway still running"))
            }
        } else {
            // Port closed while we think we're running
            if killedRogues && state.ownership == .external {
                // External gateway we adopted was killed as rogue, port now closed
                s.ownership = .none
                let (newState, restartFx) = applyRestartLogic(state: s, enforceOwnership: enforceOwnership)
                s = newState
                fx.append(contentsOf: restartFx)
            } else if state.ownership == .external {
                // External gateway died on its own
                s.ownership = .none
                let (newState, restartFx) = applyRestartLogic(state: s, enforceOwnership: enforceOwnership)
                s = newState
                fx.append(contentsOf: restartFx)
            } else if state.ownership == .ours {
                // Our process might be alive but port temporarily closed — wait for processExited
                // or next poll cycle. Don't transition yet.
                fx.append(.log("[FSM] port closed but ownership=ours, waiting for processExited"))
            } else {
                fx.append(.log("[FSM] port closed, ownership=none, waiting"))
            }
        }

    case (.waitingToRestart, .portProbeResult(let open, _)):
        if open && state.userWantsRunning {
            // External gateway appeared while we were waiting to restart — adopt it
            s.ownership = .external
            s.phase = .running
            s.restartCount = 0
            fx.append(.notifyUI(.running))
        }

    case (.stopped, .portProbeResult(let open, _)):
        if open && state.userWantsRunning {
            // Shouldn't normally happen (stopped + userWantsRunning is contradictory)
            // but handle gracefully: adopt external
            s.ownership = .external
            s.phase = .running
            fx.append(.notifyUI(.running))
        } else if !open && state.userWantsRunning && enforceOwnership {
            // Watchdog: want to be running but port is closed
            let (newState, restartFx) = applyRestartLogic(state: s, enforceOwnership: enforceOwnership)
            s = newState
            fx.append(contentsOf: restartFx)
        }
        // If !userWantsRunning, ignore — stop sticks

    case (_, .portProbeResult):
        // Stopping, restartStopping: ignore probe results during shutdown
        break

    // ─── processExited ───────────────────────────────────────────

    case (.running, .processExited(let exitCode)):
        fx.append(.log("[FSM] process exited with code \(exitCode) while running"))
        // Check if port is still open (child process may have survived)
        s.ownership = .none
        s.phase = .probing
        fx.append(.probePort)

    case (.launching, .processExited(let exitCode)):
        fx.append(.log("[FSM] process exited with code \(exitCode) while launching"))
        s.ownership = .none
        if s.userWantsRunning {
            let (newState, restartFx) = applyRestartLogic(state: s, enforceOwnership: enforceOwnership)
            s = newState
            fx.append(contentsOf: restartFx)
        } else {
            s.phase = .stopped
            fx.append(.notifyUI(.stopped))
        }

    case (.stopping, .processExited):
        // Expected — we initiated the stop
        break

    case (.restartStopping, .processExited):
        // Expected — we initiated the stop for restart
        break

    case (_, .processExited):
        fx.append(.log("[FSM] processExited ignored in \(state.phase)"))

    // ─── launchSucceeded ─────────────────────────────────────────

    case (.launching, .launchSucceeded):
        s.ownership = .ours
        s.lastSuccessfulLaunch = Date()
        // Stay in .launching — wait for port probe to confirm running

    case (_, .launchSucceeded):
        fx.append(.log("[FSM] launchSucceeded ignored in \(state.phase)"))

    // ─── launchFailed ────────────────────────────────────────────

    case (.launching, .launchFailed):
        fx.append(.log("[FSM] launch failed"))
        s.ownership = .none
        if s.userWantsRunning {
            let (newState, restartFx) = applyRestartLogic(state: s, enforceOwnership: enforceOwnership)
            s = newState
            fx.append(contentsOf: restartFx)
        } else {
            s.phase = .stopped
            fx.append(.notifyUI(.stopped))
        }

    case (_, .launchFailed):
        fx.append(.log("[FSM] launchFailed ignored in \(state.phase)"))

    // ─── stopCompleted ───────────────────────────────────────────

    case (.stopping, .stopCompleted):
        s.phase = .stopped
        s.ownership = .none
        fx.append(.notifyUI(.stopped))

    case (_, .stopCompleted):
        fx.append(.log("[FSM] stopCompleted ignored in \(state.phase)"))

    // ─── restartStopCompleted ────────────────────────────────────

    case (.restartStopping, .restartStopCompleted):
        s.ownership = .none
        s.phase = .probing
        fx.append(.notifyUI(.starting))
        fx.append(.probePort)

    case (_, .restartStopCompleted):
        fx.append(.log("[FSM] restartStopCompleted ignored in \(state.phase)"))

    // ─── restartDelayElapsed ─────────────────────────────────────

    case (.waitingToRestart, .restartDelayElapsed):
        s.phase = .launching
        fx.append(.launchProcess)

    case (_, .restartDelayElapsed):
        fx.append(.log("[FSM] restartDelayElapsed ignored in \(state.phase)"))
    }

    return (s, fx)
}

// MARK: - Restart Logic Helper

private func applyRestartLogic(
    state: GatewayState,
    enforceOwnership: Bool
) -> (GatewayState, [SideEffect]) {
    var s = state
    var fx: [SideEffect] = []

    // Reset restart count after 60s of stable uptime
    if let lastStart = s.lastSuccessfulLaunch,
       Date().timeIntervalSince(lastStart) > 60 {
        s.restartCount = 0
    }

    if enforceOwnership {
        s.restartCount += 1
        let delay = min(Double(s.restartCount) * 2.0, 30.0)
        fx.append(.log("[FSM] enforceOwnership restart attempt \(s.restartCount) in \(delay)s"))
        s.phase = .waitingToRestart
        fx.append(.notifyUI(.starting))
        fx.append(.scheduleRestart(delay: delay))
    } else {
        if s.restartCount < maxRestartAttempts {
            s.restartCount += 1
            let delay = min(Double(s.restartCount) * 2.0, 10.0)
            fx.append(.log("[FSM] restart attempt \(s.restartCount)/\(maxRestartAttempts) in \(delay)s"))
            s.phase = .waitingToRestart
            fx.append(.notifyUI(.starting))
            fx.append(.scheduleRestart(delay: delay))
        } else {
            fx.append(.log("[FSM] max restart attempts reached, giving up"))
            s.userWantsRunning = false
            s.phase = .stopped
            fx.append(.notifyUI(.stopped))
        }
    }

    return (s, fx)
}
