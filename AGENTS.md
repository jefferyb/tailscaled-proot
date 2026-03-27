# Agent Instructions

## What This Repo Is

A patched `tailscaled` daemon that runs inside **PRoot-Distro on Android (Termux)**. The stock Linux binary crashes because Android SDK 30+ blocks netlink sockets. This repo contains the patch, build script, install script, and a pre-built binary.

## Environment

- **Host**: Android device running Termux with PRoot-Distro (Debian/Ubuntu)
- **Architecture**: aarch64 / arm64
- **NOT a normal Linux box**: No real root, no kernel access, no TUN devices, no systemd as PID 1
- **Headscale**: The user runs a self-hosted Headscale control server, not the official Tailscale coordination server

## Critical Knowledge

### Why GOOS=android

The binary MUST be built with `GOOS=android GOARCH=arm64`, even though it runs in a Debian PRoot environment. This is because:
1. `GOOS=android` activates Tailscale's polling-based network monitor (instead of netlink)
2. `GOOS=linux` uses netlink sockets which are blocked by Android's kernel (even inside PRoot)
3. The binary is **not** a standard Android app -- it runs as a CLI daemon in PRoot

### Why the Patch Exists

Even with `GOOS=android`, two problems remain:
1. **Go's `net.Interfaces()` still uses netlink internally** -- the patch adds an `ifconfig`-parsing fallback in `net/netmon/state.go`
2. **Tailscale excludes Android from SSH server and Taildrop** via `!android` build tags -- the patch removes those exclusions

### Version Stamping

