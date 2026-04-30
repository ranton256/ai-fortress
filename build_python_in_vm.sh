#!/bin/bash
# Build ai-fortress/python-dev:latest inside the VM.
# Re-run this any time you change Dockerfile.python or after a VM re-provision.
set -euo pipefail

VM_NAME="${FORTRESS_VM_NAME:-ai-fortress}"
VM_USER="${FORTRESS_VM_USER:-$USER}"
_filter='/ipv4/ {sub(/\/.*/,"",$NF); ip=$NF; if (ip !~ /^127\./) {print ip; exit}}'
VM_IP=$(virsh -c qemu:///system -q domifaddr "$VM_NAME" | awk "$_filter")
[[ -z "$VM_IP" ]] && { echo "could not resolve $VM_NAME IP" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Building on $VM_USER@$VM_IP …"

scp "$REPO_DIR/Dockerfile.python" "$REPO_DIR/build_python.sh" \
    "$VM_USER@$VM_IP":/tmp/
ssh "$VM_USER@$VM_IP" 'cd /tmp && bash build_python.sh && rm -f Dockerfile.python build_python.sh && docker images ai-fortress/python-dev:latest'
