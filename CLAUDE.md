# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OpenClaw Launcher is a macOS menu bar app that manages the OpenClaw gateway process. It runs as an accessory app (no dock icon), auto-starts the gateway on launch, and provides start/stop/restart controls via a status bar menu. It also triggers the macOS Local Network permission dialog via Bonjour discovery so the gateway can access LAN devices.

## Build Commands

```bash
# Build (Release configuration)
./build.sh

# Build manually
xcodebuild -project OpenClawLauncher.xcodeproj -scheme "OpenClaw Launcher" -configuration Release -derivedDataPath build clean build

# Install to /Applications
cp -R "build/Build/Products/Release/OpenClaw Launcher.app" /Applications/

# Run from build output
open "build/Build/Products/Release/OpenClaw Launcher.app"

# Regenerate app icon (lobster + rocket emoji on gradient)
swift generate_icon.swift
```

There are no tests.

## Architecture

```
main.swift                  → Creates NSApplication + AppDelegate, starts run loop
  └─ AppDelegate            → Menu bar UI (NSStatusItem), gateway lifecycle hooks
       └─ GatewayManager    → Spawns/monitors /usr/local/bin/openclaw gateway run
            ├─ NWBrowser    → Triggers Local Network permission dialog via Bonjour
            ├─ Process      → Manages openclaw subprocess lifecycle
            └─ Timer        → Polls process health every 10s
```

**GatewayManager** launches `openclaw gateway run` (foreground mode, not `start` which is a launchd service command). It auto-restarts on crash up to 5 times with exponential backoff (2s–10s). The process environment explicitly includes `/usr/local/bin` in PATH because GUI login items get a minimal PATH that excludes it, which would break the `#!/usr/bin/env node` shebang in the openclaw script.

## Key Details

- **Bundle ID:** `ai.openclaw.launcher`
- **Deployment target:** macOS 13.0
- **App Sandbox:** Disabled (needs to spawn subprocesses and access network)
- **External dependency:** `/usr/local/bin/openclaw` (Node.js CLI tool installed via npm)
- **Scheme name has a space:** `"OpenClaw Launcher"` — must be quoted in xcodebuild commands
- **LSUIElement:** The app hides from the Dock via `NSApp.setActivationPolicy(.accessory)`
- **stderr capture:** Gateway stderr is piped to NSLog (visible via `log show --predicate 'processImagePath CONTAINS "OpenClaw"'`)
