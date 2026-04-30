# Host-side install (AI Fortress network v2 — Bifrost)

These are the templates. Real installation lives at the paths in the comments at the top of each file. The fastest path is to run `install-phase1.sh` and `start-phase1.sh` from the repo root; the manual steps below are useful when you want to install one piece at a time.

## One-time setup (manual equivalent of install-phase1.sh)

```bash
# 1. System user the Bifrost container runs as. UID 1500 must match the
#    --user flag in ai-fortress-bifrost.service and proxy_uid in ai-fortress.nft.
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --uid 1500 bifrost

# 2. Group that gates sudo access to the mint/revoke helpers.
sudo groupadd -r fortress
sudo usermod -aG fortress "$USER"
# Re-login or `newgrp fortress` for the membership to take effect.

# 3. Secrets directory and file.
sudo install -d -m 0755 /etc/ai-fortress
sudo install -m 0600 -o root -g root host/upstream.env.example /etc/ai-fortress/upstream.env
# Edit /etc/ai-fortress/upstream.env:
#   - put real Anthropic + OpenAI keys
#   - generate the admin password: openssl rand -base64 32

# 4. Bifrost config.
sudo install -m 0644 host/bifrost-config.json /etc/ai-fortress/bifrost-config.json

# 5. Image digests are already pinned in this repo. To re-pin (deliberate update):
docker pull docker.io/maximhq/bifrost
docker inspect --format='{{index .RepoDigests 0}}' docker.io/maximhq/bifrost
# Paste the @sha256:... portion into host/ai-fortress-bifrost.service before installing.

# 6. Helper scripts.
sudo install -m 0750 -o root -g fortress host/fortress-mint   /usr/local/sbin/fortress-mint
sudo install -m 0750 -o root -g fortress host/fortress-revoke /usr/local/sbin/fortress-revoke
sudo install -m 0750 -o root -g root     host/fortress-sweep  /usr/local/sbin/fortress-sweep

# 7. Sudoers (validate before installing).
sudo visudo -c -f host/ai-fortress.sudoers
sudo install -m 0440 -o root -g root host/ai-fortress.sudoers /etc/sudoers.d/ai-fortress

# 8. Systemd units.
sudo install -m 0644 host/ai-fortress-bifrost.service       /etc/systemd/system/
sudo install -m 0644 host/ai-fortress-vsock-relay.service   /etc/systemd/system/
sudo install -m 0644 host/ai-fortress-key-sweep.service     /etc/systemd/system/
sudo install -m 0644 host/ai-fortress-key-sweep.timer       /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ai-fortress-bifrost ai-fortress-vsock-relay ai-fortress-key-sweep.timer

# 9. nftables fragment.
sudo install -d -m 0755 /etc/nftables.d
sudo install -m 0644 host/ai-fortress.nft /etc/nftables.d/ai-fortress.nft
sudo nft -f /etc/nftables.d/ai-fortress.nft
sudo systemctl enable --now nftables.service

# 10. Launcher.
install -m 0755 host/agent ~/bin/agent
```

## Verify (Phase 1 of network-test-plan.md)

```bash
socat -V | head -1                                  # >= 1.7.4 (A1-1)
systemctl is-active ai-fortress-bifrost             # active   (A1-2)
docker inspect ai-fortress-bifrost --format '{{.Config.User}}'   # 1500:1500 (A1-3)
curl -fsS http://127.0.0.1:4000/health | jq                       # ok       (A1-5)
ss -ln | awk '$1=="v_str" && $2=="LISTEN"'                        # bound    (A1-9)
```

Refer to `network-test-plan.md` for the full Phase 1 A/B suite.
