#!/bin/bash
# AI Fortress — Phase 1 activation (start services + load nft).
# Run after install-phase1.sh and after editing /etc/ai-fortress/upstream.env.
#
# Run as: sudo bash start-phase1.sh
#
# Idempotent: re-running should be safe (nft -f reloads the table).

set -euo pipefail
[[ "$EUID" -ne 0 ]] && { echo "must be run as root (use sudo)" >&2; exit 1; }

say() { printf '\n=== %s ===\n' "$*"; }

# -------------------------------------------------------------------------
say "0. sanity: upstream.env has real values"
if grep -q REPLACE-ME /etc/ai-fortress/upstream.env; then
  echo "ERROR: /etc/ai-fortress/upstream.env still has REPLACE-ME placeholders."
  echo "       Edit it before running this script."
  exit 1
fi

# -------------------------------------------------------------------------
say "1. nftables ruleset"
nft -f /etc/nftables.d/ai-fortress.nft
echo "ai_fortress table loaded"
systemctl enable --now nftables.service
echo "nftables.service enabled"

# -------------------------------------------------------------------------
say "2. enable + start services"
systemctl enable --now ai-fortress-bifrost.service
systemctl enable --now ai-fortress-toolscrub.service
systemctl enable ai-fortress-vsock-relay.service ai-fortress-key-sweep.timer
# Restart so any dependency or unit-file change picks up cleanly
# (e.g. the vsock-relay TCP target switched from Bifrost on 4000 to
# the toolscrub on 4001 once the scrub was added).
systemctl restart ai-fortress-vsock-relay.service
systemctl restart ai-fortress-key-sweep.timer
systemctl restart ai-fortress-toolscrub.service

# -------------------------------------------------------------------------
say "3. quick smoke checks"
# Bifrost can take a few seconds to migrate the SQLite schema on first boot.
for _ in $(seq 1 15); do
  if curl -fsS --max-time 2 http://127.0.0.1:4000/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo -n "bifrost health (direct, :4000): "
curl -fsS --max-time 5 http://127.0.0.1:4000/health >/dev/null && echo OK || echo FAIL

# Toolscrub binds slightly after systemd reports active; poll briefly.
for _ in $(seq 1 10); do
  curl -fsS --max-time 2 http://127.0.0.1:4001/health >/dev/null 2>&1 && break
  sleep 1
done
echo -n "toolscrub health (passthrough on :4001): "
curl -fsS --max-time 5 http://127.0.0.1:4001/health >/dev/null && echo OK || echo FAIL

echo -n "bifrost runs as 1500:1500: "
docker inspect ai-fortress-bifrost --format '{{.Config.User}}' 2>/dev/null

echo -n "vsock listener bound: "
ss -ln | awk '$1=="v_str" && $2=="LISTEN"' | grep -q . && echo OK || echo FAIL

echo
echo "Phase 1 active. Run network-test-plan.md A1-* and B1-* tests next."
