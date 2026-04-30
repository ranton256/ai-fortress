# AI Fortress

A defense-in-depth sandbox for running AI coding agents on a workstation. Five independent isolation boundaries between agent-generated code and your host.

## Why

AI agents like Claude Code and OpenCode execute shell commands and write files on your behalf. That means arbitrary code runs on your machine with your user's permissions. A hallucinated `rm -rf`, a compromised pip package, or a container-escape exploit could damage or exfiltrate anything your user account can touch — including secrets in `~/.ssh`, `~/.aws`, `~/.gnupg`, and unrelated projects.

Running an agent inside a single Docker container helps, but a container shares the host kernel. One privilege-escalation bug and the boundary is gone. AI Fortress puts five locks on the door, each independent of the others.

## What you get

| Layer | Boundary | Implemented by |
|------:|----------|----------------|
| 0 | Host process can't exfil upstream LLM credentials even if compromised | Bifrost LLM gateway, dedicated UID 1500, nftables `skuid` egress allowlist |
| 1 | Agent can't touch the host kernel | KVM virtual machine (Flatcar Container Linux), virtio-fs project mount |
| 2 | Persistent malware can't survive | Read-only `/usr` on Flatcar |
| 3 | Container escape doesn't yield real syscalls | gVisor (`runsc`) user-space kernel |
| 4 | Sandbox can't reach the public internet | Internal Docker bridge (`--internal`), vsock proxy is the only egress, per-session virtual key with $5/8h cap |

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full diagram, request flow walkthrough, security controls catalog, and threat model. Quick visual:

```
host shell  →  ~/bin/agent  →  fortress-mint (sudo)  →  sk-bf-...
                                                              │
                                                              ▼
                            ssh -t  …  VIRTUAL_KEY=sk-bf-…  /opt/bin/agent-vm
                                                              │
                                                              ▼
                                                   docker run --runtime=runsc
                                                              │
                          sandbox  ──TCP──>  authproxy:4000  (sandbox_net, --internal)
                                                              │
                                                              ▼
                                                       vsock-shim (runc)
                                                              │
                            ┌─────────────────────────────────┴────────────────────┐
                            │  AF_VSOCK CID 2:4000  (KVM-mediated, never on IP)    │
                            └─────────────────────────────────┬────────────────────┘
                                                              ▼
                                                       host vsock-relay (socat)
                                                              │
                                                              ▼
                                                    Bifrost on 127.0.0.1:4000
                                                              │
                                            HTTPS (allowed only for UID 1500 by nft)
                                                              ▼
                                                      api.anthropic.com
```

The novel pieces vs. a typical "just use a container" setup are layer 0 (the proxy keeps real upstream API keys off the VM entirely) and layer 4 (every sandbox session gets a fresh budget-capped virtual key, and the upstream key never enters the sandbox).

## Setup

### 1. Pre-flight

```bash
# VM snapshot + /etc backup so you can roll back
virsh -c qemu:///system snapshot-create-as ai-fortress pre-network-v2
sudo tar czf ~/ai-fortress-pre-v2.tgz /etc/nftables /etc/sysconfig/nftables.conf /etc/systemd/system /etc/sudoers.d
```

### 2. Host-side install

```bash
# Idempotently creates user/group, installs helpers, units, sudoers, nft fragment.
# Generates a Bifrost admin password automatically; leaves upstream API keys as
# REPLACE-ME placeholders for you to fill in.
sudo bash install-phase1.sh

# Edit /etc/ai-fortress/upstream.env and put real Anthropic + OpenAI keys in.
sudo $EDITOR /etc/ai-fortress/upstream.env

# Get fortress group active in your shell
newgrp fortress

# Activate services + load nft rules
sudo bash start-phase1.sh
```

### 3. VM provisioning

```bash
# Transpile config.bu → config.json (using butane container; install butane if you prefer)
docker run --rm -i --user "$(id -u):$(id -g)" quay.io/coreos/butane:release < config.bu > config.json
sudo install -m 0644 -o qemu -g qemu config.json /var/lib/libvirt/images/config.json

# Burn down any prior VM and re-provision (the new config.bu adds vsock kernel
# modules, sshd AcceptEnv, vsock-shim service, and runsc daemon.json)
bash burn_it_down.sh
bash do_virt_install.sh    # ctrl+] to detach console once it's running
```

### 4. Launchers

