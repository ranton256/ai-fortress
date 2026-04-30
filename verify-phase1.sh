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
echo
printf 'PASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
