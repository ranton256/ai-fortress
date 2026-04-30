# AI Fortress — Architecture (as-built)

**Status:** current. This document supersedes `network-plan.md` and `network-plan-v2.md` as the source of truth for what is actually deployed. Those two are retained as design history.

The fortress is a five-layer sandboxing architecture for running AI coding agents on a workstation:

| Layer | Boundary | What's inside | Key controls |
|------:|----------|--------------|--------------|
| 0 | Host workstation | Bifrost LLM gateway, secrets, libvirt | `nft skuid 1500`, root-only secrets file, sudoers limited to two helpers |
| 1 | KVM virtual machine (Flatcar) | Docker daemon, vsock-shim, sandbox bridge | Read-only `/usr`, libvirt NAT, vsock device only |
| 2 | gVisor (`runsc`) sandbox container | The agent process and project files | User-space kernel, syscall interception |
| 3 | Internal Docker bridge `sandbox_net` | Container's network namespace | `--internal` (no default route, no NAT) |
| 4 | Per-session virtual key | One short-lived `sk-bf-*` token | Bifrost governance: $5/8h budget, 60 RPM, scoped to LLM provider |

The novel layers compared to a typical "just use a container" setup are **layer 0** (the proxy keeps upstream LLM credentials off the VM entirely) and **layer 4** (every sandbox session gets a fresh budget-capped token and the upstream key never enters the sandbox).

---

## Architecture diagram

```
┌─────────────────────────── HOST WORKSTATION (Fedora) ──────────────────────────┐
│                                                                                │
│  /etc/ai-fortress/upstream.env  (root:root 0600)                               │
│      ANTHROPIC_UPSTREAM_KEY                                                    │
│      OPENAI_UPSTREAM_KEY                                                       │
│      BIFROST_ADMIN_USERNAME / BIFROST_ADMIN_PASSWORD                           │
│                                                                                │
│  /usr/local/sbin/fortress-{mint,revoke,sweep}                                  │
│      └─ root-owned helpers; read upstream.env as root                          │
│      └─ %fortress NOPASSWD via /etc/sudoers.d/ai-fortress                      │
│                                                                                │
│  systemd: ai-fortress-bifrost.service                                          │
│      └─ docker run --network host --user 1500:1500                             │
│         maximhq/bifrost@sha256:...                                             │
│         listening on 127.0.0.1:4000                                            │
│         routes: /anthropic/v1/messages, /openai/v1/chat/completions,           │
│                 /api/governance/virtual-keys (admin basic-auth)                │
│                                                                                │
│  systemd: ai-fortress-vsock-relay.service                                      │
│      └─ socat VSOCK-LISTEN:4000,fork                                           │
│              TCP:127.0.0.1:4000                                                │
│                                                                                │
│  systemd: ai-fortress-key-sweep.timer  (every 5 min)                           │
│      └─ revokes orphaned virtual keys (dead launcher PID, or > 8h old)         │
│                                                                                │
│  nftables (table inet ai_fortress):                                            │
│      OUTPUT:                                                                   │
│        meta skuid 1500 ct state established,related accept                     │
│        meta skuid 1500 udp dport 53 accept                                     │
│        meta skuid 1500 tcp dport 443 accept                                    │
│        meta skuid 1500 drop                                                    │
│      FORWARD:                                                                  │
│        policy accept   (relaxed mode — see security controls)                  │
│                                                                                │
│  ~/bin/agent  (the launcher)                                                   │
│      └─ sudo -n fortress-mint  →  sk-bf-...                                    │
│      └─ ssh -t … VIRTUAL_KEY=… /opt/bin/agent-vm                               │
│      └─ trap: sudo -n fortress-revoke  on EXIT                                 │
│                                                                                │
│  ┌───────────────────── KVM boundary (libvirt + virtio) ──────────────────┐    │
│  ▲                                                                        ▲    │
│  │ AF_VSOCK CID 2 ↔ guest CID 42, port 4000   (hypervisor-mediated)       │    │
│  ▼                                                                        ▼    │
│  ┌────────────────── Flatcar VM ──────────────────────────────────────────┐    │
│  │                                                                        │    │
│  │  /usr  read-only       /opt/bin/{runsc, agent-vm}                      │    │
│  │  Docker daemon         /etc/docker/daemon.json registers runsc         │    │
│  │  sshd                  /etc/ssh/sshd_config.d/10-ai-fortress.conf      │    │
│  │                        (AcceptEnv VIRTUAL_KEY)                         │    │
│  │                                                                        │    │
│  │  systemd: vsock-shim.service                                           │    │
│  │      └─ docker run --device /dev/vsock                                 │    │
│  │         --security-opt seccomp=unconfined                              │    │
│  │         --network sandbox_net  --network-alias authproxy               │    │
│  │         alpine/socat@sha256:…                                          │    │
│  │         TCP-LISTEN:4000,fork  →  VSOCK-CONNECT:2:4000                  │    │
│  │                                                                        │    │
│  │  Docker network: sandbox_net  (--internal, no default route)           │    │
│  │      ┌──────────────┐  ┌─────────────────┐  ┌─────────────────┐        │    │
│  │      │ vsock-shim   │  │ agent-foo       │  │ agent-bar       │        │    │
│  │      │ (runc)       │  │ (runsc)         │  │ (runsc)         │        │    │
│  │      │ alias:       │  │ --add-host      │  │ --add-host      │        │    │
│  │      │  authproxy   │  │  authproxy:<ip> │  │  authproxy:<ip> │        │    │
│  │      │              │  │ ANTHROPIC_API_  │  │ ANTHROPIC_API_  │        │    │
│  │      │              │  │  KEY=sk-bf-…    │  │  KEY=sk-bf-…    │        │    │
│  │      │              │  │ /work →         │  │ /work →         │        │    │
│  │      │              │  │  /projects/foo  │  │  /projects/bar  │        │    │
│  │      └──────────────┘  └─────────────────┘  └─────────────────┘        │    │
│  │                                                                        │    │
│  │  virtiofs: /projects ← host:/home/ranton/projects (UID-aligned)        │    │
│  └────────────────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                  api.anthropic.com (TLS, host-side, only from UID 1500)
```

