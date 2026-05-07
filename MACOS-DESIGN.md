# AI Fortress — macOS Support Design

**Status:** proposal. Not implemented. The fortress today is Linux-only (host: Fedora; guest: Flatcar; KVM/libvirt; nftables; systemd). This document describes how to port the architecture to macOS (Apple Silicon primary, Intel as bonus) while preserving as many of the five security boundaries as possible.

---

## 1. Goal and scope

Reproduce the five-layer fortress on macOS while preserving the core invariant: **upstream LLM credentials never leave the host, and the agent process never gets a real kernel + real network**.

Primary target: Apple Silicon (M-series) running macOS 14+. Intel Macs are a secondary target — the design works identically on Intel (Flatcar amd64 is more battle-tested than arm64), but VM driver tooling has shifted toward Apple Silicon.

Explicit non-goals:
- Replicating every systemd hardening verb byte-for-byte.
- Avoiding all out-of-tree binaries (a small Swift/Go vsock bridge helper is required because `socat` on macOS does not speak `Virtualization.framework` sockets).
- Shipping a signed Network Extension (deferred — see §6.1 and §7).

---

## 2. Linux primitive → macOS equivalent

| Linux (current) | macOS native | Fidelity |
|---|---|---|
| KVM + libvirt (`virt-install`) | **Virtualization.framework** via Lima or Tart | High |
| Flatcar guest (RO `/usr`) | Same Flatcar/FCOS arm64 image inside the VM | High |
| virtio-fs (`--filesystem driver.type=virtiofs`) | `VZSharedDirectory` (Lima/Tart wrap it) | High |
| AF_VSOCK CID 2:4000 (host) ↔ CID 42 (guest) | `VZVirtioSocketDevice` — UNIX-socket fd per port on host | Medium (requires a small bridge helper, not raw `socat`) |
| `socat VSOCK-LISTEN:4000` on host | Custom Swift/Go helper, or **gvproxy** (used by podman-machine on macOS) | Medium |
| systemd units | `launchd` plists (`LaunchDaemon` under `/Library/LaunchDaemons/`) | High |
| nftables `meta skuid 1500 ... drop` (egress allowlist by UID) | **PF** with `user _bifrost` keyword **+ `sandbox-exec` profile** on the Bifrost process | Medium — see §6.1 |
| `useradd --system --uid 1500 bifrost` | `dscl . -create /Users/_bifrost UniqueID 290` | High |
| Sudoers (`%fortress NOPASSWD: ...`) | Identical (`/etc/sudoers.d/ai-fortress`) | High |
| `runsc` (gVisor) inside VM | Unchanged — runs inside the Linux guest exactly as today | High |
| Docker `--internal sandbox_net` inside VM | Unchanged | High |
| systemd `NoNewPrivileges`, `ProtectSystem=strict`, `CapabilityBoundingSet=` | launchd `Sandbox`, plus wrap `ProgramArguments` in `sandbox-exec -f profile.sb` | Medium |
| systemd timers | launchd `StartInterval` / `StartCalendarInterval` | High |
| `virsh -c qemu:///system domifaddr` | `limactl ls --json` / `limactl shell` | High |

---

## 3. Recommended stack

- **VM driver:** **Lima** (`limactl`). Apple-Silicon-native, uses Virtualization.framework by default, supports virtiofs shares, custom Flatcar images via the `images:` field, and a YAML config that maps cleanly to today's `config.bu` + `do_virt_install.sh`. Tart is the alternative if you prefer Cirrus's CI-oriented model.
- **Container runtime inside the VM:** unchanged — Docker with `runsc` registered in `daemon.json`. The VM is still Linux.
- **Bifrost on host:** **container-less**. Run the Bifrost binary directly as `_bifrost`, started by a `LaunchDaemon`. Running it via Docker on macOS would require Docker Desktop / Colima / OrbStack — all of which add another nested Linux VM and an extra trust tier to no benefit. Pin the binary by SHA256 and verify at install time.
- **Toolscrub:** unchanged — same static Go binary, rebuilt for `darwin/arm64`. Runs as its own `LaunchDaemon`.
- **vsock host-side bridge:** small Go binary (~100 LoC) using `Virtualization.framework`'s vsock listener, or shell-out to `gvproxy`. Replaces `socat VSOCK-LISTEN:4000`.

---

## 4. Per-layer redesign

### Layer 0 — Host process cannot exfil upstream credentials

