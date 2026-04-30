#!/bin/bash

# 1. Kill the current VM (just in case)
#virsh --connect qemu:///system destroy ai-fortress
#virsh --connect qemu:///system undefine ai-fortress

# 2. Overwrite the "dirty" image with the fresh base image
# (Assuming your clean download is still in ~/ai-fortress)
#sudo cp ~/ai-fortress/flatcar_production_qemu_image.img /var/lib/libvirt/images/flatcar_production_qemu_image.img

# 3. Ensure permissions are still correct
#sudo chown qemu:qemu /var/lib/libvirt/images/flatcar_production_qemu_image.img

# 4. Re-run your install script
#./do_virt_install.sh



virsh -c qemu:///system destroy ai-fortress 2>/dev/null
virsh -c qemu:///system undefine --snapshots-metadata ai-fortress

rm -f ~/ai-fortress/ai-fortress-snapshot.qcow2
bash make_overlay.sh

echo "Now run ./do_virt_install.sh"

