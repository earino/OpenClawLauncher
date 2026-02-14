import Foundation
import Network

struct UpdateCheckResult {
    let updateAvailable: Bool
    let version: String?
    let rawOutput: String
}

final class GatewayManager {
    // MARK: - Queues

    private let stateQueue = DispatchQueue(label: "ai.openclaw.launcher.state")
    private let workQueue = DispatchQueue(label: "ai.openclaw.launcher.work", qos: .utility)

    // MARK: - State (only accessed on stateQueue)

    private var state = GatewayState()
    private var managedProcess: Process?
    private var stderrPipe: Pipe?
    private var isPollInFlight = false

    // MARK: - Configuration

    private let openclawPath = "/usr/local/bin/openclaw"
    private let launchdLabel = "ai.openclaw.gateway"
    private var gatewayPort: UInt16 = 18789
    private var statusTimer: Timer?
    private var launchdServiceUnloaded = false

    var enforceOwnership: Bool {
        get { UserDefaults.standard.bool(forKey: "enforceOwnership") }
        set {
            let oldValue = UserDefaults.standard.bool(forKey: "enforceOwnership")
            UserDefaults.standard.set(newValue, forKey: "enforceOwnership")
            if newValue && !oldValue {
                workQueue.async { [self] in
                    self.launchdServiceUnloaded = false
                }
            }
        }
    }

    var onStatusChange: ((GatewayStatus) -> Void)?

    // MARK: - Init

    init() {
        UserDefaults.standard.register(defaults: ["enforceOwnership": true])
        gatewayPort = readGatewayPort()
        startStatusPolling()
    }

    // MARK: - Public API

    func send(_ event: GatewayEvent) {
        stateQueue.async { [self] in
            self.processEvent(event)
        }
    }

    func sendSync(_ event: GatewayEvent) {
        stateQueue.sync { [self] in
            self.processEvent(event)
        }
    }

    // MARK: - Event Processing (stateQueue only)

    private func processEvent(_ event: GatewayEvent) {
        let oldPhase = state.phase
        let oldStatus = state.uiStatus
        let (newState, effects) = gatewayTransition(
            state: state,
            event: event,
            enforceOwnership: enforceOwnership
        )
        state = newState
        let gen = state.generation

        // Structured logging
        let effectNames = effects.map { describeEffect($0) }.joined(separator: ", ")
        NSLog("[FSM] %@ + %@ -> %@  gen=%llu  effects=[%@]",
              String(describing: oldPhase),
              describeEvent(event),
              String(describing: state.phase),
              gen,
              effectNames)

        // Execute side effects
        for effect in effects {
            execute(effect, generation: gen)
        }

        // If UI status changed but no explicit notifyUI was in the effects, send one
        if state.uiStatus != oldStatus && !effects.contains(where: { if case .notifyUI = $0 { return true }; return false }) {
            execute(.notifyUI(state.uiStatus), generation: gen)
        }
    }

    // MARK: - Side Effect Executor (stateQueue)

