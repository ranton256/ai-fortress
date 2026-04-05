#!/bin/bash
# Create a 50GB overlay that 'points' to your fresh base image
qemu-img create -f qcow2 -F qcow2 -b ~/ai-fortress/flatcar_production_qemu_image.img ~/ai-fortress/ai-fortress-snapshot.qcow2 50G
