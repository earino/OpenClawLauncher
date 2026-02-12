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

    var onStatusChange: ((GatewayStatus) -> Void)?

    init() {
        // Trigger Local Network access by making a connection attempt.
        // This is the key reason this app exists — to surface the permission dialog.
        triggerLocalNetworkAccess()
        requestCalendarAccess()
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
        launchProcess()
    }

    func stop() {
        guard status == .running || status == .starting else { return }
        setStatus(.stopping)
        stopStatusPolling()
        terminateProcess()
        setStatus(.stopped)
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.start()
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
            setStatus(.running)
            startStatusPolling()
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
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.checkProcessAlive()
        }
    }

    private func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    private func checkProcessAlive() {
        if let proc = process, !proc.isRunning {
            // Process died without our termination handler catching it
            handleTermination(exitCode: proc.terminationStatus)
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
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }
}
