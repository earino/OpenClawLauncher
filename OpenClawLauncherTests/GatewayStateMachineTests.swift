import XCTest
@testable import OpenClaw_Launcher

final class GatewayStateMachineTests: XCTestCase {

    // MARK: - Helpers

    /// Convenience: run a transition with enforceOwnership=false by default
    private func transition(
        _ state: GatewayState,
        _ event: GatewayEvent,
        enforce: Bool = false
    ) -> (GatewayState, [SideEffect]) {
        gatewayTransition(state: state, event: event, enforceOwnership: enforce)
    }

    /// Build a state quickly
    private func state(
        phase: GatewayState.Phase = .stopped,
        wants: Bool = false,
        ownership: GatewayState.Ownership = .none,
        restartCount: Int = 0,
        generation: UInt64 = 0,
        lastSuccessfulLaunch: Date? = nil
    ) -> GatewayState {
        var s = GatewayState()
        s.phase = phase
        s.userWantsRunning = wants
        s.ownership = ownership
        s.restartCount = restartCount
        s.generation = generation
        s.lastSuccessfulLaunch = lastSuccessfulLaunch
        return s
    }

    /// Filter out .log effects for easier assertions
    private func nonLogEffects(_ effects: [SideEffect]) -> [SideEffect] {
        effects.filter { if case .log = $0 { return false }; return true }
    }

    // MARK: - Happy Path

    func testStart_probeClosedLaunchRunning() {
        // stopped → userStart → probing
        var s = state()
        let (s1, fx1) = transition(s, .userStart)
        XCTAssertEqual(s1.phase, .probing)
        XCTAssertTrue(s1.userWantsRunning)
        XCTAssertEqual(s1.generation, 1)
        XCTAssertTrue(nonLogEffects(fx1).contains(.probePort))
        XCTAssertTrue(nonLogEffects(fx1).contains(.notifyUI(.starting)))

        // probing → portProbe(closed) → launching
        let (s2, fx2) = transition(s1, .portProbeResult(open: false, killedRogues: false))
        XCTAssertEqual(s2.phase, .launching)
        XCTAssertTrue(nonLogEffects(fx2).contains(.launchProcess))

        // launching → launchSucceeded → still launching (ownership = ours)
        let (s3, fx3) = transition(s2, .launchSucceeded)
        XCTAssertEqual(s3.phase, .launching)
        XCTAssertEqual(s3.ownership, .ours)
        XCTAssertTrue(nonLogEffects(fx3).isEmpty)

        // launching → portProbe(open) → running
        let (s4, fx4) = transition(s3, .portProbeResult(open: true, killedRogues: false))
        XCTAssertEqual(s4.phase, .running)
        XCTAssertEqual(s4.restartCount, 0)
        XCTAssertTrue(nonLogEffects(fx4).contains(.notifyUI(.running)))
    }

    func testStart_probeOpenAdoptsExternal() {
        // stopped → userStart → probing
        let s = state()
        let (s1, _) = transition(s, .userStart)

        // probing → portProbe(open) → running with external ownership
        let (s2, fx2) = transition(s1, .portProbeResult(open: true, killedRogues: false))
        XCTAssertEqual(s2.phase, .running)
        XCTAssertEqual(s2.ownership, .external)
        XCTAssertTrue(nonLogEffects(fx2).contains(.notifyUI(.running)))
    }

    func testStop() {
        // running + ours → userStop → stopping
        let s = state(phase: .running, wants: true, ownership: .ours, generation: 1)
        let (s1, fx1) = transition(s, .userStop)
        XCTAssertEqual(s1.phase, .stopping)
        XCTAssertFalse(s1.userWantsRunning)
        XCTAssertEqual(s1.generation, 2)
        XCTAssertTrue(nonLogEffects(fx1).contains(.terminateOurProcess))
        XCTAssertTrue(nonLogEffects(fx1).contains(.notifyUI(.stopping)))

        // stopping → stopCompleted → stopped
        let (s2, fx2) = transition(s1, .stopCompleted)
        XCTAssertEqual(s2.phase, .stopped)
        XCTAssertEqual(s2.ownership, .none)
        XCTAssertTrue(nonLogEffects(fx2).contains(.notifyUI(.stopped)))
    }

    func testRestart() {
        // running + ours → userRestart → restartStopping
        let s = state(phase: .running, wants: true, ownership: .ours, generation: 1)
        let (s1, fx1) = transition(s, .userRestart)
        XCTAssertEqual(s1.phase, .restartStopping)
        XCTAssertTrue(s1.userWantsRunning)
        XCTAssertEqual(s1.generation, 2)
        XCTAssertTrue(nonLogEffects(fx1).contains(.terminateForRestart))

        // restartStopping → restartStopCompleted → probing
        let (s2, fx2) = transition(s1, .restartStopCompleted)
        XCTAssertEqual(s2.phase, .probing)
        XCTAssertEqual(s2.ownership, .none)
        XCTAssertTrue(nonLogEffects(fx2).contains(.probePort))
        XCTAssertTrue(nonLogEffects(fx2).contains(.notifyUI(.starting)))
    }

