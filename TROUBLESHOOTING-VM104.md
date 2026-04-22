# VM 104 (arthur-server2) — Full Troubleshooting Post-Mortem

**Date:** April 20–22, 2026  
**Host:** Proxmox VE 9.1.1 at `192.168.0.153`  
**VM:** 104 (arthur-server2) — Ubuntu 22.04, OVMF UEFI, q35, 32 GB RAM, 12 vCPUs  
**Target IP:** `192.168.0.87`  
**NIC:** virtio-net-pci, MAC `BC:24:11:0A:15:E6`, bridge `vmbr0`

---

## Timeline Summary

| Phase | What happened |
|-------|--------------|
| T-0   | VM became unreachable after balloon memory setting was changed |
| T-1   | Added wrong systemd-networkd `.network` file — broke IPv4 |
| T-2   | Deleted wrong file + accidentally wiped entire `/etc/systemd/network/` |
| T-3   | VM sent zero Ethernet frames; serial console completely silent |
| T-4   | GPU passthrough removed for diagnostics — still zero frames |
| T-5   | Root causes identified and fixed |
| T-6   | VM fully recovered: SSH working, IP correct |
| T-7   | GPU passthrough restored, VM rebooted |

---

## The Original Problem

The VM (104) became unreachable at `192.168.0.87` after the `balloon` memory setting was changed in the Proxmox web UI. The VM was running Ubuntu 22.04 with:

- `systemd-networkd` as the network backend
- `netplan` as the renderer (config at `/etc/netplan/99-static.yaml`)
- Static IP configured via MAC address match on `eth0`
- GPU passthrough: RTX 5060 Ti at PCI `0000:05:00`

---

## Root Cause #1 — Rogue `.network` File Overriding Netplan

### What happened
During an early repair attempt, the file `/etc/systemd/network/10-eth0.network` was created inside the VM. This file contained a `[Network]` section that configured the interface directly via systemd-networkd — **overriding** the Netplan-generated configuration entirely. The result: only an IPv6 link-local address was assigned; no IPv4.

### How it was found
By mounting the OS disk on the Proxmox host:

```bash
lvchange -ay pve-nvme/vm-104-disk-0
kpartx -av /dev/pve-nvme/vm-104-disk-0
mount /dev/mapper/pve--nvme-vm--104--disk--0p1 /mnt/vm104
ls /mnt/vm104/etc/systemd/network/
```

The file `10-eth0.network` was present with an explicit `[Network]` block.

### Fix
```bash
rm /mnt/vm104/etc/systemd/network/10-eth0.network
```

---

## Root Cause #2 — Missing `.link` File (Interface Renaming Broken)

### What happened
This was the **primary root cause** of the zero-frames problem. During cleanup of the rogue `.network` file, **all files** in `/etc/systemd/network/` were accidentally deleted — including the `.link` file that told `udev` to rename the virtio NIC from its predictable name (`enp6s18`) to `eth0`.

Without the `.link` file:
- The NIC was named `enp6s18` at boot (predictable naming default)
- Netplan's config matched on `Name=eth0` — **no match**
- systemd-networkd never configured the interface
- The interface stayed DOWN with no IP
- No ARP, no IPv6 ND, no frames ever left the VM

This explained all symptoms:
- Zero Ethernet frames on `tap104i0` (confirmed with `tcpdump`)
- No ARP entries for `bc:24:11:0a:15:e6` in the bridge FDB
- SSH to `192.168.0.87` timing out
- QEMU running at ~116% CPU (OS was up, just networking was dead)

### How it was confirmed
```bash
ls /mnt/vm104/etc/systemd/network/
# Output: (empty)
```

The directory was completely empty — the link file was gone.

### Fix — Created the `.link` file

```bash
cat > /mnt/vm104/etc/systemd/network/10-netplan-eth0.link << 'EOF'
[Match]
MACAddress=bc:24:11:0a:15:e6

[Link]
Name=eth0
EOF
```

This causes `udev` (via `systemd-udevd`) to rename the interface to `eth0` at boot based on the MAC address, which is what Netplan's config expects.

### Fix — Added kernel parameters as belt-and-suspenders

To ensure `eth0` naming even if the link file was ever missing again, `net.ifnames=0 biosdevname=0` were added to the kernel command line in `/boot/grub/grub.cfg` inside the VM:

```
linux /boot/vmlinuz-5.15.0-176-generic root=UUID=... ro net.ifnames=0 biosdevname=0 console=tty1 console=ttyS0
```