---

## Network flow: a single sandbox-issued completion

```
sandbox container (runsc)
  │  ANTHROPIC_BASE_URL=http://authproxy:4000/anthropic
  │  ANTHROPIC_API_KEY=sk-bf-<32-byte uuid>
  │
  │  Anthropic SDK appends /v1/messages → POST http://authproxy:4000/anthropic/v1/messages
  │  Resolves "authproxy" via /etc/hosts entry written by `--add-host=authproxy:<shim_ip>`
  │  (runsc cannot reach Docker's embedded DNS, hence the static host entry)
  │
  ▼
sandbox_net Docker bridge (172.18.0.0/16, --internal — no default route)
  │
  ▼
vsock-shim container (runc)
  │  socat TCP-LISTEN:4000,fork accepts the connection
  │  forks a child that does VSOCK-CONNECT:2:4000
  │  (container has --device /dev/vsock and seccomp=unconfined to allow
  │   socket(AF_VSOCK, SOCK_STREAM, 0))
  │
  ▼  AF_VSOCK packet — never on any IP network, only on the virtio-vsock
  │   bus mediated by the hypervisor
  │
host vsock-relay (systemd)
  │  socat VSOCK-LISTEN:4000,reuseaddr,fork accepts
  │  forks a child that does TCP:127.0.0.1:4000 (loopback only)
  │
  ▼
Bifrost (--user 1500, --network host, listening 127.0.0.1:4000)
  │  Authenticates the request: x-api-key: sk-bf-… is recognized as a virtual key
  │  Looks up the VK in its SQLite governance store, checks budget + rate limit
  │  Selects the configured upstream key for "anthropic" provider
  │  Issues outbound HTTPS request with the real ANTHROPIC_UPSTREAM_KEY
  │
  ▼  TCP 443 (TLS)
  │   nftables rule: skuid 1500 tcp dport 443 accept
  │   established/related reply traffic accepted via ct state rule
  │
api.anthropic.com
  │  Real provider responds
  │
  ▼  Response flows back the same path, byte-transparent (preserves SSE
  │   event boundaries for streaming).
  │
sandbox container reads response.
```

