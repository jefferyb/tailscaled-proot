# Agent Instructions

## What This Repo Is

A patched `tailscaled` daemon that runs inside **PRoot-Distro on Android (Termux)** without root. The stock Linux binary crashes because Android SDK 30+ blocks netlink sockets. This repo contains:
- The patch and build scripts to produce patched binaries
- A user-facing CLI tool (`tailscaled-proot`) for install/update/uninstall
- GitHub Actions CI that automatically builds for every new Tailscale release

**Public repo**: https://github.com/jefferyb/tailscaled-proot

## Environment

- **Host**: Android device running Termux with PRoot-Distro (Debian/Ubuntu)
- **Architecture**: primarily aarch64/arm64 (also supports amd64, arm)
- **NOT a normal Linux box**: No real root, no kernel access, no TUN devices, no systemd as PID 1
- **Headscale**: The maintainer runs a self-hosted Headscale control server, but the project works with official Tailscale too

## Architecture

### For End Users

Users interact only with the `tailscaled-proot` script:
- `tailscaled-proot install` -- downloads pre-built binaries from GitHub Releases, sets up auto-start
- `tailscaled-proot update` -- checks for new version, downloads, replaces, restarts
- `tailscaled-proot status` -- shows versions, daemon status, checks for updates
- `tailscaled-proot uninstall` -- removes binaries and auto-start

The script downloads **both** `tailscale` (CLI, unmodified) and `tailscaled` (daemon, patched) from our GitHub Releases. No apt package is used -- this avoids the problem of `apt upgrade` overwriting the patched binary.

### For CI / Releases

GitHub Actions watches for new Tailscale releases and:
1. Clones the Tailscale source at that tag
2. Applies our patch
3. Builds `tailscaled` with `GOOS=android` and version-matched ldflags
4. Downloads the matching official `tailscale` CLI from Tailscale's static releases
5. Creates a GitHub Release with all binaries attached
6. If the patch fails to apply, opens an issue

### For Manual/Local Builds

`build-tailscaled.sh` is still available for building locally or debugging patch issues.

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

The `tailscale` CLI and our custom-built `tailscaled` must report the **same version string**, or every command prints a warning. The build uses `-ldflags` to stamp the version:
```
-X tailscale.com/version.longStamp=<long> -X tailscale.com/version.shortStamp=<short>
```
Since we distribute both binaries from the same Tailscale release tag, they always match.

### No Apt Package

We deliberately **do not use** the official `tailscale` apt package. Our `install` command provides both binaries. This avoids `apt upgrade` overwriting the patched daemon. The `tailscaled-proot` script removes the apt package if it finds one during install.

### Auto-Start

PRoot-Distro does not support systemd. The daemon auto-starts via a snippet in `~/.bashrc` that checks `pgrep -x tailscaled` before launching. PRoot kills background processes when all sessions exit, so it restarts on next login.

## Files

| File | Purpose |
|------|---------|
| `tailscaled-proot` | User-facing CLI tool (install/update/status/uninstall) |
| `test-tailscaled-proot.sh` | Regression test suite (72 tests) -- **run before every push** |
| `tailscale-proot-distro.patch` | Git patch against tailscale source tree |
| `build-tailscaled.sh` | Build script for local/CI builds (supports `--goarch` for multi-arch) |
| `README.md` | User-facing documentation |
| `AGENTS.md` | This file -- agent instructions and institutional knowledge |
| `LICENSE` | Tailscale's BSD-3-Clause license (required for redistribution) |
| `.gitignore` | Ignores built binaries (they go in GitHub Releases, not the repo) |
| `.github/workflows/` | CI workflows for automated builds |

**Note:** Binaries are NOT committed to the repo. They are distributed via GitHub Releases.

## Testing & Development Practices

### Mandatory: Run Tests Before Every Push

**Never push without running the test suite first.** After any change to `tailscaled-proot`, run:

```bash
bash test-tailscaled-proot.sh
```

All 72+ tests must pass before committing. If any fail, fix the issue before pushing. The test script covers help/version, status, install, update, uninstall, idempotency, error handling, binary paths, `.bashrc` integrity, and network connectivity.

