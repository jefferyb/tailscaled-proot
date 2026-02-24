#!/bin/bash
# Install pre-built tailscaled for PRoot-Distro (Termux).
#
# Usage:
#   ./install.sh              # install from pre-built binary in this directory
#   ./install.sh --build      # build from source first, then install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Build from source if requested ---
if [ "${1:-}" = "--build" ]; then
    echo "Building from source..."
    "$SCRIPT_DIR/build-tailscaled.sh"
fi

# --- Install binary ---
if [ ! -f "$SCRIPT_DIR/tailscaled" ]; then
    echo "ERROR: tailscaled binary not found in $SCRIPT_DIR"
    echo "Run './install.sh --build' to build from source first."
    exit 1
fi

echo "Installing tailscaled..."
if [ -f /usr/sbin/tailscaled ]; then
    cp /usr/sbin/tailscaled /usr/sbin/tailscaled.bak 2>/dev/null || true
fi
cp "$SCRIPT_DIR/tailscaled" /usr/sbin/tailscaled
chmod +x /usr/sbin/tailscaled

# --- Install startup script ---
echo "Installing start-tailscaled script..."
cat > /usr/local/bin/start-tailscaled << 'STARTUP'
#!/bin/bash
# Start tailscaled for PRoot-Distro (Termux) environment
# Uses userspace networking since TUN devices aren't available in PRoot

TAILSCALED="/usr/sbin/tailscaled"
STATE="/var/lib/tailscale/tailscaled.state"
SOCKET="/var/run/tailscale/tailscaled.sock"
PORT="41641"

mkdir -p /var/run/tailscale /var/lib/tailscale

# Check if already running
if [ -S "$SOCKET" ] && tailscale status &>/dev/null; then
    echo "tailscaled is already running."
    exit 0
fi

# Clean up stale socket
rm -f "$SOCKET"

echo "Starting tailscaled (userspace-networking mode)..."
exec "$TAILSCALED" \
    --state="$STATE" \
    --socket="$SOCKET" \
    --tun=userspace-networking \
    --port="$PORT"
STARTUP
chmod +x /usr/local/bin/start-tailscaled

# --- Install systemd unit (for environments where systemd is PID 1) ---
echo "Installing systemd unit..."
cat > /etc/systemd/system/tailscaled-proot.service << 'UNIT'
[Unit]
Description=Tailscale daemon (PRoot userspace-networking mode)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/start-tailscaled
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# --- Create required directories ---
mkdir -p /var/run/tailscale /var/lib/tailscale

echo ""
echo "Installed:"
echo "  /usr/sbin/tailscaled          (patched binary)"
echo "  /usr/local/bin/start-tailscaled (startup script)"
echo "  /etc/systemd/system/tailscaled-proot.service"
echo ""
echo "Quick start:"
echo "  start-tailscaled &"
echo "  tailscale up --login-server https://YOUR_HEADSCALE:443 --ssh --hostname YOUR_HOST --authkey YOUR_KEY"
echo ""
tailscaled --version