With `net.ifnames=0`, the kernel assigns traditional names (`eth0`, `eth1`, ...) rather than predictable names. This is a permanent fallback.

---

## Root Cause #3 — rc-local Service Symlinks Missing

### What happened
The `/etc/rc.local` file existed and contained a failsafe network bringup script (manual `ip link set eth0 up` + `ip addr add` as a last resort). However, the `systemd` service symlinks required to actually *run* rc-local at boot were missing:

- `/etc/systemd/system/rc-local.service`
- `/etc/systemd/system/multi-user.target.wants/rc-local.service`

### Fix
```bash
ln -sf /lib/systemd/system/rc-local.service \
    /mnt/vm104/etc/systemd/system/rc-local.service
ln -sf /lib/systemd/system/rc-local.service \
    /mnt/vm104/etc/systemd/system/multi-user.target.wants/rc-local.service
```

---

## Root Cause #4 — Serial Console Not Configured in GRUB

### What happened
The QEMU serial device was present (`-chardev socket,id=serial0,...  -device isa-serial,chardev=serial0`), but GRUB was not instructed to output to the serial port. Every attempt to read the serial socket returned empty data — making remote headless diagnostics impossible.

### Fix
Prepended to `/boot/grub/grub.cfg` inside the VM:

```
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console
```

After this fix, connecting to the QEMU serial socket and sending a keystroke revealed the login prompt:

```
arthur-server login:
[  182.032858] NVRM: No NVIDIA GPU found.
```

This confirmed the OS had fully booted — the networking problem was isolated, not a boot failure.

---

## Diagnostic Dead Ends (What Was NOT the Problem)

These were all ruled out through direct verification:

| Suspect | Ruled out by |
|---------|-------------|
| Bridge misconfiguration | `bridge link show vmbr0` — tap104i0 UP, forwarding |
| Firewall blocking frames | `ebtables -L` (no rules), `iptables -L FORWARD` (ACCEPT policy) |
| GPU passthrough causing hang | Removed GPU (`qm set 104 --delete hostpci0`), still zero frames |
| QEMU process not running | `ps aux` confirmed PID at 116% CPU, ~32 GB VSZ |
| Wrong boot device | `qm status 104` = running; serial eventually showed login prompt |
| UEFI reboot loop | Ruled out once serial showed login prompt after fix |
| Disk corruption | Disk mounted successfully, all files readable/writable |

### The `reboot-timeout=1000` False Lead
The QEMU cmdline showed `-boot menu=on,strict=on,reboot-timeout=1000`. With `strict=on` and a 1-second reboot timeout, a failed UEFI boot would create a rapid reboot loop (consistent with 116% CPU). This was initially suspected, but ruled out once the link file fix allowed the serial console to reveal the login prompt.

---

## Key Diagnostic Commands Used

```bash
# Mount VM disk on Proxmox host
lvchange -ay pve-nvme/vm-104-disk-0
kpartx -av /dev/pve-nvme/vm-104-disk-0
mkdir -p /mnt/vm104
mount /dev/mapper/pve--nvme-vm--104--disk--0p1 /mnt/vm104
mount /dev/mapper/pve--nvme-vm--104--disk--0p15 /mnt/vm104/boot/efi

# Check bridge FDB for VM MAC
bridge fdb show br vmbr0 | grep -i "bc:24:11:0a:15"

# Live packet capture on VM's tap
tcpdump -i tap104i0 -e -nn

# Check ARP table on Proxmox host
ip neigh show dev vmbr0

# Read/interact with serial console
python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX)
s.connect('/var/run/qemu-server/104.serial0')
s.settimeout(0.5)
s.sendall(b'\r\n')
time.sleep(2)
data = b''
end = time.time() + 5
while time.time() < end:
    try: data += s.recv(4096)
    except: pass
print(data.decode('utf-8', 'replace'))
"

# Take VGA screendump (without GPU passthrough)
qm monitor 104
screendump /tmp/vm104.ppm

# Check QEMU process
ps aux | grep "kvm.*id.104"

# Verify no firewall filtering on bridge
ebtables -L
iptables -L FORWARD
```

---

## Final State After Resolution

```
VM 104 (arthur-server2)
├── Status: running
├── IP: 192.168.0.87/24 on eth0
├── MAC: bc:24:11:0a:15:e6
├── Default route: via 192.168.0.1
├── SSH: working (arthur@192.168.0.87)
├── GPU: RTX 5060 Ti (0000:05:00,pcie=1) — restored, active after reboot
└── Serial console: working (GRUB serial output enabled)
```

