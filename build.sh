#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"

echo "=== Building OpenClaw Launcher ==="

xcodebuild \
    -project "${PROJECT_DIR}/OpenClawLauncher.xcodeproj" \
    -scheme "OpenClaw Launcher" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    clean build

APP_PATH=$(find "${BUILD_DIR}" -name "OpenClaw Launcher.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "ERROR: Build failed — .app not found"
    exit 1
fi

echo ""
echo "=== Build Successful ==="
echo "App location: ${APP_PATH}"
echo ""
echo "To install to /Applications:"
echo "  cp -R \"${APP_PATH}\" /Applications/"
echo ""
echo "To run:"
echo "  open \"${APP_PATH}\""
echo ""
echo "To add to Login Items:"
echo "  1. Open System Settings → General → Login Items"
echo "  2. Click '+' and select 'OpenClaw Launcher' from Applications"
