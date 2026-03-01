import ApplicationServices
import AVFoundation
import Cocoa
import CoreBluetooth
import EventKit
import Network

final class PermissionsManager {

    // MARK: - Permission Status

    enum PermissionStatus: CustomStringConvertible {
        case granted
        case denied
        case notDetermined
        case restricted
        case unknown(String)

        var description: String {
            switch self {
            case .granted:        return "Granted"
            case .denied:         return "Denied"
            case .notDetermined:  return "Not Determined"
            case .restricted:     return "Restricted"
            case .unknown(let s): return s
            }
        }

        var statusColor: NSColor {
            switch self {
            case .granted:       return .systemGreen
            case .denied:        return .systemRed
            case .notDetermined: return .systemOrange
            case .restricted:    return .systemRed
            case .unknown:       return .secondaryLabelColor
            }
        }
    }

    struct PermissionInfo {
        let name: String
        let detail: String
        var status: PermissionStatus
        let requestAction: () -> Void
    }

    // MARK: - State

    private var bluetoothManager: CBCentralManager?
    private var panel: NSPanel?
    private var localNetworkStatusLabel: NSTextField?

    // MARK: - Request All (called on launch)

    func requestAll() {
        triggerLocalNetworkAccess()
        requestCalendarAccess()
        requestBluetoothAccess()
        requestAppManagementAccess()
        requestMicrophoneAccess()
    }

    // MARK: - Permission Requests

