#!/bin/bash
# General-purpose copy helper. Mirrors scp/rsync semantics: last arg is the
# destination on the VM, everything before it is one-or-more local sources.
# Resolves the VM IP via virsh (filters out loopback so Flatcar's missing
# qemu-guest-agent doesn't steer it at the host's own sshd).
#
# Usage:
#   cp_to_vm.sh <local-source>... <vm-destination>
#
# Examples:
#   cp_to_vm.sh notes.md /tmp/
#   cp_to_vm.sh ./build /opt/myapp/             # directory; recursive by default
#   cp_to_vm.sh foo.txt bar.txt /home/ranton/   # multiple sources, single dest
#
# Notes:
#   - Uses rsync (faster, recursive by default, idempotent re-runs).
#   - Destination is interpreted by sshd on the VM, so paths like '~' work,
#     but if sudo is needed on the VM, do it yourself: drop into /tmp first
#     then `ssh ... 'sudo install -m 0644 /tmp/foo /etc/...'`.
set -euo pipefail

(( $# >= 2 )) || { echo "usage: $0 <local-source>... <vm-destination>" >&2; exit 2; }

# Last arg is destination; everything else is sources.
ARGS=( "$@" )
DEST="${ARGS[$#-1]}"
unset 'ARGS[$#-1]'
SOURCES=( "${ARGS[@]}" )

# Pre-flight: every source must exist locally.
for src in "${SOURCES[@]}"; do
  if [[ ! -e "$src" ]]; then
    echo "ERROR: local path does not exist: $src" >&2
    exit 1
  fi
done

VM_NAME="${FORTRESS_VM_NAME:-ai-fortress}"
VM_USER="${FORTRESS_VM_USER:-$USER}"
_filter='/ipv4/ {sub(/\/.*/,"",$NF); ip=$NF; if (ip !~ /^127\./) {print ip; exit}}'
VM_IP=$(virsh -c qemu:///system -q domifaddr "$VM_NAME" | awk "$_filter")
[[ -z "$VM_IP" ]] && { echo "could not resolve $VM_NAME IP" >&2; exit 1; }

if ! command -v rsync >/dev/null 2>&1; then
  echo "ERROR: rsync not found. Install with: sudo dnf install rsync" >&2
  exit 1
fi

echo "Copying ${#SOURCES[@]} source(s) → $VM_USER@$VM_IP:$DEST"
exec rsync -av --progress -e ssh "${SOURCES[@]}" "$VM_USER@$VM_IP:$DEST"