Each hop is byte-transparent so streaming responses (`event: message_start`, `data: {...}`, etc.) preserve their boundaries and arrive token-by-token.

---

## Trust tiers and what each can do

| Tier | Component | Runtime | Holds | Can talk to |
|------|-----------|---------|-------|-------------|
| 0 | Host Fedora | bare metal | upstream API keys, master admin password, VK store, libvirt | anything (you, the owner) |
| 1 | Bifrost on host | Docker (runc), UID 1500, host net | upstream API keys (env) | DNS + 443 outbound only (nftables); loopback :4000 inbound |
| 2 | Flatcar VM kernel/userspace | KVM | Docker daemon, vsock-shim ownership | virbr0 NAT (relaxed mode); KVM-mediated vsock to host |
| 3 | vsock-shim container | runc, in VM | `/dev/vsock` access, sandbox_net membership | TCP from sandbox_net peers; AF_VSOCK to host CID 2 |
| 4 | Sandbox container | runsc, in VM | One short-lived virtual key, project files | sandbox_net only (no internet, no DNS, no virbr0, no VM loopback) |

Secrets only flow downward, one tier at a time, and only the minimum required at each tier. The upstream API key never crosses the KVM boundary. The master admin password never enters a user-shell process. The virtual key is the only credential that ever reaches tier 4, and it is bounded in time and dollars.

---

## Security controls catalog

### Boundary 1 — sandbox cannot reach the public internet

- **`docker network create --internal sandbox_net`**: strips the default route, NAT rules, and DNS lookups for public names from any container attached to the network. Only intra-bridge container-to-container traffic works.
- **No `/dev/vsock` exposed** to sandbox containers (only the shim has `--device /dev/vsock`).
- **gVisor (`runsc`) syscall interception** prevents the sandbox from opening raw sockets, AF_VSOCK directly, or otherwise bypassing the network namespace.
- **Verified by:** `B2-1`, `B2-2`, `B3-1`, `B3-2` (sandboxes timeout DNS-resolving anything off-bridge).

### Boundary 2 — sandbox cannot exfiltrate via the host's shell or libvirt NAT

- VM userspace can reach the libvirt NAT (relaxed mode), but the **sandbox lives on a separate Docker bridge that has no route to virbr0**.
- **`B2-3`**: sandbox cannot connect to `192.168.124.1` (virbr0 gateway).
- **`B2-4`**: sandbox cannot reach VM loopback `127.0.0.1` (where in principle other VM services could listen).
- **`B3-11`**: same check from a real launcher-style sandbox.

### Boundary 3 — the only path off the bridge is the proxy

- The shim's container has `--network-alias authproxy` and listens on TCP 4000. **Nothing else on `sandbox_net` listens on a network port.**
- Sandboxes resolve `authproxy` via a static `--add-host` entry (necessary because runsc's netstack does not reach Docker's embedded DNS at 127.0.0.11).
- **`A2-9`**: `curl http://authproxy:4000/health` from a sandbox-net container returns Bifrost's health JSON.

### Boundary 4 — the proxy demands a virtual key

- `bifrost-config.json` sets `client.enforce_auth_on_inference: true` and `governance.auth_config.disable_auth_on_inference: true`. Together: inference requires a valid VK *only* — admin basic-auth is not accepted on inference routes, and inference is not allowed without a VK.
- **`B1-11`**: requests without a VK return 401.
- **`B3-5`/`B3-6`**: a VK cannot list or mint other keys — those endpoints require admin basic-auth, which the sandbox does not have.

### Boundary 5 — the virtual key has limits

- **`max_budget: 5.0` USD** with `reset_duration: "8h"`. Soft TTL of 8h enforced by the orphan sweeper (since Bifrost has no native key expiry).
- **`request_max_limit: 60` RPM** rate limit.
- **`provider_configs: [anthropic, openai]`** with `allowed_models: ["*"]` — keys can only call configured providers.
- **`B3-3`**: budget cap can be observed by exhausting a small test budget.

### Boundary 6 — upstream credentials never leave the host

