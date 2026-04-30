# AI Fortress: vsock Auth-Proxy Extension — Detailed Design (v2)

> **Historical design document.** Superseded by `ARCHITECTURE.md` (the as-built
> source of truth). The implementation diverged from this plan in several
> ways (notably: LiteLLM was replaced by Bifrost; SELinux/seccomp/runsc-DNS
> issues required workarounds). See the "Implementation deltas" section in
> `ARCHITECTURE.md` for the full list. Retained for design history.

This is a revision of `network-plan.md` (v1). The high-level architecture is unchanged: a host-side LiteLLM proxy mints short-lived virtual keys, and sandboxes reach it only over `AF_VSOCK`. v2 fixes correctness gaps in v1 (notably the nftables policy and cgroup match), shrinks the master-key blast radius, and promotes a few "future work" items to v1 because they are load-bearing for the security argument.

## Changes from v1

1. **nftables now default-drops** for the relevant traffic and matches LiteLLM by **UID**, not cgroup. The cgroup approach in v1 didn't actually match the LiteLLM container's traffic because docker places container processes outside the unit's cgroup tree.
2. **Forward-chain behavior is now explicitly described.** v1's threat-model row claimed virbr0 forward traffic was dropped; v2 either drops it (strict mode) or admits it is allowed (relaxed mode), and explains the tradeoff. The default is *relaxed* — VM has internet egress for ops, sandboxes do not — because the design protects keys, not connectivity.
3. **Master key never enters a user-shell process.** Minting and revoking are done by `sudo`-invoked helper scripts owned by root. The user shell only ever sees the resulting virtual key.
4. **Orphan-key sweep is in v1.** A systemd timer reaps virtual keys whose owning launcher PID is gone, closing the `kill -9` gap.
5. **Image digests are pinned**, not just tags. Both LiteLLM and the socat shim are addressed by `@sha256:...`.
6. **VM IP discovery is retried** with backoff and falls back to the qemu-guest-agent so cold-start races don't fail the launcher.
7. **One canonical install path for the vsock device** (libvirt-native XML). v1's two-options framing is replaced with one path plus a documented manual fallback.
8. **Verification plan calls out the LiteLLM Anthropic-compat endpoint explicitly** and adds a socat-version check.
9. **Logging is consistent** across both socat hops (`-ly` everywhere; no debug spam in steady state).
10. **`--security-opt label=disable` is acknowledged** as an intentional carry-over from `agent-up`, out of scope for this round.

## Goals (unchanged from v1)

1. No upstream API credentials inside the VM, ever.
2. No sandbox-initiated network egress except via the proxy.
3. Per-sandbox virtual keys with capped budgets and TTLs.
4. No new TCP listeners on the host's IP network.

## Non-goals (unchanged)

- Defending against host compromise.
- Multi-tenant fortress.
- Offline operation.
- Per-IP rate limiting at the proxy.

## Architecture

```
┌──────────── Host (workstation, Fedora) ───────────┐
│                                                   │
│  /etc/ai-fortress/upstream.env  (root:root 0600)  │
│      ANTHROPIC_UPSTREAM_KEY                       │
│      OPENAI_UPSTREAM_KEY                          │
│      LITELLM_MASTER_KEY                           │
│                                                   │
│  systemd: ai-fortress-litellm.service             │
│      └─ docker run --network host                 │
│         --user 1500:1500  litellm@sha256:...      │
│         listening on 127.0.0.1:4000               │
│                                                   │
│  systemd: ai-fortress-vsock-relay.service         │
│      └─ socat VSOCK-LISTEN:4000,fork              │
│              TCP:127.0.0.1:4000                   │
│                                                   │
│  systemd: ai-fortress-key-sweep.timer             │
│      └─ reaps virtual keys with dead launchers    │
│                                                   │
│  /usr/local/sbin/fortress-mint    (root:fortress) │
│  /usr/local/sbin/fortress-revoke  (root:fortress) │
│      sudoers: NOPASSWD for %fortress              │
│                                                   │
│  nftables: skuid 1500 → 443 only;                 │
│            virbr0 forward → relaxed (default)     │
│                                                   │
│  ~/bin/agent       (the new launcher)             │
│                                                   │
│  ────────── KVM boundary (Level 1) ───────────    │
│  ▲                                                │
│  │ AF_VSOCK (CID 2 ↔ guest CID, port 4000)        │
│  ▼                                                │
│  ┌────── Flatcar VM ──────────────────────────┐   │
│  │                                            │   │
│  │  systemd: vsock-shim.service               │   │
│  │      └─ docker run --device /dev/vsock     │   │
│  │         --network sandbox_net  socat       │   │
│  │         TCP-LISTEN:4000,fork               │   │
│  │         VSOCK-CONNECT:2:4000               │   │
│  │      (DNS name: "authproxy" on bridge)     │   │
│  │                                            │   │
│  │  Docker network: sandbox_net  --internal   │   │
│  │      ├─ vsock-shim                         │   │
│  │      ├─ agent-foo  (runtime=runsc)         │   │
│  │      └─ agent-bar  (runtime=runsc)         │   │
│  │                                            │   │
│  │  Sandboxes have NO route off the VM        │   │
│  │  except authproxy:4000.                    │   │
│  └────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────┘
```

