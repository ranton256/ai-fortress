#!/bin/bash

# Allow the 'qemu' user to see the new snapshot
sudo setfacl -m u:qemu:x /home/ranton
sudo setfacl -m u:qemu:x /home/ranton/ai-fortress
sudo chown ranton:libvirt ~/ai-fortress/ai-fortress-snapshot.qcow2
sudo chmod 664 ~/ai-fortress/ai-fortress-snapshot.qcow2

# If you are on Fedora/RHEL, relabel for SELinux
sudo chcon -t virt_image_t ~/ai-fortress/ai-fortress-snapshot.qcow2
