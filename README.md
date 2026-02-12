# OpenClaw Launcher

A macOS menu bar app that launches and manages the [OpenClaw](https://openclaw.ai) gateway, with a specific focus on solving the macOS Local Network permission problem.

## The Problem

I use OpenClaw to control a TP-Link TAPO PTZ camera on my local network. On macOS, apps that want to communicate with devices on the local network need explicit **Local Network permission** — a system dialog the user must approve. Without it, the gateway silently fails to reach LAN devices like cameras and sensors.

The OpenClaw CLI (`openclaw gateway run`) is a Node.js process. Command-line tools launched via launchd or login items don't reliably trigger the Local Network permission dialog. macOS ties this permission to an **app bundle** with a proper `Info.plist` containing `NSLocalNetworkUsageDescription` and `NSBonjourServices`. A bare CLI process doesn't have that, so the OS never asks and never grants access.

**OpenClaw Launcher** is a native macOS app wrapper that:
1. Triggers the Local Network permission dialog on launch (via Bonjour discovery)
2. Runs `openclaw gateway run` as a managed child process
3. Inherits the granted network permission to the gateway subprocess
4. Auto-restarts the gateway on crash (up to 5 times with exponential backoff)
5. Lives in the menu bar with start/stop/restart controls

## Screenshot

Once running, you'll see a menu bar item showing the gateway status:

```
🌐 OpenClaw: Running
├── Status: Running
├── Start Gateway      ⌘S
├── Stop Gateway       ⌘X
├── Restart Gateway    ⌘R
├── Check for Updates… ⌘U
└── Quit               ⌘Q
```

## Requirements

- macOS 13.0 (Ventura) or later
- [OpenClaw CLI](https://openclaw.ai) installed at `/usr/local/bin/openclaw`
- Xcode 14+ (to build from source)

## Building

```bash
./build.sh
```

The built app will be at `build/Build/Products/Release/OpenClaw Launcher.app`.

## Installation

```bash
# Copy to Applications
cp -R "build/Build/Products/Release/OpenClaw Launcher.app" /Applications/

# Launch it
open "/Applications/OpenClaw Launcher.app"
```

To start automatically at login, add it to **System Settings > General > Login Items**.

## How It Works

The app is intentionally minimal — three Swift files:

- **`main.swift`** — App entry point
- **`AppDelegate.swift`** — Menu bar UI and status display
- **`GatewayManager.swift`** — Process lifecycle, Bonjour-based Local Network permission trigger, auto-restart logic

On launch, the app uses `NWBrowser` to perform a Bonjour browse for `_http._tcp` services. This is what triggers macOS to show the Local Network permission dialog. Once granted, the permission applies to the app and its child processes — including the `openclaw gateway run` subprocess it manages.

The app explicitly sets `/usr/local/bin` in the child process's `PATH` because macOS login items run with a minimal environment that doesn't include it, which would otherwise break the `#!/usr/bin/env node` shebang in the openclaw script.

## Regenerating the App Icon

The app icon (a lobster with a rocket) is generated programmatically:

```bash
swift generate_icon.swift
```

This renders emoji onto a gradient background at all required macOS icon sizes.

## License

[MIT](LICENSE)
