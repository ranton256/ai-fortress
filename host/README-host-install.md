# Host-side install (AI Fortress network v2)

These are the templates. Real installation lives at the paths in the comments at the top of each file.

## One-time setup

```bash
# 1. System user the LiteLLM container runs as. UID 1500 must match the
#    --user flag in ai-fortress-litellm.service and the litellm_uid in
#    ai-fortress.nft.
sudo useradd --system --no-create-home --shell /usr/sbin/nologin --uid 1500 litellm

# 2. Group that gates sudo access to the mint/revoke helpers.
sudo groupadd -r fortress
sudo usermod -aG fortress "$USER"
# Re-login or `newgrp fortress` for the membership to take effect.

# 3. Secrets directory and file.
sudo install -d -m 0755 /etc/ai-fortress
sudo install -m 0600 -o root -g root host/upstream.env.example /etc/ai-fortress/upstream.env
# Edit /etc/ai-fortress/upstream.env and put real keys in. Generate the
# master key with: openssl rand -base64 32

# 4. LiteLLM config.
sudo install -m 0644 host/litellm-config.yaml /etc/ai-fortress/litellm-config.yaml

# 5. Image digests are already pinned in the unit files in this repo.
#    To re-pin (deliberate update), pull and inspect:
docker pull docker.io/litellm/litellm:main-stable
docker inspect --format='{{index .RepoDigests 0}}' docker.io/litellm/litellm:main-stable
docker pull alpine/socat
docker inspect --format='{{index .RepoDigests 0}}' alpine/socat
# Paste the @sha256:... portions into host/ai-fortress-litellm.service and
# vm/vsock-shim.service (and the embedded copy in config.bu) before installing.
# Note: ghcr.io/berriai/litellm is private; we use docker.io/litellm/litellm instead.

# 6. Helper scripts.
sudo install -m 0750 -o root -g fortress host/fortress-mint   /usr/local/sbin/fortress-mint
sudo install -m 0750 -o root -g fortress host/fortress-revoke /usr/local/sbin/fortress-revoke
sudo install -m 0750 -o root -g root     host/fortress-sweep  /usr/local/sbin/fortress-sweep

# 7. Sudoers (validate before installing).
sudo visudo -c -f host/ai-fortress.sudoers
sudo install -m 0440 -o root -g root host/ai-fortress.sudoers /etc/sudoers.d/ai-fortress

# 8. Systemd units.
sudo install -m 0644 host/ai-fortress-litellm.service       /etc/systemd/system/
sudo install -m 0644 host/ai-fortress-vsock-relay.service   /etc/systemd/system/
sudo install -m 0644 host/ai-fortress-key-sweep.service     /etc/systemd/system/
sudo install -m 0644 host/ai-fortress-key-sweep.timer       /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ai-fortress-litellm ai-fortress-vsock-relay ai-fortress-key-sweep.timer

# 9. nftables fragment.
sudo install -d -m 0755 /etc/nftables.d
sudo install -m 0644 host/ai-fortress.nft /etc/nftables.d/ai-fortress.nft
sudo nft -f /etc/nftables.d/ai-fortress.nft

# 10. Launcher.
install -m 0755 host/agent ~/bin/agent
```

## Verify (Phase 1 of network-test-plan.md)

```bash
socat -V | head -1                         # >= 1.7.4 (A1-1)
systemctl is-active ai-fortress-litellm    # active   (A1-2)
docker inspect ai-fortress-litellm --format '{{.Config.User}}'   # 1500:1500 (A1-3)
curl -fsS http://127.0.0.1:4000/health | jq                       # ok       (A1-5)
sudo ss -lx | grep -i vsock                                       # bound    (A1-9)
```

Refer to `network-test-plan.md` for the full Phase 1 A/B suite.