    private func execute(_ effect: SideEffect, generation: UInt64) {
        switch effect {
        case .probePort:
            performPollCycle(generation: generation)

        case .launchProcess:
            do {
                let (proc, pipe) = try performLaunchProcess()
                managedProcess = proc
                stderrPipe = pipe
                processEvent(.launchSucceeded)
            } catch {
                NSLog("Failed to launch openclaw gateway: %@", "\(error)")
                processEvent(.launchFailed)
            }

        case .terminateOurProcess:
            let proc = managedProcess
            let pipe = stderrPipe
            managedProcess = nil
            stderrPipe = nil
            workQueue.async { [self] in
                if let proc = proc {
                    GatewayManager.performTerminateProcess(proc, pipe: pipe)
                }
                self.send(.stopCompleted)
            }

        case .killExternalGateway:
            workQueue.async { [self] in
                GatewayManager.performKillExternalGateway()
                self.send(.stopCompleted)
            }

        case .terminateForRestart:
            let proc = managedProcess
            let pipe = stderrPipe
            managedProcess = nil
            stderrPipe = nil
            workQueue.async { [self] in
                if let proc = proc {
                    GatewayManager.performTerminateProcess(proc, pipe: pipe)
                }
                self.send(.restartStopCompleted)
            }

        case .killExternalForRestart:
            workQueue.async { [self] in
                GatewayManager.performKillExternalGateway()
                self.send(.restartStopCompleted)
            }

        case .scheduleRestart(let delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                self.stateQueue.async {
                    guard self.state.generation == generation else {
                        NSLog("[FSM] stale restartDelayElapsed (gen %llu != %llu), discarding",
                              generation, self.state.generation)
                        return
                    }
                    self.processEvent(.restartDelayElapsed)
                }
            }

        case .terminateSync:
            if let proc = managedProcess {
                GatewayManager.performTerminateProcess(proc, pipe: stderrPipe)
            }
            managedProcess = nil
            stderrPipe = nil

        case .notifyUI(let uiStatus):
            let status = uiStatus
            DispatchQueue.main.async { [weak self] in
                self?.onStatusChange?(status)
            }

        case .log(let message):
            NSLog("%@", message)
        }
    }

    // MARK: - Poll Cycle

