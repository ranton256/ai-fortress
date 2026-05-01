#!/bin/bash
# Phase 1 verification — runs as the invoking user. Prompts for sudo password
# once for the bifrost-UID and file-perm tests; everything else via sudo -n
# (NOPASSWD on the fortress-mint/-revoke helpers).
set -u

PASS=0; FAIL=0
say()   { printf '\n=== %s ===\n' "$*"; }
ok()    { printf 'OK   %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }

# Trigger sudo to cache credentials for the password-needing tests below.
sudo -v || { echo "sudo unavailable; aborting"; exit 1; }

# -------------------------------------------------------------------------
say "B1-7: upstream.env mode/owner"
m=$(sudo stat -c '%a %U:%G' /etc/ai-fortress/upstream.env)
[[ "$m" == "600 root:root" ]] && ok "upstream.env $m" || bad "upstream.env: $m"

say "B1-8: sudoers grants only the two helpers"
s=$(sudo grep -h fortress /etc/sudoers.d/ai-fortress | tr -s ' ')
echo "$s"
echo "$s" | grep -q 'fortress-mint, /usr/local/sbin/fortress-revoke' && ok "sudoers shape" || bad "sudoers shape"

# -------------------------------------------------------------------------
say "A1-13: bifrost (UID 1500) can reach :443"
code=$(sudo -u bifrost -- curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ 2>/dev/null)
[[ "$code" =~ ^[1-9][0-9][0-9]$ ]] && ok "bifrost reached :443 (code=$code)" || bad "bifrost did not reach :443 (got $code)"

say "B1-2: bifrost UID 1500 cannot reach :80"
code=$(sudo -u bifrost -- curl -sS --max-time 3 -o /dev/null -w '%{http_code}' http://example.com/ 2>/dev/null)
[[ "$code" == "000" ]] && ok "bifrost blocked on :80" || bad "bifrost reached :80 (got $code)"

say "B1-3: bifrost UID 1500 cannot reach :22"
sudo -u bifrost -- timeout 3 bash -c 'cat </dev/tcp/93.184.215.14/22' 2>/dev/null
[[ $? -ne 0 ]] && ok "bifrost blocked on :22" || bad "bifrost reached :22"

say "B1-4: other UIDs unaffected (relaxed mode)"
code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://example.com/)
[[ "$code" =~ ^[23][0-9][0-9]$ ]] && ok "user shell reaches :80 (code=$code)" || bad "user :80 broke (got $code)"

# -------------------------------------------------------------------------
say "A1-10: mint a virtual key"
LSTART=$(awk '{print $22}' /proc/$$/stat)
VK=$(sudo -n /usr/local/sbin/fortress-mint smoke-test "$$" "$LSTART" 2>&1)
echo "$VK" | head -1
if [[ "$VK" =~ ^sk-bf- ]]; then
  ok "minted: ${VK:0:14}..."
  MINTED=1
else
  bad "mint failed"; MINTED=0
fi

if [[ "$MINTED" == "1" ]]; then
  say "A1-12: auth chain reaches upstream Anthropic"
  body='{"model":"claude-sonnet-4-6","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}'
  resp=$(curl -sS --max-time 30 \
    -H "x-api-key: $VK" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    -X POST http://127.0.0.1:4000/anthropic/v1/messages \
    -d "$body")
  echo "$resp" | head -c 400; echo
  if echo "$resp" | jq -e '.content[0].text' >/dev/null 2>&1; then
    ok "got real completion"
  elif echo "$resp" | jq -e '.error.type == "invalid_request_error" and (.error.message | test("usage limits|rate limit|quota"; "i"))' >/dev/null 2>&1; then
    ok "auth chain reached upstream (Anthropic returned billing/quota error — proves VK→upstream plumbing works)"
  else
    bad "unexpected response shape"
  fi

  say "A1-11: revoke the virtual key"
  sudo -n /usr/local/sbin/fortress-revoke "$VK" && ok "revoked" || bad "revoke errored"

  say "B1-12: revoked key is no longer usable"
  code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    -H "x-api-key: $VK" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    -X POST http://127.0.0.1:4000/anthropic/v1/messages -d "$body")
  [[ "$code" =~ ^4[0-9][0-9]$ ]] && ok "revoked key rejected (code=$code)" || bad "revoked key still works (got $code)"
fi

# -------------------------------------------------------------------------
say "B1-9: mint helper rejects bad project name"
sudo -n /usr/local/sbin/fortress-mint 'foo;rm -rf /' 1 1 2>&1 | head -1
[[ ${PIPESTATUS[0]} -ne 0 ]] && ok "rejected bad project" || bad "accepted bad project"

say "B1-10: mint helper rejects non-numeric PID"
sudo -n /usr/local/sbin/fortress-mint smoke abc 1 2>&1 | head -1
[[ ${PIPESTATUS[0]} -ne 0 ]] && ok "rejected non-numeric pid" || bad "accepted non-numeric pid"

# -------------------------------------------------------------------------
say "A1-15: orphan-key sweep deletes a synthetic dead-launcher key"
DEAD_VK=$(sudo -n /usr/local/sbin/fortress-mint sweep-test 99999999 1 2>&1 | tail -1)
if [[ "$DEAD_VK" =~ ^sk-bf- ]]; then
  echo "minted ${DEAD_VK:0:14}... with dead PID"
  sudo -n /usr/local/sbin/fortress-sweep
  sleep 1
  # Use a real Anthropic-shape body so the request actually reaches the auth
  # plugin. An empty {} body is rejected at the routing layer with HTTP 500
  # before auth runs, which would mask whether the VK was actually revoked.
  body='{"model":"claude-sonnet-4-6","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}'
  resp=$(curl -sS --max-time 5 -w '\nHTTP=%{http_code}\n' \
    -H "x-api-key: $DEAD_VK" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    -X POST http://127.0.0.1:4000/anthropic/v1/messages -d "$body")
  code=$(echo "$resp" | awk -F= '/^HTTP=/{print $2}')
  [[ "$code" == "401" ]] && ok "swept (code=$code on revoked)" || bad "sweep didn't kill it (got $code)"
else
  bad "could not mint sweep test key"
fi

# -------------------------------------------------------------------------
# Toolscrub tests (added Phase 1 extension)
# -------------------------------------------------------------------------
say "A1-16: toolscrub service is active and listening on :4001"
state=$(systemctl is-active ai-fortress-toolscrub 2>&1)
echo "  state=$state"
listening=$(ss -ltn 2>&1 | awk '{print $4}' | grep -q '^127\.0\.0\.1:4001$' && echo y || echo n)
echo "  listening=$listening"
[[ "$state" == "active" && "$listening" == "y" ]] && ok "toolscrub up" || bad "toolscrub state=$state listening=$listening"

# Mint a fresh VK for the toolscrub tests so we don't reuse the one from above
# (which was deliberately revoked).
TS_LSTART=$(awk '{print $22}' /proc/$$/stat)
TS_VK=$(sudo -n /usr/local/sbin/fortress-mint toolscrub-test "$$" "$TS_LSTART" 2>&1 | tail -1)
if [[ ! "$TS_VK" =~ ^sk-bf- ]]; then
  bad "could not mint VK for toolscrub tests; skipping A1-17..B1-17"
else
  trap "sudo -n /usr/local/sbin/fortress-revoke '$TS_VK' >/dev/null 2>&1 || true; $(trap -p EXIT | sed 's/trap -- //;s/ EXIT$//;s/^.//;s/.$//')" EXIT 2>/dev/null || \
    trap "sudo -n /usr/local/sbin/fortress-revoke '$TS_VK' >/dev/null 2>&1 || true" EXIT

  say "A1-17: clean request (no tools[]) round-trips through scrub"
  body='{"model":"claude-sonnet-4-6","max_tokens":15,"messages":[{"role":"user","content":"hi"}]}'
  for endpoint in "http://127.0.0.1:4000/anthropic/v1/messages" "http://127.0.0.1:4001/anthropic/v1/messages"; do
    resp=$(curl -sS --max-time 30 \
      -H "x-api-key: $TS_VK" \
      -H 'anthropic-version: 2023-06-01' \
      -H 'content-type: application/json' \
      -X POST "$endpoint" -d "$body")
    if echo "$resp" | jq -e '.content[0].text or (.error.type == "invalid_request_error" and (.error.message | test("usage limits|rate limit|quota"; "i")))' >/dev/null 2>&1; then
      ok "via $endpoint: chain works"
    else
      bad "via $endpoint: unexpected response: $(echo "$resp" | head -c 200)"
    fi
  done

  say "A1-18: client-side tools (custom, function, text_editor, bash) survive scrub byte-for-byte"
  # We can't easily inspect what arrives at Bifrost upstream, but the
  # Go unit tests already prove byte-identical passthrough for these
  # cases. Here we verify behaviorally: a request with a custom tool
  # should still allow the model to use it (model "calls" the tool by
  # emitting a tool_use block in the response).
  ct_body='{
    "model": "claude-sonnet-4-6",
    "max_tokens": 100,
    "tools": [
      {"type":"custom","name":"echo","description":"echoes the input","input_schema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}
    ],
    "tool_choice": {"type":"tool","name":"echo"},
    "messages": [{"role":"user","content":"call the echo tool with text=hello"}]
  }'
  resp=$(curl -sS --max-time 30 \
    -H "x-api-key: $TS_VK" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    -X POST http://127.0.0.1:4001/anthropic/v1/messages \
    -d "$ct_body")
  # Either the tool got used (tool_use block in response) or upstream rejected for billing
  if echo "$resp" | jq -e '.content[]? | select(.type=="tool_use" and .name=="echo")' >/dev/null 2>&1; then
    ok "client-side custom tool reached the model and was invoked"
  elif echo "$resp" | jq -e '.error.type == "invalid_request_error" and (.error.message | test("usage limits|rate limit|quota"; "i"))' >/dev/null 2>&1; then
    ok "auth chain works (Anthropic billing); custom tool body did not error out at scrub"
  else
    bad "client-side tool path failed: $(echo "$resp" | head -c 300)"
  fi

  say "B1-14: web_fetch_* is stripped (journal log + scrub side-effect)"
  # First flush the journal cursor so we only see logs from this test
  journal_since=$(date '+%Y-%m-%d %H:%M:%S')
  fetch_body='{
    "model":"claude-sonnet-4-6","max_tokens":50,
    "tools":[
      {"type":"web_fetch_20250910","name":"web_fetch"},
      {"type":"custom","name":"keep_me","input_schema":{"type":"object"}}
    ],
    "messages":[{"role":"user","content":"hi"}]
  }'
  resp=$(curl -sS --max-time 30 \
    -H "x-api-key: $TS_VK" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'content-type: application/json' \
    -X POST http://127.0.0.1:4001/anthropic/v1/messages \
    -d "$fetch_body")
  sleep 1
  # Did the toolscrub log a 'stripped' line?
  log_seen=$(sudo journalctl -u ai-fortress-toolscrub --since "$journal_since" 2>&1 | grep -c 'stripped.*web_fetch_20250910' || true)
  [[ "$log_seen" -ge 1 ]] && ok "scrub logged web_fetch_20250910 stripped" || bad "no scrub log entry; logs: $(sudo journalctl -u ai-fortress-toolscrub --since "$journal_since" 2>&1 | tail -5)"

  say "B1-15: every server-side family is stripped (logged)"
  for typ in web_search_20250305 code_execution_20250825 computer_20250124; do
    journal_since=$(date '+%Y-%m-%d %H:%M:%S')
    sleep 1
    bod="$(jq -nc --arg t "$typ" '{model:"claude-sonnet-4-6",max_tokens:5,tools:[{type:$t,name:"x"}],messages:[{role:"user",content:"hi"}]}')"
    curl -sS --max-time 15 \
      -H "x-api-key: $TS_VK" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
      -X POST http://127.0.0.1:4001/anthropic/v1/messages -d "$bod" >/dev/null
    sleep 1
    seen=$(sudo journalctl -u ai-fortress-toolscrub --since "$journal_since" 2>&1 | grep -c "stripped.*$typ" || true)
    [[ "$seen" -ge 1 ]] && ok "$typ stripped" || bad "$typ not logged as stripped"
  done

  say "B1-16: governance API is NOT scrubbed (regression — fortress-mint must keep working)"
  # The mint helper itself goes through 127.0.0.1:4000 directly (admin
  # path is on Bifrost, not the toolscrub). But sanity check that the
  # toolscrub passes through governance traffic if it ever reached it.
  # We've effectively proven this above (mints in this script all
  # succeeded), so just sanity check the path filter:
  read -r U P < <(sudo awk -F= '/^BIFROST_ADMIN_USERNAME=/{u=$2}/^BIFROST_ADMIN_PASSWORD=/{p=$2}END{print u,p}' /etc/ai-fortress/upstream.env)
  code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    -u "$U:$P" "http://127.0.0.1:4001/api/governance/virtual-keys")
  [[ "$code" == "200" ]] && ok "governance API passes through scrub (code=$code)" || bad "governance API broken via scrub (got $code)"

  say "A1-15b: streaming SSE survives the toolscrub"
  stream_body='{"model":"claude-sonnet-4-6","max_tokens":15,"stream":true,"messages":[{"role":"user","content":"hi"}]}'
  out=$(curl -sS --max-time 30 -N \
    -H "x-api-key: $TS_VK" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
    -X POST http://127.0.0.1:4001/anthropic/v1/messages -d "$stream_body")
  if echo "$out" | grep -qE '^event: ' && echo "$out" | grep -qE '^data: '; then
    ok "got SSE event/data frames through scrub"
  elif echo "$out" | jq -e '.error.type == "invalid_request_error" and (.error.message | test("usage limits|rate limit|quota"; "i"))' >/dev/null 2>&1; then
    ok "auth/upstream replied (billing); scrub did not corrupt the streaming request"
  else
    bad "no SSE frames or recognizable response: $(echo "$out" | head -c 200)"
  fi
fi

# -------------------------------------------------------------------------
echo
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
