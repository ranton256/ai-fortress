#!/bin/bash
# Install file(s) to a root-owned destination on the VM.
# Stages each source into /tmp/ on the VM, then runs `sudo install` to place
# it at the destination with the requested mode, owned root:root.
#
# Usage:
#   install_to_vm.sh [-m MODE] <source>... <dest>
#
# - One source + dest = dest is a file path (e.g. /opt/bin/agent-vm)
# - Multiple sources + dest = dest must be an existing directory on the VM
# - MODE defaults to 0755
#
# Examples:
#   install_to_vm.sh -m 0755 vm/agent-vm /opt/bin/agent-vm
#   install_to_vm.sh -m 0644 ./foo.conf ./bar.conf /etc/myapp/
#   install_to_vm.sh ./tool /opt/bin/tool                  # mode 0755 by default
#
# Notes:
#   - sudo on the VM may prompt for password unless you've cached creds via
#     ssh + sudo -v just before, or the VM's user has NOPASSWD configured
#     for /usr/bin/install on a path you trust.
#   - For one-off use that doesn't need root, use cp_to_vm.sh instead.
set -euo pipefail

MODE=0755
case "${1:-}" in
  -m) MODE="$2"; shift 2 ;;
  --mode) MODE="$2"; shift 2 ;;
  --mode=*) MODE="${1#--mode=}"; shift ;;
esac

(( $# >= 2 )) || { echo "usage: $0 [-m MODE] <source>... <dest>" >&2; exit 2; }

ARGS=( "$@" )
DEST="${ARGS[$#-1]}"
unset 'ARGS[$#-1]'
SOURCES=( "${ARGS[@]}" )

# Pre-flight: every source must exist locally.
for src in "${SOURCES[@]}"; do
  [[ -f "$src" ]] || { echo "ERROR: not a regular file: $src" >&2; exit 1; }
done

VM_NAME="${FORTRESS_VM_NAME:-ai-fortress}"
VM_USER="${FORTRESS_VM_USER:-$USER}"
_filter='/ipv4/ {sub(/\/.*/,"",$NF); ip=$NF; if (ip !~ /^127\./) {print ip; exit}}'
VM_IP=$(virsh -c qemu:///system -q domifaddr "$VM_NAME" | awk "$_filter")
[[ -z "$VM_IP" ]] && { echo "could not resolve $VM_NAME IP" >&2; exit 1; }

# Decide: is dest a directory (multi-source) or a file (single source)?
MODE_DIR=false
if (( ${#SOURCES[@]} > 1 )) || [[ "$DEST" == */ ]]; then
  MODE_DIR=true
fi

# Stage sources into a unique /tmp dir on the VM via rsync.
STAGE_DIR="/tmp/install-to-vm.$$.$(date +%s)"
echo "Staging ${#SOURCES[@]} file(s) → $VM_USER@$VM_IP:$STAGE_DIR"
ssh "$VM_USER@$VM_IP" "mkdir -p '$STAGE_DIR'"
rsync -a -e ssh "${SOURCES[@]}" "$VM_USER@$VM_IP:$STAGE_DIR/"

# Build the remote install + cleanup commands.
declare -a INSTALL_CMDS
if $MODE_DIR; then
  # Multi-source: install each into the dest directory.
  for src in "${SOURCES[@]}"; do
    base=$(basename "$src")
    INSTALL_CMDS+=( "sudo install -m $MODE -o root -g root '$STAGE_DIR/$base' '$DEST'" )
  done
else
  base=$(basename "${SOURCES[0]}")
  INSTALL_CMDS+=( "sudo install -m $MODE -o root -g root '$STAGE_DIR/$base' '$DEST'" )
fi

# Run them, then clean up the staging directory regardless.
remote_script=$(printf '%s; ' "${INSTALL_CMDS[@]}")
remote_script+="rm -rf '$STAGE_DIR'"
echo "Running on VM:"
printf '  %s\n' "${INSTALL_CMDS[@]}"
ssh -t "$VM_USER@$VM_IP" "$remote_script"
echo "Done."
