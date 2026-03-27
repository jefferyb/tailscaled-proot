#!/bin/bash
# Build tailscaled for PRoot-Distro (Termux) environments.
#
# This patches tailscale to work around Android's netlink socket restrictions
# and builds with GOOS=android so the polling-based network monitor is used
# instead of the netlink-based one.
#
# Usage:
#   ./build-tailscaled.sh [version]
#
# Examples:
#   ./build-tailscaled.sh           # builds latest tagged version
#   ./build-tailscaled.sh v1.96.2   # builds specific version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/tailscale-proot-distro.patch"
VERSION="${1:-}"
BUILD_DIR="/tmp/tailscale-proot-build"
OUTPUT_DIR="$SCRIPT_DIR"

# --- Prerequisites ---
check_prereqs() {
    local missing=()
    command -v go  >/dev/null 2>&1 || missing+=(go)
    command -v git >/dev/null 2>&1 || missing+=(git)

    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: missing required tools: ${missing[*]}"
        echo ""
        echo "Install Go (1.26+):"
        echo "  curl -LO https://go.dev/dl/go1.26.1.linux-arm64.tar.gz"
        echo "  rm -rf /usr/local/go && tar -C /usr/local -xzf go1.26.1.linux-arm64.tar.gz"
        echo "  export PATH=/usr/local/go/bin:\$PATH"
        exit 1
    fi

    if [ ! -f "$PATCH_FILE" ]; then
        echo "ERROR: patch file not found: $PATCH_FILE"
        exit 1
    fi

    GO_VER=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+')
    if [ "$(echo "$GO_VER < 1.26" | bc -l 2>/dev/null || echo 1)" = "1" ]; then
        echo "WARNING: Go 1.26+ recommended. You have $(go version)"
    fi
}

# --- Clone ---
clone_source() {
    rm -rf "$BUILD_DIR"
    if [ -n "$VERSION" ]; then
        echo "Cloning tailscale $VERSION..."
        git clone --depth 1 --branch "$VERSION" https://github.com/tailscale/tailscale.git "$BUILD_DIR"
    else
        echo "Cloning tailscale (latest)..."
        git clone --depth 1 https://github.com/tailscale/tailscale.git "$BUILD_DIR"
    fi
}

# --- Patch ---
apply_patch() {
    echo "Applying PRoot-Distro patch..."
    cd "$BUILD_DIR"
    git apply "$PATCH_FILE"
    echo "Patch applied successfully."
}

# --- Build ---
build_binary() {
    echo "Building tailscaled (GOOS=android GOARCH=arm64)..."
    cd "$BUILD_DIR"

    # Match the installed tailscale client's version string to avoid
    # "client version != tailscaled server version" warnings.
    LDFLAGS=""
    if command -v tailscale &>/dev/null; then
        CLIENT_LONG=$(tailscale version 2>/dev/null | grep 'long version:' | awk '{print $3}')
        CLIENT_SHORT=$(tailscale version 2>/dev/null | head -1)
        if [ -n "$CLIENT_LONG" ] && [ -n "$CLIENT_SHORT" ]; then
            echo "Stamping version to match client: $CLIENT_LONG"
            LDFLAGS="-X tailscale.com/version.longStamp=$CLIENT_LONG -X tailscale.com/version.shortStamp=$CLIENT_SHORT"
        fi
    fi

    CGO_ENABLED=0 GOOS=android GOARCH=arm64 go build -ldflags "$LDFLAGS" -o "$OUTPUT_DIR/tailscaled" ./cmd/tailscaled
    echo ""
    echo "Build complete: $OUTPUT_DIR/tailscaled"
    "$OUTPUT_DIR/tailscaled" --version
}

# --- Cleanup ---
cleanup() {
    echo "Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
}

# --- Main ---
check_prereqs
clone_source
apply_patch
build_binary
cleanup

echo ""
echo "Done! Install with:"
echo "  cp $OUTPUT_DIR/tailscaled /usr/sbin/tailscaled"
echo ""
echo "Start with:"
echo "  start-tailscaled &"
