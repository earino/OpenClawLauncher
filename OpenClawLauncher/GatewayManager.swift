import EventKit
import Foundation
import Network

enum GatewayStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
}

final class GatewayManager {
    private(set) var status: GatewayStatus = .stopped
    private var process: Process?
    private var stderrPipe: Pipe?
    private var statusTimer: Timer?
    private var restartCount = 0
    private let maxRestartAttempts = 5
    private let openclawPath = "/usr/local/bin/openclaw"
    private var gatewayPort: UInt16 = 18789
    private var isExternalGateway = false
    private var isPolling = false
    private let pollQueue = DispatchQueue(label: "ai.openclaw.launcher.poll", qos: .utility)

    var onStatusChange: ((GatewayStatus) -> Void)?

    init() {
        gatewayPort = readGatewayPort()
        triggerLocalNetworkAccess()
        requestCalendarAccess()
        startStatusPolling()
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

        connection.start(queue: pollQueue)

        pollQueue.asyncAfter(deadline: .now() + 2) {
            complete(false)
        }
    }

    // MARK: - Local Network Permission Trigger

    private func triggerLocalNetworkAccess() {
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Browser is active — Local Network permission was granted or dialog was shown
                break
            case .failed(let error):
                NSLog("NWBrowser failed: \(error)")
            default:
                break
            }
        }
        browser.start(queue: .global(qos: .utility))

        // Keep browser alive briefly to ensure dialog appears, then cancel
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            browser.cancel()
        }
    }

    // MARK: - Calendar Permission Trigger

    private func requestCalendarAccess() {
        let store = EKEventStore()
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, error in
                if let error = error {
                    NSLog("Calendar access request error: \(error)")
                } else {
                    NSLog("Calendar access \(granted ? "granted" : "denied")")
                }
            }
        } else {
            store.requestAccess(to: .event) { granted, error in
                if let error = error {
                    NSLog("Calendar access request error: \(error)")
                } else {
                    NSLog("Calendar access \(granted ? "granted" : "denied")")
                }
            }
        }
    }

    // MARK: - Process Lifecycle

    func start() {
        guard status == .stopped else { return }

        guard FileManager.default.isExecutableFile(atPath: openclawPath) else {
            NSLog("openclaw binary not found at \(openclawPath)")
            return
        }

        setStatus(.starting)
        restartCount = 0

        // Check if gateway is already running before launching a duplicate
        checkPortListening(port: gatewayPort) { [weak self] isListening in
            DispatchQueue.main.async {
                guard let self = self, self.status == .starting else { return }

                if isListening {
                    NSLog("Gateway port \(self.gatewayPort) already open — adopting existing gateway")
                    self.isExternalGateway = true
                    self.setStatus(.running)
                } else {
                    self.launchProcess()
                }
            }
        }
    }

    func stop() {
        guard status == .running || status == .starting else { return }
        setStatus(.stopping)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if self?.isExternalGateway == true {
                self?.killExternalGateway()
            } else {
                self?.terminateProcess()
            }
            DispatchQueue.main.async {
                self?.isExternalGateway = false
                self?.setStatus(.stopped)
            }
        }
    }

    /// Synchronous stop for use during app termination.
    /// Only kills our own process — leaves external gateways running.
    func stopSync() {
        guard status == .running || status == .starting else { return }
        setStatus(.stopping)
        if !isExternalGateway {
            terminateProcess()
        }
        isExternalGateway = false
        setStatus(.stopped)
    }

    func restart() {
        guard status == .running || status == .starting else { return }
        setStatus(.stopping)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if self?.isExternalGateway == true {
                self?.killExternalGateway()
            } else {
                self?.terminateProcess()
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isExternalGateway = false
                self.setStatus(.stopped)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.start()
                }
            }
        }
    }

    private func launchProcess() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: openclawPath)
        proc.arguments = ["gateway", "run"]

        // Ensure /usr/local/bin is in PATH — GUI apps launched at login
        // have a minimal PATH that may not include it, which breaks
        // shebang resolution for scripts like #!/usr/bin/env node.
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !currentPath.contains("/usr/local/bin") {
            env["PATH"] = "/usr/local/bin:" + currentPath
        }
        proc.environment = env

        // Capture stderr so failures are visible in system log
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let msg = String(data: data, encoding: .utf8) {
                NSLog("openclaw stderr: %@", msg)
            }
        }
        self.stderrPipe = errPipe

        proc.terminationHandler = { [weak self] terminatedProcess in
            // Stop the readability handler immediately to prevent a
            // tight spin loop on the closed pipe (100% CPU).
            self?.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe = nil
            DispatchQueue.main.async {
                self?.handleTermination(exitCode: terminatedProcess.terminationStatus)
            }
        }

        do {
            try proc.run()
            self.process = proc
            isExternalGateway = false
            setStatus(.running)
        } catch {
            NSLog("Failed to launch openclaw gateway: \(error)")
            setStatus(.stopped)
        }
    }

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }

        let pid = proc.processIdentifier

        // Kill the entire process tree — openclaw is a Node.js script that
        // spawns child processes (the actual gateway server). Sending SIGTERM
        // only to the top-level process leaves orphaned children running.
        killDescendants(of: pid, signal: SIGTERM)
        proc.terminate()

        // Give it 5 seconds to exit gracefully
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Force kill if still running
        if proc.isRunning {
            killDescendants(of: pid, signal: SIGKILL)
            kill(pid, SIGKILL)
            proc.waitUntilExit()
        }

        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        process = nil
    }

    private func killExternalGateway() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "openclaw gateway"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NSLog("Failed to kill external gateway: \(error)")
        }
    }

    /// Recursively find and signal all descendant processes.
    private func killDescendants(of pid: pid_t, signal: Int32) {
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
        } catch {
            // pgrep not found or failed — no children to kill
        }
    }

    private func handleTermination(exitCode: Int32) {
        guard status == .running || status == .starting else {
            // We initiated the stop, no restart needed
            return
        }

        NSLog("Gateway process exited with code \(exitCode)")

        // Check if the port is still open — child process may have survived
        checkPortListening(port: gatewayPort) { [weak self] isListening in
            DispatchQueue.main.async {
                guard let self = self, self.status == .running || self.status == .starting else { return }

                if isListening {
                    NSLog("Gateway port still open — child process survived, adopting as external")
                    self.process = nil
                    self.isExternalGateway = true
                    self.setStatus(.running)
                } else {
                    self.process = nil
                    self.attemptRestart()
                }
            }
        }
    }

    private func attemptRestart() {
        if restartCount < maxRestartAttempts {
            restartCount += 1
            let delay = min(Double(restartCount) * 2.0, 10.0) // backoff: 2s, 4s, 6s, 8s, 10s
            NSLog("Restarting gateway (attempt \(restartCount)/\(maxRestartAttempts)) in \(delay)s")
            setStatus(.starting)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard self?.status == .starting else { return }
                self?.launchProcess()
            }
        } else {
            NSLog("Gateway crashed \(maxRestartAttempts) times, giving up")
            setStatus(.stopped)
        }
    }

    // MARK: - Status Polling

    private func startStatusPolling() {
        stopStatusPolling()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollGatewayStatus()
        }
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func pollGatewayStatus() {
        guard !isPolling else { return }
        isPolling = true

        checkPortListening(port: gatewayPort) { [weak self] isListening in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.reconcileStatus(portOpen: isListening)
                self.isPolling = false
            }
        }
    }

    private func reconcileStatus(portOpen: Bool) {
        switch status {
        case .stopping:
            // User-initiated stop in progress, don't override
            break
        case .starting:
            if portOpen {
                // Gateway is ready (either ours finished starting, or external)
                setStatus(.running)
            }
        case .stopped:
            if portOpen {
                // External gateway detected
                isExternalGateway = true
                setStatus(.running)
            }
        case .running:
            if !portOpen {
                if isExternalGateway {
                    // External gateway died
                    isExternalGateway = false
                    setStatus(.stopped)
                } else if process == nil || process?.isRunning == false {
                    // Our process died and port is closed — truly dead
                    // (terminationHandler should have caught this, but safety net)
                    setStatus(.stopped)
                }
            }
        }
    }

    // MARK: - Update Check

    func checkForUpdates(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard FileManager.default.isExecutableFile(atPath: openclawPath) else {
                completion("openclaw binary not found at \(openclawPath)")
                return
            }

            let proc = Process()
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: openclawPath)
            proc.arguments = ["update", "status"]
            proc.standardOutput = pipe
            proc.standardError = pipe

            do {
                try proc.run()
                proc.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "No output"
                completion(output)
            } catch {
                completion("Failed to check for updates: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helpers

    private func setStatus(_ newStatus: GatewayStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }

    deinit {
        stopStatusPolling()
        if !isExternalGateway, let proc = process, proc.isRunning {
            let pid = proc.processIdentifier
            killDescendants(of: pid, signal: SIGTERM)
            proc.terminate()
        }
    }
}