The data path (one Anthropic completion request) is unchanged from v1: SDK → in-VM shim → vsock → host relay → LiteLLM → upstream. Streaming is byte-transparent at every hop.

## Trust tiers (unchanged)

| Tier | Component                   | Runtime              | Trusted with                                                  |
|------|-----------------------------|----------------------|---------------------------------------------------------------|
| 0    | Host Fedora                 | bare metal           | ANTHROPIC_UPSTREAM_KEY, LITELLM_MASTER_KEY, sandbox lifecycle |
| 1    | LiteLLM container on host   | Docker (runc)        | upstream keys, virtual-key DB, internet egress (skuid 1500)   |
| 2    | Flatcar VM kernel/userspace | KVM                  | vsock shim, Docker daemon, sandbox lifecycle on VM            |
| 3    | vsock-shim container        | Docker (runc) on VM  | /dev/vsock access, sandbox_net membership                     |
| 4    | sandbox container           | Docker (runsc) on VM | one short-lived virtual key, project files only               |

The master key is now also a tier-0 secret strictly: it never crosses into a user-shell process. See the `fortress-mint`/`fortress-revoke` helpers below.

## Component-by-component design

### Host: secrets

One file. v1's `master-key.env` duplicate is gone — the master key only ever lives in `upstream.env`, which is root-only.

`/etc/ai-fortress/upstream.env` — read by the LiteLLM daemon and by the root-owned mint/revoke helpers. Mode `0600`, owned by `root:root`.

```
ANTHROPIC_UPSTREAM_KEY=sk-ant-...
OPENAI_UPSTREAM_KEY=sk-...
LITELLM_MASTER_KEY=sk-master-<32 random bytes, base64>
```

Generate the master key once: `openssl rand -base64 32`.

The `fortress` group is still created (`sudo groupadd -r fortress && sudo usermod -aG fortress $USER`), but it now gates `sudo` access to the helper binaries — not access to a key file.

### Host: dedicated UID for LiteLLM

Allocate a system UID for the LiteLLM container. This is the lever that makes the nftables rule actually match.

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --uid 1500 litellm
```

UID 1500 is arbitrary; pick anything not in use. The number must match the `--user` flag in the systemd unit and the `skuid` match in nftables.

Why a system user instead of cgroup matching: with `--network host`, the LiteLLM container's outbound packets originate in the host's root netns from the container's process. Docker places that process in `system.slice/docker-<container-id>.scope`, **not** in the systemd unit's slice — so v1's `meta cgroup "system.slice/ai-fortress-litellm.service"` would not match. Matching `skuid 1500` is robust, simple, and survives container ID changes.

### Host: LiteLLM proxy

`/etc/ai-fortress/litellm-config.yaml` is unchanged from v1.

`/etc/systemd/system/ai-fortress-litellm.service`:

```ini
[Unit]
Description=AI Fortress LiteLLM proxy
After=docker.service network-online.target
Requires=docker.service

[Service]
Restart=always
RestartSec=5
EnvironmentFile=/etc/ai-fortress/upstream.env
ExecStartPre=-/usr/bin/docker rm -f ai-fortress-litellm
ExecStartPre=/usr/bin/install -d -m 0750 -o 1500 -g 1500 /var/lib/ai-fortress
ExecStart=/usr/bin/docker run --rm --name ai-fortress-litellm \
  --network host \
  --user 1500:1500 \
  -v /etc/ai-fortress/litellm-config.yaml:/app/config.yaml:ro \
  -v /var/lib/ai-fortress:/var/lib/ai-fortress \
  -e ANTHROPIC_UPSTREAM_KEY \
  -e OPENAI_UPSTREAM_KEY \
  -e LITELLM_MASTER_KEY \
  ghcr.io/berriai/litellm@sha256:<DIGEST> \
  --config /app/config.yaml --host 127.0.0.1 --port 4000
