# AI Fortress: vsock Auth-Proxy Extension — Detailed Design

## Goals

1. **No upstream API credentials inside the VM, ever.** The real `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` live only on the host workstation. A full VM compromise (gVisor escape + privilege escalation in Flatcar) must not yield them.
2. **No sandbox-initiated network egress except via the proxy.** Sandbox containers can only reach one destination: a vsock-mediated relay to the host proxy. They cannot reach the internet, the libvirt NAT, or each other.
3. **Per-sandbox virtual keys with capped budgets and TTLs.** A leaked sandbox token expires within hours and can spend at most a few dollars before exhaustion.
4. **No new TCP listeners on the host's IP network.** The proxy is reachable from the VM only via `AF_VSOCK`, not via `virbr0` or any other host interface.

## Non-goals

- Defending against host compromise (out of scope; the host is the trust root).
- Multi-tenant fortress (single user, single workstation).
- Offline operation (the proxy needs internet egress to the upstreams).
- Per-IP rate limiting at the proxy (vsock collapses every sandbox to `127.0.0.1` from LiteLLM's perspective; budgeting is per virtual key instead).

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
│      └─ docker run --network host  litellm        │
│         listening on 127.0.0.1:4000               │
│                                                   │
│  systemd: ai-fortress-vsock-relay.service         │
│      └─ socat VSOCK-LISTEN:4000,fork              │
│              TCP:127.0.0.1:4000                   │
│                                                   │
│  nftables: only LiteLLM can reach the internet,   │
│  and only to api.anthropic.com / api.openai.com   │
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

The data path for one Anthropic completion request:

```
agent SDK
  → http://authproxy:4000/v1/messages   (TCP, internal Docker bridge)
  → in-VM socat shim
  → AF_VSOCK CID 2, port 4000           (virtio-vsock, hypervisor-mediated)
  → host socat relay
  → http://127.0.0.1:4000/v1/messages   (TCP, host loopback)
  → LiteLLM
  → https://api.anthropic.com/v1/messages  (TLS, host network, allowed by nftables)
```

SSE responses flow back the same path. Every hop is byte-transparent so streaming preserves event boundaries.

## Trust tiers

| Tier | Component                   | Runtime              | Trusted with                                                  |
|------|-----------------------------|----------------------|---------------------------------------------------------------|
| 0    | Host Fedora                 | bare metal           | ANTHROPIC_UPSTREAM_KEY, LITELLM_MASTER_KEY, sandbox lifecycle |
| 1    | LiteLLM container on host   | Docker (runc)        | upstream keys, virtual-key DB, internet egress                |
| 2    | Flatcar VM kernel/userspace | KVM                  | vsock shim, Docker daemon, sandbox lifecycle on VM            |
| 3    | vsock-shim container        | Docker (runc) on VM  | /dev/vsock access, sandbox_net membership                     |
| 4    | sandbox container           | Docker (runsc) on VM | one short-lived virtual key, project files only               |

The key invariant: secrets only flow downward by one tier at a time, and only the minimum required at each tier. Tier 0 holds the upstream keys, tier 1 holds them too (it has to in order to call the API), tier 2 never sees them, tier 3 never sees them, tier 4 sees only an ephemeral virtual key.

## Component-by-component design

### Host: secrets file

`/etc/ai-fortress/upstream.env`, mode `0600`, owned by `root:root`, never checked into git.

```
ANTHROPIC_UPSTREAM_KEY=sk-ant-...
OPENAI_UPSTREAM_KEY=sk-...
LITELLM_MASTER_KEY=sk-master-<32 random bytes, base64>
```

Created once, by hand, after running `openssl rand -base64 32` for the master key. The same file is read by both the LiteLLM systemd unit and the agent launcher script — those are the only two consumers, both running as root or as a member of a dedicated `fortress` group.

### Host: LiteLLM proxy

`/etc/ai-fortress/litellm-config.yaml`:

```yaml
model_list:
  - model_name: claude-*
    litellm_params:
      model: anthropic/claude-*
      api_key: os.environ/ANTHROPIC_UPSTREAM_KEY
  - model_name: gpt-*
    litellm_params:
      model: openai/gpt-*
      api_key: os.environ/OPENAI_UPSTREAM_KEY

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: sqlite:////var/lib/ai-fortress/litellm.db

litellm_settings:
  drop_params: true
  set_verbose: false
  max_budget: 100.0
  budget_duration: 30d
  request_timeout: 600
```

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
ExecStartPre=/usr/bin/install -d -m 0750 /var/lib/ai-fortress
ExecStart=/usr/bin/docker run --rm --name ai-fortress-litellm \
  --network host \
  -v /etc/ai-fortress/litellm-config.yaml:/app/config.yaml:ro \
  -v /var/lib/ai-fortress:/var/lib/ai-fortress \
  -e ANTHROPIC_UPSTREAM_KEY \
  -e OPENAI_UPSTREAM_KEY \
  -e LITELLM_MASTER_KEY \
  ghcr.io/berriai/litellm:main-stable \
  --config /app/config.yaml --host 127.0.0.1 --port 4000
ExecStop=/usr/bin/docker stop ai-fortress-litellm

[Install]
WantedBy=multi-user.target
```

`--network host` plus `--host 127.0.0.1` means the listener is bound to host loopback only. Nothing on `virbr0`, nothing on the LAN, can reach it. The vsock relay is the only non-loopback path.

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
ExecStart=/usr/bin/socat -d \
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

Requires socat ≥ 1.7.4 (vsock support landed in 1.7.4). Fedora 41 ships a recent enough version. `nodelay` keeps SSE token latency tight.

The unit needs to read/write `/dev/vsock`, which is owned by `root:kvm` mode `0660` on most distros. Either run as root (simplest, locked down by the systemd hardening above), or add a `User=` directive and add that user to `kvm`.

### Host: nftables egress allowlist

The LiteLLM container runs with `--network host`, so its egress traffic shows up on the host's normal network. We constrain that with nftables.

`/etc/nftables.d/ai-fortress.nft`:

```
table inet ai_fortress {
    set llm_endpoints_v4 {
        type ipv4_addr
        flags interval
        # Resolved at config time; refresh via timer
        elements = { 0.0.0.0/0 }   # placeholder; see notes
    }

    chain output {
        type filter hook output priority 0; policy accept;

        # Trust the LiteLLM container's outbound connections only to llm endpoints.
        # Identify it by uid (the docker daemon runs as root, so this is coarse).
        # Better: pin via cgroup match — see below.
        meta cgroup "system.slice/ai-fortress-litellm.service" \
            ip daddr @llm_endpoints_v4 tcp dport 443 accept
        meta cgroup "system.slice/ai-fortress-litellm.service" \
            udp dport 53 accept
        meta cgroup "system.slice/ai-fortress-litellm.service" \
            drop
    }
}
```

Two operational notes:

1. DNS allowlist by IP is fragile because `api.anthropic.com` is fronted by a CDN with rotating IPs. The pragmatic option is to allow `tcp dport 443 to 0.0.0.0/0` but only from the LiteLLM cgroup, accepting that the proxy could in principle reach any HTTPS endpoint. The hard option is an egress proxy like mitmproxy or squid that does SNI-based filtering. Recommend the pragmatic option for v1, with a TODO for SNI filtering once you've measured how stable the upstream IP set is.
2. cgroup matching assumes systemd-managed cgroups, which Fedora 41 has. If `meta cgroup` doesn't behave on your kernel, fall back to `skuid root` plus a separate netns for LiteLLM (a bigger refactor).

### Host: virtual-key minting helper

The agent launcher (replacing `agent-up`) runs on the host. Skeleton at `~/bin/agent`:

```bash
#!/bin/bash
set -euo pipefail

PROJECT_NAME="${1:-}"
TYPE="${2:-default}"
[[ -z "$PROJECT_NAME" ]] && { echo "usage: agent <project> [python|default]" >&2; exit 1; }

# Read master key (host only, never crosses into VM)
source /etc/ai-fortress/upstream.env

# Mint a per-session virtual key
VIRTUAL_KEY=$(curl -fsS --max-time 5 \
    -X POST http://127.0.0.1:4000/key/generate \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "$(cat <<JSON
{
  "models": ["claude-*", "gpt-*"],
  "max_budget": 5.0,
  "duration": "8h",
  "metadata": {"project": "$PROJECT_NAME", "host_user": "$USER"}
}
JSON
)" | jq -r .key)

# Hand off to the VM. The virtual key is the ONLY secret crossing into the VM.
# We pass it via SSH env, not via the command line (avoids ps leakage).
exec ssh -t \
    -o SendEnv=VIRTUAL_KEY \
    -o ServerAliveInterval=30 \
    fortress@ai-fortress.local \
    VIRTUAL_KEY="$VIRTUAL_KEY" /usr/local/bin/agent-vm "$PROJECT_NAME" "$TYPE"
```

Key properties:

- The master key is sourced from `upstream.env` (root-readable, or readable by a fortress group member). It never leaves this script's process.
- The minted virtual key is short-lived (8h), capped ($5), and revocable from the host without touching anything on the VM.
- The virtual key is passed to the VM as an SSH `SendEnv` value, not as a command-line argument, so it doesn't appear in `ps` output on the VM.
- The script `exec`s into SSH so Ctrl-C and signal handling work correctly. When the user exits the agent shell, SSH closes, the `docker run` inside ends, and the virtual key (which is timer-bounded anyway) becomes dead weight that LiteLLM will GC.

Optional: on script exit, call `/key/delete` to revoke immediately. Not strictly necessary because of the TTL, but tighter.

### Guest: vsock kernel modules

Add to `config.bu`:

```yaml
storage:
  files:
    - path: /etc/modules-load.d/vsock.conf
      mode: 0644
      contents:
        inline: |
          vsock
          vmw_vsock_virtio_transport
```

These are in Flatcar's stock kernel; just need to be loaded at boot. Verify with `lsmod | grep vsock` after reboot.

### Guest: libvirt domain — adding the vsock device

`virt-install` (recent versions) supports vsock via the libvirt domain XML. Two integration paths:

**Option A** — edit `do_virt_install.sh`, append:

```
  --qemu-commandline="-device vhost-vsock-pci,guest-cid=42" \
```

CID 42 (any integer ≥ 3, unique per host) becomes the VM's vsock identity. Pick a value and stick with it.

**Option B** — edit the domain XML after install, via `virsh edit ai-fortress`, adding under `<devices>`:

```xml
<vsock model='virtio'>
  <cid auto='no' address='42'/>
</vsock>
```

Option B is the libvirt-native way and survives `virsh dumpxml`/restore cleanly. Recommend B for the installed VM, A for the install script if you want the vsock device present from first boot.

After this change, the VM's `/dev/vsock` device exists and the host can address the guest as CID 42 (and the guest addresses the host as CID 2).

### Guest: in-VM vsock shim

Flatcar has no socat package, so the shim is a tiny container. Add to `config.bu`:

```yaml
systemd:
  units:
    - name: vsock-shim.service
      enabled: true
      contents: |
        [Unit]
        Description=AI Fortress vsock shim (TCP -> vsock)
        After=docker.service projects.mount
        Requires=docker.service

        [Service]
        Restart=always
        RestartSec=5
        ExecStartPre=-/usr/bin/docker rm -f vsock-shim
        ExecStartPre=/usr/bin/docker network inspect sandbox_net >/dev/null 2>&1 || \
          /usr/bin/docker network create --driver bridge --internal sandbox_net
        ExecStart=/usr/bin/docker run --rm --name vsock-shim \
          --network sandbox_net \
          --network-alias authproxy \
          --device /dev/vsock \
          alpine/socat \
          -d \
          TCP-LISTEN:4000,reuseaddr,fork \
          VSOCK-CONNECT:2:4000
        ExecStop=/usr/bin/docker stop vsock-shim

        [Install]
        WantedBy=multi-user.target
```

Two important details:

1. `--network-alias authproxy` makes the shim resolvable inside `sandbox_net` as `authproxy`. Sandboxes use `http://authproxy:4000` and never need to know it's a vsock shim.
2. `--internal` on `sandbox_net` is the load-bearing flag — it strips the sandbox network of any default route off the VM. The only thing reachable from a sandbox is other containers on the same bridge, which is just the shim. Docker DNS still works on internal networks, so name resolution for `authproxy` is fine.

The shim container is not under `runsc`; it uses the default `runc` runtime. It is trusted infrastructure, runs only socat (no untrusted code), and needs `/dev/vsock` access which is awkward under gVisor.

### Guest: agent-vm script

The thing that runs inside the VM, invoked via SSH from the host launcher. `/usr/local/bin/agent-vm`:

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

Compared to the original `agent-up`:

- All three `-e *_API_KEY` passthroughs from the user shell are gone.
- `--network sandbox_net` replaces the implicit default bridge.
- `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` redirect SDK traffic to the shim.
- The script reads `VIRTUAL_KEY` from its env (passed by SSH `SendEnv`), not from a CLI arg, so the value never appears in process listings.

## Bootstrap order

First-time install:

1. **Host:**
   1. Install LiteLLM image: `docker pull ghcr.io/berriai/litellm:main-stable`.
   2. Create `/etc/ai-fortress/upstream.env` with the three secrets, `chmod 600`.
   3. Drop in `litellm-config.yaml`, the two systemd units, and the nftables fragment.
   4. `systemctl enable --now ai-fortress-litellm ai-fortress-vsock-relay`.
   5. `systemctl reload nftables`.
   6. Verify: `curl -sS http://127.0.0.1:4000/health`.
   7. Verify vsock listener: `ss -lx | grep -i vsock` (or `socat -V` then `socat - VSOCK-CONNECT:1:4000` from another shell).
2. **Libvirt:**
   1. `virsh edit ai-fortress`, add the `<vsock>` element with a chosen CID.
   2. `virsh shutdown ai-fortress && virsh start ai-fortress`.
3. **Guest (Flatcar):**
   1. Update `config.bu` to add the vsock kernel modules and `vsock-shim.service`. Re-transpile, drop the new `config.json` into libvirt's images dir, re-provision (or for an already-running VM, drop the unit file in via SSH and `systemctl daemon-reload && systemctl enable --now vsock-shim`).
   2. Create `sandbox_net` if not auto-created: handled by `ExecStartPre` in the unit.
   3. Drop `agent-vm` into `/usr/local/bin` and `chmod +x`.
4. **Host launcher:**
   1. Drop `~/bin/agent` and `chmod +x`.
   2. Configure SSH: `~/.ssh/config` entry for `ai-fortress.local` with `SendEnv VIRTUAL_KEY`, and confirm `/etc/ssh/sshd_config` on the VM has `AcceptEnv VIRTUAL_KEY`.

## Verification plan

End-to-end smoke test, in order:

```bash
# 1. Host proxy is up
curl -fsS http://127.0.0.1:4000/health | jq

# 2. Host vsock listener is bound
ss -l | grep -i vsock        # or: socat -u VSOCK-LISTEN:9999 - <<<test (in another shell)

# 3. Guest can reach host over vsock
ssh fortress@ai-fortress.local 'docker run --rm --device /dev/vsock alpine/socat - VSOCK-CONNECT:2:4000 <<<""'

# 4. Guest shim resolves and proxies
ssh fortress@ai-fortress.local \
  'docker run --rm --network sandbox_net curlimages/curl curl -fsS http://authproxy:4000/health'

# 5. Sandbox cannot reach the open internet
ssh fortress@ai-fortress.local \
  'docker run --rm --network sandbox_net curlimages/curl curl --max-time 5 https://example.com' \
  && echo "FAIL: sandbox reached internet" || echo "OK: sandbox blocked"

# 6. End-to-end completion
agent test-project
# inside the sandbox:
#   curl -fsS http://authproxy:4000/v1/messages \
#        -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
#        -H "content-type: application/json" \
#        -d '{"model":"claude-sonnet-4-6","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}'

# 7. Streaming works (SSE)
# inside the sandbox:
#   add "stream": true to the body above and confirm token-by-token output
```

If step 5 succeeds in reaching `example.com`, `sandbox_net` was not created with `--internal` — fix the `ExecStartPre` and recreate the network.

## Threat model walk-through

| Scenario                                  | What the attacker reaches                                                                        | What stops them                                                                                                                                                                                                            |
|-------------------------------------------|--------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Compromised agent in sandbox              | Project files in `/work`, virtual key with $5/8h cap, the shim TCP port                          | runsc syscall isolation, `--internal` network blocks all egress, virtual key budget caps spend, virtual key cannot read or list other keys                                                                                 |
| Sandbox tries to exfil to attacker.com    | n/a                                                                                              | `sandbox_net --internal`: no default route, no DNS resolver, no NAT                                                                                                                                                        |
| gVisor escape → VM userspace              | The vsock-shim container, the docker socket if reachable, Flatcar `/etc` (but no upstream keys live here) | nftables on the host blocks any non-LiteLLM cgroup from internet egress, so even at this tier the attacker can only reach the LLM endpoints via the proxy with a virtual key. Master key is on the host, never present.   |
| VM userspace → host via libvirt NAT       | virbr0 gateway on the host                                                                       | nftables policy: only the LiteLLM cgroup can reach the internet; everything else from virbr0 is dropped at the host's forward chain                                                                                        |
| KVM escape                                | Host workstation                                                                                 | Out of scope; this is the level the fortress was always advertising as the strongest line                                                                                                                                  |
| Stolen virtual key (e.g., logged somewhere) | LLM API access for ≤ 8h, ≤ $5                                                                 | TTL expiry; revoke from host: `curl -X POST .../key/delete -H "Authorization: Bearer $LITELLM_MASTER_KEY" -d '{"keys":["sk-..."]}'`                                                                                        |
| Compromised host                          | Everything                                                                                       | Out of scope                                                                                                                                                                                                               |

The critical promotion this design buys you: upstream key exfiltration now requires a KVM escape, not a gVisor escape. The proxy lives at tier 1 (host); the VM (tier 2) and everything below it never holds the upstream key. This is the security argument that justifies the whole vsock detour over a simpler "proxy in the VM" design.

## File-by-file change summary

New files in repo (templates; actual installed copies may have user-specific paths):

```
host/
  litellm-config.yaml
  ai-fortress-litellm.service
  ai-fortress-vsock-relay.service
  ai-fortress.nft
  agent                       # the new launcher; goes in user's ~/bin
  README-host-install.md      # the one-time install steps above

vm/
  agent-vm                    # goes in /usr/local/bin inside the VM
  vsock-shim.service          # also embedded in config.bu

config.bu                     # MODIFIED: add vsock-shim.service unit + vsock modules-load.d
do_virt_install.sh            # MODIFIED: add --qemu-commandline for vsock device, OR document virsh edit step
```

Files to delete or supersede:

- `agent-up` — replaced by `host/agent` + `vm/agent-vm`. Keep around for one release as a deprecated path, then remove.

Files NOT touched:

- `daemon.json` — gVisor runtime config is unchanged.
- `Dockerfile.python` — sandbox image content is unchanged; the proxy is invisible to it.
- `burn_it_down.sh`, `make_overlay.sh`, image fetch scripts — unrelated.

## Open questions / future work

1. **SNI-based egress filtering at the host.** The current nftables rule allows the LiteLLM cgroup to reach any HTTPS host. Tighter is to put LiteLLM behind a sslh/squid-style SNI filter or in its own netns with a userspace proxy. Worth doing once you've confirmed the rest of the design is stable.
2. **Multiple concurrent sandboxes.** socat with `fork` handles each connection in a child process. Fine for ≤10 concurrent agents. If you ever push past that, swap socat for a small Go relay using `golang.org/x/sys/unix` AF_VSOCK + goroutines.
3. **Per-project budgets.** LiteLLM supports virtual key hierarchies and per-tag spend tracking. The launcher already tags virtual keys with project metadata; the analytics piece is "free" once you pull up LiteLLM's admin UI.
4. **VM access without SSH.** SSH is the path of least resistance for the launcher → VM hop, but it adds an SSH dependency. Alternatives: virtio-serial channel + a tiny dispatcher daemon inside the VM, or `virsh qemu-agent-command` if the QEMU guest agent is installed. SSH is fine for v1.
5. **Image pinning.** The systemd units pin LiteLLM by tag (`main-stable`) and the shim by `alpine/socat` tag-less. Pin both by digest (`@sha256:...`) before this is "production." A compromised proxy image is a credential compromise.
6. **vsock relay HA.** If `ai-fortress-vsock-relay.service` dies, sandboxes stall on their next request. systemd `Restart=always` covers process crashes; for harder failures, add a healthcheck that probes `socat - VSOCK-CONNECT:2:4000` from inside the VM and alerts.
7. **Cleanup on session exit.** The launcher could trap EXIT to call `/key/delete` immediately, in addition to the natural TTL expiry. Belt and suspenders.
8. **Audit logging.** LiteLLM writes request logs to its SQLite DB. Tail those into your normal log pipeline and you have a full audit trail of every prompt every sandbox sent — useful both for debugging and for spotting weirdness after the fact.
