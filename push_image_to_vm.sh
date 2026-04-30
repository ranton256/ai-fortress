#!/bin/bash
# Stream a host-built Docker image into the VM's Docker daemon.
# No intermediate tarball on disk — saves are piped through SSH directly.
#
# Usage: push_image_to_vm.sh <image[:tag]> [<image[:tag]> ...]
#
# Examples:
#   bash push_image_to_vm.sh ai-fortress/python-dev:latest
#   bash push_image_to_vm.sh my-custom:latest some-other:v1
#
# Tip: prefix with `time` if you want to see how long the transfer took.
set -euo pipefail

(( $# > 0 )) || { echo "usage: $0 <image[:tag]> [<image[:tag]> ...]" >&2; exit 2; }

VM_NAME="${FORTRESS_VM_NAME:-ai-fortress}"
VM_USER="${FORTRESS_VM_USER:-$USER}"
_filter='/ipv4/ {sub(/\/.*/,"",$NF); ip=$NF; if (ip !~ /^127\./) {print ip; exit}}'
VM_IP=$(virsh -c qemu:///system -q domifaddr "$VM_NAME" | awk "$_filter")
[[ -z "$VM_IP" ]] && { echo "could not resolve $VM_NAME IP" >&2; exit 1; }

# Verify each image exists on the host before we start transferring.
for img in "$@"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "ERROR: image not found on host: $img" >&2
    echo "       Build it first (e.g. docker build -t $img -f Dockerfile.foo .)" >&2
    exit 1
  fi
done

# Show a progress meter if `pv` is available; otherwise just stream.
SIZE_BYTES=$(docker image inspect "$@" --format '{{.Size}}' | awk '{s+=$1} END{print s}')
SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
echo "Pushing $# image(s), ~${SIZE_MB} MB uncompressed, to $VM_USER@$VM_IP …"

if command -v pv >/dev/null 2>&1; then
  docker save "$@" | pv -s "$SIZE_BYTES" | ssh "$VM_USER@$VM_IP" 'docker load'
else
  docker save "$@" | ssh "$VM_USER@$VM_IP" 'docker load'
fi

echo
echo "=== verifying images now in VM ==="
ssh "$VM_USER@$VM_IP" "docker images $(printf '%s ' "$@") --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'"
