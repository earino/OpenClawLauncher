#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
README="${PROJECT_DIR}/README.md"

# --- Usage ---
if [ $# -ne 1 ]; then
    echo "Usage: ./release.sh <version>"
    echo "Example: ./release.sh 1.0.5"
    exit 1
fi

# Strip leading 'v' if present
VERSION="${1#v}"
TAG="v${VERSION}"
ZIP_NAME="OpenClaw-Launcher-v${VERSION}-macos.zip"

echo "=== Releasing OpenClaw Launcher ${TAG} ==="
echo ""

# --- Pre-flight checks ---
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: Working tree has uncommitted changes. Commit or stash them first."
    exit 1
fi

if git tag -l "${TAG}" | grep -q "${TAG}"; then
    echo "ERROR: Tag ${TAG} already exists."
    exit 1
fi

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh (GitHub CLI) is not installed."
    exit 1
fi

# --- Build ---
echo ">>> Building..."
"${PROJECT_DIR}/build.sh"

APP_PATH=$(find "${PROJECT_DIR}/build" -name "OpenClaw Launcher.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Build failed — .app not found"
    exit 1
fi

# --- Create zip ---
echo ""
echo ">>> Creating ${ZIP_NAME}..."
(cd "$(dirname "$APP_PATH")" && zip -r "${PROJECT_DIR}/${ZIP_NAME}" "OpenClaw Launcher.app")

# --- Update README ---
echo ""
echo ">>> Updating README.md..."
sed -i '' -E "s/OpenClaw-Launcher-v[0-9]+\.[0-9]+\.[0-9]+-macos\.zip/OpenClaw-Launcher-v${VERSION}-macos.zip/g" "$README"

# --- Commit, tag, push ---
echo ""
echo ">>> Committing README update..."
git add "$README"
git commit -m "Update README to point to ${TAG} release"

echo ">>> Tagging ${TAG}..."
git tag "${TAG}"

echo ">>> Pushing to origin..."
git push origin main --tags

# --- GitHub release ---
echo ""
echo ">>> Creating GitHub release..."
RELEASE_URL=$(gh release create "${TAG}" "${PROJECT_DIR}/${ZIP_NAME}" \
    --title "${TAG}" \
    --generate-notes)
echo "Release created: ${RELEASE_URL}"

# --- Install locally ---
echo ""
echo ">>> Installing to /Applications..."
cp -R "$APP_PATH" /Applications/

echo ""
echo "=== Release ${TAG} complete ==="
echo "  GitHub: ${RELEASE_URL}"
echo "  Installed to /Applications/OpenClaw Launcher.app"
