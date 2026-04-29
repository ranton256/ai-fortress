# AI Fortress: Network v2 Verification Plan

Companion doc to `network-plan-v2.md`. Goal: catch regressions early as the network proxy is rolled in. Three classes of test:

- **R** — Regression: current sandbox features that have nothing to do with networking. These must keep passing through every phase.
- **A** — Allowed: things that should work *over the network* once each phase is deployed.
- **B** — Blocked: things that *must not* work, at any phase.

If a test ever flips state between phases, stop and investigate before continuing.

## How to use this doc

1. Snapshot first (see "Pre-flight"). The implementation touches secrets files, systemd units, nftables, libvirt XML, and the Flatcar Ignition config. Anything in there can brick the workstation or VM.
2. Implement in phases. After each phase, run **R** in full plus the **A** and **B** tests marked for that phase.
3. Treat any FAIL on **R** as a stop-the-line event — the v2 plan should not break what works today.
4. Treat any FAIL on **B** as a security regression — the proxy is leaking.

Conventions used below:

- `$VM_IP`, `$VM_USER` — set as the launcher does:
  ```bash
  VM_IP=$(virsh -c qemu:///system -q domifaddr --source agent ai-fortress \
          | awk '/ipv4/ {sub(/\/.*/,"",$NF); print $NF; exit}')
  [[ -z "$VM_IP" ]] && VM_IP=$(virsh -c qemu:///system -q domifaddr ai-fortress \
          | awk '/ipv4/ {sub(/\/.*/,"",$NF); print $NF; exit}')
  VM_USER="${FORTRESS_VM_USER:-$USER}"
  ```
- `PASS` = command exits 0 and output contains the expected token (when given).
- `FAIL` = anything else.
- Tests assume **relaxed forward-chain mode** (the v2 default). Strict-mode tests are flagged separately.
- All tests are read-only or self-cleaning except where noted.

## Pre-flight: baseline and rollback

Before touching anything, capture the working state.

| ID    | Intent                                  | Command                                                                         | Expected                                              |
|-------|-----------------------------------------|---------------------------------------------------------------------------------|-------------------------------------------------------|
| PF-1  | VM snapshot exists                      | `virsh -c qemu:///system snapshot-create-as ai-fortress pre-network-v2`         | snapshot created                                      |
| PF-2  | Host config backed up                   | `sudo tar czf ~/ai-fortress-pre-v2.tgz /etc/nftables /etc/systemd/system /etc/sudoers.d 2>/dev/null` | tarball exists, non-empty               |
| PF-3  | Current `agent-up` still works          | run a sandbox via existing `agent-up test-project` and exit cleanly              | sandbox launches, `/work` is writable                |
| PF-4  | Capture current sandbox env             | inside the existing sandbox: `env \| grep -E 'API_KEY\|BASE_URL'`               | record the variables for later comparison             |
| PF-5  | Capture current LLM call (smoke)        | inside existing sandbox: a known-working API call                               | one successful completion (proves baseline)           |

Rollback: `virsh snapshot-revert ai-fortress pre-network-v2 && sudo tar xzf ~/ai-fortress-pre-v2.tgz -C /` and reload services.

---

## Regression suite (R) — run after every phase

These check that the parts of the sandbox unrelated to network changes have not been disturbed. Run all of them after Phase 1, Phase 2, and Phase 3.

