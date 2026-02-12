import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var gatewayManager: GatewayManager!

    // Menu items we need to update
    private var statusMenuItem: NSMenuItem!
    private var startMenuItem: NSMenuItem!
    private var stopMenuItem: NSMenuItem!
    private var restartMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        gatewayManager = GatewayManager()
        gatewayManager.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.updateUI(status: status)
            }
        }

        setupMenuBar()

        // Auto-start the gateway
        gatewayManager.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        gatewayManager.stop()
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

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit OpenClaw Launcher", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        updateUI(status: gatewayManager.status)
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
        gatewayManager.start()
    }

    @objc private func stopGateway() {
        gatewayManager.stop()
    }

    @objc private func restartGateway() {
        gatewayManager.restart()
    }

    @objc private func checkForUpdates() {
        statusMenuItem.title = "Status: Checking for updates..."
        gatewayManager.checkForUpdates { [weak self] result in
            DispatchQueue.main.async {
                self?.updateUI(status: self?.gatewayManager.status ?? .stopped)
                self?.showAlert(title: "Update Status", message: result)
            }
        }
    }

    @objc private func quitApp() {
        gatewayManager.stop()
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