    // MARK: - Stop Sticks

    func testStoppedIgnoresPortProbeWhenNotWantingRunning() {
        let s = state(phase: .stopped, wants: false)
        let (s1, fx1) = transition(s, .portProbeResult(open: true, killedRogues: false))
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertTrue(nonLogEffects(fx1).isEmpty)
    }

    // MARK: - Crash Recovery

    func testProcessExitedWhileRunning() {
        let s = state(phase: .running, wants: true, ownership: .ours, generation: 1)
        let (s1, fx1) = transition(s, .processExited(exitCode: 1))
        // Should go to probing (not launching) with ownership cleared
        XCTAssertEqual(s1.phase, .probing)
        XCTAssertEqual(s1.ownership, .none)
        XCTAssertTrue(nonLogEffects(fx1).contains(.probePort))
    }

    func testProcessExitedWhileRunning_portClosed_relaunches() {
        // Full flow: processExited → probing → port closed → launching [launchProcess]
        let s = state(phase: .running, wants: true, ownership: .ours, generation: 1)
        let (s1, _) = transition(s, .processExited(exitCode: 0))
        XCTAssertEqual(s1.phase, .probing)
        XCTAssertEqual(s1.ownership, .none)

        // Port is closed — should transition to launching and emit launchProcess
        let (s2, fx2) = transition(s1, .portProbeResult(open: false, killedRogues: false))
        XCTAssertEqual(s2.phase, .launching)
        XCTAssertTrue(nonLogEffects(fx2).contains(.launchProcess))
    }

    func testProcessExitedWhileRunning_portOpen_adoptsExternal() {
        // Full flow: processExited → probing → port open → running (external)
        let s = state(phase: .running, wants: true, ownership: .ours, generation: 1)
        let (s1, _) = transition(s, .processExited(exitCode: 0))
        XCTAssertEqual(s1.phase, .probing)
        XCTAssertEqual(s1.ownership, .none)

        // Port is open — child survived, adopt as external
        let (s2, fx2) = transition(s1, .portProbeResult(open: true, killedRogues: false))
        XCTAssertEqual(s2.phase, .running)
        XCTAssertEqual(s2.ownership, .external)
        XCTAssertTrue(nonLogEffects(fx2).contains(.notifyUI(.running)))
    }

    func testProcessExitedWhileLaunching() {
        let s = state(phase: .launching, wants: true, ownership: .ours, generation: 1)
        let (s1, fx1) = transition(s, .processExited(exitCode: 1))
        // Should go to waitingToRestart
        XCTAssertEqual(s1.phase, .waitingToRestart)
        XCTAssertEqual(s1.restartCount, 1)
        XCTAssertTrue(nonLogEffects(fx1).contains(where: {
            if case .scheduleRestart = $0 { return true }; return false
        }))
    }

    func testLaunchFailed() {
        let s = state(phase: .launching, wants: true, ownership: .none, generation: 1)
        let (s1, fx1) = transition(s, .launchFailed)
        XCTAssertEqual(s1.phase, .waitingToRestart)
        XCTAssertEqual(s1.restartCount, 1)
        XCTAssertTrue(nonLogEffects(fx1).contains(where: {
            if case .scheduleRestart = $0 { return true }; return false
        }))
    }

    func testRestartDelayElapsed() {
        let s = state(phase: .waitingToRestart, wants: true, restartCount: 1, generation: 1)
        let (s1, fx1) = transition(s, .restartDelayElapsed)
        XCTAssertEqual(s1.phase, .launching)
        XCTAssertTrue(nonLogEffects(fx1).contains(.launchProcess))
    }

    // MARK: - Rogue Reclamation

    func testRunningExternalKilledAsRogue() {
        // running + external, port now closed, rogues killed → restart
        let s = state(phase: .running, wants: true, ownership: .external, generation: 1)
        let (s1, _) = transition(s, .portProbeResult(open: false, killedRogues: true))
        XCTAssertEqual(s1.phase, .waitingToRestart)
        XCTAssertEqual(s1.ownership, .none)
    }

    func testRunningExternalDied() {
        // running + external, port closed, no rogues killed → external died
        let s = state(phase: .running, wants: true, ownership: .external, generation: 1)
        let (s1, _) = transition(s, .portProbeResult(open: false, killedRogues: false))
        XCTAssertEqual(s1.phase, .waitingToRestart)
        XCTAssertEqual(s1.ownership, .none)
    }