- `ANTHROPIC_UPSTREAM_KEY`/`OPENAI_UPSTREAM_KEY` live in `/etc/ai-fortress/upstream.env` (root:root 0600). Read by the Bifrost systemd unit's `EnvironmentFile=` directive and by the root-owned helper scripts.
- **`B3-8`**: the upstream key value is not present in any sandbox env var.
- **`B3-9`/`B3-10`**: the upstream key and admin password are not findable in any file inside the sandbox.

### Boundary 7 — the host process running the LLM cannot misuse network egress

- `useradd --system --uid 1500 bifrost` gives the proxy a dedicated system UID.
- **nftables** restricts UID 1500 to outbound DNS (53/udp) and HTTPS (443/tcp). Reply traffic on Bifrost's loopback listener is allowed via `ct state established,related accept` (otherwise the proxy could not respond to incoming requests).
- **A1-13**: UID 1500 can reach `api.anthropic.com:443`.
- **B1-2/B1-3**: UID 1500 cannot reach `:80` or `:22`.
- **B1-4**: other UIDs (your shell) are unaffected by these rules.

### Boundary 8 — the user shell never sees the master credential

- The Bifrost admin password lives only in `/etc/ai-fortress/upstream.env` (root:root 0600).
- The user shell calls `sudo -n /usr/local/sbin/fortress-mint` for VK minting; the helper reads the password as root and never returns it. Stdout is the `sk-bf-*` value only.
- A narrowly scoped sudoers entry permits `%fortress NOPASSWD: /usr/local/sbin/fortress-mint, /usr/local/sbin/fortress-revoke` and nothing else.
- **B1-5**: the admin password is not findable in `/proc/$LAUNCHER_PID/environ`.

### Boundary 9 — orphaned virtual keys are cleaned up

- The launcher's `EXIT` trap calls `fortress-revoke` for clean exits.
- The `ai-fortress-key-sweep.timer` (5-minute cadence) lists VKs, parses the `description` field for the launcher PID + start-time-ns + creation timestamp, and revokes any whose owning process is gone or whose age exceeds 8 hours.
- **A1-15**: a synthetic dead-launcher key is reaped within one sweep tick.
- **A3-9**: a launcher killed mid-flight does not leak its VK.

---

## Threat model walkthrough (as-built)

| Scenario | What the attacker reaches | What stops them |
|----------|--------------------------|-----------------|
| Compromised agent in sandbox | Project files in `/work`, virtual key with $5/8h cap, the shim TCP port | runsc syscall isolation; `--internal` blocks egress; VK budget caps spend; VK cannot read or list other VKs |
| Sandbox tries to exfil to attacker.com | n/a | `sandbox_net --internal`: no default route, no DNS resolver |
| gVisor escape → VM userspace | The vsock-shim container, the docker socket if reachable, Flatcar `/etc` (no upstream keys live there) | Master password is on the host; attacker can use the vsock channel only with a valid VK, which is short-lived and budget-capped |
| VM userspace egress via libvirt NAT | Internet (relaxed mode) | Irrelevant — keys aren't in the VM. Attacker can reach the public internet but cannot call our LLM accounts. (Strict mode adds `iifname virbr0 oifname != virbr0 drop` to forward chain to remove this too.) |
| Compromised Bifrost image | Upstream keys, master password, internet on 443/53 | Image pinned by digest. nftables `skuid 1500` confines the container to 53/udp + 443/tcp only |
| Stolen virtual key (logged somewhere) | LLM API access for ≤ 8h, ≤ $5 | Soft TTL via sweeper; budget cap; manual revoke via `sudo fortress-revoke <key>` |
| Stolen master password | Equivalent to upstream-key compromise (mint unlimited keys) | Master password readable only as root or via the two helper scripts. A host-root compromise is required |
| KVM escape | Host workstation | Out of scope — fortress was always advertised as ending here |
| Compromised host | Everything | Out of scope |

---

## Operational notes