The `tailscale` CLI client (installed via apt from Tailscale's official repo) and our custom-built `tailscaled` daemon must report the **same version string**, or every command prints a warning. The build script handles this automatically by reading the installed client's version via `tailscale version` and passing it through `-ldflags`:
```
-X tailscale.com/version.longStamp=<long> -X tailscale.com/version.shortStamp=<short>
```

### Apt Package Hold

The `tailscale` apt package is held (`apt-mark hold tailscale`) to prevent `apt upgrade` from overwriting our patched `/usr/sbin/tailscaled` with the stock Linux binary. Both `install.sh` and `build-tailscaled.sh --upgrade` manage this automatically. If the package is accidentally unheld and upgraded, the stock binary will crash with the netlink error -- just re-run `./install.sh` or `./build-tailscaled.sh --upgrade`.

### Auto-Start

PRoot-Distro does not support systemd. The daemon auto-starts via a snippet in `~/.bashrc` that checks `pgrep -x tailscaled` before launching. PRoot kills background processes when all sessions exit, so it restarts on next login.

## Files

| File | Purpose |
|------|---------|
| `tailscaled` | Pre-built patched binary (aarch64, GOOS=android) |
| `tailscale-proot-distro.patch` | Git patch against tailscale source tree |
| `build-tailscaled.sh` | Clones tailscale, applies patch, builds with version stamps |
| `install.sh` | Installs binary, startup script, systemd unit, bashrc auto-start |
| `README.md` | User-facing documentation |

## Common Tasks

### Upgrade to a New Tailscale Version

**Easiest**: `./build-tailscaled.sh --upgrade` handles everything (unhold, apt upgrade, build, install, re-hold, restart).

**Manual steps** (if --upgrade doesn't work or you need more control):

1. `apt-mark unhold tailscale`
2. `apt update && apt install -y --only-upgrade tailscale`
3. Check the new version: `tailscale version`
4. Rebuild: `./build-tailscaled.sh v<NEW_VERSION>` (e.g., `./build-tailscaled.sh v1.98.0`)
5. If the patch fails to apply, see "Regenerating the Patch" below
6. Install: `cp tailscaled /usr/sbin/tailscaled`
7. Re-hold: `apt-mark hold tailscale`
8. Restart: `pkill tailscaled` -- it auto-restarts on next shell, or run `start-tailscaled &`
9. Verify: `tailscale status` should have no version warning
10. Commit the updated `tailscaled` binary and `tailscale-proot-distro.patch` to this repo

### Regenerating the Patch When It Fails to Apply

The patch targets specific files and context lines. When upstream changes these files (even cosmetically, like copyright headers), `git apply` fails. To fix:

1. Clone the new version: `git clone --depth 1 --branch v<VERSION> https://github.com/tailscale/tailscale.git /tmp/tailscale-proot-build`
2. Make a baseline commit: `cd /tmp/tailscale-proot-build && git add -A && git commit -m "baseline"`
3. Apply the same logical changes manually (see "What the Patch Modifies" below)
4. Generate new patch: `git diff > /path/to/this/repo/tailscale-proot-distro.patch`
5. Build and test

### What the Patch Modifies

All changes follow two patterns:

**Pattern 1 -- ifconfig fallback** (1 file):
- `net/netmon/state.go`: Add `"os/exec"` import. In `netInterfaces()`, change `return nil, err` to `return netInterfacesFallback()`. Add `netInterfacesFallback()` and `parseIfconfigOutput()` functions that parse `ifconfig` output for interface name, flags, MTU, and IP addresses.

**Pattern 2 -- remove `!android` exclusions** (9 files):
- `envknob/featureknob/featureknob.go`: Add `"android"` to the SSH-allowed OS list
- `feature/taildrop/fileops_fs.go`: Change `//go:build !android` to `//go:build !ts_omit_taildrop`
- `ipn/ipnlocal/ssh.go`: Remove `&& !android` from build tag
- `ipn/ipnlocal/ssh_stub.go`: Move `android` from stub-included to stub-excluded
- `ssh/tailssh/tailssh.go`: Remove `&& !android` from build tag
- `ssh/tailssh/user.go`: Remove `&& !android` from build tag
- `ssh/tailssh/incubator.go`: Remove `&& !android` from build tag
- `ssh/tailssh/incubator_linux.go`: Remove `&& !android` from build tag
- `ssh/tailssh/auditd_linux.go`: Remove `&& !android` from build tag

### Fresh Machine Setup

1. Install Termux, then PRoot-Distro (e.g., `proot-distro install debian`)
2. Inside PRoot: `apt update && apt install -y curl gnupg`
3. Add Tailscale apt repo (for the CLI only): follow https://tailscale.com/download/linux
4. `apt install tailscale` -- this gives you the `tailscale` CLI
5. Clone this repo and run `./install.sh`
6. Connect: `tailscale up --login-server https://headscale.jefferyb.dev:443 --ssh --hostname galaxy-tab-s9-termux --authkey "YOUR_KEY"`
7. Exit and re-enter PRoot to verify auto-start works

### Go Version

Tailscale's `go.mod` specifies the minimum Go version. As of v1.96.2, it requires **Go 1.26.1**. Check `go.mod` in the cloned source if the build segfaults -- a segfault during build almost always means the Go toolchain is too old. Install from https://go.dev/dl/.

## Gotchas

- **`--tun=userspace-networking`** is required. PRoot has no access to kernel TUN devices.
- **`--port=41641`** is the default WireGuard port. Don't change unless you have a reason.
- **Segfault during build** = Go version too old. Check `go.mod` in the tailscale source.
- **`net.Interfaces()` errors at runtime** = the ifconfig fallback isn't working. Make sure `ifconfig` is installed (`apt install net-tools`).
- **"SSH server not supported on android"** = the build tag patches weren't applied. Verify `GOOS=android` was used AND the patch was applied before building.
- **Stale socket** (`/var/run/tailscale/tailscaled.sock`): If the daemon crashes, the socket file may remain. The auto-start snippet handles this by removing it before launch.
- **UDP buffer warnings** at daemon startup are cosmetic. They only affect throughput, not functionality.
- **The `tailscale` CLI binary does NOT need patching** -- only `tailscaled` (the daemon) touches netlink.
- **`apt upgrade` will break things** if the package isn't held. Always verify with `apt-mark showhold | grep tailscale`. If it's not held, run `apt-mark hold tailscale`.
- **Binary is ~34MB** and committed to the repo. This is intentional for quick installs without rebuilding.

## Continuous Improvement

After completing a build, upgrade, or troubleshooting task, reflect on the session:

1. **Did a new pattern or workaround work better than what's documented here?** (e.g. a new file needed patching, a different build flag helped, a better fallback approach)
2. **Did something waste time?** (e.g. trying an approach that doesn't work in PRoot, forgetting a gotcha already documented, downloading the wrong Go version)
3. **Did the user correct you or suggest a better approach?**
4. **Did upstream Tailscale change something relevant?** (e.g. new build tags, renamed files, new netlink usage, changed version stamping)

If yes to any of these, **update this AGENTS.md** before ending the session:

- Add the new knowledge to the relevant section (Gotchas, Common Tasks, Critical Knowledge, etc.)
- Remove or revise anything that led to wasted effort
- Keep it concise -- only add what future sessions will actually benefit from
- Don't add one-off debugging details specific to a single session

**Do not ask the user for permission** -- just update this file quietly as part of wrapping up. The user expects this file to get better over time. Commit it alongside any other changes.