    // MARK: - Generation Counter

    func testUserStartBumpsGen() {
        let s = state(generation: 5)
        let (s1, _) = transition(s, .userStart)
        XCTAssertEqual(s1.generation, 6)
    }

    func testUserStopBumpsGen() {
        let s = state(phase: .running, wants: true, ownership: .ours, generation: 5)
        let (s1, _) = transition(s, .userStop)
        XCTAssertEqual(s1.generation, 6)
    }

    func testStopCancelsPendingRestart() {
        // waitingToRestart → userStop → stopped (gen bumped, any pending scheduleRestart is stale)
        let s = state(phase: .waitingToRestart, wants: true, restartCount: 2, generation: 5)
        let (s1, fx1) = transition(s, .userStop)
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertFalse(s1.userWantsRunning)
        XCTAssertEqual(s1.generation, 6)
        XCTAssertTrue(nonLogEffects(fx1).contains(.notifyUI(.stopped)))
    }

    // MARK: - Double-Click Protection

    func testUserStartIgnoredWhenProbing() {
        let s = state(phase: .probing, wants: true, generation: 1)
        let (s1, fx1) = transition(s, .userStart)
        XCTAssertEqual(s1.phase, .probing) // unchanged
        XCTAssertEqual(s1.generation, 1)   // not bumped
        // Only a log effect
        XCTAssertTrue(nonLogEffects(fx1).isEmpty)
    }

    func testUserStartIgnoredWhenRunning() {
        let s = state(phase: .running, wants: true, ownership: .ours, generation: 1)
        let (s1, fx1) = transition(s, .userStart)
        XCTAssertEqual(s1.phase, .running)
        XCTAssertEqual(s1.generation, 1)
        XCTAssertTrue(nonLogEffects(fx1).isEmpty)
    }

    // MARK: - Max Restarts

    func testMaxRestartsGivesUp() {
        // restartCount at max → launchFailed → stopped, gives up
        let s = state(phase: .launching, wants: true, restartCount: 5, generation: 1)
        let (s1, fx1) = transition(s, .launchFailed)
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertFalse(s1.userWantsRunning)
        XCTAssertTrue(nonLogEffects(fx1).contains(.notifyUI(.stopped)))
    }

    func testExponentialBackoff() {
        // Verify backoff delays: 2s, 4s, 6s, 8s, 10s (capped)
        var s = state(phase: .launching, wants: true, restartCount: 0, generation: 1)

        let expectedDelays: [TimeInterval] = [2.0, 4.0, 6.0, 8.0, 10.0]
        for expected in expectedDelays {
            let (s1, fx1) = transition(s, .launchFailed)
            let scheduleEffects = nonLogEffects(fx1).compactMap { effect -> TimeInterval? in
                if case .scheduleRestart(let delay) = effect { return delay }
                return nil
            }
            XCTAssertEqual(scheduleEffects.first, expected, "Expected delay \(expected)")
            // Set up for next iteration: back in launching
            s = s1
            s.phase = .launching
        }
    }

    func testRestartCountResetAfterStableUptime() {
        // If lastSuccessfulLaunch > 60s ago, restartCount resets
        let oldLaunch = Date().addingTimeInterval(-120) // 2 minutes ago
        let s = state(phase: .launching, wants: true, ownership: .ours, restartCount: 4, generation: 1, lastSuccessfulLaunch: oldLaunch)
        let (s1, fx1) = transition(s, .processExited(exitCode: 1))
        // restartCount should have been reset to 0 then incremented to 1
        XCTAssertEqual(s1.restartCount, 1)
        XCTAssertEqual(s1.phase, .waitingToRestart)
        XCTAssertTrue(nonLogEffects(fx1).contains(.scheduleRestart(delay: 2.0)))
    }

    // MARK: - Enforce Ownership

    func testEnforceOwnershipNeverGivesUp() {
        // Even at restartCount=100, enforce mode still restarts
        let s = state(phase: .launching, wants: true, restartCount: 100, generation: 1)
        let (s1, fx1) = transition(s, .launchFailed, enforce: true)
        XCTAssertEqual(s1.phase, .waitingToRestart)
        XCTAssertEqual(s1.restartCount, 101)
        XCTAssertTrue(nonLogEffects(fx1).contains(where: {
            if case .scheduleRestart = $0 { return true }; return false
        }))
    }

    func testBackoffCapsAt30s() {
        // enforce mode caps at 30s
        let s = state(phase: .launching, wants: true, restartCount: 50, generation: 1)
        let (s1, fx1) = transition(s, .launchFailed, enforce: true)
        XCTAssertEqual(s1.phase, .waitingToRestart)
        // delay = min(51 * 2.0, 30.0) = 30.0
        XCTAssertTrue(nonLogEffects(fx1).contains(.scheduleRestart(delay: 30.0)))
    }