- Dedicated `_bifrost` UID (e.g. 290; first free under 500 by macOS convention).
- `/etc/ai-fortress/upstream.env` root:wheel 0600 — identical to Linux.
- LaunchDaemon plist runs Bifrost as `_bifrost`, loads env via `EnvironmentVariables`.
- Egress confinement (defense in depth):
  - **`sandbox-exec -f /etc/ai-fortress/bifrost.sb`** wrapping the binary:
    ```scheme
    (version 1)
    (deny default)
    (allow process-fork process-exec)
    (allow file-read*)
    (allow file-write* (subpath "/var/lib/ai-fortress"))
    (allow network-bind (local ip "127.0.0.1:4000"))
    (allow network-outbound (remote tcp "*:443"))
    (allow network-outbound (remote udp "*:53"))
    ```
  - **PF anchor** `ai_fortress`:
    ```
    pass out quick proto tcp from any to any port 443 user _bifrost
    pass out quick proto udp from any to any port 53  user _bifrost
    block out quick from any user _bifrost
    ```
- Either mechanism alone is weaker than nftables-skuid; together they roughly match it.

### Layer 1 — Agent cannot touch the host kernel

- Linux VM via `limactl start fortress.yaml`.
- Lima YAML pins Flatcar arm64 (or amd64 on Intel), declares the projects virtio-fs share, and registers a vsock device bound to port 4000.
- Sketch:
  ```yaml
  vmType: vz
  arch: aarch64
  images:
    - location: "https://stable.release.flatcar-linux.net/.../flatcar_production_qemu_image.img"
      arch: aarch64
  cpus: 4
  memory: 16GiB
  mounts:
    - location: "~/projects"
      mountPoint: "/projects"
      writable: true
  vmOpts:
    vz:
      socketDevices:
        - port: 4000
  ```

### Layer 2 — No malware persistence

- Same Flatcar guest → `/usr` read-only.
- Fallback if Flatcar arm64 proves problematic: Lima default Ubuntu, which weakens this boundary (writable `/usr`). Recommend Flatcar.

### Layer 3 — gVisor

- Identical. Runs in the Linux VM. No macOS-specific changes.

### Layer 4 — Sandbox cannot reach the public internet

- Identical: Docker `--internal sandbox_net` inside the VM, vsock-shim is the only egress, `--add-host authproxy:<ip>` injection by `agent-vm` unchanged.

### Layer 5 — Per-session virtual key

- Identical Bifrost governance config and `fortress-mint` / `fortress-revoke` flow.
- Sweeper runs from a launchd timer (`StartInterval=300`) instead of a systemd timer.
- Sweeper plist sketch:
  ```xml
  <key>Label</key>            <string>com.ai-fortress.key-sweep</string>
  <key>ProgramArguments</key> <array><string>/usr/local/sbin/fortress-sweep</string></array>
  <key>StartInterval</key>    <integer>300</integer>
  <key>UserName</key>         <string>root</string>
  ```

### Toolscrub

- Identical request-side `tools[]` stripping. Built for `darwin/arm64`.
- Runs as a `LaunchDaemon` between the vsock-relay and Bifrost (`127.0.0.1:4001` → `127.0.0.1:4000`).

---

## 5. Network flow on macOS (single inference)

```
sandbox container (runsc, in Lima Linux VM)
  │  ANTHROPIC_BASE_URL=http://authproxy:4000/anthropic
  │  ANTHROPIC_API_KEY=sk-bf-…
  ▼
sandbox_net Docker bridge (--internal, no default route)
  ▼
vsock-shim container (alpine/socat, --device /dev/vsock)
  │  TCP-LISTEN:4000  →  VSOCK-CONNECT:2:4000
  ▼
[Virtualization.framework vsock fabric]
  ▼
host vsock-bridge (small Go/Swift helper, LaunchDaemon)
  │  accepts VZ vsock connection on port 4000
  │  forwards to TCP 127.0.0.1:4001
  ▼
ai-fortress-toolscrub (LaunchDaemon, 127.0.0.1:4001)
  │  strips matching tools[] entries; passthrough otherwise
  ▼
Bifrost binary (LaunchDaemon, runs as _bifrost, sandbox-exec'd)
  │  authenticates VK, swaps for upstream key, forwards
  ▼  TCP 443 — allowed by PF user-rule and sandbox-exec network-outbound
api.anthropic.com
```

The only difference from the Linux flow is the host-side leg between vsock and toolscrub: one custom helper instead of two `socat` invocations chained.

---

## 6. What gets dropped or weakened

### 6.1 Per-UID egress allowlist (medium severity)

Linux today: a single kernel-level `nft skuid 1500 drop` makes it impossible for the Bifrost process to talk to anything except DNS + 443. macOS has no such primitive. PF inherits OpenBSD's `user <uid>` keyword (still works as of macOS 14/15), but Apple has been quietly deprecating PF in favor of Network Extensions, and there is no public commitment that `user` will keep working.

