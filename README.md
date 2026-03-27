# tailscaled-proot

Run Tailscale (with SSH server + Taildrop) inside PRoot-Distro on Android without root.

The stock `tailscaled` crashes in PRoot because Android blocks netlink sockets. This project provides patched binaries that work around that, built automatically for every new Tailscale release.

## Prerequisites

- [Termux](https://termux.dev/) with [PRoot-Distro](https://github.com/termux/proot-distro) installed (Debian, Ubuntu, etc.)
- `curl` and `net-tools` inside PRoot (`apt install -y curl net-tools`)
- No root required

## Quick Start

```bash
# Download the installer
curl -fsSL https://raw.githubusercontent.com/jefferyb/tailscaled-proot/main/tailscaled-proot \
  -o /usr/local/bin/tailscaled-proot && chmod +x /usr/local/bin/tailscaled-proot

# Install (downloads both tailscale CLI + patched daemon, sets up auto-start)
tailscaled-proot install
```

Then connect to your network (only needed once):

```bash
# If using Headscale (self-hosted):
tailscale up \
  --login-server https://headscale.example.com:443 \
  --ssh \
  --hostname my-device \
  --authkey "YOUR_AUTHKEY"

# If using official Tailscale:
tailscale up --ssh --hostname my-device
```

That's it. The daemon starts automatically every time you open a PRoot-Distro shell.

## Updating

```bash
tailscaled-proot update
```

Checks GitHub for the latest release, downloads matching binaries, and restarts the daemon. Skips if already up to date.

## Commands

| Command | Description |
|---------|-------------|
| `tailscaled-proot install` | Download and install both binaries, configure auto-start, start daemon |
| `tailscaled-proot update` | Update to the latest version |
| `tailscaled-proot status` | Show versions, daemon status, and check for updates |
| `tailscaled-proot uninstall` | Remove binaries and auto-start (preserves Tailscale state) |
| `tailscaled-proot help` | Show help |

## How It Works

This project distributes patched `tailscaled` binaries that:

1. **Build with `GOOS=android`** -- uses a polling-based network monitor instead of netlink
2. **Fall back to `ifconfig` parsing** -- when Go's `net.Interfaces()` fails (netlink blocked), interface info is read from `ifconfig` output
3. **Enable SSH server on Android** -- removes `!android` build tag restrictions
4. **Enable Taildrop file operations** -- removes the `!android` build tag from filesystem-based file ops

Binaries are built automatically via GitHub Actions whenever Tailscale publishes a new release.

## Transparency and Security

**Everything in this project is open and auditable.** We take this seriously because you're trusting these binaries with your network access.

- **Automated builds only** -- every binary is built by GitHub Actions in a clean CI environment. No binaries are built locally or uploaded manually. You can verify this by checking the [Actions tab](https://github.com/jefferyb/tailscaled-proot/actions).
- **Minimal, readable patch** -- the [patch file](tailscale-proot-distro.patch) is ~280 lines and modifies only 10 files. The changes are limited to (1) an `ifconfig` fallback for network interface detection and (2) removing `!android` build tag exclusions. No new network calls, no telemetry, no additional dependencies.
- **Reproducible builds** -- you can build the exact same binaries yourself with `./build-tailscaled.sh v<VERSION>` and compare them. The build script, patch, and CI workflow are all in this repo.
- **Official Tailscale source** -- we clone directly from [tailscale/tailscale](https://github.com/tailscale/tailscale) at the tagged release. The only modifications are in our patch.
- **No fork** -- this is a patch-based project, not a maintained fork. The patch is small and easy to review against any Tailscale release. We don't carry custom code beyond what's needed to run in PRoot.

## Alternative: dpkg-divert (for existing apt installs)

If you already have the `tailscale` apt package installed and prefer to keep managing the CLI through apt, you can use `dpkg-divert` to protect just the daemon binary:

```bash
# Tell dpkg to never overwrite /usr/sbin/tailscaled
dpkg-divert --add --rename --divert /usr/sbin/tailscaled.stock /usr/sbin/tailscaled

# Download and install just the patched daemon
curl -fsSL https://github.com/jefferyb/tailscaled-proot/releases/latest/download/tailscaled-arm64 \
  -o /usr/sbin/tailscaled && chmod +x /usr/sbin/tailscaled
```

With this approach:
- `apt upgrade` updates the CLI freely but the stock daemon goes to `/usr/sbin/tailscaled.stock`
- Your patched daemon at `/usr/sbin/tailscaled` stays untouched
- **You still need to manually download the matching patched daemon** after each CLI update to avoid version mismatch warnings

To undo:
```bash
rm /usr/sbin/tailscaled
dpkg-divert --remove --rename /usr/sbin/tailscaled
```

## What the Patch Changes

10 files modified across the Tailscale source:

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

## Building from Source

If you prefer to build yourself instead of using the pre-built binaries:

```bash
# Requires Go 1.26+ (check go.mod in tailscale source for exact version)
./build-tailscaled.sh v1.96.2
```

See [AGENTS.md](AGENTS.md) for detailed build and patch regeneration instructions.

## Notes

- **No root required** -- runs entirely in userspace via PRoot-Distro
- `--tun=userspace-networking` is used since PRoot has no kernel TUN access
- UDP buffer size warnings at startup are cosmetic
- Works with both [Tailscale](https://tailscale.com) and [Headscale](https://github.com/juanfont/headscale)

## Background

- [Go issue #40569](https://github.com/golang/go/issues/40569) -- `net.Interfaces()` broken on Android SDK 30+
- [Tailscale PR #15518](https://github.com/tailscale/tailscale/pull/15518) -- Stop trying to use netlink on Android
- [Tailscale issue #9836](https://github.com/tailscale/tailscale/issues/9836) -- Starting tsnet server on Android fails

## License

The Tailscale source code is licensed under [BSD-3-Clause](LICENSE). This project is not affiliated with or endorsed by Tailscale Inc. "Tailscale" is a registered trademark of Tailscale Inc.
