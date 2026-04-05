# README for ai-fortress




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