**Mitigation:** layer `sandbox-exec` on top so even if PF's `user` keyword regresses, the network-outbound profile still confines Bifrost. Combined, the two roughly match the Linux guarantee. Long-term, a signed `NEFilterDataProvider` Network Extension would be the "right" answer, but it requires an Apple Developer Program enrollment and notarization — see §7.

### 6.2 launchd hardening verbs are coarser than systemd (low severity)

No exact equivalents of `ProtectSystem=strict`, `MemoryDenyWriteExecute`, `RestrictNamespaces`, `CapabilityBoundingSet=`. Closest substitutes:
- launchd `Sandbox` key.
- Wrap the executable in `sandbox-exec -f profile.sb`.
- Filesystem-level immutability via SIP-protected paths (binaries under `/usr/local/sbin` are still writable by root; SIP doesn't extend there).

### 6.3 No native vsock CLI tool (low severity)

`socat` on macOS doesn't speak Virtualization.framework's vsock fds. We must ship a tiny bridge binary (~100 LoC). Same security guarantee, more code to audit and codesign.

### 6.4 Flatcar arm64 is less battle-tested (low severity)

Mature enough to use as of 2024-2025, but if Flatcar arm64 proves unstable, falling back to a Lima-default Ubuntu image weakens **Layer 2** (writable `/usr`). Flatcar arm64 is the recommended call.

### 6.5 No `virsh snapshot-create-as` (cosmetic)

Lima offers `limactl snapshot` plus you can `cp` the qcow2 from `~/.lima/<name>/`. Functional parity, different command surface.

### 6.6 Codesigning friction (cosmetic, install-time)

The macOS vsock bridge binary and the toolscrub binary should be ad-hoc codesigned (`codesign --sign -`) so Gatekeeper doesn't block them on first launch. Not strictly a drop — install-time work only. A "real" Developer-ID signature is nicer but optional.

### What is **not** dropped

- The upstream-key-never-leaves-host invariant (Layer 0).
- The KVM-class VM boundary (Layer 1) — Virtualization.framework is hardware-virtualized, not paravirtual.
- gVisor (Layer 3).
- The `--internal` bridge (Layer 4).
- Per-session virtual key with budget cap (Layer 5).
- Toolscrub denylist (LLM-as-egress-channel mitigation).

All five boundaries transfer 1:1 in concept. Only **Layer 0's** enforcement mechanism is meaningfully softer.

---

## 7. Open questions before implementation

| Question | Default recommendation |
|---|---|
| VM driver: Lima vs Tart vs raw `vfkit`? | Lima — the conservative pick |
| Bifrost as native binary or Docker container? | Native binary (avoids nested VM via Docker Desktop / Colima) |
| Egress confinement: PF + sandbox-exec, or signed Network Extension? | PF + sandbox-exec for v1; Network Extension as future hardening |
| Intel Mac support in scope? | Yes — same design, Flatcar amd64 is more battle-tested |
| Sweeper cadence on launchd? | `StartInterval=300` (matches the 5-min systemd timer) |

---

## 8. Launcher and installer changes (summary)

- `host/agent`: replace `virsh -c qemu:///system -q domifaddr` with `limactl ls --json fortress | jq -r '.sshAddress'` (or equivalent). SSH-and-SendEnv flow unchanged.
- `vm/agent-vm`: **no change** — runs inside the Linux guest.
- `install-phase1.sh`: split into a sibling `install-phase1-macos.sh` that uses `dscl` / `launchctl` / `pfctl` instead of `useradd` / `systemctl` / `nft`. Keep the Linux script untouched.
- `host/ai-fortress.nft`: parallel `host/ai-fortress.pf.conf` and `host/bifrost.sb` (sandbox-exec profile).
- New `host/vsock-bridge/` source tree for the Go/Swift helper, with a `host/build-vsock-bridge.sh` mirror of `host/build-toolscrub.sh`.
- New `host/launchd/` directory holding the four LaunchDaemon plists (`com.ai-fortress.bifrost`, `com.ai-fortress.toolscrub`, `com.ai-fortress.vsock-bridge`, `com.ai-fortress.key-sweep`).

---

## 9. Verification deltas

The 47-test verify suite (`verify-phase{1,2,3}.sh`) ports almost line-for-line:
- Replace `systemctl is-active` with `launchctl print system/com.ai-fortress.<svc>`.
- Replace `virsh domifaddr` with `limactl ls`.
- Add a Layer-0-equivalent test: confirm Bifrost (running as `_bifrost`) cannot connect to `93.184.216.34:80` (example.com) but can connect to `:443`.
- Drop the `nft list table inet ai_fortress` assertion; replace with `pfctl -a ai_fortress -sr` and a sandbox-exec profile-load check.

In-VM tests (Phase 2 + the sandbox-side parts of Phase 3) are unchanged.