| ID   | Intent                                    | Command                                                                                                                          | Expected                                                                                |
|------|-------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------|
| R-1  | Host docker daemon healthy                | `systemctl is-active docker`                                                                                                     | `active`                                                                                |
| R-2  | libvirt domain is running                 | `virsh -c qemu:///system list --state-running \| grep ai-fortress`                                                               | one match                                                                               |
| R-3  | VM is SSH-reachable                       | `ssh "$VM_USER@$VM_IP" true`                                                                                                     | exits 0                                                                                 |
| R-4  | virtiofs `/projects` is mounted in VM     | `ssh "$VM_USER@$VM_IP" 'mountpoint -q /projects && ls /projects'`                                                                | exits 0, lists project dirs                                                             |
| R-5  | VM `/projects` ownership matches host UID | `ssh "$VM_USER@$VM_IP" 'stat -c "%u %g" /projects/test-project'` and compare to `stat -c "%u %g" ~/projects/test-project`        | values match                                                                            |
| R-6  | gVisor binary present and runnable        | `ssh "$VM_USER@$VM_IP" '/opt/bin/runsc --version'`                                                                               | prints a version                                                                        |
| R-7  | gVisor registered as docker runtime       | `ssh "$VM_USER@$VM_IP" 'docker info --format "{{.Runtimes}}" \| grep runsc'`                                                     | match                                                                                   |
| R-8  | Sandbox can launch under runsc            | `ssh "$VM_USER@$VM_IP" 'docker run --rm --runtime=runsc alpine uname -a'`                                                        | prints kernel info; no error                                                            |
| R-9  | Sandbox can write into `/work`            | inside an `agent <project>` shell: `touch /work/.touchtest && rm /work/.touchtest`                                              | exits 0                                                                                 |
| R-10 | Python sandbox image still launches       | `agent test-project python` and `python --version` inside                                                                        | python prints version                                                                   |
| R-11 | Default sandbox image still launches      | `agent test-project` and confirm the opencode image starts                                                                       | shell prompt available                                                                  |
| R-12 | `burn_it_down.sh` parse-checks            | `bash -n burn_it_down.sh`                                                                                                        | exits 0 (don't actually run it during testing)                                          |
| R-13 | Host has no unexpected listeners          | `sudo ss -ltnp \| grep -v 127.0.0.1 \| grep -v '\[::1\]'`                                                                        | nothing on a non-loopback IP that wasn't there in PF (compare to baseline `ss` output)  |

R-13 is the load-bearing check that v2 didn't accidentally bind a TCP port on `0.0.0.0` or on virbr0 — a goal of the design.

---

## Phase 1 — Host services (LiteLLM, relay, helpers, nft)

After deploying the LiteLLM unit, vsock relay, helper scripts, sudoers, and nftables fragment.

### Phase 1 allowed (A)

| ID    | Intent                                          | Command                                                                                              | Expected                                            |
|-------|-------------------------------------------------|------------------------------------------------------------------------------------------------------|-----------------------------------------------------|
| A1-1  | socat is recent enough                          | `socat -V \| head -1 \| awk '{print $3}'`                                                            | ≥ 1.7.4                                             |
| A1-2  | LiteLLM container is running                    | `docker ps --filter name=ai-fortress-litellm --format '{{.Status}}'`                                 | starts with `Up`                                    |
| A1-3  | LiteLLM container runs as UID 1500              | `docker inspect ai-fortress-litellm --format '{{.Config.User}}'`                                     | `1500:1500`                                         |
| A1-4  | LiteLLM image is digest-pinned                  | `grep '@sha256:' /etc/systemd/system/ai-fortress-litellm.service`                                    | one match                                           |
| A1-5  | LiteLLM `/health` responds on loopback          | `curl -fsS http://127.0.0.1:4000/health`                                                             | JSON, status ok                                     |
| A1-6  | Anthropic-compat route exists                   | `curl -isS -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:4000/v1/messages -H 'content-type: application/json' -d '{}'` | `401` (route is wired; auth missing)                |
| A1-7  | OpenAI-compat route exists                      | `curl -isS -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:4000/v1/chat/completions -H 'content-type: application/json' -d '{}'`   | `401`                                               |
| A1-8  | vsock relay unit is active                      | `systemctl is-active ai-fortress-vsock-relay`                                                        | `active`                                            |
| A1-9  | vsock listener is bound                         | `sudo ss -lx \| grep -i vsock`                                                                       | one match on port 4000                              |
| A1-10 | Mint helper produces a virtual key              | `sudo -n /usr/local/sbin/fortress-mint smoke $$ "$(awk '{print $22}' /proc/$$/stat)"`                | prints `sk-...`                                     |
| A1-11 | Revoke helper deletes the key                   | `sudo -n /usr/local/sbin/fortress-revoke <key from A1-10>`                                           | exits 0                                             |
| A1-12 | Real upstream call via master key works         | `curl -fsS -H "Authorization: Bearer $(sudo grep ^LITELLM_MASTER /etc/ai-fortress/upstream.env \| cut -d= -f2-)" -X POST http://127.0.0.1:4000/v1/messages -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}'` (run this from a root shell so the user shell never sees the master key) | JSON response with `content` array              |
| A1-13 | LiteLLM as UID 1500 can reach :443              | `sudo -u litellm -- curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://api.anthropic.com/`  | non-zero HTTP code (proves the connection completed); not `000` |
| A1-14 | Sweeper unit + timer enabled                    | `systemctl is-enabled ai-fortress-key-sweep.timer`                                                   | `enabled`                                           |
| A1-15 | Sweeper revokes orphan keys                     | mint a key with PID=`99999999` (a nonexistent PID) and start-ns `1`, then run `sudo /usr/local/sbin/fortress-sweep`, then list keys | the synthetic key is gone                           |

### Phase 1 blocked (B)

| ID    | Intent                                          | Command                                                                                              | Expected                                                |
|-------|-------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------|
| B1-1  | LiteLLM is not bound on a non-loopback IP       | `sudo ss -ltnp \| grep ':4000' \| grep -v '127.0.0.1'`                                               | empty                                                   |
| B1-2  | LiteLLM as UID 1500 cannot reach :80            | `sudo -u litellm -- curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://example.com/`        | `000` (connection refused/dropped)                      |
| B1-3  | LiteLLM as UID 1500 cannot reach :22            | `sudo -u litellm -- timeout 3 bash -c 'cat </dev/tcp/93.184.215.14/22' ; echo $?`                    | non-zero exit                                           |
| B1-4  | Other UIDs are unaffected (relaxed mode)        | `curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://example.com/`                           | `2xx`/`3xx` (your shell still has internet)             |
| B1-5  | Master key never enters user shell environ      | `agent test-project &` (let it start), then on host `cat /proc/$!/environ \| tr '\0' '\n' \| grep -i litellm_master` | empty                                                   |
| B1-6  | `master-key.env` does not exist                 | `sudo test ! -f /etc/ai-fortress/master-key.env && echo OK`                                          | `OK` (v1's duplicate file should not be present)        |
| B1-7  | upstream.env is root-only                       | `stat -c '%a %U:%G' /etc/ai-fortress/upstream.env`                                                   | `600 root:root`                                         |
| B1-8  | Sudoers grants only the two helpers             | `sudo grep -h fortress /etc/sudoers.d/ai-fortress`                                                   | matches `fortress-mint, fortress-revoke` and nothing else |
| B1-9  | Mint helper rejects bad project names           | `sudo -n /usr/local/sbin/fortress-mint 'foo;rm -rf /' 1 1`                                           | exits non-zero with "bad project name"                  |
| B1-10 | Mint helper rejects non-numeric PID             | `sudo -n /usr/local/sbin/fortress-mint smoke abc 1`                                                  | exits non-zero with "bad pid"                           |
| B1-11 | Anthropic call without virtual key fails        | `curl -fsS -X POST http://127.0.0.1:4000/v1/messages -H 'content-type: application/json' -d '{}'`     | non-zero exit (401)                                     |
| B1-12 | Revoked key is no longer usable                 | revoke a freshly minted key, then call `/v1/messages` with it                                        | 401                                                     |
| B1-13 | Master key not in sudoer-script's process tree on idle | `pgrep -af fortress-`                                                                          | empty unless mid-mint/revoke                             |

A1-12 deliberately runs as root. If you find yourself sourcing the master key into a non-root shell to test it, **stop** — that defeats the master-key isolation property the design depends on.

---

## Phase 2 — VM services (vsock device, shim, sshd dropin)

After updating libvirt XML, re-provisioning the VM (or hot-installing the shim unit + sshd dropin), and rebooting.

### Phase 2 allowed (A)

| ID    | Intent                                          | Command                                                                                                                  | Expected                                          |
|-------|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------|
| A2-1  | VM has vsock device                             | `virsh -c qemu:///system dumpxml ai-fortress \| grep -A1 '<vsock'`                                                       | `<cid auto='no' address='42'/>`                   |
| A2-2  | Guest vsock kernel modules loaded               | `ssh "$VM_USER@$VM_IP" 'lsmod \| grep -E "^vsock\|vmw_vsock_virtio"'`                                                    | both modules present                              |
| A2-3  | `/dev/vsock` exists in VM                       | `ssh "$VM_USER@$VM_IP" 'test -c /dev/vsock && echo OK'`                                                                  | `OK`                                              |
| A2-4  | sshd accepts `VIRTUAL_KEY` env                  | `grep -r AcceptEnv /etc/ssh/sshd_config.d/` on the VM via SSH                                                            | `AcceptEnv VIRTUAL_KEY`                           |
| A2-5  | vsock-shim unit is active                       | `ssh "$VM_USER@$VM_IP" 'systemctl is-active vsock-shim'`                                                                 | `active`                                          |
| A2-6  | vsock-shim image is digest-pinned               | `ssh "$VM_USER@$VM_IP" 'systemctl cat vsock-shim \| grep "@sha256:"'`                                                    | one match                                         |
| A2-7  | sandbox_net exists and is internal              | `ssh "$VM_USER@$VM_IP" 'docker network inspect sandbox_net --format "{{.Internal}}"'`                                    | `true`                                            |
| A2-8  | Guest can reach host over vsock                 | `ssh "$VM_USER@$VM_IP" 'docker run --rm --device /dev/vsock alpine/socat -u - VSOCK-CONNECT:2:4000 <<<""'`               | exits 0                                           |
| A2-9  | sandbox_net resolves `authproxy`                | `ssh "$VM_USER@$VM_IP" 'docker run --rm --network sandbox_net curlimages/curl curl -fsS http://authproxy:4000/health'`   | JSON, status ok                                   |
| A2-10 | Anthropic route reachable from sandbox_net      | `ssh "$VM_USER@$VM_IP" 'docker run --rm --network sandbox_net curlimages/curl curl -isS -o /dev/null -w "%{http_code}\n" -X POST http://authproxy:4000/v1/messages -H content-type:application/json -d {}'` | `401`                                             |

### Phase 2 blocked (B)

| ID    | Intent                                          | Command                                                                                                                  | Expected                                                 |
|-------|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------|
| B2-1  | sandbox_net containers cannot reach internet    | `ssh "$VM_USER@$VM_IP" 'docker run --rm --network sandbox_net curlimages/curl curl --max-time 5 https://example.com'`    | non-zero exit                                            |
| B2-2  | sandbox_net cannot resolve public DNS           | `ssh "$VM_USER@$VM_IP" 'docker run --rm --network sandbox_net curlimages/curl getent hosts api.anthropic.com'`           | empty / non-zero                                         |
| B2-3  | sandbox_net cannot reach virbr0 gateway         | `ssh "$VM_USER@$VM_IP" 'docker run --rm --network sandbox_net curlimages/curl curl --max-time 3 http://192.168.122.1/'`  | non-zero (replace IP with your virbr0 gateway)           |
| B2-4  | sandbox_net cannot reach VM host loopback       | `ssh "$VM_USER@$VM_IP" 'docker run --rm --network sandbox_net curlimages/curl curl --max-time 3 http://127.0.0.1:4000/health'` | non-zero (no host-net access from sandbox_net containers) |
| B2-5  | shim does NOT run under runsc                   | `ssh "$VM_USER@$VM_IP" 'docker inspect vsock-shim --format "{{.HostConfig.Runtime}}"'`                                   | `runc` (or empty / default) — not `runsc`                |
| B2-6  | sandbox containers cannot get `/dev/vsock`      | inside an `agent` sandbox: `ls /dev/vsock`                                                                               | "No such file or directory"                              |
| B2-7  | LiteLLM is not reachable directly via vsock for sandbox containers without going through the shim | inside a sandbox: `cat </dev/vsock` (or any direct attempt)                                                              | error (no vsock device exposed)                          |
| B2-8  | Other sandbox containers' env not visible       | from sandbox A: `docker ps` (should fail — no docker socket in sandbox)                                                 | "permission denied" or "command not found"               |

B2-4 is the one most likely to surprise you — confirm it explicitly. The threat model depends on it.

---

## Phase 3 — Launcher end-to-end (`agent`, `agent-vm`)

After dropping `~/bin/agent` and `/usr/local/bin/agent-vm` into place.

### Phase 3 allowed (A)

| ID    | Intent                                          | Command                                                                                                                              | Expected                                                                |
|-------|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| A3-1  | Launcher runs without master-key.env            | `~/bin/agent test-project` (with `master-key.env` absent)                                                                            | sandbox launches                                                        |
| A3-2  | Launcher tolerates VM cold start                | `virsh shutdown ai-fortress`, wait, `virsh start ai-fortress`, then immediately run `~/bin/agent test-project`                        | succeeds within ~20s; no "could not resolve" error                      |
| A3-3  | `VIRTUAL_KEY` is in sandbox env                 | inside the sandbox: `env \| grep -E '^(ANTHROPIC\|OPENAI)_API_KEY'`                                                                  | both set, value starts with `sk-`                                       |
| A3-4  | `BASE_URL`s point at the shim                   | inside the sandbox: `env \| grep BASE_URL`                                                                                           | `ANTHROPIC_BASE_URL=http://authproxy:4000`, `OPENAI_BASE_URL=http://authproxy:4000/v1` |
| A3-5  | Anthropic completion succeeds end-to-end        | inside the sandbox: `curl -fsS http://authproxy:4000/v1/messages -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d '{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}'` | JSON with `content` array                                               |
| A3-6  | Streaming SSE works                             | same as A3-5 but with `"stream": true`                                                                                               | token-by-token output, `event: message_stop` at end                     |
| A3-7  | OpenAI-style call works (if OPENAI key configured) | inside the sandbox: a `chat/completions` call against `http://authproxy:4000/v1/chat/completions`                                | 200, JSON                                                               |
| A3-8  | Two concurrent sandboxes work                   | run `agent foo` and `agent bar` in different terminals, make a completion in each                                                    | both succeed; LiteLLM `/key/info` shows two distinct keys               |
| A3-9  | Key revoke on launcher exit                     | mint via launcher, exit with Ctrl-D, then check `/key/info` for that key                                                             | not present                                                             |
| A3-10 | Orphan sweep covers `kill -9`                   | `agent foo` → grab key from sandbox env → host `kill -9` the launcher PID → wait for next sweep tick → `/key/info`                   | the orphaned key is revoked within ~5 min                               |
| A3-11 | Project tag attaches to virtual key             | mint via launcher, then `curl /key/info` and look at `metadata.project`                                                              | matches the project arg                                                 |

### Phase 3 blocked (B)

| ID    | Intent                                          | Command                                                                                                                              | Expected                                                                |
|-------|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------|
| B3-1  | Sandbox cannot reach Anthropic directly         | inside the sandbox: `curl --max-time 5 https://api.anthropic.com/v1/messages` (with no override)                                     | non-zero exit (DNS or routing failure)                                  |
| B3-2  | Sandbox cannot reach generic internet           | inside the sandbox: `curl --max-time 5 https://example.com/`                                                                         | non-zero exit                                                           |
| B3-3  | Virtual key has bounded budget                  | inside the sandbox, run completions in a loop until rejection                                                                        | eventually 429 / `budget exceeded`; not unlimited                       |
| B3-4  | Virtual key rejected by upstream after revoke   | revoke the key from another shell, then make a request inside the sandbox                                                            | 401                                                                     |
| B3-5  | Virtual key cannot list/manage other keys       | inside the sandbox: `curl -H "Authorization: Bearer $ANTHROPIC_API_KEY" http://authproxy:4000/key/info`                              | non-2xx                                                                 |
| B3-6  | Virtual key cannot mint new keys                | inside the sandbox: `curl -X POST -H "Authorization: Bearer $ANTHROPIC_API_KEY" http://authproxy:4000/key/generate -d '{}'`          | non-2xx                                                                 |
| B3-7  | `VIRTUAL_KEY` not in `ps` output                | from another VM shell during a session: `ps auxe \| grep -i virtual_key`                                                             | no command-line containing the key                                      |
| B3-8  | Upstream API keys are not in the sandbox env    | inside the sandbox: `env \| grep -i upstream`                                                                                        | empty                                                                   |
| B3-9  | Upstream API keys are not in any sandbox file   | inside the sandbox: `grep -r 'sk-ant-\|ANTHROPIC_UPSTREAM' / 2>/dev/null \| head`                                                    | empty                                                                   |
| B3-10 | Master key is not in any sandbox file           | inside the sandbox: `grep -r 'LITELLM_MASTER\|sk-master' / 2>/dev/null \| head`                                                      | empty                                                                   |
| B3-11 | Sandbox cannot pivot to host loopback           | inside the sandbox: `curl --max-time 3 http://127.0.0.1:4000/health` (note: this is the *VM's* loopback, not the host's, but should also fail because sandbox_net is internal) | non-zero                                                                |

B3-3 is worth running deliberately at least once before relying on the budget cap. Set `max_budget` to something tiny (e.g. `0.05`) for a test mint, run a few completions, confirm the cap fires, then return the helper to its normal value.

---

## Lifecycle / robustness suite

Run this suite once at the end of Phase 3 and any time the helpers, sweeper, or LiteLLM unit changes.

| ID    | Intent                                          | Procedure                                                                                                                            | Pass criterion                                          |
|-------|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------|
| L-1   | LiteLLM survives restart                        | `sudo systemctl restart ai-fortress-litellm` while a sandbox is idle                                                                  | sandbox's next request succeeds (after a brief pause)   |
| L-2   | vsock relay survives restart                    | `sudo systemctl restart ai-fortress-vsock-relay` mid-stream                                                                          | new requests succeed; in-flight stream may drop (acceptable) |
| L-3   | VM reboot recovers cleanly                      | `virsh reboot ai-fortress`, wait, run `agent test-project`                                                                            | sandbox reaches `authproxy` on first try                |
| L-4   | Host reboot recovers cleanly                    | reboot host, run `agent` after login                                                                                                  | succeeds without manual intervention                    |
| L-5   | Launcher SIGKILL leaves no live key after sweep | `kill -9` the launcher; wait one sweep tick; check `/key/info`                                                                       | the key is gone                                         |
| L-6   | Many concurrent sandboxes (smoke)               | launch 5 sandboxes, each makes 10 sequential completions                                                                              | all succeed; no socat fork issues; no relay errors      |
| L-7   | nft rule reload is idempotent                   | `sudo systemctl reload nftables` twice                                                                                               | both reloads succeed; rule still in effect (re-run B1-2) |
| L-8   | `burn_it_down.sh` does not break host services  | (only run in a disposable session) verify host LiteLLM/vsock-relay still active afterwards                                            | both `active`                                           |

L-8 is destructive — only run once, deliberately, after confirming you have a snapshot.

## Strict-mode-only tests (skip in relaxed mode)

If you've enabled the strict forward-chain rule (`iifname virbr0 oifname != virbr0 drop`), add these:

| ID    | Intent                                          | Command                                                                                                                              | Expected                                                |
|-------|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------|
| S-1   | VM userspace cannot reach internet              | `ssh "$VM_USER@$VM_IP" 'curl --max-time 5 https://example.com'`                                                                      | non-zero                                                |
| S-2   | VM userspace can still reach the host loopback over vsock (the proxy path) | A2-8 still passes                                                                                                | exits 0                                                 |
| S-3   | Image refresh is automated outside the VM       | document the refresh procedure; run it once                                                                                          | a stale image rebuild succeeds                          |

If S-1 fails (VM still has internet), the forward rule isn't active — `nft list ruleset | grep -A5 forward`.

## Cross-cutting checks (run anytime)

These don't fit in a phase, but should pass at all times after the rollout completes.

| ID    | Intent                                          | Command                                                                                                                              | Expected                                                |
|-------|-------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------|
| X-1   | nftables ruleset loaded                         | `sudo nft list table inet ai_fortress`                                                                                               | shows the chain with `meta skuid 1500` rules             |
| X-2   | LiteLLM config doesn't accidentally log keys    | `sudo grep -i 'set_verbose' /etc/ai-fortress/litellm-config.yaml`                                                                    | `set_verbose: false`                                    |
| X-3   | LiteLLM DB is mode 0750 root-or-1500 readable   | `sudo stat -c '%a %U:%G' /var/lib/ai-fortress`                                                                                       | `0750 …:…` with owner UID 1500                          |
| X-4   | sudoers file passes `visudo -c`                 | `sudo visudo -c -f /etc/sudoers.d/ai-fortress`                                                                                       | "parsed OK"                                             |
| X-5   | All systemd units start at boot                 | `systemctl is-enabled ai-fortress-litellm ai-fortress-vsock-relay ai-fortress-key-sweep.timer`                                       | all `enabled`                                           |
| X-6   | No upstream API keys present in VM              | `ssh "$VM_USER@$VM_IP" 'sudo grep -rsE "sk-ant-\|sk-proj-\|sk-master" /etc /root /home 2>/dev/null'`                                 | empty                                                   |
| X-7   | `agent-up` (legacy) is gone or marked deprecated | `head -3 ~/bin/agent-up 2>/dev/null` or `ls -l ~/bin/agent-up`                                                                       | missing, or first lines mention deprecation             |

## Sign-off checklist

Before declaring v2 done:

- [ ] All R-tests pass after every phase.
- [ ] All A-tests pass for the relevant phase.
- [ ] All B-tests pass (i.e., correctly block) for the relevant phase.
- [ ] L-1 through L-7 pass.
- [ ] X-1 through X-7 pass.
- [ ] PF-3 (legacy `agent-up`) parity: a session via `agent` is functionally equivalent to a session via the old `agent-up`, minus the upstream-key passthrough.
- [ ] One real working day spent using the new flow without falling back to `agent-up`.
- [ ] One deliberate budget-cap test (B3-3) was actually executed (not just read).
- [ ] One deliberate kill-9 orphan-sweep test (L-5) was actually executed.
- [ ] PF-2 backup tarball is filed somewhere durable; the snapshot from PF-1 is retained for at least a week post-rollout.

The last two bullets matter — the budget cap and the orphan sweep are the only two things between "leaked virtual key" and "real money / real exposure". Read-only confirmation isn't enough.