- **Health endpoint:** `curl http://127.0.0.1:4000/health` returns `{"status":"ok","components":{"db_pings":"ok"}}`.
- **VK list:** `sudo -n /usr/local/sbin/fortress-revoke` doesn't list (it deletes by value); use the basic-auth admin endpoint: `curl -fsS -u $USER:$PASS http://127.0.0.1:4000/api/governance/virtual-keys | jq`.
- **Force a sweep:** `sudo /usr/local/sbin/fortress-sweep` runs the reaper immediately.
- **Logs:** `journalctl -u ai-fortress-bifrost`, `journalctl -u ai-fortress-vsock-relay`, `journalctl -u ai-fortress-key-sweep`. Inside the VM: `journalctl -u vsock-shim` and `docker logs vsock-shim`.
- **Audit trail:** Bifrost's request log is in its SQLite store at `/var/lib/ai-fortress/config.db` (LiteLLM-era `litellm.db` is gone).
- **Test plan:** the 47-test verification battery lives in `verify-phase1.sh`, `verify-phase2.sh`, `verify-phase3.sh`. Re-run any time after a config change.
- **Rollback:** `rollback.md` documents how to unwind by phase. The pre-deployment artifacts are `~/ai-fortress-pre-v2.tgz` (host `/etc` backup) and the `pre-network-v2` libvirt snapshot (recreate after each disk re-provision).
- **Sandbox images:** the VM's Docker daemon needs sandbox images present locally before `agent <project> <variant>` can use them. Two helpers manage this:
  - `build_python_in_vm.sh` — SCPs `Dockerfile.python` + `build_python.sh` into the VM and builds `ai-fortress/python-dev:latest` there. Re-run after each re-provision.
  - `push_image_to_vm.sh <image[:tag]> [...]` — for any image built on the host, streams it into the VM via `docker save | ssh "docker load"` (no temp tarball). Used for custom agent images that need host-side build context.
- **Generic file transfer:** `cp_to_vm.sh <local-source>... <vm-destination>` is a thin `rsync` wrapper for non-image artifacts (configs, build outputs, dotfiles). Mirrors scp calling convention; resolves the VM IP the same way the other helpers do.
- **Root-owned destinations:** `install_to_vm.sh [-m MODE] <source>... <dest>` stages files in `/tmp/` then runs `sudo install` on the VM to place them at root-owned paths like `/opt/bin/` or `/etc/...`. Each invocation uses a unique staging dir and cleans up afterward. Use this instead of `cp_to_vm.sh` whenever the destination requires root.
- **Sandbox `HOME`:** `agent-vm` sets `HOME=/work` so caches (Bun, npm, pip) end up in the project bind-mount instead of unwritable `/`. Project `.gitignore` should exclude `.bun/`, `.npm/`, `.cache/`, `.local/` etc. Images that bake in a proper user with a writable home dir can override `HOME` from their entrypoint.

---

## Implementation deltas vs. the original plans

These are the things that surfaced during implementation and don't appear in `network-plan.md` / `network-plan-v2.md`.

| Symptom or surprise | Cause | Fix |
|---------------------|-------|-----|
| Bifrost replies time out from host shell | `nft skuid 1500 drop` killed Bifrost's SYN-ACK on the inbound loopback connection | Added `meta skuid $proxy_uid ct state established,related accept` *before* the drop |
| LiteLLM bootstrapping fails: `database_url must start with postgresql://` | LiteLLM's bundled Prisma schema is hardcoded to PostgreSQL | Switched to **Bifrost** (single Go binary, SQLite supported, drop-in for /v1/messages and /v1/chat/completions semantics under /anthropic/* and /openai/* prefixes) |
| Bifrost crashes with `PermissionError: '/.cache'` | Container runs as UID 1500 but `$HOME` defaults to `/` | Added `-e HOME=/var/lib/ai-fortress` to the unit |
| `key_ids: ["*"]` returns 500 from `/api/governance/virtual-keys` | Bifrost interprets `["*"]` literally as a key named `*`, not a wildcard, on this endpoint | Omit `key_ids` entirely; Bifrost defaults to "any configured key for this provider" |
| Inference returns 401 even with a valid VK | `disable_auth_on_inference: false` requires admin basic-auth on inference routes too | Set `disable_auth_on_inference: true` so VK is the sole inference auth |
| vsock-shim active but every connection dies | Docker default seccomp profile on Flatcar blocks `socket(AF_VSOCK, …)` (errno 1) | Added `--security-opt seccomp=unconfined` to the shim container |
| `agent-vm` install fails with "Read-only file system" | Flatcar mounts `/usr` read-only | Install at `/opt/bin/agent-vm` (alongside `/opt/bin/runsc`) |
| `--runtime=runsc` fails: "unknown or invalid runtime name: runsc" | Fresh VM had no `/etc/docker/daemon.json` | Added it to `config.bu` so re-provisions inherit it declaratively |
| Sandbox cannot resolve `authproxy` despite being on `sandbox_net` | runsc's netstack doesn't reach Docker's embedded DNS at 127.0.0.11 | `agent-vm` looks up the shim's IP at launch time and passes `--add-host authproxy:<ip>` |
| `virsh domifaddr --source agent` returns `127.0.0.1` | Flatcar has no qemu-guest-agent; virsh returns the VM's lo address | `host/agent` and verify scripts filter `127.0.0.0/8` and fall through to the DHCP lease |
| `--connect qemu:///system` missing from `burn_it_down.sh` | The repo's libvirt URI is system, not user session | Added `--connect qemu:///system` and `--snapshots-metadata` |
| Bun-based sandbox image fails on launch with `EACCES: mkdir '/.local'` | `--user 1000:1000` overrides image's `USER`; if the image didn't bake a user with a home dir via `useradd -m`, `$HOME` defaults to `/` and any `~/.cache` write fails | `agent-vm` now passes `-e HOME=/work` so caches go into the writable bind-mount. Tradeoff: caches accumulate in the project dir; users add `.bun/`, `.npm/` etc. to `.gitignore` |