ExecStop=/usr/bin/docker stop ai-fortress-litellm

[Install]
WantedBy=multi-user.target
```

Three changes from v1:

- `--user 1500:1500` so the container's processes run as UID 1500 on the host (docker default has no userns remap, so host UID == container UID). This is what nftables matches.
- `install -d ... -o 1500 -g 1500` so the SQLite DB directory is writable by UID 1500.
- Image is pinned by digest. Resolve once: `docker pull ghcr.io/berriai/litellm:main-stable && docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/berriai/litellm:main-stable` and paste the `@sha256:...` portion into the unit. Re-pin deliberately when you want to update.

### Host: vsock relay

`/etc/systemd/system/ai-fortress-vsock-relay.service`:

```ini
[Unit]
Description=AI Fortress vsock-to-LiteLLM relay
After=ai-fortress-litellm.service
Requires=ai-fortress-litellm.service

[Service]
Restart=always
RestartSec=2
ExecStart=/usr/bin/socat -ly \
  VSOCK-LISTEN:4000,reuseaddr,fork \
  TCP:127.0.0.1:4000,nodelay
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
```

Unchanged from v1 except for explicit confirmation that `-ly` is also used here (matching the in-VM shim — see below). Requires socat ≥ 1.7.4. Verify in bootstrap: `socat -V | head -1`.

### Host: nftables egress allowlist (rewritten)

This is the section that changed most. v1's chain had `policy accept` and only conditionally dropped, which was the opposite of what the threat-model row claimed.

`/etc/nftables.d/ai-fortress.nft`:

```
table inet ai_fortress {
    # Trusted UID (the litellm system user created above).
    # Keep this in sync with the --user flag on the LiteLLM unit.
    define litellm_uid = 1500

    chain output {
        type filter hook output priority 0; policy accept;

        # LiteLLM is allowed to do DNS and HTTPS. Everything originating from
        # this UID that isn't 53/udp or 443/tcp is dropped — note the *drop*
        # at the end of this UID's stanza, not at the end of the chain.
        meta skuid $litellm_uid udp dport 53 accept
        meta skuid $litellm_uid tcp dport 443 accept
        meta skuid $litellm_uid drop

        # All other host traffic is unaffected (default accept).
    }

    chain forward {
        type filter hook forward priority 0; policy accept;

        # See "Forward-chain policy" below for strict-mode alternative.
        # Default (relaxed) mode: VM userspace keeps internet access for
        # image pulls and OS updates. Sandbox isolation is enforced inside
        # the VM via Docker's --internal network, not at this hook.
    }
}
```

Two notes:

1. **SNI filtering is still future work.** The current rule lets UID 1500 reach any HTTPS host. A compromised LiteLLM image could in principle reach an attacker's endpoint. Tightening this requires a userspace SNI filter (mitmproxy / sslh / squid) or a per-process netns. Tracked in Open Questions.
2. **Why not lock down with a destination IP set?** `api.anthropic.com` is CDN-fronted and rotates IPs frequently; an IP allowlist would either let-through too much (a whole CDN block) or break randomly. UID + dport is the v1-shippable answer.

#### Forward-chain policy

The threat-model row in v1 ("VM userspace → host via libvirt NAT") claimed forward traffic was dropped. That's not true with the rule above, and dropping it would break the VM's own ability to pull images and update.

Two modes are supported, pick one:

**Relaxed (default):** Forward chain `policy accept`. The VM has internet egress. This is fine because:
- Sandbox traffic cannot reach `virbr0` (sandbox_net is `--internal`).
- VM userspace compromise (tier 2) gets internet, but no upstream keys live in the VM, so internet access is not a key-exfiltration channel. The attacker can call any API with their own credentials — but cannot call ours, because they don't have ours.

**Strict (optional):** If you want the VM offline except for vsock, add to the forward chain:

```
iifname "virbr0" oifname != "virbr0" drop
```

This breaks `docker pull` and `dnf update` from inside the VM. Use `burn_it_down.sh` + re-provision for image refreshes; tolerate ostree updates being applied at host-controlled moments. Not recommended for v1 unless you've already automated image refresh outside the VM.

The threat-model table below reflects relaxed mode.

### Host: virtual-key minting helpers

The biggest correctness change in v2: the master key never enters a user-shell process. Instead, two root-owned helpers wrap LiteLLM's `/key/generate` and `/key/delete`.

`/usr/local/sbin/fortress-mint` (mode `0750`, owner `root:fortress`):

```bash
#!/bin/bash
set -euo pipefail
umask 077

