#!/bin/bash
# Phase 3 verification — installs the launchers, then exercises A3-/B3-.
# Sidesteps SSH+docker quoting issues by passing all values via -e env vars
# and running a single `sh -c` inside the sandbox.
set -u

VM_NAME="${FORTRESS_VM_NAME:-ai-fortress}"
VM_USER="${FORTRESS_VM_USER:-ranton}"
_filter='/ipv4/ {sub(/\/.*/,"",$NF); ip=$NF; if (ip !~ /^127\./) {print ip; exit}}'
VM_IP=$(virsh -c qemu:///system -q domifaddr "$VM_NAME" 2>/dev/null | awk "$_filter")
[[ -z "$VM_IP" ]] && { echo "could not resolve VM IP" >&2; exit 1; }
echo "VM_IP=$VM_IP  VM_USER=$VM_USER"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15)
sshvm() { ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"; }

PASS=0; FAIL=0
say() { printf '\n=== %s ===\n' "$*"; }
ok()  { printf 'OK   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# -------------------------------------------------------------------------
say "Install: ~/bin/agent on host"
mkdir -p "$HOME/bin"
install -m 0755 "$REPO_DIR/host/agent" "$HOME/bin/agent"
ls -l "$HOME/bin/agent" >/dev/null && ok "host launcher installed" || bad "install failed"

say "Install: /opt/bin/agent-vm in VM"
scp "${SSH_OPTS[@]}" "$REPO_DIR/vm/agent-vm" "$VM_USER@$VM_IP":/tmp/agent-vm >/dev/null
sshvm 'sudo install -m 0755 /tmp/agent-vm /opt/bin/agent-vm && rm /tmp/agent-vm' \
  && ok "agent-vm installed" || bad "agent-vm install failed"

sudo -v || { echo "sudo unavailable"; exit 1; }

# -------------------------------------------------------------------------
say "Setup: mint a VK for the test sandbox"
LSTART=$(awk '{print $22}' /proc/$$/stat)
TEST_VK=$(sudo -n /usr/local/sbin/fortress-mint phase3-test "$$" "$LSTART")
if [[ "$TEST_VK" =~ ^sk-bf- ]]; then
  ok "minted ${TEST_VK:0:14}..."
else
  bad "mint failed: $TEST_VK"; exit 1
fi
trap 'sudo -n /usr/local/sbin/fortress-revoke "$TEST_VK" 2>/dev/null || true' EXIT

# Helpers --------------------------------------------------------------------
# Run a single shell command inside a sandbox container that mirrors agent-vm
# (runsc, sandbox_net, label disable, base URLs + VK env). Args are env=value
# pairs followed by '--' then the sh -c command.
SHIM_IP=$(sshvm 'docker inspect vsock-shim --format "{{ range .NetworkSettings.Networks }}{{ .IPAddress }}{{ end }}"')
echo "SHIM_IP=$SHIM_IP"

sandbox_sh() {
  local envs=() cmd="" extra_env=""
  while (( $# )); do
    if [[ "$1" == "--" ]]; then shift; cmd="$1"; break; fi
    envs+=( -e "$1" )
    shift
  done
  if (( ${#envs[@]} > 0 )); then
    extra_env=$(printf '%q ' "${envs[@]}")
  fi
  sshvm "docker run --rm --runtime=runsc --network sandbox_net \
    --add-host authproxy:$SHIM_IP \
    --security-opt label=disable \
    -e ANTHROPIC_BASE_URL=http://authproxy:4000/anthropic \
    -e OPENAI_BASE_URL=http://authproxy:4000/openai/v1 \
    -e ANTHROPIC_API_KEY=$TEST_VK \
    -e OPENAI_API_KEY=$TEST_VK \
    $extra_env \
    curlimages/curl sh -c $(printf '%q' "$cmd")"
}

# -------------------------------------------------------------------------
say "A3-3+A3-4: env shape inside the sandbox"
out=$(sandbox_sh -- 'env | grep -E "^(ANTHROPIC|OPENAI)_(BASE_URL|API_KEY)="')
echo "$out"
echo "$out" | grep -q 'ANTHROPIC_BASE_URL=http://authproxy:4000/anthropic' && ok "ANTHROPIC_BASE_URL set" || bad "ANTHROPIC_BASE_URL wrong"
echo "$out" | grep -q "ANTHROPIC_API_KEY=$TEST_VK" && ok "ANTHROPIC_API_KEY set" || bad "ANTHROPIC_API_KEY wrong"
echo "$out" | grep -q 'OPENAI_BASE_URL=http://authproxy:4000/openai/v1' && ok "OPENAI_BASE_URL set" || bad "OPENAI_BASE_URL wrong"

# -------------------------------------------------------------------------
say "A3-5: real Anthropic completion via the full sandbox path"
BODY='{"model":"claude-sonnet-4-6","max_tokens":15,"messages":[{"role":"user","content":"hi"}]}'
resp=$(sandbox_sh "BODY=$BODY" -- '
  curl -sS --max-time 30 \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -X POST "$ANTHROPIC_BASE_URL/v1/messages" \
    -d "$BODY"
')
echo "$resp" | head -c 400; echo
if echo "$resp" | jq -e '.content[0].text' >/dev/null 2>&1; then
  ok "got real completion"
elif echo "$resp" | jq -e '.error.type == "invalid_request_error" and (.error.message | test("usage limits|rate limit|quota"; "i"))' >/dev/null 2>&1; then
  ok "auth chain reached upstream (Anthropic billing/quota error — proves plumbing)"
else
  bad "unexpected response shape"
fi

# -------------------------------------------------------------------------
say "A3-6: streaming SSE works"
sb=$(sandbox_sh "BODY=$(echo "$BODY" | jq -c '. + {stream: true}')" -- '
  curl -sS --max-time 30 -N \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -X POST "$ANTHROPIC_BASE_URL/v1/messages" \
    -d "$BODY"
')
echo "$sb" | head -c 300; echo
echo "$sb" | grep -qE '^event:|^data:' && ok "got SSE frames" || bad "no SSE frames"

# -------------------------------------------------------------------------
say "A3-11: project tag attaches to virtual key"
read -r U P < <(sudo awk -F= '/^BIFROST_ADMIN_USERNAME=/{u=$2}/^BIFROST_ADMIN_PASSWORD=/{p=$2}END{print u,p}' /etc/ai-fortress/upstream.env)
desc=$(curl -fsS -u "$U:$P" http://127.0.0.1:4000/api/governance/virtual-keys \
       | jq -r --arg v "$TEST_VK" '.virtual_keys[]? | select(.value == $v) | .description')
echo "description: $desc"
echo "$desc" | jq -e '.project == "phase3-test"' >/dev/null && ok "project tag matches" || bad "project tag missing"

# -------------------------------------------------------------------------
say "A3-9: agent launcher revokes its key on exit"
PRE_COUNT=$(curl -fsS -u "$U:$P" http://127.0.0.1:4000/api/governance/virtual-keys | jq '.count')
FORTRESS_VM_USER=__nobody__ "$HOME/bin/agent" lifecycle-test 2>/dev/null &
LAUNCHER_PID=$!
sleep 4
wait "$LAUNCHER_PID" 2>/dev/null
sleep 2
POST_COUNT=$(curl -fsS -u "$U:$P" http://127.0.0.1:4000/api/governance/virtual-keys | jq '.count')
echo "VK count: pre=$PRE_COUNT post=$POST_COUNT"
[[ "$POST_COUNT" -le "$PRE_COUNT" ]] && ok "no leaked key" || bad "launcher leaked a key"

# -------------------------------------------------------------------------
say "B3-1: Sandbox cannot reach Anthropic directly"
out=$(sandbox_sh -- 'curl -sS --max-time 5 https://api.anthropic.com/v1/messages 2>&1 || true')
echo "$out" | head -3
echo "$out" | grep -qE 'Could not resolve|Failed to connect|timed out' \
  && ok "direct Anthropic blocked" || bad "sandbox reached Anthropic directly"

say "B3-2: Sandbox cannot reach generic internet"
out=$(sandbox_sh -- 'curl -sS --max-time 5 https://example.com/ 2>&1 || true')
echo "$out" | head -3
echo "$out" | grep -qE 'Could not resolve|Failed to connect|timed out' \
  && ok "internet blocked" || bad "sandbox reached internet"

say "B3-5: VK cannot list other keys"
code=$(sandbox_sh -- '
  curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
    http://authproxy:4000/api/governance/virtual-keys
' | tail -1)
echo "code=$code"
[[ "$code" =~ ^4[0-9][0-9]$ ]] && ok "VK cannot list (code=$code)" || bad "VK could list (got $code)"

say "B3-6: VK cannot mint new keys"
code=$(sandbox_sh -- '
  curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
    -H "content-type: application/json" \
    -X POST http://authproxy:4000/api/governance/virtual-keys \
    -d "{\"name\":\"evil\"}"
' | tail -1)
echo "code=$code"
[[ "$code" =~ ^4[0-9][0-9]$ ]] && ok "VK cannot mint (code=$code)" || bad "VK could mint (got $code)"

# -------------------------------------------------------------------------
say "B3-7: VIRTUAL_KEY not in process command line"
out=$(sandbox_sh -- 'cat /proc/1/cmdline | tr "\0" " "; echo; ps -o args= 2>/dev/null || true')
echo "$out" | head -5
echo "$out" | grep -q "$TEST_VK" && bad "VK appears in cmdline/ps" || ok "VK not in cmdline/ps"

# -------------------------------------------------------------------------
say "B3-8: upstream API keys not in sandbox env"
upstream_anthropic=$(sudo awk -F= '/^ANTHROPIC_UPSTREAM_KEY=/{print $2}' /etc/ai-fortress/upstream.env)
# Pass the needle via a file inside the container so it never appears in env
# (otherwise grep would find its own pattern variable in env and false-positive).
out=$(sandbox_sh "PW_HEAD=${upstream_anthropic:0:20}" -- '
  printf "%s" "$PW_HEAD" > /tmp/needle
  unset PW_HEAD
  env | grep -F -f /tmp/needle && echo LEAKED || echo NOT_FOUND
  rm -f /tmp/needle
')
echo "$out"
echo "$out" | grep -q NOT_FOUND && ok "no upstream key in sandbox env" || bad "upstream key leaked"

# -------------------------------------------------------------------------
say "B3-10: admin password not in sandbox files (search via env-var, not args)"
admin_pw=$(sudo awk -F= '/^BIFROST_ADMIN_PASSWORD=/{print $2}' /etc/ai-fortress/upstream.env)
# Pass the pattern via env so the grep argv doesn't contain it.
# Use a written-to-disk pattern so it doesn't end up in /proc/*/cmdline either.
out=$(sandbox_sh "PW_NEEDLE=$admin_pw" -- '
  printf "%s" "$PW_NEEDLE" > /tmp/pat
  unset PW_NEEDLE
  # grep the filesystem (excluding /proc and /sys to avoid self-references) for the password.
  grep -rlF -f /tmp/pat / --exclude-dir=proc --exclude-dir=sys --exclude=/tmp/pat 2>/dev/null | head
  # grep current env too
  env | grep -F -f /tmp/pat || true
  rm -f /tmp/pat
')
if [[ -z "$out" ]]; then
  ok "admin password not present anywhere in sandbox"
else
  echo "$out" | head -5
  bad "admin password traces in sandbox"
fi

# -------------------------------------------------------------------------
say "B3-11: sandbox cannot reach VM loopback"
code=$(sandbox_sh -- '
  curl -sS -o /dev/null -w "%{http_code}" --max-time 3 \
    http://127.0.0.1:4000/health 2>&1 || true
' | tail -1)
echo "code=$code"
[[ "$code" == "000" ]] && ok "VM loopback unreachable" || bad "VM loopback reachable (got $code)"

# -------------------------------------------------------------------------
echo
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
