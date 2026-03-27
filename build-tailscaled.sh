#!/bin/bash
# Build tailscaled for PRoot-Distro (Termux) environments.
#
# This patches tailscale to work around Android's netlink socket restrictions
# and builds with GOOS=android so the polling-based network monitor is used
# instead of the netlink-based one.
#
# Usage:
#   ./build-tailscaled.sh [version]      # build only
#   ./build-tailscaled.sh --upgrade      # full upgrade: unhold apt pkg, upgrade CLI, build, install, re-hold
#
# Examples:
#   ./build-tailscaled.sh                # builds latest tagged version
#   ./build-tailscaled.sh v1.96.2        # builds specific version
#   ./build-tailscaled.sh --upgrade      # upgrades everything to latest

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/tailscale-proot-distro.patch"
BUILD_DIR="/tmp/tailscale-proot-build"
OUTPUT_DIR="$SCRIPT_DIR"
UPGRADE_MODE=false
VERSION=""

# --- Parse args ---
if [ "${1:-}" = "--upgrade" ]; then
    UPGRADE_MODE=true
else
    VERSION="${1:-}"
fi

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

# --- Upgrade: unhold, apt upgrade, determine version ---
upgrade_cli() {
    echo "==> Unholding tailscale package..."
    apt-mark unhold tailscale 2>/dev/null || true

    echo "==> Upgrading tailscale CLI via apt..."
    apt update -qq
    apt install -y --only-upgrade tailscale

    # Get the new CLI version to use as the build target
    VERSION="v$(tailscale version 2>/dev/null | head -1)"
    echo "==> CLI upgraded to $VERSION"
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
    if ! git apply "$PATCH_FILE" 2>/dev/null; then
        echo ""
        echo "ERROR: Patch failed to apply cleanly against $VERSION."
        echo "The upstream source has likely changed. The patch needs to be regenerated."
        echo ""
        echo "See AGENTS.md section 'Regenerating the Patch When It Fails to Apply'"
        echo "or manually apply the changes and run:  git diff > $PATCH_FILE"
        exit 1
    fi
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

# --- Install (upgrade mode only) ---
install_binary() {
    echo "==> Installing patched tailscaled to /usr/sbin/tailscaled..."
    cp "$OUTPUT_DIR/tailscaled" /usr/sbin/tailscaled
    chmod +x /usr/sbin/tailscaled
}

# --- Hold package ---
hold_package() {
    echo "==> Holding tailscale package to prevent apt from overwriting our binary..."
    apt-mark hold tailscale
}

# --- Restart daemon ---
restart_daemon() {
    echo "==> Restarting tailscaled..."
    pkill tailscaled 2>/dev/null || true
    sleep 1
    rm -f /var/run/tailscale/tailscaled.sock
    mkdir -p /var/run/tailscale /var/lib/tailscale
    tailscaled \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/var/run/tailscale/tailscaled.sock \
        --tun=userspace-networking \
        --port=41641 &>/dev/null &
    disown $!

    for _ in 1 2 3 4 5; do
        [ -S /var/run/tailscale/tailscaled.sock ] && break
        sleep 1
    done
    echo "==> tailscaled restarted."
}

# --- Cleanup ---
cleanup() {
    echo "Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
}

# --- Main ---
check_prereqs

if [ "$UPGRADE_MODE" = true ]; then
    echo "===== Full Upgrade Mode ====="
    upgrade_cli
    clone_source
    apply_patch
    build_binary
    install_binary
    hold_package
    restart_daemon
    cleanup
    echo ""
    echo "===== Upgrade complete! ====="
    tailscale status 2>&1 | head -1
else
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
fi