# Args: <project> <launcher_pid> <launcher_pid_start_ns>
PROJECT="${1:?missing project}"
LPID="${2:?missing pid}"
LSTART="${3:?missing pid_start_ns}"

# Validate inputs strictly — these become metadata that's later used by the sweeper.
[[ "$PROJECT" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad project name" >&2; exit 2; }
[[ "$LPID" =~ ^[0-9]+$ ]]              || { echo "bad pid" >&2; exit 2; }
[[ "$LSTART" =~ ^[0-9]+$ ]]            || { echo "bad pid_start_ns" >&2; exit 2; }

# The invoking user's name comes from sudo, not the user-controlled environment.
HOST_USER="${SUDO_USER:-unknown}"

# Read master key (this script runs as root via sudo).
source /etc/ai-fortress/upstream.env

BODY=$(jq -n \
  --arg project    "$PROJECT" \
  --arg user       "$HOST_USER" \
  --arg lpid       "$LPID" \
  --arg lstart     "$LSTART" \
  '{models:["claude-*","gpt-*"],
    max_budget:5.0,
    duration:"8h",
    rpm_limit:60,
    metadata:{project:$project, host_user:$user,
              launcher_pid:$lpid, launcher_pid_start_ns:$lstart}}')

RESP=$(curl -fsS --max-time 5 \
    -X POST http://127.0.0.1:4000/key/generate \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$BODY")

KEY=$(jq -r .key <<<"$RESP")
[[ -z "$KEY" || "$KEY" == "null" ]] && { echo "mint failed: $RESP" >&2; exit 1; }

# Print *only* the virtual key on stdout. Caller captures it.
printf '%s\n' "$KEY"
```

`/usr/local/sbin/fortress-revoke` (mode `0750`, owner `root:fortress`):

```bash
#!/bin/bash
set -euo pipefail
KEY="${1:?missing key}"
source /etc/ai-fortress/upstream.env
curl -fsS --max-time 5 -X POST http://127.0.0.1:4000/key/delete \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg k "$KEY" '{keys:[$k]}')" >/dev/null
```

`/etc/sudoers.d/ai-fortress` (validate with `visudo -c -f`):

```
%fortress ALL=(root) NOPASSWD: /usr/local/sbin/fortress-mint, /usr/local/sbin/fortress-revoke
```

The `agent` launcher uses these instead of sourcing `master-key.env`:

```bash
#!/bin/bash
set -euo pipefail

PROJECT_NAME="${1:-}"
TYPE="${2:-default}"
[[ -z "$PROJECT_NAME" ]] && { echo "usage: agent <project> [python|default]" >&2; exit 1; }

VM_NAME="${FORTRESS_VM_NAME:-ai-fortress}"
VM_USER="${FORTRESS_VM_USER:-$USER}"

# Resolve the VM IP with retries — handles cold-start races where libvirt's
# DHCP lease table hasn't populated yet.
resolve_vm_ip() {
  local tries=0
  while (( tries < 20 )); do
    local ip
    ip=$(virsh -c qemu:///system -q domifaddr --source agent "$VM_NAME" 2>/dev/null \
         | awk '/ipv4/ {sub(/\/.*/,"",$NF); print $NF; exit}') || true
    if [[ -z "$ip" ]]; then
      ip=$(virsh -c qemu:///system -q domifaddr "$VM_NAME" 2>/dev/null \
           | awk '/ipv4/ {sub(/\/.*/,"",$NF); print $NF; exit}') || true
    fi
    if [[ -n "$ip" ]]; then printf '%s' "$ip"; return 0; fi
    sleep 1
    tries=$((tries+1))
  done
  return 1
}

VM_IP=$(resolve_vm_ip) || { echo "could not resolve $VM_NAME IP after 20s" >&2; exit 1; }

# Capture launcher identity for the sweeper. Shell PID + start-time-in-ns is
# unique-enough on this host: even with PID reuse after a reboot, start-ns
# resets, so a stale entry won't collide with a fresh launcher.
LPID=$$
LSTART=$(awk '{print $22}' /proc/$$/stat)

VIRTUAL_KEY=$(sudo -n /usr/local/sbin/fortress-mint "$PROJECT_NAME" "$LPID" "$LSTART")

cleanup() {
  sudo -n /usr/local/sbin/fortress-revoke "$VIRTUAL_KEY" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh -t \
    -o SendEnv=VIRTUAL_KEY \
    -o ServerAliveInterval=30 \
    "$VM_USER@$VM_IP" \
    VIRTUAL_KEY="$VIRTUAL_KEY" /usr/local/bin/agent-vm "$PROJECT_NAME" "$TYPE"
```

Properties:

- The user-shell process never sees the master key.
- The mint helper validates inputs (regex on `PROJECT`, numerics on PID/start-ns) so a malicious `$1` can't smuggle JSON or shell metacharacters into the request body.
- `--source agent` on `virsh domifaddr` queries the qemu-guest-agent first (faster, works before DHCP lease lands); falls back to the lease table if the agent isn't running.
- Retry loop covers the cold-start race.

### Host: orphan-key sweeper

A small systemd timer reaps virtual keys whose launcher PID no longer exists.

`/usr/local/sbin/fortress-sweep` (mode `0750`, owner `root:root`):

```bash
#!/bin/bash
set -euo pipefail
source /etc/ai-fortress/upstream.env

# List all keys with their metadata.
KEYS=$(curl -fsS --max-time 10 \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    "http://127.0.0.1:4000/key/info?return_full_object=true" || true)

[[ -z "$KEYS" ]] && exit 0

jq -c '.keys[]? | select(.metadata.launcher_pid != null)' <<<"$KEYS" \
| while read -r key; do
    KEY_TOKEN=$(jq -r .token   <<<"$key")
    LPID=$(jq -r '.metadata.launcher_pid' <<<"$key")
    LSTART=$(jq -r '.metadata.launcher_pid_start_ns' <<<"$key")

    # If the PID exists AND its start-time matches, the launcher is still alive.
    if [[ -r "/proc/$LPID/stat" ]]; then
      CUR_START=$(awk '{print $22}' "/proc/$LPID/stat" 2>/dev/null || echo 0)
      [[ "$CUR_START" == "$LSTART" ]] && continue
    fi

    # Launcher is gone — revoke.
    /usr/local/sbin/fortress-revoke "$KEY_TOKEN" || true
  done
```

`/etc/systemd/system/ai-fortress-key-sweep.service`:

```ini
[Unit]
Description=AI Fortress orphan virtual-key sweep
After=ai-fortress-litellm.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fortress-sweep
```

`/etc/systemd/system/ai-fortress-key-sweep.timer`:

```ini
[Unit]
Description=Run AI Fortress key sweep every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

5-minute granularity is the right tradeoff: tighter than the 8h TTL by orders of magnitude, loose enough not to thrash the LiteLLM DB.

### Guest: vsock kernel modules and sshd config

Unchanged from v1. Add to `config.bu`:

```yaml
storage:
  files:
    - path: /etc/modules-load.d/vsock.conf
      mode: 0644
      contents:
        inline: |
          vsock
          vmw_vsock_virtio_transport

    - path: /etc/ssh/sshd_config.d/10-ai-fortress.conf
      mode: 0644
      contents:
        inline: |
          AcceptEnv VIRTUAL_KEY
```

### Guest: libvirt domain — adding the vsock device (one canonical path)

v1 offered two options; v2 picks one. Edit the running domain:

```
virsh -c qemu:///system edit ai-fortress
```

Add under `<devices>`:

```xml
<vsock model='virtio'>
  <cid auto='no' address='42'/>
</vsock>
```

CID 42 is arbitrary — any integer ≥ 3 unique on this host. Stop and start the domain (`virsh shutdown ai-fortress && virsh start ai-fortress`); a live edit isn't enough because vsock is hot-plug-sensitive on some libvirt builds.

For a fresh provision via `do_virt_install.sh`, replace the relevant block with:

```bash
virt-install \
  --connect qemu:///system \
  ...existing flags... \
  --vsock cid.address=42,model=virtio \
  ...
```

`--vsock` is the libvirt-native flag (not `--qemu-commandline`), which generates the same XML and avoids libvirt's "tainted by custom qemu args" warning.

### Guest: in-VM vsock shim

`/etc/systemd/system/vsock-shim.service` (rendered from `config.bu`):

```ini
[Unit]
Description=AI Fortress vsock shim (TCP -> vsock)
After=docker.service projects.mount
Requires=docker.service

[Service]
Restart=always
RestartSec=5
ExecStartPre=-/usr/bin/docker rm -f vsock-shim
ExecStartPre=/bin/sh -c '/usr/bin/docker network inspect sandbox_net >/dev/null 2>&1 || \
  /usr/bin/docker network create --driver bridge --internal sandbox_net'
ExecStart=/usr/bin/docker run --rm --name vsock-shim \
  --network sandbox_net \
  --network-alias authproxy \
  --device /dev/vsock \
  alpine/socat@sha256:<DIGEST> \
  -ly \
  TCP-LISTEN:4000,reuseaddr,fork,nodelay \
  VSOCK-CONNECT:2:4000
ExecStop=/usr/bin/docker stop vsock-shim

[Install]
WantedBy=multi-user.target
```

Changes from v1:

- `-d` replaced with `-ly` — matches the host relay, no debug spam in steady state.
- `alpine/socat` pinned by digest. Resolve once: `docker pull alpine/socat && docker inspect --format='{{index .RepoDigests 0}}' alpine/socat`.
- The `ExecStartPre` for network creation is wrapped in `/bin/sh -c` because the v1 form (`||` between two `ExecStartPre` lines) doesn't compose the way the prose suggested.

### Guest: agent-vm script

Unchanged from v1 in essentials. Carrying over the `--security-opt label=disable` from the existing `agent-up`; tightening the SELinux story is out of scope for this round but worth a follow-up.

```bash
#!/bin/bash
set -euo pipefail

PROJECT_NAME="$1"
TYPE="${2:-default}"
PROJECT_PATH="/projects/$PROJECT_NAME"

[[ -z "${VIRTUAL_KEY:-}" ]] && { echo "VIRTUAL_KEY env not set" >&2; exit 1; }

case "$TYPE" in
  python) IMAGE="ai-fortress/python-dev:latest" ;;
  *)      IMAGE="ghcr.io/anomalyco/opencode:latest" ;;
esac

USER_FLAGS="--user $(id -u):$(id -g)"

exec docker run -it --rm \
  $USER_FLAGS \
  --name "agent-$PROJECT_NAME-$(date +%s)" \
  --runtime=runsc \
  --network sandbox_net \
  --security-opt label=disable \
  -v "$PROJECT_PATH:/work" \
  -w /work \
  -e ANTHROPIC_BASE_URL=http://authproxy:4000 \
  -e ANTHROPIC_API_KEY="$VIRTUAL_KEY" \
  -e OPENAI_BASE_URL=http://authproxy:4000/v1 \
  -e OPENAI_API_KEY="$VIRTUAL_KEY" \
  "$IMAGE"
```

The SDK base-URL caveat from v1 still applies: clients that hardcode `api.anthropic.com` will fail with DNS errors because `sandbox_net --internal` has no resolver for the public internet.

## Bootstrap order

1. **Host:**
   1. `docker pull ghcr.io/berriai/litellm:main-stable` and resolve its digest. Same for `alpine/socat`. Paste both into the unit files.
   2. `sudo useradd --system --no-create-home --shell /usr/sbin/nologin --uid 1500 litellm`.
   3. `sudo groupadd -r fortress && sudo usermod -aG fortress $USER` (then re-login or `newgrp fortress`).
   4. Generate the master key (`openssl rand -base64 32`) and write `/etc/ai-fortress/upstream.env` (`chmod 600 root:root`).
   5. Drop in `litellm-config.yaml`, the systemd units, the nft fragment, and the helper scripts (`fortress-mint`, `fortress-revoke`, `fortress-sweep`).
   6. Drop in `/etc/sudoers.d/ai-fortress` and validate with `sudo visudo -c`.
   7. `socat -V | head -1` — confirm ≥ 1.7.4. (Fedora 41 should be fine; verify before depending on it.)
   8. `systemctl enable --now ai-fortress-litellm ai-fortress-vsock-relay ai-fortress-key-sweep.timer`.
   9. `systemctl reload nftables`.
   10. Verify: `curl -sS http://127.0.0.1:4000/health` and `ss -lx | grep -i vsock`.
2. **Libvirt:**
   1. `virsh edit ai-fortress`, add `<vsock>`. Shutdown/start.
3. **Guest (Flatcar):**
   1. Update `config.bu` (vsock modules, sshd dropin, vsock-shim unit). Re-transpile and re-provision, **or** for an already-running VM, copy the unit and dropin in via SSH, `systemctl daemon-reload && systemctl enable --now vsock-shim && systemctl reload sshd`.
   2. Confirm UID alignment between the VM user (provisioned in `config.bu`) and the host user owning `/projects`. `config.bu` ships `ranton`; if you fork, set `passwd.users[0].name` and `uid:` accordingly.
   3. Drop `agent-vm` into `/usr/local/bin` and `chmod +x`.
4. **Host launcher:**
   1. Drop `~/bin/agent` and `chmod +x`.
   2. Optional: `FORTRESS_VM_USER=...` if your VM SSH user differs from `$USER`.

## Verification plan

```bash
# 0. Resolve VM (same way the launcher does)
VM_IP=$(virsh -c qemu:///system -q domifaddr --source agent ai-fortress \
        | awk '/ipv4/ {sub(/\/.*/,"",$NF); print $NF; exit}')
[[ -z "$VM_IP" ]] && VM_IP=$(virsh -c qemu:///system -q domifaddr ai-fortress \
        | awk '/ipv4/ {sub(/\/.*/,"",$NF); print $NF; exit}')
VM_USER="${FORTRESS_VM_USER:-$USER}"

# 1. socat version
socat -V | head -1   # expect >= 1.7.4

# 2. Host proxy is up
curl -fsS http://127.0.0.1:4000/health | jq

# 3. Anthropic-compat endpoint exists at LiteLLM
#    (this should 401 without auth, NOT 404 — proves the route is wired)
curl -isS -o /dev/null -w '%{http_code}\n' \
     -X POST http://127.0.0.1:4000/v1/messages \
     -H 'content-type: application/json' -d '{}'  # expect 401

# 4. Host vsock listener is bound
ss -lx | grep -i vsock

# 5. Mint/revoke helpers work and the user shell never sees the master key
TEST_KEY=$(sudo -n /usr/local/sbin/fortress-mint smoke-test $$ \
            "$(awk '{print $22}' /proc/$$/stat)")
echo "minted ok: ${TEST_KEY:0:8}..."
sudo -n /usr/local/sbin/fortress-revoke "$TEST_KEY" && echo "revoked ok"

# 6. nftables: only UID 1500 can reach 443
sudo -u litellm -- bash -c 'curl -sS --max-time 5 https://api.anthropic.com -o /dev/null && echo OK_LITELLM'
curl -sS --max-time 5 https://example.com -o /dev/null && echo OK_USER  # both should succeed in relaxed mode
# A negative test for UID 1500 reaching non-443:
sudo -u litellm -- bash -c 'curl -sS --max-time 3 http://example.com -o /dev/null' \
    && echo "FAIL: litellm reached :80" || echo "OK: litellm blocked on :80"

# 7. Guest can reach host over vsock
ssh "$VM_USER@$VM_IP" \
    'docker run --rm --device /dev/vsock alpine/socat -u - VSOCK-CONNECT:2:4000 <<<""' \
    && echo "OK: vsock open"

# 8. Guest shim resolves and proxies
ssh "$VM_USER@$VM_IP" \
    'docker run --rm --network sandbox_net curlimages/curl curl -fsS http://authproxy:4000/health'

# 9. Sandbox cannot reach the open internet
ssh "$VM_USER@$VM_IP" \
  'docker run --rm --network sandbox_net curlimages/curl curl --max-time 5 https://example.com' \
  && echo "FAIL: sandbox reached internet" || echo "OK: sandbox blocked"

# 10. End-to-end completion
agent test-project
# inside the sandbox:
#   curl -fsS http://authproxy:4000/v1/messages \
#        -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
#        -H "content-type: application/json" \
#        -d '{"model":"claude-sonnet-4-6","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}'

# 11. Streaming works (SSE) — add "stream": true and confirm token-by-token.

# 12. Orphan-key sweep
#    Mint a key, then kill -9 the launcher. Within ~5 min the key should be gone.
sudo -n /usr/local/sbin/fortress-sweep    # force a run
curl -fsS -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
     http://127.0.0.1:4000/key/info?return_full_object=true | jq '.keys | length'
```

If step 9 succeeds in reaching `example.com`, `sandbox_net` was not created with `--internal`. If step 6's negative test fails (litellm reaches :80), the `skuid` rule isn't loaded — re-check `nft list table inet ai_fortress`.

## Threat-model walk-through (corrected)

| Scenario                                  | What the attacker reaches                                                                                                | What stops them                                                                                                                                                                          |
|-------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Compromised agent in sandbox              | Project files in `/work`, virtual key with $5/8h cap, the shim TCP port                                                  | runsc syscall isolation; `--internal` blocks egress; virtual key budget caps spend; key cannot list/read other keys                                                                       |
| Sandbox tries to exfil to attacker.com    | n/a                                                                                                                      | `sandbox_net --internal`: no default route, no DNS resolver, no NAT                                                                                                                       |
| gVisor escape → VM userspace              | The vsock-shim container, the docker socket if reachable, Flatcar `/etc` (no upstream keys live here)                    | Master key is on the host, never present in the VM. Attacker can use the vsock channel only with a valid virtual key, which is short-lived and budget-capped                              |
| VM userspace egress via libvirt NAT       | Internet (relaxed mode) or nothing (strict mode)                                                                         | Relaxed: irrelevant — keys aren't in the VM. Strict: forward-chain rule drops `iifname virbr0 oifname != virbr0`                                                                          |
| Compromised LiteLLM image                 | Upstream keys, master key, internet on 443/53                                                                            | Image pinned by digest (deliberate updates only). `skuid 1500` confines the container to 443/53 only — no `:80`, no other ports. SNI filter is future work                                |
| Stolen virtual key (logged somewhere)     | LLM API access for ≤ 8h, ≤ $5                                                                                            | TTL expiry; orphan-key sweep revokes within ~5 min if the launcher process is gone; manual revoke via `sudo fortress-revoke <key>`                                                       |
| Stolen master key                         | Equivalent to upstream-key compromise (mint unlimited keys)                                                              | Master key never enters a user-shell process; only readable as root or via the two helper scripts. A host-root compromise is required                                                     |
| KVM escape                                | Host workstation                                                                                                         | Out of scope                                                                                                                                                                              |
| Compromised host                          | Everything                                                                                                               | Out of scope                                                                                                                                                                              |

The promotion v1 buys is preserved and the master-key row is now honest about what protects it (host-root only).

## File-by-file change summary

```
host/
  litellm-config.yaml
  ai-fortress-litellm.service
  ai-fortress-vsock-relay.service
  ai-fortress-key-sweep.service
  ai-fortress-key-sweep.timer
  ai-fortress.nft
  upstream.env.example          # template; root-only secrets file
  fortress-mint                 # /usr/local/sbin/, root:fortress 0750
  fortress-revoke               # /usr/local/sbin/, root:fortress 0750
  fortress-sweep                # /usr/local/sbin/, root:root    0750
  ai-fortress.sudoers           # → /etc/sudoers.d/ai-fortress
  agent                         # the new launcher; goes in user's ~/bin
  README-host-install.md

vm/
  agent-vm                      # /usr/local/bin inside the VM
  vsock-shim.service            # also embedded in config.bu

config.bu                       # MODIFIED: add vsock-shim.service unit, vsock modules-load.d,
                                # sshd_config.d/10-ai-fortress.conf
do_virt_install.sh              # MODIFIED: add --vsock cid.address=42,model=virtio
```

Files deleted/superseded:

- `agent-up` — replaced by `host/agent` + `vm/agent-vm`. Drops `OPENCODE_API_KEY` along with the other key passthroughs. Keep around for one release as a deprecated path, then remove.

Files NOT touched: `daemon.json`, `Dockerfile.python`, `burn_it_down.sh`, `make_overlay.sh`, image fetch scripts.

## Open questions / future work

1. **SNI-based egress filtering at the host.** Tighten the `skuid 1500 → 443` rule to the actual upstream hostnames. Probably mitmproxy in transparent mode, or LiteLLM in its own netns behind a userspace SNI filter.
2. **Per-process netns for LiteLLM.** Removes the `--network host` reliance entirely and lets the firewall match by interface, not UID. Bigger refactor; UID match is the v1-shippable answer.
3. **SELinux on the sandbox bind mount.** `--security-opt label=disable` is inherited from the existing `agent-up`. Replace with explicit `:z` / `:Z` semantics or a sandbox-specific SELinux type. Tracked separately.
4. **More than ~10 concurrent sandboxes.** socat with `fork` is fine in this range; beyond it, swap to a Go relay using `golang.org/x/sys/unix` AF_VSOCK + goroutines.
5. **Per-project budgets / analytics.** Virtual keys are already tagged with `project` metadata. Hook into LiteLLM's admin UI or tail the SQLite DB.
6. **VM access without SSH.** Replace the SSH hop with a virtio-serial dispatcher or `virsh qemu-agent-command`. SSH is fine for v1.
7. **Strict forward-chain mode.** Make the VM offline-except-for-vsock. Requires automating image refresh outside the VM.