```bash
# host launcher
install -m 0755 host/agent ~/bin/agent

# in-VM launcher (requires VM to be reachable via SSH)
VM_IP=$(virsh -c qemu:///system -q domifaddr ai-fortress | awk '/ipv4/ {sub(/\/.*/,"",$NF); print $NF}')
scp vm/agent-vm "ranton@$VM_IP":/tmp/agent-vm
ssh "ranton@$VM_IP" 'sudo install -m 0755 /tmp/agent-vm /opt/bin/agent-vm && rm /tmp/agent-vm'
```

### 5. Verify

```bash
bash verify-phase1.sh   # 13 tests — host services
bash verify-phase2.sh   # 16 tests — VM-side vsock + shim
bash verify-phase3.sh   # 18 tests — launcher end-to-end + sandbox-side blocked paths
```

A green run on all three is the definition of "Phase complete."

## Usage

```bash
agent <project-folder-name> [python|default|<your-image>]
```

`agent` mints a per-session virtual key, SSHes into the VM, and starts a gVisor-trapped container scoped to `/projects/<project>`. The agent inside the container talks to `authproxy:4000` instead of `api.anthropic.com`; the sandbox has no other network egress. On exit, the virtual key is revoked. Stale keys (e.g. after `kill -9`) are reaped within ~5 minutes by the `ai-fortress-key-sweep.timer`.

### Image management

Two image variants are wired into `agent-vm` by default: `default` (`ghcr.io/anomalyco/opencode:latest`, pulled from a registry on first use) and `python` (`ai-fortress/python-dev:latest`, built from the local `Dockerfile.python`). For custom images, build on the host and push the image into the VM's Docker daemon — three helpers cover the common patterns:

```bash
# Re-build the python-dev image inside the VM (e.g. after a re-provision).
bash build_python_in_vm.sh

# Build any image on the host, then stream it into the VM's docker daemon
# via `docker save | ssh "docker load"` (no temp tarball on disk).
docker build -t my-custom:latest -f Dockerfile.foo \
  --build-arg USER_UID=$(id -u) \
  --build-arg USER_GID=$(id -g) \
  --build-arg USERNAME=$(whoami) .
bash push_image_to_vm.sh my-custom:latest
```

`agent <project> my-custom` then launches a sandbox using `my-custom:latest`. (You'll need a small case-statement edit in `vm/agent-vm` to map a friendly name like `worker` to your image — or just refer to the full tag.)

**HOME inside the sandbox.** `agent-vm` sets `HOME=/work` so cache directories created by the agent (Bun, npm, pip, etc.) end up under the project bind-mount. Add the relevant cache paths to your project's `.gitignore` if you don't want to commit them. If your image has a baked-in user with a proper home directory and you'd rather use that, override `HOME` from inside the image's entrypoint.

### Copying arbitrary files to the VM

For everything that isn't a Docker image (config snippets, build artifacts, dotfiles, etc.) there's `cp_to_vm.sh` — an `rsync`-based helper with `scp`-style calling convention:

```bash
bash cp_to_vm.sh notes.md /tmp/                   # single file
bash cp_to_vm.sh ./build /opt/myapp/              # directory, recursive
bash cp_to_vm.sh a.txt b.txt c.txt /home/ranton/  # many sources, one dest
```

Resolves the VM IP via `virsh` (filtering loopback), preserves perms/timestamps, and re-runs cheaply (only changed bytes are sent). For destinations that need root on the VM side, drop into `/tmp/` first and finish with `ssh ranton@<vm> 'sudo install ...'`.

## Reference

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — full as-built architecture, network flow, controls, threat model.
- [`network-test-plan.md`](network-test-plan.md) — 47-test verification suite.
- [`rollback.md`](rollback.md) — how to unwind safely by phase.
- [`network-plan.md`](network-plan.md) and [`network-plan-v2.md`](network-plan-v2.md) — design history (superseded by ARCHITECTURE.md).
- [`host/README-host-install.md`](host/README-host-install.md) — manual install steps if you don't want the script.

## Getting in and out of the VM

The `do_virt_install.sh` script attaches to the VM's serial console (`--graphics none`). To detach without stopping the VM, press **`Ctrl` + `]`**. To reattach: `virsh -c qemu:///system console ai-fortress`.

To shut the VM down gracefully: `virsh -c qemu:///system shutdown ai-fortress`. To force-stop (equivalent of pulling the power cord): `virsh -c qemu:///system destroy ai-fortress`. To remove the libvirt registration entirely (project files on the host are unaffected): see `burn_it_down.sh`.
