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
systemctl enable --now ai-fortress-litellm.service
systemctl enable --now ai-fortress-vsock-relay.service
systemctl enable --now ai-fortress-key-sweep.timer

# -------------------------------------------------------------------------
say "3. quick smoke checks"
sleep 2  # let LiteLLM finish starting

echo -n "litellm health: "
curl -fsS --max-time 5 http://127.0.0.1:4000/health >/dev/null && echo OK || echo FAIL

echo -n "litellm runs as 1500:1500: "
docker inspect ai-fortress-litellm --format '{{.Config.User}}' 2>/dev/null

echo -n "vsock listener bound: "
ss -lx | grep -qi vsock && echo OK || echo FAIL

echo
echo "Phase 1 active. Run network-test-plan.md A1-* and B1-* tests next."
