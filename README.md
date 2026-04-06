# README: The AI Fortress (Flatcar + gVisor + Libvirt)

This setup represents a **"Defense-in-Depth"** approach to agentic AI development. By moving the execution of AI-generated code from your primary workstation into a multi-layered sandbox, you mitigate the risk of "stochastic accidents" or malicious escapes while maintaining high performance on local hardware.

## 1. Background & Motivation

AI agents (OpenCode, Claude Code, etc.) are increasingly capable of executing shell commands and writing to the filesystem. However, giving an LLM-driven process direct access to a primary workstation presents significant security risks:

- **Kernel Exploits:** A container escape could compromise the host.
- **Data Exfiltration:** Agents could inadvertently (or maliciously) access private keys, documents, or unrelated projects.
- **Dependency Hell:** Global installs by agents can clutter the host OS.

**The Solution:** This architecture utilizes a "Russian Doll" isolation strategy:

1. **Level 1 (KVM):** A dedicated Virtual Machine (Flatcar) isolates the environment from the physical host kernel.
2. **Level 2 (Immutable OS):** Flatcar Container Linux provides a read-only root filesystem, preventing persistent malware.
3. **Level 3 (gVisor):** A user-space kernel (`runsc`) intercepts syscalls, trapping the agent in a fake kernel.
4. **Level 4 (Ephemeral Mounts):** Containers are scoped to specific subdirectories, ensuring one project cannot see another.

## 2. Architecture Overview

- **Host:** Linux Workstation (Skia).
- **VM:** Flatcar Container Linux (Stable) via `libvirt`.
- **Storage:** `virtio-fs` bridges the host `~/projects` folder to the VM at `/projects`.
- **Runtime:** `gVisor` (runsc) configured as a Docker runtime.

## 3. Prerequisites

- `libvirt`, `qemu-kvm`, and `virt-install` installed on the host.
- Host user added to `libvirt` and `kvm` groups.
- SELinux booleans set: `sudo setsebool -P virt_use_nfs 1` (for virtio-fs support).

## 4. Setup Instructions

### A. Prepare the Base Image

1. Download the Flatcar QEMU image.

2. Create a **Backing File** (Snapshot) to keep the base image pristine:

   Bash

   ```
   qemu-img create -f qcow2 -F qcow2 -b ~/ai-fortress/flatcar_production_qemu_image.img ~/ai-fortress/ai-fortress-snapshot.qcow2 50G
   ```

### B. Generate Ignition Config

Create a `config.bu` (Butane) file to define the VM state (users, mounts, and gVisor install service). Transpile it:

Bash

```
docker run --rm -i quay.io/coreos/butane:release < config.bu > config.json
sudo mv config.json /var/lib/libvirt/images/
```

### C. Provision the VM

Run the `virt-install` script using `virtio-fs` for the project mount and `fw_cfg` to pass the Ignition config:

Bash

```
virt-install \
  --name ai-fortress \
  --ram 16384 \
  --vcpus 4 \
  --disk path=~/ai-fortress/ai-fortress-snapshot.qcow2,format=qcow2 \
  --filesystem type=mount,accessmode=passthrough,driver.type=virtiofs,source.dir=/home/ranton/projects,target.dir=host_projects \
  --qemu-commandline="-fw_cfg name=opt/org.flatcar-linux/config,file=/var/lib/libvirt/images/config.json"
```

### D. Arm the Sandbox (Inside VM)

1. Install gVisor to `/opt/bin/runsc`.
2. Configure Docker (`/etc/docker/daemon.json`) to include the `runsc` runtime.
3. Restart Docker: `sudo systemctl restart docker`.

## 5. Usage: The "On-Demand" Agent

Launch an isolated sandbox for a specific project directory:

Bash

```
agent <project-folder-name>
```

This triggers the `agent-up` script, which launches a gVisor-trapped container with `--security-opt label=disable` to bypass SELinux conflicts between the VM and the sandbox.


## Getting out of VM or cleaning up

Getting stuck in a serial console is a rite of passage when working with headless VMs. Since you used `--graphics none`, your current terminal is "attached" to the VM's internal serial port.

### 1. How to get out (Detach)
To "escape" the console and get back to your host machine's prompt (**skia**) without stopping the VM, use the keyboard shortcut:

**`Ctrl` + `]`** (Control and the right square bracket)

> **Note:** If you are on a non-US keyboard, it is sometimes `Ctrl` + `5` or `Ctrl` + `Shift` + `]`.

---

### 2. How to Shut Down or Kill the VM
Once you are back at your host prompt, you have two options to stop the "Fortress":

#### **Option A: The "Graceful" Way**
This sends an ACPI shutdown signal (like pressing the power button).
```bash
virsh --connect qemu:///system shutdown ai-fortress
```

#### **Option B: The "Emergency" Way (Recommended for "issues")**
If the VM is hung or the boot failed, use `destroy`. This is the equivalent of pulling the power cord. It doesn't delete the VM; it just stops the process immediately.
```bash
virsh --connect qemu:///system destroy ai-fortress
```

---

### 3. Cleaning up to start over
If the "issues" you saw were related to the Ignition config not loading or a disk error, you should "undefine" the VM before running your script again. This wipes the VM's metadata from libvirt (but keeps your image files safe in `/var/lib/libvirt/images`).

```bash
# 1. Kill it
virsh --connect qemu:///system destroy ai-fortress

# 2. Delete its registration
virsh --connect qemu:///system undefine ai-fortress
```

### 4. How to see what went wrong
Before you try again, you can check the logs to see why it was struggling:
```bash
# Check the last 50 lines of the VM's log
sudo tail -n 50 /var/log/libvirt/qemu/ai-fortress.log
```

**Common "first boot" issues with Flatcar:**
* **No Network:** If the console was just sitting there, it might be waiting for a DHCP address.
* **Ignition Error:** If you see "failed to fetch config," it means the `fw_cfg` path in your script didn't point to the `config.json` correctly.

What did the console output look like before you got stuck? If you saw a **"Reached target Multi-User System"** message, the VM actually booted successfully, and you're just a `Ctrl + ]` away from victory!