---

## Files Modified Inside VM Disk

| File | Change |
|------|--------|
| `/etc/systemd/network/10-eth0.network` | **DELETED** — was overriding netplan |
| `/etc/systemd/network/10-netplan-eth0.link` | **CREATED** — renames NIC to eth0 by MAC |
| `/boot/grub/grub.cfg` | **MODIFIED** — added serial commands + `net.ifnames=0 biosdevname=0` to kernel cmdline |
| `/etc/systemd/system/rc-local.service` | **CREATED** (symlink → `/lib/systemd/system/rc-local.service`) |
| `/etc/systemd/system/multi-user.target.wants/rc-local.service` | **CREATED** (symlink → same) |
| `/etc/netplan/99-static.yaml` | Unchanged — was correct throughout |

---

## GPU Passthrough — RTX 5060 Ti (Blackwell GB206)

Getting the RTX 5060 Ti working under QEMU/VFIO passthrough required fixing three separate issues, each with a different symptom.

---

### GPU Issue #1 — Kernel 5.15 Cannot Initialize Blackwell

**Symptom:** `nvidia-smi` failed. dmesg showed `NVRM: No NVIDIA GPU found` or initialization timeouts. The GPU was visible in `lspci` but the driver could not probe it.

**Root cause:** The NVIDIA open kernel module (`nvidia-open`) requires kernel 6.x for Blackwell (GB206) architecture. Kernel 5.15 (Ubuntu 22.04 default) does not have the required GPU firmware interfaces.

**Fix:** Install the HWE kernel:
```bash
apt install linux-generic-hwe-22.04
# Results in: 6.8.0-110-generic
```
Confirm DKMS rebuilt for the new kernel:
```bash
dkms status
# nvidia/580.126.09, 6.8.0-110-generic, x86_64: installed
```

---

### GPU Issue #2 — VM Hangs Before Kernel Boot When RAM ≥ 32 GB

**Symptom:** With GPU passthrough active, the VM produced zero serial output and zero Ethernet frames. The QEMU serial socket returned `b''`. The VM appeared to hang at the firmware/QEMU level before the kernel started. This happened every time, but only with the GPU attached.

**Root cause:** The QEMU q35 machine places the **64-bit PCI MMIO window** immediately after RAM in the address space. The default window size is only ~2 GB.

The RTX 5060 Ti (Blackwell) has Resizable BAR — BAR1 supports expansion up to **16 GB**. When the VM's kernel boots and the NVIDIA driver tries to resize BAR1, it needs 16 GB of contiguous MMIO space. With the default 2 GB window there is nowhere to put it, and QEMU hangs at the PCI host level before the kernel can even print anything.

The more RAM the VM has, the higher the MMIO window base address is pushed — but the window size stays 2 GB. Adding RAM makes this worse, not better.

With 32 GB RAM the layout was:
```
0 ──────────── 32 GB   RAM
32 GB ───── ~34 GB     64-bit PCI MMIO (2 GB default — too small for 16 GB BAR)
```

**Fix:** Explicitly set the 64-bit PCI hole to 128 GB in the VM config:
```
args: -global q35-pcihost.pci-hole64-size=128G
```
And suppress ROM BAR initialization (prevents a secondary hang during VBIOS ROM scan):
```
hostpci0: 0000:05:00,pcie=1,rombar=0,x-vga=1
```

With 128 GB hole:
```
0 ──────────── 32 GB   RAM
32 GB ─────── 160 GB   64-bit PCI MMIO (128 GB — GPU BAR expansion succeeds)
```

This fix is required any time RAM ≥ ~16 GB with a Resizable BAR GPU. Increasing RAM further (e.g. to 80 GB) does not break it as long as the hole size is large enough:
```
0 ──────────── 80 GB   RAM
80 GB ─────── 208 GB   64-bit PCI MMIO (128 GB — still fine)
```

---

### GPU Issue #3 — "GPU Fell Off the Bus" During Driver Probe

**Symptom:** VM booted successfully (serial output, SSH working). GPU visible in `lspci`. But `nvidia-smi` failed with "couldn't communicate with the NVIDIA driver". `modprobe nvidia` returned `No such device`. dmesg showed:
```
NVRM: The NVIDIA GPU 0000:01:00.0 (PCI ID: 10de:2d04) installed in this system has
NVRM: fallen off the bus and is not responding to commands.
nvidia: probe of 0000:01:00.0 failed with error -1
NVRM: None of the NVIDIA devices were initialized.
```

