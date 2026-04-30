#!/bin/bash
# Phase 2 verification — runs on the host, SSHes into the freshly-provisioned VM.
# Exercises the A2-/B2- battery from network-test-plan.md.
set -u

VM_NAME="${FORTRESS_VM_NAME:-ai-fortress}"
VM_USER="${FORTRESS_VM_USER:-ranton}"

# Resolve VM IP via virsh (same as the launcher does)
resolve_vm_ip() {
  # Filter out 127.0.0.0/8 — when the qemu-guest-agent isn't running (e.g.
  # Flatcar), --source agent reports the VM's lo address which would steer
  # SSH at the host's own sshd. The DHCP-lease fallback gives the real IP.
  _filter='/ipv4/ {sub(/\/.*/,"",$NF); ip=$NF; if (ip !~ /^127\./) {print ip; exit}}'
  local tries=0 ip
  while (( tries < 30 )); do
    ip=$(virsh -c qemu:///system -q domifaddr --source agent "$VM_NAME" 2>/dev/null | awk "$_filter") || true
    if [[ -z "$ip" ]]; then
      ip=$(virsh -c qemu:///system -q domifaddr "$VM_NAME" 2>/dev/null | awk "$_filter") || true
    fi
    if [[ -z "$ip" ]]; then
      ip=$(virsh -c qemu:///system -q domifaddr --source lease "$VM_NAME" 2>/dev/null | awk "$_filter") || true
    fi
    if [[ -n "$ip" ]]; then printf '%s' "$ip"; return 0; fi
    sleep 1
    tries=$((tries+1))
  done
  return 1
}

VM_IP=$(resolve_vm_ip) || { echo "could not resolve $VM_NAME IP" >&2; exit 1; }
echo "VM_IP=$VM_IP  VM_USER=$VM_USER"

# Trust the new host key on first connection (we already cleared the old entry).
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/known_hosts" -o ServerAliveInterval=15)
sshvm() { ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"; }

PASS=0; FAIL=0
say() { printf '\n=== %s ===\n' "$*"; }
ok()  { printf 'OK   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }

# Wait for vsock-shim to come up (Docker has to pull alpine/socat on first boot).
say "Waiting for vsock-shim.service to be active…"
for _ in $(seq 1 60); do
  state=$(sshvm 'systemctl is-active vsock-shim 2>&1' 2>/dev/null || true)
  if [[ "$state" == "active" ]]; then break; fi
  sleep 2
done
echo "vsock-shim state = $state"

# -------------------------------------------------------------------------
say "A2-1: VM has vsock device in libvirt XML"
virsh -c qemu:///system dumpxml "$VM_NAME" | grep -q "<vsock " \
  && ok "vsock element present" || bad "no vsock element"
virsh -c qemu:///system dumpxml "$VM_NAME" | grep -E '<cid ' || true

say "A2-2: Guest vsock kernel modules loaded"
mods=$(sshvm 'lsmod | grep -E "^vsock|vmw_vsock_virtio|vhost_vsock"' 2>&1)
echo "$mods"
echo "$mods" | grep -q '^vsock' && ok "vsock module present" || bad "vsock module missing"

say "A2-3: /dev/vsock exists in VM"
sshvm 'test -c /dev/vsock' && ok "/dev/vsock present" || bad "/dev/vsock missing"

say "A2-4: sshd accepts VIRTUAL_KEY env"
out=$(sshvm 'cat /etc/ssh/sshd_config.d/10-ai-fortress.conf 2>&1')
echo "$out"
echo "$out" | grep -q 'AcceptEnv VIRTUAL_KEY' && ok "AcceptEnv present" || bad "AcceptEnv missing"

say "A2-5: vsock-shim is active"
[[ "$state" == "active" ]] && ok "vsock-shim active" || bad "vsock-shim state=$state"

say "A2-6: vsock-shim image is digest-pinned"
sshvm 'systemctl cat vsock-shim 2>&1 | grep -q "@sha256:"' \
  && ok "shim pinned by digest" || bad "shim not pinned"

say "A2-7: sandbox_net exists and is --internal"
internal=$(sshvm 'docker network inspect sandbox_net --format "{{.Internal}}" 2>&1')
echo "internal=$internal"
[[ "$internal" == "true" ]] && ok "sandbox_net is internal" || bad "sandbox_net not internal"

say "A2-8: Guest reaches host over vsock (CID 2:4000)"
out=$(sshvm 'docker run --rm --device /dev/vsock --security-opt seccomp=unconfined alpine/socat -u - VSOCK-CONNECT:2:4000 </dev/null 2>&1')
ec=$?
echo "$out" | head -5
[[ $ec -eq 0 ]] && ok "vsock reachable" || bad "vsock unreachable (exit=$ec)"

say "A2-9: sandbox_net resolves authproxy and gets /health"
out=$(sshvm 'docker run --rm --network sandbox_net curlimages/curl curl -fsS --max-time 10 http://authproxy:4000/health 2>&1')
echo "$out" | head -3
echo "$out" | grep -q '"status":"ok"' && ok "authproxy /health ok via shim" || bad "authproxy /health failed"

say "A2-10: Anthropic route reachable from sandbox_net (no auth → 401)"
code=$(sshvm 'docker run --rm --network sandbox_net curlimages/curl curl -isS -o /dev/null -w "%{http_code}" --max-time 10 -X POST http://authproxy:4000/anthropic/v1/messages -H content-type:application/json -d "{}" 2>&1' | tail -c 4)
echo "code=$code"
[[ "$code" =~ ^(401|403|500)$ ]] && ok "route reachable (code=$code)" || bad "unexpected code $code"

# -------------------------------------------------------------------------
say "B2-1: sandbox_net cannot reach internet"
out=$(sshvm 'docker run --rm --network sandbox_net curlimages/curl curl --max-time 5 https://example.com 2>&1' || true)
echo "$out" | head -3
echo "$out" | grep -qE 'Could not resolve|Failed to connect|timed out' \
  && ok "internet blocked" || bad "internet reachable from sandbox_net"

say "B2-2: sandbox_net cannot resolve public DNS"
out=$(sshvm 'docker run --rm --network sandbox_net curlimages/curl getent hosts api.anthropic.com 2>&1' || true)
echo "$out" | head -3
[[ -z "$(echo "$out" | grep -E '^[0-9]')" ]] && ok "DNS blocked" || bad "DNS resolves on sandbox_net"

say "B2-3: sandbox_net cannot reach virbr0 gateway (192.168.124.1)"
out=$(sshvm 'docker run --rm --network sandbox_net curlimages/curl curl --max-time 3 http://192.168.124.1/ 2>&1' || true)
echo "$out" | head -3
echo "$out" | grep -qE 'Failed to connect|timed out|host unreachable' \
  && ok "virbr0 gateway blocked" || bad "virbr0 gateway reachable"

say "B2-4: sandbox_net cannot reach VM loopback"
out=$(sshvm 'docker run --rm --network sandbox_net curlimages/curl curl --max-time 3 http://127.0.0.1:4000/health 2>&1' || true)
echo "$out" | head -3
echo "$out" | grep -qE 'Failed to connect|timed out|Connection refused' \
  && ok "VM loopback unreachable from sandbox_net" || bad "VM loopback reachable"

say "B2-5: shim does NOT run under runsc"
runtime=$(sshvm 'docker inspect vsock-shim --format "{{.HostConfig.Runtime}}"' 2>&1)
echo "runtime=$runtime"
[[ "$runtime" != "runsc" ]] && ok "shim runs under $runtime (not runsc)" || bad "shim is under runsc"

say "B2-6: sandbox container cannot access /dev/vsock"
out=$(sshvm 'docker run --rm --network sandbox_net alpine ls /dev/vsock 2>&1' || true)
echo "$out"
echo "$out" | grep -qE 'No such file|cannot access' \
  && ok "/dev/vsock not exposed to sandbox" || bad "/dev/vsock leaked into sandbox"

# -------------------------------------------------------------------------
echo
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
