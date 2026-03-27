#!/bin/bash
# Build a patched tailscaled binary for PRoot-Distro (Termux) environments.
#
# Clones the Tailscale source, applies our patch (ifconfig fallback + SSH/Taildrop
# on Android), and cross-compiles with GOOS=android.
#
# Usage:
#   ./build-tailscaled.sh [options] [version]
#
# Options:
#   --goarch=ARCH   Target architecture: arm64, amd64, arm (default: arm64)
#   --output=DIR    Output directory (default: current directory)
#
# Examples:
#   ./build-tailscaled.sh v1.96.2                    # build arm64 for v1.96.2
#   ./build-tailscaled.sh --goarch=amd64 v1.96.2     # build amd64 for v1.96.2
#   ./build-tailscaled.sh                             # build arm64 from latest tag
#
# Output:
#   tailscaled-<arch>     in the output directory
#
# This project is not affiliated with or endorsed by Tailscale Inc.
# Tailscale source code is licensed under BSD-3-Clause.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/tailscale-proot-distro.patch"
BUILD_DIR="/tmp/tailscale-proot-build"
OUTPUT_DIR="."
GOARCH="arm64"
VERSION=""

# --- Parse args ---
for arg in "$@"; do
    case "$arg" in
        --goarch=*) GOARCH="${arg#--goarch=}" ;;
        --output=*) OUTPUT_DIR="${arg#--output=}" ;;
        -*)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--goarch=ARCH] [--output=DIR] [version]" >&2
            exit 1
            ;;
        *) VERSION="$arg" ;;
    esac
done

# --- Validate ---
case "$GOARCH" in
    arm64|amd64|arm) ;;
    *)
        echo "ERROR: unsupported --goarch=$GOARCH (must be arm64, amd64, or arm)" >&2
        exit 1
        ;;
esac

# --- Prerequisites ---
check_prereqs() {
    local missing=()
    command -v go  >/dev/null 2>&1 || missing+=(go)
    command -v git >/dev/null 2>&1 || missing+=(git)

    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: missing required tools: ${missing[*]}" >&2
        exit 1
    fi

    if [ ! -f "$PATCH_FILE" ]; then
        echo "ERROR: patch file not found: $PATCH_FILE" >&2
        exit 1
    fi
}

# --- Clone ---
clone_source() {
    rm -rf "$BUILD_DIR"
    if [ -n "$VERSION" ]; then
        echo "==> Cloning tailscale $VERSION..."
        git clone --depth 1 --branch "$VERSION" https://github.com/tailscale/tailscale.git "$BUILD_DIR"
    else
        echo "==> Cloning tailscale (latest tag)..."
        git clone --depth 1 https://github.com/tailscale/tailscale.git "$BUILD_DIR"
    fi
}

# --- Patch ---
apply_patch() {
    echo "==> Applying PRoot-Distro patch..."
    cd "$BUILD_DIR"
    if ! git apply "$PATCH_FILE" 2>/dev/null; then
        echo "" >&2
        echo "ERROR: Patch failed to apply cleanly against ${VERSION:-latest}." >&2
        echo "The upstream source has likely changed. The patch needs to be regenerated." >&2
        echo "" >&2
        echo "See AGENTS.md section 'Regenerating the Patch When It Fails to Apply'" >&2
        exit 1
    fi
    echo "    Patch applied successfully."
}

# --- Build ---
build_binary() {
    local ver_short="${VERSION#v}"
    local output_file="$OUTPUT_DIR/tailscaled-$GOARCH"

    echo "==> Building tailscaled (GOOS=android GOARCH=$GOARCH)..."
    cd "$BUILD_DIR"

    # Stamp the version to match the official release so CLI and daemon
    # report identical strings (avoids "client != server version" warnings).
    local ldflags=""
    if [ -n "$VERSION" ]; then
        local tag_commit
        tag_commit=$(git rev-parse --short=10 HEAD 2>/dev/null || echo "unknown")
        ldflags="-X tailscale.com/version.shortStamp=$ver_short"
    fi

    mkdir -p "$OUTPUT_DIR"
    CGO_ENABLED=0 GOOS=android GOARCH="$GOARCH" go build \
        ${ldflags:+-ldflags "$ldflags"} \
        -o "$output_file" \
        ./cmd/tailscaled

    echo ""
    echo "==> Build complete: $output_file"
    if [ "$GOARCH" = "$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" ]; then
        "$output_file" --version
    else
        echo "    (cross-compiled, cannot run --version on this host)"
    fi
}

# --- Cleanup ---
cleanup() {
    echo "==> Cleaning up build directory..."
    rm -rf "$BUILD_DIR"
}

# --- Main ---
check_prereqs
clone_source
apply_patch
build_binary
cleanup

echo ""
echo "Done!"