**Root cause:** The NVIDIA GPU Reset Bug. The Proxmox host kernel identified the RTX 5060 Ti as the **boot VGA device** and the UEFI EFI framebuffer (`efifb`) driver mapped the GPU's framebuffer into the host's address space during boot:
```
# From Proxmox host dmesg:
pci 0000:05:00.0: vgaarb: setting as boot VGA device
efifb: framebuffer at 0x...
vfio-pci 0000:05:00.0: vgaarb: deactivate vga console
```

When `vfio-pci` then bound to the GPU, the GPU was left in a **dirty, partially-initialized state** — the host had touched its registers but never cleanly shut it down. When the VM later tried to initialize the GPU from scratch, the GPU did not respond correctly to PCI config space reads, causing the "fell off the bus" error.

The `vendor_reset` kernel module (which can fix this for older GPUs) is not available on Proxmox kernel 6.17 and does not support Blackwell anyway.

**Fix:** Prevent the Proxmox host from using the GPU's EFI framebuffer at all. Add `video=efifb:off` to the Proxmox host's GRUB cmdline:
```bash
# On Proxmox host: edit /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt video=efifb:off"
update-grub
reboot
```

After reboot, `vfio-pci` claims the GPU before the EFI framebuffer driver can touch it. The GPU is handed to the VM in a clean power-on state and driver probe succeeds.

**Verification:** After the host reboot with `video=efifb:off`:
```
$ nvidia-smi
Wed Apr 22 18:29:05 2026
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 580.126.09    Driver Version: 580.126.09    CUDA Version: 13.0              |
| GPU  Name              Persistence-M | Bus-Id       Disp.A | Volatile Uncorr. ECC     |
| RTX 5060 Ti            Off           | 00000000:01:00.0 Off |                  N/A    |
```

---

### Final Working GPU Passthrough Config

**Proxmox host `/etc/default/grub`:**
```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt video=efifb:off"
```

**VM 104 `/etc/pve/qemu-server/104.conf` (relevant lines):**
```
args: -global q35-pcihost.pci-hole64-size=128G
hostpci0: 0000:05:00,pcie=1,rombar=0,x-vga=1
machine: q35
memory: 32768
```

**Inside VM — NVIDIA driver package:**
```
nvidia-dkms-580-open   # version 580.126.09 — open kernel module required for Blackwell
```

**Note:** The proprietary NVIDIA driver cannot be used for Blackwell (RTX 5060 Ti / GB206). Only `nvidia-open` (open kernel module) supports this architecture.

---

## Lessons Learned

1. **Never delete files from `/etc/systemd/network/` carelessly.** Both `.link` files (for interface renaming) and `.network` files (for IP config) live there. Deleting `.link` files silently breaks interface naming.

2. **Always enable serial console before debugging headless VMs.** Add GRUB serial output from the start. Without it, diagnosing boot issues requires mounting the disk — much slower.

3. **`net.ifnames=0 biosdevname=0` is a useful belt-and-suspenders for VMs.** If udev/systemd-networkd link files are ever lost, traditional naming (`eth0`) still works.

4. **Check the bridge FDB first.** `bridge fdb show br vmbr0 | grep <MAC>` tells you immediately whether the VM has sent *any* frames. If the MAC is absent, the issue is inside the guest. If present (even STALE), the guest OS is up.

5. **Serial console interaction is the fastest path to diagnosis.** Even a silent serial socket will respond once you send a keystroke — it was at the login prompt the whole time.

6. **ARP table on the host (`ip neigh show dev vmbr0`) is ground truth.** After the fix, entries for `192.168.0.87 lladdr bc:24:11:0a:15:e6` appeared immediately — confirming the VM had acquired its IP without needing an SSH attempt first.

7. **For GPU passthrough with Resizable BAR GPUs and large RAM, always set `q35-pcihost.pci-hole64-size`.** The default 2 GB MMIO hole is far too small for modern GPUs. Use 128 GB or larger. This becomes critical once VM RAM exceeds ~16 GB.

8. **Add `video=efifb:off` to the Proxmox host GRUB before passing through a GPU that is the host's boot VGA device.** Without it, the GPU is left in a dirty state by the host EFI framebuffer and will "fall off the bus" when the VM driver tries to probe it.