    private func startStatusPolling() {
        DispatchQueue.main.async { [weak self] in
            self?.statusTimer?.invalidate()
            self?.statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.stateQueue.async {
                    guard let self = self else { return }
                    guard !self.isPollInFlight else { return }
                    self.isPollInFlight = true
                    let gen = self.state.generation
                    let enforce = self.enforceOwnership
                    let wants = self.state.userWantsRunning
                    self.workQueue.async {
                        self.performPollCycleWork(generation: gen, enforceOwnership: enforce, userWantsRunning: wants)
                    }
                }
            }
        }
    }

    private func performPollCycle(generation: UInt64) {
        guard !isPollInFlight else { return }
        isPollInFlight = true
        let enforce = enforceOwnership
        let wants = state.userWantsRunning
        workQueue.async { [self] in
            performPollCycleWork(generation: generation, enforceOwnership: enforce, userWantsRunning: wants)
        }
    }

    private func performPollCycleWork(generation: UInt64, enforceOwnership: Bool, userWantsRunning: Bool) {
        // Step 1: Kill rogues if enforce ownership is on and user wants running
        var killedRogues = false
        if enforceOwnership && userWantsRunning {
            killedRogues = performKillRogueGateways()
        }

        // Step 2: Check port
        let semaphore = DispatchSemaphore(value: 0)
        var portOpen = false
        checkPortListening(port: gatewayPort) { result in
            portOpen = result
            semaphore.signal()
        }
        semaphore.wait()

        // Step 3: Feed result back as event
        stateQueue.async { [self] in
            self.isPollInFlight = false
            guard self.state.generation == generation else {
                NSLog("[FSM] stale poll result (gen %llu != %llu), discarding",
                      generation, self.state.generation)
                return
            }
            self.processEvent(.portProbeResult(open: portOpen, killedRogues: killedRogues))
        }
    }

    // MARK: - Process Operations

    private func performLaunchProcess() throws -> (Process, Pipe) {
        guard FileManager.default.isExecutableFile(atPath: openclawPath) else {
            throw NSError(domain: "ai.openclaw.launcher", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "openclaw binary not found at \(openclawPath)"])
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: openclawPath)
        proc.arguments = ["gateway", "run"]

        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !currentPath.contains("/usr/local/bin") {
            env["PATH"] = "/usr/local/bin:" + currentPath
        }
        proc.environment = env

        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let msg = String(data: data, encoding: .utf8) {
                NSLog("openclaw stderr: %@", msg)
            }
        }

        proc.terminationHandler = { [weak self] terminatedProcess in
            guard let self = self else { return }
            self.stateQueue.async {
                guard self.managedProcess === terminatedProcess else {
                    return  // stale callback from a previous process
                }
                // Clean up stderr pipe to prevent spin loop
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.managedProcess = nil
                self.stderrPipe = nil
                self.processEvent(.processExited(exitCode: terminatedProcess.terminationStatus))
            }
        }

        try proc.run()
        return (proc, errPipe)
    }

    private static func performTerminateProcess(_ proc: Process, pipe: Pipe?) {
        pipe?.fileHandleForReading.readabilityHandler = nil

        guard proc.isRunning else { return }

        let pid = proc.processIdentifier
        killDescendants(of: pid, signal: SIGTERM)
        proc.terminate()

        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if proc.isRunning {
            killDescendants(of: pid, signal: SIGKILL)
            kill(pid, SIGKILL)
            proc.waitUntilExit()
        }
    }

    private static func performKillExternalGateway() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "openclaw.*gateway"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("Failed to kill external gateway: %@", "\(error)")
        }
    }

    private func performKillRogueGateways() -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "openclaw.*gateway"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice

        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            return false
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }

        let allPids = output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        guard !allPids.isEmpty else { return false }

        // Fresh read of managed process PID (not a stale snapshot)
        var ourPids = Set<pid_t>()
        var currentManagedPid: pid_t? = nil
        stateQueue.sync {
            if let proc = self.managedProcess, proc.isRunning {
                currentManagedPid = proc.processIdentifier
            }
        }
        if let pid = currentManagedPid {
            ourPids.insert(pid)
            GatewayManager.collectDescendants(of: pid, into: &ourPids)
        }

        var roguePids = allPids.filter { !ourPids.contains($0) }
        guard !roguePids.isEmpty else { return false }

        // Try to unload launchd service first (prevents KeepAlive respawn)
        if !launchdServiceUnloaded {
            if isLaunchdServiceLoaded() {
                NSLog("Enforce Ownership: launchd service '%@' is loaded, unloading via bootout", launchdLabel)
                if unloadLaunchdService() {
                    launchdServiceUnloaded = true
                    Thread.sleep(forTimeInterval: 1)
                    // Re-check which rogues are still alive after bootout
                    roguePids = roguePids.filter { kill($0, 0) == 0 }
                    if roguePids.isEmpty {
                        NSLog("Enforce Ownership: all rogues terminated by launchd bootout")
                        return true
                    }
                } else {
                    NSLog("Enforce Ownership: bootout failed, will retry next cycle")
                    // Leave launchdServiceUnloaded false so we retry
                }
            } else {
                launchdServiceUnloaded = true
            }
        }

        for pid in roguePids {
            NSLog("Enforce Ownership: killing rogue gateway process %d", pid)
            kill(pid, SIGTERM)
        }

        Thread.sleep(forTimeInterval: 2)
        for pid in roguePids {
            kill(pid, SIGKILL)
        }
        return true
    }

    // MARK: - launchd Helpers

    private func isLaunchdServiceLoaded() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list", launchdLabel]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func unloadLaunchdService() -> Bool {
        let uid = getuid()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(uid)/\(launchdLabel)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let success = task.terminationStatus == 0
            if success {
                NSLog("Enforce Ownership: successfully unloaded launchd service '%@'", launchdLabel)
            } else {
                NSLog("Enforce Ownership: launchctl bootout exited with status %d", task.terminationStatus)
            }
            return success
        } catch {
            NSLog("Enforce Ownership: launchctl bootout failed: %@", "\(error)")
            return false
        }
    }

    // MARK: - Process Tree Helpers

    private static func killDescendants(of pid: pid_t, signal: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.split(separator: "\n") {
                    if let childPid = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                        killDescendants(of: childPid, signal: signal)
                        kill(childPid, signal)
                    }
                }
            }
        } catch {}
    }

    private static func collectDescendants(of pid: pid_t, into pids: inout Set<pid_t>) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.split(separator: "\n") {
                    if let childPid = pid_t(line.trimmingCharacters(in: .whitespaces)) {
                        pids.insert(childPid)
                        collectDescendants(of: childPid, into: &pids)
                    }
                }
            }
        } catch {}
    }

    // MARK: - TCP Port Probe

    private func checkPortListening(port: UInt16, completion: @escaping (Bool) -> Void) {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        var completed = false
        let complete: (Bool) -> Void = { result in
            guard !completed else { return }
            completed = true
            connection.cancel()
            completion(result)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                complete(true)
            case .failed, .cancelled:
                complete(false)
            case .waiting:
                complete(false)
            default:
                break
            }
        }

        let callbackQueue = DispatchQueue(label: "ai.openclaw.launcher.portcheck")
        connection.start(queue: callbackQueue)

        callbackQueue.asyncAfter(deadline: .now() + 2) {
            complete(false)
        }
    }

    // MARK: - Config Reading

    private func readGatewayPort() -> UInt16 {
        let configPath = (NSHomeDirectory() as NSString).appendingPathComponent(".openclaw/openclaw.json")
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let port = gateway["port"] as? Int,
              port > 0, port <= Int(UInt16.max)
        else {
            return 18789
        }
        return UInt16(port)
    }

    // MARK: - Update Check

    func checkForUpdates(completion: @escaping (UpdateCheckResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard FileManager.default.isExecutableFile(atPath: openclawPath) else {
                completion(UpdateCheckResult(updateAvailable: false, version: nil, rawOutput: "openclaw binary not found at \(openclawPath)"))
                return
            }

            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: openclawPath)
            proc.arguments = ["update", "status"]
            proc.standardOutput = pipe
            proc.standardError = pipe

            var env = ProcessInfo.processInfo.environment
            let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            if !currentPath.contains("/usr/local/bin") {
                env["PATH"] = "/usr/local/bin:" + currentPath
            }
            proc.environment = env

            do {
                try proc.run()
                proc.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No output"
                completion(parseUpdateOutput(output))
            } catch {
                completion(UpdateCheckResult(updateAvailable: false, version: nil, rawOutput: "Failed to check for updates: \(error.localizedDescription)"))
            }
        }
    }

    private func parseUpdateOutput(_ output: String) -> UpdateCheckResult {
        let lowered = output.lowercased()
        let hasUpdate = lowered.contains("update available") || lowered.contains("new version")

        var version: String?
        let patterns = [
            "\\(npm\\s+([^)]+)\\)",
            "→\\s*([\\d.]+)",
            "=>\\s*([\\d.]+)",
            "version\\s+([\\d.]+)",
            "([\\d]+\\.[\\d]+\\.[\\d]+)"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output) {
                version = String(output[range])
                break
            }
        }

        return UpdateCheckResult(updateAvailable: hasUpdate, version: version, rawOutput: output)
    }

    // MARK: - Logging Helpers

    private func describeEvent(_ event: GatewayEvent) -> String {
        switch event {
        case .userStart: return "userStart"
        case .userStop: return "userStop"
        case .userRestart: return "userRestart"
        case .userQuit: return "userQuit"
        case .processExited(let code): return "processExited(\(code))"
        case .portProbeResult(let open, let killed): return "portProbeResult(open:\(open), killedRogues:\(killed))"
        case .restartDelayElapsed: return "restartDelayElapsed"
        case .stopCompleted: return "stopCompleted"
        case .restartStopCompleted: return "restartStopCompleted"
        case .launchSucceeded: return "launchSucceeded"
        case .launchFailed: return "launchFailed"
        }
    }

    private func describeEffect(_ effect: SideEffect) -> String {
        switch effect {
        case .probePort: return "probePort"
        case .launchProcess: return "launchProcess"
        case .terminateOurProcess: return "terminateOurProcess"
        case .killExternalGateway: return "killExternalGateway"
        case .terminateForRestart: return "terminateForRestart"
        case .killExternalForRestart: return "killExternalForRestart"
        case .scheduleRestart(let delay): return "scheduleRestart(\(delay)s)"
        case .terminateSync: return "terminateSync"
        case .notifyUI(let status): return "notifyUI(\(status))"
        case .log: return "log"
        }
    }

    // MARK: - Deinit

    deinit {
        statusTimer?.invalidate()
        if let proc = managedProcess, proc.isRunning {
            GatewayManager.performTerminateProcess(proc, pipe: stderrPipe)
        }
    }
}