**WARNING:** The test suite does NOT run `--purge`. It cycles through uninstall/install but preserves Tailscale state so it won't break the Headscale registration.

### TDD: Write Tests First

Follow **Test-Driven Development** -- when adding a new feature or fixing a bug:

1. **Write the test first** in `test-tailscaled-proot.sh` that describes the expected behavior
2. **Run the test** and confirm it fails (proving the feature is missing or the bug exists)
3. **Implement the change** in `tailscaled-proot`
4. **Run the full test suite** and confirm everything passes (new test + all existing tests)
5. **Commit together** -- the test and the implementation go in the same commit

This ensures every feature has test coverage and no change accidentally breaks existing functionality.

### DRY: Don't Repeat Yourself

- **In `tailscaled-proot`**: Extract shared logic into helper functions. Don't duplicate code between `cmd_install` and `cmd_update` -- use shared helpers like `fetch_release()`, `download()`, `verify_checksums()`, `ensure_daemon_running()`, etc.
- **In `test-tailscaled-proot.sh`**: Use the `run` / `check_exit` / `check_contains` / `check` helper functions. Don't write raw bash conditionals for assertions.
- **Between files**: If the same constant or pattern appears in multiple places, make sure changing it in one place doesn't silently break another. For example, install paths (`/usr/bin`, `/usr/sbin`) should come from variables, not hardcoded strings scattered throughout.

### Adding Tests for New Features

When adding a new command, option, or behavior to `tailscaled-proot`:

1. Add a new section in `test-tailscaled-proot.sh` (follow the existing numbered section pattern)
2. Test both the **happy path** (it works) and **error path** (bad input, missing prereqs)
3. Test **idempotency** -- running the command twice should produce the same result
4. Update the test count in this file if it changes significantly

## Common Tasks

### Adding Support for a New Tailscale Release (when CI handles it)

If CI is set up, this happens automatically. If the patch fails, CI opens an issue. Then:
1. Clone the new version and manually apply the same logical changes
2. Generate a new patch: `git diff > tailscale-proot-distro.patch`
3. Commit and push -- CI will retry

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

### Fresh Machine Setup (for maintainer)

1. Install Termux, then PRoot-Distro (e.g., `proot-distro install debian`)
2. Inside PRoot: `apt update && apt install -y curl`
3. Run: `curl -fsSL https://raw.githubusercontent.com/jefferyb/tailscaled-proot/main/tailscaled-proot -o /usr/local/bin/tailscaled-proot && chmod +x /usr/local/bin/tailscaled-proot`
4. Run: `tailscaled-proot install`
5. Connect: `tailscale up --login-server https://headscale.jefferyb.dev:443 --ssh --hostname galaxy-tab-s9-termux --authkey "YOUR_KEY"`
6. Exit and re-enter PRoot to verify auto-start works

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
- **The `tailscale` CLI binary does NOT need patching** -- only `tailscaled` (the daemon) touches netlink. But we distribute both to keep versions matched.
- **`apt upgrade` will break things** if the user installed the official `tailscale` apt package. The `tailscaled-proot install` command removes it and provides both binaries itself.
- **Cross-compilation works fine** since `CGO_ENABLED=0`. CI can build arm64 binaries on x86_64 runners.

## Similar Projects

- [anasfanani/tailscale-android-cli](https://github.com/anasfanani/tailscale-android-cli) -- Full fork approach, SSH enabled, but tends to fall behind upstream
- [spotsnel/tailscaled-android](https://github.com/spotsnel/tailscaled-android) -- Uses `wlynxg/anet` library, appears stale
- [Termux root-packages/tailscale](https://github.com/termux/termux-packages/pull/22980) -- Official Termux package, requires root

Our approach (patch-based, not a full fork) is designed to be easier to keep current with upstream.

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

### Before Every Commit

1. **Run the test suite**: `bash test-tailscaled-proot.sh` -- all tests must pass
2. **Add tests for new behavior**: If you changed `tailscaled-proot`, add or update tests
3. **Update this file**: If you learned something new, add it here
4. **Push to both remotes**: `git push origin main && git push github main`

**Do not ask the user for permission** -- just update this file quietly as part of wrapping up. The user expects this file to get better over time. Commit it alongside any other changes.
