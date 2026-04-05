#/bin/bash 

SOURCE_DIR=/home/ranton/projects
TARGET_DIR=host_projects
# We use the snapshot file we just created
DISK_PATH=/home/ranton/ai-fortress/ai-fortress-snapshot.qcow2


# if you don't have virt-install then do this (fedora version)
# sudo dnf install virt-install

# if you get this type of error:
# $ ./do_virt_install.sh
#
# ERROR    authentication unavailable: no polkit agent available to authenticate action 'org.libvirt.unix.manage'
# Then you need to run these commands.
#
# sudo usermod -aG libvirt ranton
# sudo usermod -aG kvm ranton
# newgrp libvirt
# newgrp kvm

# this expects the image in /var/lib/libvirt

# Move the image and config to the system storage pool
#sudo mv ~/ai-fortress/flatcar_production_qemu_image.img /var/lib/libvirt/images/
#sudo mv ~/ai-fortress/config.json /var/lib/libvirt/images/

# Set the ownership so the hypervisor can read them
#sudo chown qemu:qemu /var/lib/libvirt/images/flatcar_production_qemu_image.img
#sudo chown qemu:qemu /var/lib/libvirt/images/config.json

# Restore default SELinux labels for this directory
#sudo restorecon -v /var/lib/libvirt/images/*

# set SELinux labels for projects directory
#  sudo chcon -R -t virt_content_t /home/ranton/projects^C

# --filesystem type=mount,accessmode=passthrough,driver.type=virtiofs,source.dir=/home/ranton/projects,target.dir=host_projects \


virt-install \
  --connect qemu:///system \
  --name ai-fortress \
  --ram 16384 \
  --vcpus 4 \
  --os-variant fedora-coreos-stable \
  --import \
  --disk path=${DISK_PATH},format=qcow2 \
  --network network=default \
  --graphics none \
  --memorybacking source.type=memfd,access.mode=shared \
  --filesystem type=mount,accessmode=passthrough,driver.type=virtiofs,source.dir=${SOURCE_DIR},target.dir=${TARGET_DIR} \
  --qemu-commandline="-fw_cfg name=opt/org.flatcar-linux/config,file=/var/lib/libvirt/images/config.json"