    // MARK: - App Quit

    func testQuitFromRunningOurs() {
        let s = state(phase: .running, wants: true, ownership: .ours, generation: 1)
        let (s1, fx1) = transition(s, .userQuit)
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertFalse(s1.userWantsRunning)
        XCTAssertEqual(s1.ownership, .none)
        XCTAssertTrue(nonLogEffects(fx1).contains(.terminateSync))
    }

    func testQuitFromRunningExternal() {
        let s = state(phase: .running, wants: true, ownership: .external, generation: 1)
        let (s1, fx1) = transition(s, .userQuit)
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertEqual(s1.ownership, .none)
        // Should NOT terminateSync for external
        XCTAssertFalse(nonLogEffects(fx1).contains(.terminateSync))
    }

    func testQuitFromStopped() {
        let s = state(phase: .stopped, wants: false, generation: 1)
        let (s1, fx1) = transition(s, .userQuit)
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertFalse(nonLogEffects(fx1).contains(.terminateSync))
    }

    func testQuitFromWaiting() {
        let s = state(phase: .waitingToRestart, wants: true, ownership: .none, generation: 1)
        let (s1, fx1) = transition(s, .userQuit)
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertFalse(s1.userWantsRunning)
        XCTAssertFalse(nonLogEffects(fx1).contains(.terminateSync))
    }

    // MARK: - UI Status Mapping

    func testUIStatusMapping() {
        XCTAssertEqual(state(phase: .stopped).uiStatus, .stopped)
        XCTAssertEqual(state(phase: .probing).uiStatus, .starting)
        XCTAssertEqual(state(phase: .launching).uiStatus, .starting)
        XCTAssertEqual(state(phase: .waitingToRestart).uiStatus, .starting)
        XCTAssertEqual(state(phase: .running).uiStatus, .running)
        XCTAssertEqual(state(phase: .stopping).uiStatus, .stopping)
        XCTAssertEqual(state(phase: .restartStopping).uiStatus, .stopping)
    }

    // MARK: - Edge Cases

    func testStopFromProbingWithNoOwnership() {
        // probing + ownership=none → userStop → goes straight to stopped (nothing to kill)
        let s = state(phase: .probing, wants: true, ownership: .none, generation: 1)
        let (s1, fx1) = transition(s, .userStop)
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertEqual(s1.ownership, .none)
        XCTAssertTrue(nonLogEffects(fx1).contains(.notifyUI(.stopped)))
        // Should NOT contain terminateOurProcess
        XCTAssertFalse(nonLogEffects(fx1).contains(.terminateOurProcess))
    }

    func testRestartFromProbingWithNoOwnership() {
        // probing + ownership=none → userRestart → goes straight to probing (nothing to stop)
        let s = state(phase: .probing, wants: true, ownership: .none, generation: 1)
        let (s1, fx1) = transition(s, .userRestart)
        XCTAssertEqual(s1.phase, .probing)
        XCTAssertTrue(s1.userWantsRunning)
        XCTAssertTrue(nonLogEffects(fx1).contains(.probePort))
        XCTAssertTrue(nonLogEffects(fx1).contains(.notifyUI(.starting)))
    }

    func testStopExternalFromRunning() {
        let s = state(phase: .running, wants: true, ownership: .external, generation: 1)
        let (s1, fx1) = transition(s, .userStop)
        XCTAssertEqual(s1.phase, .stopping)
        XCTAssertTrue(nonLogEffects(fx1).contains(.killExternalGateway))
    }

    func testWaitingToRestartAdoptsExternalOnProbe() {
        let s = state(phase: .waitingToRestart, wants: true, restartCount: 1, generation: 1)
        let (s1, fx1) = transition(s, .portProbeResult(open: true, killedRogues: false))
        XCTAssertEqual(s1.phase, .running)
        XCTAssertEqual(s1.ownership, .external)
        XCTAssertEqual(s1.restartCount, 0)
        XCTAssertTrue(nonLogEffects(fx1).contains(.notifyUI(.running)))
    }

    func testProcessExitedWhileLaunchingNotWanting() {
        // If userWantsRunning is false (user stopped during launch), go to stopped
        let s = state(phase: .launching, wants: false, ownership: .ours, generation: 1)
        let (s1, fx1) = transition(s, .processExited(exitCode: 0))
        XCTAssertEqual(s1.phase, .stopped)
        XCTAssertTrue(nonLogEffects(fx1).contains(.notifyUI(.stopped)))
    }
}