---

## Known limitations / future work

1. **No SNI-based egress filtering at the host.** UID 1500 can reach any HTTPS host. Tightening would require a userspace SNI filter (mitmproxy or sslh) or a per-process netns. Tracked.
2. **Strict forward-chain mode** is opt-in (commented out in `host/ai-fortress.nft`). Enabling it removes the VM's own internet access (breaks `docker pull` from inside the VM), and in return removes the relaxed-mode caveat in the threat model.
3. **runsc DNS** is bypassed via `--add-host`; if the shim's IP rotates (it doesn't in normal operation, but it could after `docker network prune`), `agent-vm` re-resolves it on each launch.
4. **No native VK TTL** in Bifrost. The sweeper enforces a soft 8h ceiling on a 5-minute cadence. A `kill -9` of a launcher leaks its VK for at most ~5 minutes.
5. **Bifrost UI** is reachable on `127.0.0.1:4000` and protected by basic-auth (`is_enabled: true`). It is not exposed to the LAN. Future work: bind it to a separate port and disable on prod hosts.
6. **Image pinning by digest** is in place for both `litellm/litellm` and `alpine/socat`, but `curlimages/curl` (used by the verify scripts) is tag-only. Verifier tests are not load-bearing for security; not pinning is acceptable.

---

## Glossary

- **Bifrost** — A Go-based LLM gateway from MaximHQ with native virtual-key governance, SQLite support, and Anthropic/OpenAI-compatible endpoints (`/anthropic/v1/messages`, `/openai/v1/chat/completions`). Replaced LiteLLM in this project because LiteLLM's bundled Prisma schema is PostgreSQL-only.
- **Virtual key (VK)** — A short-lived `sk-bf-*` token minted via Bifrost's governance API. Carries budget, rate limit, and provider scope.
- **`fortress-mint` / `-revoke` / `-sweep`** — Three root-owned helper scripts at `/usr/local/sbin/`. Sudoers gives the `fortress` group NOPASSWD on `mint` and `revoke`. The sweeper runs from a systemd timer.
- **vsock-shim** — A small `socat` container in the VM that bridges TCP traffic on `sandbox_net` to AF_VSOCK on the host. Trusted infrastructure (runs under runc, not runsc).
- **vsock-relay** — The host-side mirror of the shim. Bridges AF_VSOCK CID 2:4000 to `127.0.0.1:4000` (Bifrost).
- **`sandbox_net`** — A Docker bridge inside the VM created with `--internal`. The only thing reachable from a container on this bridge is other containers on the same bridge.
- **CID 42** — The VM's vsock connection ID. The host is always CID 2 (`VMADDR_CID_HOST`). Any number ≥ 3 unique on the host works for the guest.
