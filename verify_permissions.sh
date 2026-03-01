#!/bin/bash
# verify_permissions.sh — Quick check of macOS permissions relevant to OpenClaw Launcher
# Usage: ./verify_permissions.sh

echo "=== OpenClaw Launcher Permission Checks ==="
echo

# 1. Accessibility (AXIsProcessTrusted)
echo "1. Accessibility (Assistive Access)"
# Use a tiny Swift snippet to check AXIsProcessTrusted from the command line
AX_RESULT=$(swift -e 'import ApplicationServices; print(AXIsProcessTrusted())' 2>/dev/null)
if [ "$AX_RESULT" = "true" ]; then
    echo "   Status: GRANTED (this terminal process is trusted)"
else
    echo "   Status: NOT GRANTED for this process (expected for terminal)"
    echo "   Note: OpenClaw Launcher.app needs its own Accessibility entry."
fi
echo "   Settings: System Settings > Privacy & Security > Accessibility"
echo

# 2. Automation — test osascript control of Terminal
echo "2. Automation (Terminal.app)"
RESULT=$(osascript -e 'tell application "Terminal" to get name' 2>&1)
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "   Status: GRANTED (can control Terminal.app)"
else
    echo "   Status: DENIED or NOT YET PROMPTED"
    echo "   Error: $RESULT"
fi
echo "   Settings: System Settings > Privacy & Security > Automation"
echo

# 3. Automation — test osascript control of iTerm2 (if installed)
if [ -d "/Applications/iTerm.app" ]; then
    echo "3. Automation (iTerm2)"
    RESULT=$(osascript -e 'tell application "iTerm" to get name' 2>&1)
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        echo "   Status: GRANTED (can control iTerm2)"
    else
        echo "   Status: DENIED or NOT YET PROMPTED"
        echo "   Error: $RESULT"
    fi
    echo "   Settings: System Settings > Privacy & Security > Automation"
    echo
fi

# 4. Check if OpenClaw Launcher is in /Applications
echo "4. App Installation"
if [ -d "/Applications/OpenClaw Launcher.app" ]; then
    echo "   Status: Installed in /Applications"
else
    echo "   Status: NOT in /Applications (some permissions require this)"
fi
echo

echo "=== Done ==="
echo "For full permission status, open OpenClaw Launcher > Permissions... (⌘P)"