    private func triggerLocalNetworkAccess() {
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                break
            case .failed(let error):
                NSLog("NWBrowser failed: \(error)")
            default:
                break
            }
        }
        browser.start(queue: .global(qos: .utility))

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            browser.cancel()
        }
    }

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

    private func requestBluetoothAccess() {
        bluetoothManager = CBCentralManager(delegate: nil, queue: .global(qos: .utility))

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.bluetoothManager = nil
        }
    }

    private func requestMicrophoneAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("Microphone access \(granted ? "granted" : "denied")")
        }
    }

    private func requestAppManagementAccess() {
        DispatchQueue.global(qos: .utility).async {
            let bundlePath = "/Applications/OpenClaw Launcher.app"
            let probe = bundlePath + "/.openclaw-permission-probe"
            let fm = FileManager.default
            guard fm.fileExists(atPath: bundlePath) else { return }
            if fm.createFile(atPath: probe, contents: nil) {
                try? fm.removeItem(atPath: probe)
            }
        }
    }

    private func requestAccessibilityAccess() {
        // Prompt macOS to show the Accessibility permission dialog
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Accessibility Check

    func checkAccessibilityStatus() -> PermissionStatus {
        return AXIsProcessTrusted() ? .granted : .denied
    }

    // MARK: - Automation Preflight

    /// Tests whether the app can control the given terminal via AppleScript.
    /// Returns nil on success, or an error message string on failure.
    func testAutomationPermission(terminalBundleID: String) -> String? {
        let appName = terminalBundleID == "com.googlecode.iterm2" ? "iTerm" : "Terminal"
        let script = "tell application \"\(appName)\" to get name"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Failed to run osascript: \(error.localizedDescription)"
        }

        if process.terminationStatus == 0 {
            return nil // success
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        if errStr.contains("not allowed assistive access")
            || errStr.contains("assistive access") {
            return "Accessibility (Assistive Access) permission is required.\n\n"
                + "Go to: System Settings > Privacy & Security > Accessibility\n"
                + "and add \"OpenClaw Launcher\"."
        }

        if errStr.contains("Not authorized to send Apple events")
            || errStr.contains("CommandProcess") && errStr.contains("error")
            || errStr.contains("-1743") {
            return "Automation permission is required to control \(appName).\n\n"
                + "Go to: System Settings > Privacy & Security > Automation\n"
                + "and enable \"\(appName)\" under \"OpenClaw Launcher\"."
        }

        return "osascript failed (exit \(process.terminationStatus)): \(errStr)"
    }

    // MARK: - Status Checks

    private func checkCalendarStatus() -> PermissionStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess:  return .granted
        case .denied:                   return .denied
        case .notDetermined:            return .notDetermined
        case .restricted, .writeOnly:   return .restricted
        @unknown default:               return .unknown("Unknown")
        }
    }

    private func checkBluetoothStatus() -> PermissionStatus {
        if #available(macOS 13.1, *) {
            switch CBCentralManager.authorization {
            case .allowedAlways:  return .granted
            case .denied:         return .denied
            case .notDetermined:  return .notDetermined
            case .restricted:     return .restricted
            @unknown default:     return .unknown("Unknown")
            }
        } else {
            return .unknown("Requires macOS 13.1+")
        }
    }

    private func checkLocalNetworkStatus() {
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        var resolved = false

        browser.stateUpdateHandler = { [weak self] state in
            guard !resolved else { return }
            switch state {
            case .ready:
                resolved = true
                browser.cancel()
                DispatchQueue.main.async {
                    self?.updateLocalNetworkLabel(.granted)
                }
            case .failed:
                resolved = true
                browser.cancel()
                DispatchQueue.main.async {
                    self?.updateLocalNetworkLabel(.denied)
                }
            case .cancelled:
                // If cancelled by our timeout and never resolved, treat as denied
                if !resolved {
                    resolved = true
                    DispatchQueue.main.async {
                        self?.updateLocalNetworkLabel(.denied)
                    }
                }
            default:
                break
            }
        }

        browser.start(queue: .global(qos: .utility))

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            guard !resolved else { return }
            browser.cancel()
        }
    }

    private func updateLocalNetworkLabel(_ status: PermissionStatus) {
        localNetworkStatusLabel?.stringValue = status.description
        localNetworkStatusLabel?.textColor = status.statusColor
    }

    private func checkMicrophoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:     return .granted
        case .denied:         return .denied
        case .notDetermined:  return .notDetermined
        case .restricted:     return .restricted
        @unknown default:     return .unknown("Unknown")
        }
    }

    private func checkAppManagementStatus() -> PermissionStatus {
        let bundlePath = "/Applications/OpenClaw Launcher.app"
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundlePath) else {
            return .unknown("Not in /Applications")
        }
        let probe = bundlePath + "/.openclaw-permission-probe"
        if fm.createFile(atPath: probe, contents: nil) {
            try? fm.removeItem(atPath: probe)
            return .granted
        }
        return .denied
    }

    private func allPermissions() -> [PermissionInfo] {
        return [
            PermissionInfo(
                name: "Local Network",
                detail: "Discover network devices",
                status: .unknown("Checking..."),
                requestAction: { [weak self] in self?.triggerLocalNetworkAccess() }
            ),
            PermissionInfo(
                name: "Calendar",
                detail: "Read and manage events",
                status: checkCalendarStatus(),
                requestAction: { [weak self] in self?.requestCalendarAccess() }
            ),
            PermissionInfo(
                name: "Bluetooth",
                detail: "Discover BT devices",
                status: checkBluetoothStatus(),
                requestAction: { [weak self] in self?.requestBluetoothAccess() }
            ),
            PermissionInfo(
                name: "Microphone",
                detail: "Process voice input",
                status: checkMicrophoneStatus(),
                requestAction: { [weak self] in self?.requestMicrophoneAccess() }
            ),
            PermissionInfo(
                name: "App Management",
                detail: "Update app in /Applications",
                status: checkAppManagementStatus(),
                requestAction: { [weak self] in self?.requestAppManagementAccess() }
            ),
            PermissionInfo(
                name: "Accessibility",
                detail: "Control terminal for Dashboard",
                status: checkAccessibilityStatus(),
                requestAction: { [weak self] in self?.requestAccessibilityAccess() }
            ),
        ]
    }

    // MARK: - Panel UI

    func showPanel() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panelWidth: CGFloat = 440
        let rowHeight: CGFloat = 52
        let permissions = allPermissions()
        let contentHeight = CGFloat(permissions.count) * rowHeight
            + CGFloat(permissions.count - 1) * 1  // separators
            + 60  // bottom buttons + padding

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: contentHeight),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "Permissions"
        p.isReleasedWhenClosed = false
        p.center()

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false

        for (i, perm) in permissions.enumerated() {
            let row = makePermissionRow(perm)
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

            if i < permissions.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                container.addArrangedSubview(sep)
                sep.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
            }
        }

        // Bottom bar
        let bottomBar = NSStackView()
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8

        let settingsButton = NSButton(title: "Open System Settings", target: self, action: #selector(openSystemSettings))
        settingsButton.bezelStyle = .rounded
        bottomBar.addArrangedSubview(settingsButton)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomBar.addArrangedSubview(spacer)

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPanel))
        refreshButton.bezelStyle = .rounded
        bottomBar.addArrangedSubview(refreshButton)

        container.addArrangedSubview(bottomBar)
        bottomBar.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -20).isActive = true

        let scrollView = NSScrollView()
        scrollView.documentView = container
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        p.contentView = scrollView

        container.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true

        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Kick off async Local Network probe
        checkLocalNetworkStatus()
    }

    private func makePermissionRow(_ perm: PermissionInfo) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 52).isActive = true

        // Left side: name (bold) + detail (gray)
        let nameLabel = NSTextField(labelWithString: perm.name)
        nameLabel.font = .boldSystemFont(ofSize: 13)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let detailLabel = NSTextField(labelWithString: perm.detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        // Right side: status indicator + Request button
        let statusText = NSTextField(labelWithString: perm.status.description)
        statusText.font = .systemFont(ofSize: 12)
        statusText.textColor = perm.status.statusColor
        statusText.translatesAutoresizingMaskIntoConstraints = false
        statusText.setContentHuggingPriority(.required, for: .horizontal)

        if perm.name == "Local Network" {
            localNetworkStatusLabel = statusText
        }

        let requestButton = NSButton(title: "Request", target: nil, action: nil)
        requestButton.bezelStyle = .rounded
        requestButton.controlSize = .small
        requestButton.font = .systemFont(ofSize: 11)
        requestButton.translatesAutoresizingMaskIntoConstraints = false
        let action = perm.requestAction
        requestButton.target = self
        requestButton.tag = 0
        // Store action via ObjC associated object
        objc_setAssociatedObject(requestButton, &PermissionsManager.requestActionKey, action, .OBJC_ASSOCIATION_RETAIN)
        requestButton.action = #selector(requestButtonClicked(_:))

        row.addSubview(nameLabel)
        row.addSubview(detailLabel)
        row.addSubview(statusText)
        row.addSubview(requestButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),

            detailLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            requestButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            requestButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            statusText.trailingAnchor.constraint(equalTo: requestButton.leadingAnchor, constant: -8),
            statusText.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    private static var requestActionKey: UInt8 = 0

    @objc private func requestButtonClicked(_ sender: NSButton) {
        if let action = objc_getAssociatedObject(sender, &PermissionsManager.requestActionKey) as? () -> Void {
            action()
        }
    }

    @objc private func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func refreshPanel() {
        guard let p = panel else { return }
        p.close()
        panel = nil
        localNetworkStatusLabel = nil
        showPanel()
    }
}
