# AI Fortress Network v2 — Rollback Procedures

Reference for unwinding the network v2 changes back to a working pre-v2 state. Organized by "how far did we get before something went wrong" — start at the section matching your current state, run the commands top-to-bottom, then run the verification block at the end of that section.

The pre-v2 state we're rolling back to:
- VM snapshot: `pre-network-v2` (created by `virsh -c qemu:///system snapshot-create-as ai-fortress pre-network-v2`)
- Host `/etc` tarball: `~/ai-fortress-pre-v2.tgz`
- The original `agent-up` script in `~/bin/` (still there — v2 hasn't deleted it yet)

If the rollback ever feels uncertain, the snapshot + tarball are the ground truth: restore them and you're back to "the day before we started."

---

## 0. Quick reference: state markers

You can tell which phases have been applied by checking these markers:

| Marker                                                 | Indicates                          |
|--------------------------------------------------------|------------------------------------|
| `id bifrost` succeeds                                  | install-phase1.sh ran              |
| `getent group fortress` succeeds                       | install-phase1.sh ran              |
| `test -f /etc/ai-fortress/upstream.env`                | install-phase1.sh ran              |
| `systemctl is-active ai-fortress-bifrost`              | start-phase1.sh ran                |
| `sudo nft list table inet ai_fortress` returns rules   | start-phase1.sh ran                |
| `virsh -c qemu:///system dumpxml ai-fortress \| grep vsock` | Phase 2 libvirt edit applied  |
| `ssh "$VM_USER@$VM_IP" 'systemctl is-active vsock-shim'` reports active | Phase 2 VM provisioning applied |
| `test -x ~/bin/agent`                                  | Phase 3 launcher dropped in        |

Run them in order — earlier phases can be rolled back without touching later ones, but if you've applied Phase 2 you generally also rolled back Phase 1.

---

## 1. Rollback after `install-phase1.sh` only (no services started yet)

This unwinds: `bifrost` user (or legacy `litellm` user), `fortress` group, `/etc/ai-fortress/`, helper scripts, sudoers, systemd unit files, nft fragment file. No services were started, no nft rules were loaded.

```bash
# Remove sudoers dropin first — if anything in the rest of this script breaks
# sudo, you don't want our dropin to be the one referencing missing helpers.
sudo rm -f /etc/sudoers.d/ai-fortress

# Helper scripts
sudo rm -f /usr/local/sbin/fortress-mint \
           /usr/local/sbin/fortress-revoke \
           /usr/local/sbin/fortress-sweep

# Systemd unit files (none enabled yet at this stage)
sudo rm -f /etc/systemd/system/ai-fortress-bifrost.service \
           /etc/systemd/system/ai-fortress-vsock-relay.service \
           /etc/systemd/system/ai-fortress-key-sweep.service \
           /etc/systemd/system/ai-fortress-key-sweep.timer
sudo systemctl daemon-reload

# nft fragment + restore the nftables.conf include line if we added it
sudo rm -f /etc/nftables.d/ai-fortress.nft
if [ -f /etc/sysconfig/nftables.conf.bak.preinstall ]; then
  sudo mv /etc/sysconfig/nftables.conf.bak.preinstall /etc/sysconfig/nftables.conf
fi

# Secrets dir (check first if you want to keep the master key for some reason)
sudo rm -rf /etc/ai-fortress

# User and group
sudo gpasswd -d "$USER" fortress 2>/dev/null || true   # remove yourself from group
sudo groupdel fortress 2>/dev/null || true
sudo userdel bifrost 2>/dev/null || sudo userdel litellm 2>/dev/null || true
```

### Verify rollback at this stage

```bash
# All of these should fail / return empty:
id bifrost                               # should report "no such user"
getent group fortress                    # should be empty
ls /etc/ai-fortress 2>&1                 # "No such file or directory"
ls /etc/sudoers.d/ai-fortress 2>&1       # "No such file or directory"
ls /etc/systemd/system/ai-fortress-* 2>&1 # nothing matches
ls /etc/nftables.d/ai-fortress.nft 2>&1  # "No such file or directory"

# This should succeed (existing flow still works):
sudo whoami                              # root
agent-up test-project                    # original sandbox launches (Ctrl-D to exit)
```

---

## 2. Rollback after `start-phase1.sh` (services started, nft rules loaded)

If services were started, do this *first*, then run section 1.

```bash
# Stop and disable the services (order matters — relay depends on bifrost)
sudo systemctl disable --now ai-fortress-key-sweep.timer
sudo systemctl disable --now ai-fortress-vsock-relay.service
sudo systemctl disable --now ai-fortress-bifrost.service

# Remove the nft table from the running ruleset. This does NOT touch any
# other rules; only our table is affected.
sudo nft delete table inet ai_fortress 2>/dev/null || true

# If you want to also disable the nftables service entirely (it was disabled
# pre-v2), do this too. Skip if you have other reasons to keep it on.
sudo systemctl disable --now nftables.service

# Confirm the proxy container is gone
docker ps -a --filter name=ai-fortress-bifrost --format '{{.Names}}'   # should be empty
docker rm -f ai-fortress-bifrost 2>/dev/null || true
# (legacy LiteLLM-era container, if it ever existed)
docker rm -f ai-fortress-litellm 2>/dev/null || true

# Then proceed with section 1.
```

### Verify rollback at this stage

```bash
systemctl is-active ai-fortress-bifrost 2>&1       # "inactive" or "could not find unit"
sudo nft list table inet ai_fortress 2>&1          # "No such file or directory"
ss -lx | grep -i vsock                             # empty
docker ps --filter name=ai-fortress 2>&1           # nothing matches
```

Then continue with section 1 to remove the files and users.

---

## 3. Rollback Phase 2 (vsock device + VM provisioning)

If you've already added the `<vsock>` device to libvirt or re-provisioned the VM with the v2 `config.bu`, undo as follows.

### 3a. Remove the libvirt vsock device

```bash
# Edit the running domain XML and delete the <vsock>...</vsock> block
virsh -c qemu:///system edit ai-fortress
# Save and exit. Then:
virsh -c qemu:///system shutdown ai-fortress
# Wait for shutdown, then:
virsh -c qemu:///system start ai-fortress
```

### 3b. Revert the VM filesystem changes (modules-load, sshd dropin, vsock-shim unit)

The cleanest revert is to use the snapshot:

```bash
# Stop the running domain first
virsh -c qemu:///system destroy ai-fortress       # forceful but the snapshot has the state
virsh -c qemu:///system snapshot-revert ai-fortress pre-network-v2
virsh -c qemu:///system start ai-fortress
```

Note: `snapshot-revert` reverts the *disk* to the pre-v2 state, but the libvirt domain XML edit from 3a is independent of the snapshot — do 3a as well to make sure the vsock device is gone.

### Verify

```bash
virsh -c qemu:///system dumpxml ai-fortress | grep -i vsock     # empty
ssh "$VM_USER@$VM_IP" 'systemctl is-active vsock-shim 2>&1'     # "inactive" or unit not found
ssh "$VM_USER@$VM_IP" 'lsmod | grep vsock'                      # empty
ssh "$VM_USER@$VM_IP" 'agent-up test-project'                   # NOTE: this would only work if agent-up was inside the VM. The host-side agent-up pre-v2 still works as before.
```

---

## 4. Rollback Phase 3 (launcher in ~/bin)

```bash
rm -f ~/bin/agent
# agent-up was never removed during the rollout, so nothing to restore.
```

### Verify

```bash
which agent                                # not found
which agent-up                             # ~/bin/agent-up
agent-up test-project                      # works as before
```

---

## 5. Nuclear option — restore everything from the pre-flight artifacts

When in doubt or rolling back is getting messy:

```bash
# 1. Stop everything we may have started
sudo systemctl disable --now ai-fortress-bifrost ai-fortress-vsock-relay \
                              ai-fortress-key-sweep.timer nftables 2>/dev/null || true
sudo nft flush ruleset

# 2. Remove our files (idempotent)
sudo rm -f /etc/sudoers.d/ai-fortress
sudo rm -f /usr/local/sbin/fortress-{mint,revoke,sweep}
sudo rm -f /etc/systemd/system/ai-fortress-*
sudo rm -rf /etc/nftables.d/ai-fortress.nft /etc/ai-fortress
sudo systemctl daemon-reload

# 3. Restore /etc from the pre-flight tarball.
#    Pre-flight captured these dirs: /etc/nftables/, /etc/sysconfig/nftables.conf,
#    /etc/systemd/system, /etc/sudoers.d. Extract back to /:
sudo tar xzf ~/ai-fortress-pre-v2.tgz -C /

# 4. Remove the user + group we created
sudo gpasswd -d "$USER" fortress 2>/dev/null || true
sudo groupdel fortress 2>/dev/null || true
sudo userdel bifrost 2>/dev/null || sudo userdel litellm 2>/dev/null || true

# 5. Restore the VM to its pre-v2 state
virsh -c qemu:///system destroy ai-fortress 2>/dev/null || true
virsh -c qemu:///system snapshot-revert ai-fortress pre-network-v2
virsh -c qemu:///system start ai-fortress

# 6. Remove the host-side launcher
rm -f ~/bin/agent

# 7. systemd reload + sanity
sudo systemctl daemon-reload
sudo systemctl is-active nftables    # back to whatever it was pre-v2 (was inactive)
```

### Verify nuclear rollback

```bash
# The two key smoke tests for "we are fully back to pre-v2":
sudo whoami && echo SUDO_OK            # sudo still works
agent-up test-project                  # Original sandbox launches; you're inside; Ctrl-D to exit
```

If both pass, you're at the pre-flight baseline. The snapshot and tarball can be retained for at least a week post-rollout in case something is noticed later.

---

## 6. Recovery from worst-case scenarios

### 6a. Sudo broken (the sudoers file got corrupted somehow)

The `install-phase1.sh` script uses `visudo -c` so this should never happen, but if it does:

- From a graphical session, `pkexec rm /etc/sudoers.d/ai-fortress` will work without `sudo`.
- From a TTY with no GUI: reboot into single-user mode (add `single` to the kernel cmdline at the GRUB prompt), `mount -o remount,rw /`, remove the file, reboot.
- Last resort: boot a Fedora live USB and edit the file from there.

### 6b. nftables blocking traffic you didn't expect

```bash
sudo nft flush ruleset
```

This drops *all* nft rules, returning the system to "no firewall." Rerun `start-phase1.sh` only after diagnosing why our table caused trouble.

### 6c. Proxy container is consuming too many resources

```bash
sudo systemctl stop ai-fortress-bifrost.service
docker stop ai-fortress-bifrost 2>/dev/null
sudo systemctl disable ai-fortress-bifrost.service
```

### 6d. Toolscrub is breaking inference (legitimate requests being rejected)

The scrub is a separate process that can be turned off without uninstalling. The vsock-relay just needs to point back at Bifrost directly:

```bash
# Disable the scrub
sudo systemctl disable --now ai-fortress-toolscrub.service

# Edit the relay's TCP target back to Bifrost (port 4000)
sudo sed -i 's|TCP:127.0.0.1:4001|TCP:127.0.0.1:4000|' /etc/systemd/system/ai-fortress-vsock-relay.service

# Drop the dependency on the toolscrub
sudo sed -i 's|^After=ai-fortress-toolscrub.service$|After=ai-fortress-bifrost.service|' /etc/systemd/system/ai-fortress-vsock-relay.service
sudo sed -i 's|^Requires=ai-fortress-toolscrub.service$|Requires=ai-fortress-bifrost.service|' /etc/systemd/system/ai-fortress-vsock-relay.service

sudo systemctl daemon-reload
sudo systemctl restart ai-fortress-vsock-relay
```

You're now back to the pre-toolscrub topology (sandbox → relay → Bifrost). The LLM-as-egress channel is open again — re-enable application-layer denies in `Dockerfile.worker` if you want some protection while debugging.

To fully remove the scrub:

```bash
sudo systemctl disable --now ai-fortress-toolscrub.service
sudo rm -f /etc/systemd/system/ai-fortress-toolscrub.service \
           /usr/local/sbin/ai-fortress-toolscrub \
           /etc/ai-fortress/toolscrub.json
sudo systemctl daemon-reload
```

The unit has `Restart=always`, so `stop` alone is enough only if `disable` follows.

### 6d. VM is broken / unreachable after Phase 2 changes

```bash
virsh -c qemu:///system destroy ai-fortress
virsh -c qemu:///system snapshot-revert ai-fortress pre-network-v2
virsh -c qemu:///system start ai-fortress
```

If the snapshot itself is broken, the VM disk file is at `/home/ranton/ai-fortress/ai-fortress-snapshot.qcow2`, which is a snapshot overlay on the original Flatcar image at `/home/ranton/ai-fortress/flatcar_production_qemu_image.img`. As a last resort, `make_overlay.sh` and `do_virt_install.sh` rebuild a fresh VM from those base images.

---

## 7. What rollback does NOT undo

- API spend already incurred while the proxy was running. Check `/var/lib/ai-fortress/config.db` (SQLite) for the audit trail before deleting it.
- Anything you did inside a sandbox during testing. The host's view of `/projects/` is the source of truth — sandboxes can only modify files you can already modify yourself.
- Snapshot/backup files left in `~`. Delete them manually when you're sure they're not needed.

---

## 8. Useful one-liners

```bash
# What did v2 add to my host?
sudo find /etc/ai-fortress /etc/sudoers.d/ai-fortress \
          /etc/systemd/system/ai-fortress-* \
          /etc/nftables.d/ai-fortress.nft \
          /usr/local/sbin/fortress-* 2>/dev/null

# What's currently active?
systemctl list-units --all 'ai-fortress*' 'nftables*' --no-pager

# What's in the running nft ruleset?
sudo nft list ruleset
```
