# tailscaled on Termux (PRoot-Distro)

Run `tailscaled` inside a PRoot-Distro environment on Android (Termux) with Headscale or Tailscale, including SSH server support.

## The Problem

The standard Linux `tailscaled` binary crashes in PRoot-Distro with:

```
netmon.New: route ip+net: netlinkrib: permission denied
```

Android SDK 30+ blocks `bind()` on `NETLINK_ROUTE` sockets. Go's `net.Interfaces()` depends on netlink, so `tailscaled` (compiled with `GOOS=linux`) fails immediately at startup.

## The Solution

This repo contains a patched build of `tailscaled` that:

1. **Builds with `GOOS=android`** -- uses a polling-based network monitor instead of the netlink-based one
2. **Falls back to `ifconfig` parsing** -- when `net.Interfaces()` fails, interface info is read from `ifconfig` output instead
3. **Enables SSH server on Android** -- removes `!android` build tag restrictions from the SSH server code
4. **Enables Taildrop file operations** -- removes the `!android` build tag from the filesystem-based file ops

## Quick Start

### Option A: Use the Pre-built Binary

```bash
# Install
./install.sh

# Start the daemon
start-tailscaled &

# Connect to your network
tailscale up \
  --login-server https://headscale.example.com:443 \
  --ssh \
  --hostname my-device \
  --authkey "YOUR_AUTHKEY"
```

### Option B: Build from Source

Requires Go 1.25+.

```bash
# Install Go if needed
curl -LO https://go.dev/dl/go1.25.5.linux-arm64.tar.gz
rm -rf /usr/local/go && tar -C /usr/local -xzf go1.25.5.linux-arm64.tar.gz
export PATH=/usr/local/go/bin:$PATH

# Build and install
./install.sh --build

# Start and connect
start-tailscaled &
tailscale up \
  --login-server https://headscale.example.com:443 \
  --ssh \
  --hostname my-device \
  --authkey "YOUR_AUTHKEY"
```

## What's in This Repo

| File | Description |
|------|-------------|
| `tailscaled` | Pre-built binary (aarch64, based on v1.94.2) |
| `tailscale-proot-distro.patch` | Git patch against the tailscale source tree |
| `build-tailscaled.sh` | Build script: clones tailscale, applies patch, compiles |
| `install.sh` | Installs binary, startup script, and systemd unit |

## What the Patch Changes

10 files modified across the tailscale source:

| File | Change |
|------|--------|
| `net/netmon/state.go` | `ifconfig`-based fallback when `net.Interfaces()` fails |
| `envknob/featureknob/featureknob.go` | Allow SSH server on `android` |
| `ipn/ipnlocal/ssh.go` | Include `android` in SSH build tags |
| `ipn/ipnlocal/ssh_stub.go` | Exclude `android` from SSH stub |
| `ssh/tailssh/tailssh.go` | Include `android` in SSH build tags |
| `ssh/tailssh/user.go` | Include `android` in SSH build tags |
| `ssh/tailssh/incubator.go` | Include `android` in SSH build tags |
| `ssh/tailssh/incubator_linux.go` | Include `android` in SSH build tags |
| `ssh/tailssh/auditd_linux.go` | Include `android` in SSH build tags |
| `feature/taildrop/fileops_fs.go` | Use filesystem file ops on `android` |

## Installed Files

After running `install.sh`:

| Path | Description |
|------|-------------|
| `/usr/sbin/tailscaled` | Patched tailscaled binary |
| `/usr/local/bin/start-tailscaled` | Startup script (userspace-networking mode) |
| `/etc/systemd/system/tailscaled-proot.service` | Systemd unit (for environments where systemd is PID 1) |

## Notes

- The `tailscale` CLI binary (client) does **not** need patching -- only `tailscaled` (the daemon) uses netlink
- Install the stock `tailscale` CLI from the [official Tailscale repo](https://tailscale.com/download/linux) as usual
- The "client version != server version" warning is harmless
- UDP buffer size warnings at startup are cosmetic and only affect throughput

## Upgrading

To build against a newer tailscale version:

```bash
./build-tailscaled.sh v1.XX.X
```

The patch may need minor adjustments if upstream changes the patched files significantly.

## Background

- [Go issue #40569](https://github.com/golang/go/issues/40569) -- `net.Interfaces()` broken on Android SDK 30+
- [Tailscale PR #15518](https://github.com/tailscale/tailscale/pull/15518) -- Stop trying to use netlink on android
- [Tailscale issue #9836](https://github.com/tailscale/tailscale/issues/9836) -- Starting tsnet server on Android fails
