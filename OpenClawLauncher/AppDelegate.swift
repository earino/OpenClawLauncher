import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var gatewayManager: GatewayManager!
    private var permissionsManager: PermissionsManager!

    // Menu items we need to update
    private var statusMenuItem: NSMenuItem!
    private var startMenuItem: NSMenuItem!
    private var stopMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!
    private var enforceOwnershipMenuItem: NSMenuItem!
    private var dashboardMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When running inside the test host, skip all UI and gateway setup
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        gatewayManager = GatewayManager()
        gatewayManager.onStatusChange = { [weak self] status in
            self?.updateUI(status: status)
        }

        permissionsManager = PermissionsManager()
        permissionsManager.requestAll()

        setupMenuBar()

        // Auto-start the gateway
        gatewayManager.send(.userStart)
    }

    func applicationWillTerminate(_ notification: Notification) {
        gatewayManager?.sendSync(.userQuit)
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "OpenClaw")
        button.imagePosition = .imageLeading
        updateButtonTitle(status: .starting)

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        startMenuItem = NSMenuItem(title: "Start Gateway", action: #selector(startGateway), keyEquivalent: "s")
        startMenuItem.target = self
        menu.addItem(startMenuItem)

        stopMenuItem = NSMenuItem(title: "Stop Gateway", action: #selector(stopGateway), keyEquivalent: "x")
        stopMenuItem.target = self
        menu.addItem(stopMenuItem)

        restartMenuItem = NSMenuItem(title: "Restart Gateway", action: #selector(restartGateway), keyEquivalent: "r")
        restartMenuItem.target = self
        menu.addItem(restartMenuItem)

        menu.addItem(NSMenuItem.separator())

        dashboardMenuItem = NSMenuItem(
            title: "Open Dashboard",
            action: #selector(openDashboard),
            keyEquivalent: "d"
        )
        dashboardMenuItem.target = self
        dashboardMenuItem.isHidden = !isDashboardInstalled()
        menu.addItem(dashboardMenuItem)

        menu.addItem(NSMenuItem.separator())

        enforceOwnershipMenuItem = NSMenuItem(
            title: "Enforce Ownership",
            action: #selector(toggleEnforceOwnership),
            keyEquivalent: "e"
        )
        enforceOwnershipMenuItem.target = self
        enforceOwnershipMenuItem.state = gatewayManager.enforceOwnership ? .on : .off
        menu.addItem(enforceOwnershipMenuItem)

        menu.addItem(NSMenuItem.separator())

        let permissionsItem = NSMenuItem(title: "Permissions...", action: #selector(showPermissions), keyEquivalent: "p")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit OpenClaw Launcher", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - UI Updates

    private func updateUI(status: GatewayStatus) {
        updateButtonTitle(status: status)

        switch status {
        case .stopped:
            statusMenuItem.title = "Status: Stopped"
            startMenuItem.isEnabled = true
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
        case .starting:
            statusMenuItem.title = "Status: Starting..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = false
        case .running:
            statusMenuItem.title = "Status: Running"
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = true
            restartMenuItem.isEnabled = true
        case .stopping:
            statusMenuItem.title = "Status: Stopping..."
            startMenuItem.isEnabled = false
            stopMenuItem.isEnabled = false
            restartMenuItem.isEnabled = false
        }
    }

    private func updateButtonTitle(status: GatewayStatus) {
        guard let button = statusItem?.button else { return }
        switch status {
        case .running:
            button.title = " OpenClaw: Running"
        case .stopped:
            button.title = " OpenClaw: Stopped"
        case .starting:
            button.title = " OpenClaw: Starting"
        case .stopping:
            button.title = " OpenClaw: Stopping"
        }
    }

    // MARK: - Actions

    @objc private func startGateway() {
        gatewayManager.send(.userStart)
    }

    @objc private func stopGateway() {
        gatewayManager.send(.userStop)
    }

    @objc private func restartGateway() {
        gatewayManager.send(.userRestart)
    }

    @objc private func toggleEnforceOwnership() {
        gatewayManager.enforceOwnership.toggle()
        enforceOwnershipMenuItem.state = gatewayManager.enforceOwnership ? .on : .off
    }

    @objc private func showPermissions() {
        permissionsManager.showPanel()
    }

    @objc private func checkForUpdates() {
        statusMenuItem.title = "Status: Checking for updates..."
        gatewayManager.checkForUpdates { [weak self] result in
            DispatchQueue.main.async {
                // Restore current status display — the next onStatusChange will update it,
                // but force a refresh now since checkForUpdates overwrote the menu item.
                self?.statusMenuItem.title = "Status: ..."
                self?.showUpdateAlert(result: result)
            }
        }
    }

    @objc private func quitApp() {
        gatewayManager.sendSync(.userQuit)
        NSApp.terminate(nil)
    }

    @objc private func openDashboard() {
        let startScript = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".openclaw/workspace/skills/claw-dashboard/start.sh")
        let bashCommand = "/bin/bash -lc 'stty rows 30 cols 138; \(startScript)'"

        let script: String
        if preferredTerminalBundleID() == "com.googlecode.iterm2" {
            script = """
            tell application "iTerm"
                activate
                create window with default profile command "\(bashCommand)"
                tell current window
                    tell current session
                        set columns to 138
                        set rows to 30
                    end tell
                end tell
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "\(bashCommand)"
            end tell
            """
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? "unknown"
                NSLog("Dashboard: osascript failed (exit %d): %@", process.terminationStatus, errStr)
            }
        } catch {
            NSLog("Dashboard: failed to launch osascript: %@", error.localizedDescription)
        }
    }

    private func isDashboardInstalled() -> Bool {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".openclaw/workspace/skills/claw-dashboard/index.js")
        return FileManager.default.fileExists(atPath: path)
    }

    private func preferredTerminalBundleID() -> String {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
            return "com.googlecode.iterm2"
        }
        return "com.apple.Terminal"
    }

    private func showUpdateAlert(result: UpdateCheckResult) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        if result.updateAvailable {
            alert.messageText = "Update Available"
            if let version = result.version {
                alert.informativeText = "OpenClaw version \(version) is available.\n\nRun this in Terminal to update:\nopenclaw update"
            } else {
                alert.informativeText = "A new version of OpenClaw is available.\n\nRun this in Terminal to update:\nopenclaw update"
            }
        } else if result.rawOutput.contains("not found") || result.rawOutput.contains("Failed to") {
            alert.messageText = "Update Status"
            alert.informativeText = result.rawOutput
        } else {
            alert.messageText = "Up to Date"
            alert.informativeText = "OpenClaw is running the latest version."
        }

        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        dashboardMenuItem.isHidden = !isDashboardInstalled()
    }
}
