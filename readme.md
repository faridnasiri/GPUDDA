# Proxmox Hyper-V Migration — Complete Technical Documentation

**Host:** `192.168.0.153` (Proxmox VE)  
**Date:** April 2026  
**Author:** Farid Nasiri  

---

## Table of Contents

1. [Goal](#1-goal)
2. [Infrastructure Overview](#2-infrastructure-overview)
3. [Phase 1 — NVMe Mount and Storage Preparation](#3-phase-1--nvme-mount-and-storage-preparation)
4. [Phase 2 — LVM Thin Pool Extension](#4-phase-2--lvm-thin-pool-extension)
5. [Phase 3 — VM Creation and VHDX Import](#5-phase-3--vm-creation-and-vhdx-import)
6. [Phase 4 — AVHDX Checkpoint Merge (rds2 / yt)](#6-phase-4--avhdx-checkpoint-merge-rds2--yt)
7. [Phase 5 — VM 104 (arthur-server2) Linux Boot Fix](#7-phase-5--vm-104-arthur-server2-linux-boot-fix)
8. [Phase 6 — NVIDIA RTX 5060 Ti GPU Passthrough](#8-phase-6--nvidia-rtx-5060-ti-gpu-passthrough)
9. [Phase 7 — VM 104 NVIDIA Driver + AI Stack](#9-phase-7--vm-104-nvidia-driver--ai-stack)
10. [Phase 8 — VM 106 (yt) VirtIO SCSI — The BSOD Journey](#10-phase-8--vm-106-yt-virtio-scsi--the-bsod-journey)
11. [Phase 9 — VM 105 (guacamole) Linux Boot Fix](#11-phase-9--vm-105-guacamole-linux-boot-fix)
12. [Final VM States](#12-final-vm-states)
13. [Remaining Work](#13-remaining-work)
14. [Key Lessons Learned](#14-key-lessons-learned)
15. [Quick Reference — All Commands](#15-quick-reference--all-commands)

---

## 1. Goal

Migrate **7 Windows/Linux Hyper-V VMs** from a decommissioned Windows host to a **Proxmox VE** server, with full performance optimization:

| # | VM Name | OS | Goal |
|---|---------|-----|------|
| 100 | dc | Windows Server 2019 | Domain Controller |
| 101 | rds | Windows Server 2019 | Remote Desktop Services |
| 102 | rds2 | Windows Server 2019 | RDS (had checkpoint) |
| 103 | arthur | Ubuntu Linux | Dev workstation |
| 104 | arthur-server2 | Ubuntu Linux | AI/ML server with GPU |
| 105 | guacamole | Linux | Apache Guacamole gateway |
| 106 | yt | Windows Server 2019 | General purpose |

**Additional objectives:**
- Passthrough NVIDIA RTX 5060 Ti (16GB VRAM) to VM 104
- Install CUDA 12.8 + PyTorch 2.11 AI stack on VM 104
- Migrate all Windows VMs to **VirtIO SCSI** drivers (major performance gain over emulated SATA)
- Migrate all VMs to **VirtIO NIC** (paravirtual, better throughput)
- Use **OVMF (UEFI)** for all VMs (required for GPU passthrough, better hardware compatibility)

---

## 2. Infrastructure Overview

### Proxmox Host
```
IP:      192.168.0.153
SSH key: ssh-ed25519 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

### Storage
```
/dev/sda        — Boot SSD, contains Proxmox OS + LVM VG "pve"
/dev/nvme0n1p1  — 931.5 GB NTFS partition (NVMe drive), all source VHDX files
```

### VHDX Source Layout on NVMe
```
/mnt/nvme/vhds/
    dc/dc/dc/Virtual Hard Disks/dc.vhdx              (20 GB)
    rds/Virtual Hard Disks/rds.vhdx                   (22 GB)
    rds2/Virtual Hard Disks/
        rds2.vhdx                                      (base, 90 GB)
        rds2_25E6B8CF-312E-49E9-B21E-26227247B5E2.avhdx  (checkpoint delta)

/mnt/nvme/vhds2/
    arthur/Virtual Hard Disks/
        arthur-os.vhdx    (54 GB)
        arthur-seed.vhdx  (55 GB)
    arthur-server2/Virtual Hard Disks/
        arthur-server2-os.vhdx    (55 GB)
        arthur-server2-seed.vhdx  (55 GB)
    guacamole/Virtual Hard Disks/guacamole-os.vhdx    (15 GB)
    yt/Virtual Hard Disks/
        yt.vhdx                                        (base, 127 GB)
        yt_FB7CE1FA-F4E1-4C04-A35D-DE63FFE66A1F.avhdx (checkpoint delta)
```

---

## 3. Phase 1 — NVMe Mount and Storage Preparation

### Problem: NTFS volume not mounted

The 931 GB NVMe drive containing all VHDX files was a raw NTFS partition from the Windows host. Proxmox does not mount NTFS by default.

### Commands

```bash
# Install ntfs-3g
apt-get install -y ntfs-3g

# Mount (initially with ntfs-3g driver)
mkdir -p /mnt/nvme
mount -t ntfs-3g /dev/nvme0n1p1 /mnt/nvme

# Add to fstab for persistence
echo '/dev/nvme0n1p1 /mnt/nvme ntfs3 defaults,nofail 0 0' >> /etc/fstab
```

### Problem: ntfs-3g too slow for qemu-img

`ntfs-3g` (FUSE) is slow for large sequential reads. `qemu-img info` on `.avhdx` files returned incorrect results because the FUSE driver misread the VHDX header.

**Fix:** Re-mount with the in-kernel `ntfs3` driver (faster, no FUSE overhead):

```bash
umount /mnt/nvme
mount -t ntfs3 /dev/nvme0n1p1 /mnt/nvme
echo 'MOUNTED OK'
mount | grep nvme
```

**Verify mount:**
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL
```

### Problem: /var/lib/vz/images running out of space

During initial testing, VHDX files were rsync'd to `/var/lib/vz/images/` which lives on the root `/dev/sda` LVM volume (only ~100 GB free).

**Fix:** Cancel the rsync, remove copies, work directly from NVMe mount:
```bash
pkill -f 'rsync.*vhds'
rm -rf /var/lib/vz/images/vhds /var/lib/vz/images/vhds2
df -h /
```

---

## 4. Phase 2 — LVM Thin Pool Extension

### Problem: local-lvm has no free space

```
pvesm status
# local-lvm: total=3.51T used=3.49T avail=20G (only ~20 GB free!)
```

The `pve` VG showed `VFree = 0` because all physical extents were allocated. The thin pool (`pve/data`) had internal free space but the VG had no room to grow it.

### Diagnosis

```bash
fdisk -l /dev/sda     # Show partition layout
vgdisplay pve         # Confirm 0 free PEs
pvesm status          # Show storage pools
lvs pve               # List logical volumes
```

**Output showed:** `/dev/sda` had unpartitioned space at the end of the disk.

### Fix: Create new partition + extend VG

```bash
# Create new partition (type 8e00 = Linux LVM)
sgdisk -n 4:0:0 -t 4:8e00 /dev/sda

# Make kernel re-read partition table
partx -a -v /dev/sda

# Initialize as PV and extend VG
pvcreate /dev/sda4
vgextend pve /dev/sda4

# Extend the thin pool LV (pve/data, not pve/pve-data)
lvextend -l +100%FREE pve/data
```

> **Gotcha:** The thin pool LV is named `pve/data`, NOT `pve/pve-data`. Running `lvextend` on the wrong name fails silently.

```bash
# Verify
pvesm status | grep local-lvm
lvs pve
```

---

## 5. Phase 3 — VM Creation and VHDX Import

### VM Creation

All VMs created with VirtIO NIC and VirtIO-SCSI controller from the start:

```bash
qm create 100 --name dc             --memory 4096  --cores 2 \
    --net0 virtio,bridge=vmbr0 --ostype win2k19 --scsihw virtio-scsi-pci
qm create 101 --name rds            --memory 4096  --cores 2 \
    --net0 virtio,bridge=vmbr0 --ostype win2k19 --scsihw virtio-scsi-pci
qm create 102 --name rds2           --memory 4096  --cores 2 \
    --net0 virtio,bridge=vmbr0 --ostype win2k19 --scsihw virtio-scsi-pci
qm create 103 --name arthur         --memory 4096  --cores 2 \
    --net0 virtio,bridge=vmbr0 --ostype l26     --scsihw virtio-scsi-pci
qm create 104 --name arthur-server2 --memory 4096  --cores 2 \
    --net0 virtio,bridge=vmbr0 --ostype l26     --scsihw virtio-scsi-pci
qm create 105 --name guacamole      --memory 2048  --cores 2 \
    --net0 virtio,bridge=vmbr0 --ostype l26     --scsihw virtio-scsi-pci
qm create 106 --name yt             --memory 4096  --cores 2 \
    --net0 virtio,bridge=vmbr0 --ostype l26     --scsihw virtio-scsi-pci
```

### VHDX Import (simple disks)

For VMs without checkpoints (dc, rds, arthur, arthur-server2, guacamole):

```bash
# Example: dc
qm importdisk 100 '/mnt/nvme/vhds/dc/dc/dc/Virtual Hard Disks/dc.vhdx' local-lvm
qm set 100 --scsi0 local-lvm:vm-100-disk-0 --boot order=scsi0

# Example: rds
qm importdisk 101 '/mnt/nvme/vhds/rds/Virtual Hard Disks/rds.vhdx' local-lvm
qm set 101 --scsi0 local-lvm:vm-101-disk-0 --boot order=scsi0
```

Full import script: [scripts/import-vms.sh](scripts/import-vms.sh)

### Add OVMF (UEFI) to all VMs

Required for GPU passthrough (VM 104) and better Windows UEFI compatibility:

```bash
# Windows VMs: OVMF + q35 machine
qm set 100 --bios ovmf --machine q35 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 101 --bios ovmf --machine q35 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 102 --bios ovmf --machine q35 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 106 --bios ovmf --machine q35 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0

# Linux VMs
qm set 104 --bios ovmf --machine q35 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
```

> **Important:** `pre-enrolled-keys=0` disables Secure Boot. Required for NVIDIA open kernel modules.

---

## 6. Phase 4 — AVHDX Checkpoint Merge (rds2 / yt)

Both `rds2` and `yt` had **Hyper-V checkpoints** — meaning the live data is stored in a `.avhdx` delta file, not the base `.vhdx`. Simply importing the base `.vhdx` would give an outdated disk.

### Problem: qemu-img couldn't read .avhdx from ntfs-3g

```bash
qemu-img info '/mnt/nvme/vhds/rds2/Virtual Hard Disks/rds2_25E6B8CF...avhdx'
# Error: Could not open ... (failed to open ...): could not read header
```

**Root cause:** ntfs-3g FUSE driver had a race condition reading the VHDX header.

**Fix:** Re-mount with ntfs3 kernel driver OR copy the avhdx to ext4 first:

```bash
# Option A: switch to ntfs3
umount /mnt/nvme
mount -t ntfs3 /dev/nvme0n1p1 /mnt/nvme

# Option B: copy to /tmp on ext4 filesystem
cp '/mnt/nvme/vhds/rds2/Virtual Hard Disks/rds2_25E6B8CF...avhdx' /tmp/rds2.avhdx
qemu-img info /tmp/rds2.avhdx
```

### Merge commands (yt — succeeded)

```bash
# 1. Rebase: tell qemu-img where the parent is
qemu-img rebase -u \
  -b '/mnt/nvme/vhds2/yt/Virtual Hard Disks/yt.vhdx' -F vhdx \
  -f vhdx '/mnt/nvme/vhds2/yt/Virtual Hard Disks/yt_FB7CE1FA-F4E1-4C04-A35D-DE63FFE66A1F.avhdx'

# 2. Convert merged chain directly to LVM raw device
qemu-img convert -p -f vhdx \
  '/mnt/nvme/vhds2/yt/Virtual Hard Disks/yt_FB7CE1FA-F4E1-4C04-A35D-DE63FFE66A1F.avhdx' \
  -O raw /dev/pve/vm-106-disk-0

# 3. Attach disk to VM
qm set 106 --scsi0 local-lvm:vm-106-disk-0 --boot order=scsi0
```

### rds2 status: UNRESOLVED

The rds2 avhdx merge failed even with ntfs3 mount — `qemu-img` could not reliably parse the VHDX chain from the NVMe. Rds2 was imported as the **base vhdx only** (missing checkpoint data). Full merge requires:

```bash
# Copy both files to ext4 work directory first
cp '/mnt/nvme/vhds/rds2/Virtual Hard Disks/rds2.vhdx' /tmp/rds2-base.vhdx
cp '/mnt/nvme/vhds/rds2/Virtual Hard Disks/rds2_25E6B8CF-312E-49E9-B21E-26227247B5E2.avhdx' /tmp/rds2.avhdx

# Then rebase + convert
qemu-img rebase -u -b /tmp/rds2-base.vhdx -F vhdx -f vhdx /tmp/rds2.avhdx
qemu-img convert -p -f vhdx /tmp/rds2.avhdx -O raw /dev/pve/vm-102-disk-0
qm set 102 --scsi0 local-lvm:vm-102-disk-0 --boot order=scsi0
```

---

## 7. Phase 5 — VM 104 (arthur-server2) Linux Boot Fix

### Problem: VM wouldn't get network after import

VM 104 (Ubuntu) was imported from Hyper-V and had cloud-init configured to use DHCP via the old Hyper-V NIC MAC address. In Proxmox the NIC MAC changed (`BC:24:11:0A:15:E6`) so DHCP didn't bind, and cloud-init's `networkd-wait-online` stalled the boot for **90+ seconds**.

### Diagnosis via guestfish (offline disk inspection)

```bash
# Check what network config files exist
guestfish --ro -a /dev/pve/vm-104-disk-0 -i ls /etc/netplan/
guestfish --ro -a /dev/pve/vm-104-disk-0 -i cat /etc/netplan/50-cloud-init.yaml

# Check grub config
guestfish --ro -a /dev/pve/vm-104-disk-0 -i cat /boot/grub/grub.cfg | grep linux.*vmlinuz
```

### Fix via guestfish (offline patching, VM stopped)

```bash
guestfish -a /dev/pve/vm-104-disk-0 -i <<FISH
# Disable cloud-init network management
write /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg "network: {config: disabled}\n"

# Mask boot-stalling units
ln-sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln-sf /dev/null /etc/systemd/system/cloud-init-local.service
ln-sf /dev/null /etc/systemd/system/cloud-init.service
ln-sf /dev/null /etc/systemd/system/cloud-final.service
ln-sf /dev/null /etc/systemd/system/cloud-config.service

# Remove old cloud-init netplan
rm /etc/netplan/50-cloud-init.yaml

# Write static netplan (match by new MAC)
write /etc/netplan/99-static.yaml "network:\n    version: 2\n    ethernets:\n        eth0:\n            match:\n                macaddress: bc:24:11:0a:15:e6\n            set-name: eth0\n            addresses:\n                - 192.168.0.87/24\n            routes:\n                - to: default\n                  via: 192.168.0.1\n            nameservers:\n                addresses: [8.8.8.8]\n            dhcp4: false\n"

# Enable serial console for 'qm terminal' access
ln-sf /lib/systemd/system/serial-getty@.service \
  /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
FISH
```

Full script: [scripts/fix-linux-vm-networking.sh](scripts/fix-linux-vm-networking.sh)

### Problem: password unknown after import

The Hyper-V VM had a password that wasn't known. Fix via shadow file patching:

```bash
# Generate hash on Proxmox host
HASH=$(openssl passwd -6 'YOUR_PASSWORD_HERE')

# Download shadow, patch, upload
guestfish --ro -a /dev/pve/vm-104-disk-0 -i download /etc/shadow /tmp/vm104-shadow
sed -i "s|^arthur:[^:]*:|arthur:${HASH}:|" /tmp/vm104-shadow
sed -i "s|^root:[^:]*:|root:${HASH}:|"     /tmp/vm104-shadow
guestfish -a /dev/pve/vm-104-disk-0 -i upload /tmp/vm104-shadow /etc/shadow
rm /tmp/vm104-shadow
```

### Install SSH key for passwordless access

```bash
PUBKEY="ssh-ed25519 XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

guestfish -a /dev/pve/vm-104-disk-0 -i <<FISH
mkdir-p /home/arthur/.ssh
write /home/arthur/.ssh/authorized_keys "${PUBKEY}\n"
chmod 0700 /home/arthur/.ssh
chmod 0600 /home/arthur/.ssh/authorized_keys
chown 1000 1000 /home/arthur/.ssh
chown 1000 1000 /home/arthur/.ssh/authorized_keys
mkdir-p /root/.ssh
write /root/.ssh/authorized_keys "${PUBKEY}\n"
chmod 0700 /root/.ssh
chmod 0600 /root/.ssh/authorized_keys
FISH
```

### Problem: GRUB not outputting to serial

After enabling serial-getty, `qm terminal 104` showed a blank screen. The GRUB menu was not configured to output to ttyS0.

**Fix:** Patch `grub.cfg` directly via guestfish:

```bash
guestfish --ro -a /dev/pve/vm-104-disk-0 -i download /boot/grub/grub.cfg /tmp/grub.cfg

# Add serial init at top
sed -i "1s/^/serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\n/" /tmp/grub.cfg
# Add serial to terminal list
sed -i "s/terminal_input console/terminal_input serial console/"   /tmp/grub.cfg
sed -i "s/terminal_output console/terminal_output serial console/" /tmp/grub.cfg
# Clear recordfail if set (causes menu to show indefinitely)
sed -i "s/recordfail=1/recordfail=0/" /tmp/grub.cfg

guestfish -a /dev/pve/vm-104-disk-0 -i upload /tmp/grub.cfg /boot/grub/grub.cfg
```

### Final: VM 104 boots successfully

```bash
qm start 104
# Wait 60s then:
ping -c 3 192.168.0.87  # PING OK
ssh arthur@192.168.0.87 "hostname && uptime"
```

---

## 8. Phase 6 — NVIDIA RTX 5060 Ti GPU Passthrough

### Hardware

```
PCI slot: 05:00.0  NVIDIA RTX 5060 Ti (10de:2d04)  — GFX
PCI slot: 05:00.1  NVIDIA RTX 5060 Ti HD Audio     — Audio
IOMMU group: 29    (isolated — both devices in same group, clean passthrough)
```

### Step 1: Enable IOMMU and bind GPU to vfio-pci

See [scripts/setup-vfio.sh](scripts/setup-vfio.sh).

```bash
# On Proxmox host:
scp scripts/setup-vfio.sh root@192.168.0.153:/tmp/
ssh root@192.168.0.153 "bash /tmp/setup-vfio.sh"
# Host reboots automatically
```

### Verify after reboot

```bash
lspci -k -s 05:00
# Should show: Kernel driver in use: vfio-pci
# (NOT nouveau or nvidia)

dmesg | grep -i iommu | head -5
# Should show: DMAR: IOMMU enabled
```

### Step 2: Attach GPU to VM 104

```bash
# Add PCI passthrough (no x-vga=1 — we keep VGA std for noVNC)
qm set 104 --hostpci0 0000:05:00,pcie=1
qm set 104 --vga std
qm set 104 --cpu host
```

> **Note on `x-vga=1`:** Setting this makes the GPU claim primary VGA, which breaks noVNC console. Omitting it lets the GPU work for CUDA/AI while the `std` vga device handles the noVNC display.

### Problem: VM wouldn't start with GPU + SeaBIOS

```
Error: KVM: entry failed, hardware error 0x80000021
```

SeaBIOS (legacy BIOS) cannot initialize a PCIe GPU properly. Fix: switch to OVMF and reset EFI vars.

```bash
# Delete old efidisk (had pre-enrolled Microsoft keys = Secure Boot ON)
qm set 104 --delete efidisk0
lvremove -f pve/vm-104-disk-2

# Recreate with Secure Boot OFF
qm set 104 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 104 --bios ovmf --machine q35
```

> **Secure Boot must be OFF** for NVIDIA's open kernel module (`nvidia-driver-580-open`).
> `pre-enrolled-keys=0` = no Microsoft keys = Secure Boot disabled at OVMF level.

### Step 3: Start VM and verify GPU is visible

```bash
ssh arthur@192.168.0.87 "lspci | grep -i nvidia"
# 05:00.0 VGA compatible controller: NVIDIA Corporation ...
```

---

## 9. Phase 7 — VM 104 NVIDIA Driver + AI Stack

### Install NVIDIA driver (580 open)

```bash
ssh arthur@192.168.0.87 bash << 'EOF'
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver-580-open
sudo reboot
EOF
```

Wait 60s, then verify:

```bash
ssh arthur@192.168.0.87 "nvidia-smi"
# Expected output:
# +-----------------------------------------------------------------------------+
# | NVIDIA-SMI 580.xx    Driver Version: 580.xx    CUDA Version: 13.0          |
# | GPU 0: NVIDIA GeForce RTX 5060 Ti  16311 MiB VRAM                          |
# +-----------------------------------------------------------------------------+
```

### Install AI Stack (CUDA 12.8 + PyTorch 2.11)

Full script: [scripts/install-ai-stack.sh](scripts/install-ai-stack.sh)

```bash
scp scripts/install-ai-stack.sh arthur@192.168.0.87:/tmp/
ssh arthur@192.168.0.87 "bash /tmp/install-ai-stack.sh"
# Logged to /tmp/ai-setup.log
```

### Verify PyTorch CUDA

```bash
ssh arthur@192.168.0.87 "source ~/ai-env/bin/activate && python -c \"
import torch
print('PyTorch:', torch.__version__)
print('CUDA:', torch.cuda.is_available())
print('GPU:', torch.cuda.get_device_name(0))
\""
# PyTorch: 2.11.0+cu128
# CUDA: True
# GPU: NVIDIA GeForce RTX 5060 Ti
```

### Final VM 104 config

```bash
qm config 104
# balloon: 1024
# bios: ovmf
# boot: order=scsi0
# cores: 6
# cpu: host
# efidisk0: local-lvm:vm-104-disk-3,efitype=4m,pre-enrolled-keys=0,size=4M
# hostpci0: 0000:05:00,pcie=1
# machine: q35
# memory: 40960
# net0: virtio=BC:24:11:0A:15:E6,bridge=vmbr0
# scsi0: local-lvm:vm-104-disk-0,size=90G
# scsi1: local-lvm:vm-104-disk-1,size=180G
# scsihw: virtio-scsi-pci
# serial0: socket
# vga: std
```

---

## 10. Phase 8 — VM 106 (yt) VirtIO SCSI — The BSOD Journey

This was the most complex part of the migration. **7 BSOD attempts** before the root cause was found.

### Background

VM 106 (Windows Server 2019, hostname "dev") was imported from Hyper-V with an emulated SATA disk (`sata0`). The goal was to switch it to VirtIO SCSI (`scsi0`) for better performance. The VirtIO drivers (from `virtio-win.iso`) were pre-installed inside Windows.

### Attempt 1–3: Direct switch sata0 → scsi0

```bash
qm set 106 --scsi0 local-lvm:vm-106-disk-0,cache=writeback
qm set 106 --delete sata0
qm set 106 --boot order=scsi0
qm start 106
```

**Result:** BSOD `INACCESSIBLE_BOOT_DEVICE` immediately on boot.

### Attempt 4: Registry patching via WinRM

Established WinRM remote management. Inspected the vioscsi service registry keys:

```powershell
# From management machine (elevated PowerShell)
$so   = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
$cred = New-Object PSCredential(".\farid", (ConvertTo-SecureString "YOUR_PASSWORD_HERE" -AsPlainText -Force))
$s    = New-PSSession -ComputerName 192.168.0.92 -Credential $cred `
        -SessionOption $so -Authentication Negotiate

Invoke-Command -Session $s -ScriptBlock {
    sc.exe qc vioscsi
    reg query HKLM\SYSTEM\CurrentControlSet\Services\vioscsi
}
```

**Finding:** `vioscsi` registry key was missing `Group="SCSI miniport"`, `Tag`, and `PnpInterface` subkey — all required for Windows to load the driver at boot before the storage stack initializes.

Applied the registry fix ([scripts/vioscsi-registry-fix.ps1](scripts/vioscsi-registry-fix.ps1)):
- Set `Start=0` (BOOT_START)  
- Set `Group="SCSI miniport"`
- Set `Tag=21`
- Created `PnpInterface\5=1`
- Populated `CriticalDeviceDatabase` entries for all VirtIO PCI IDs
- Ran `pnputil /add-driver vioscsi.inf /install`

**Result:** Still BSOD. `sc.exe qc vioscsi` showed `BOOT_START` — but still crashed.

### Attempts 5–7: Various registry permutations

Tried different combinations of:
- All ControlSets (CurrentControlSet, ControlSet001, ControlSet002)
- Different Tag values
- Forcing `ImagePath` values
- `devcon install` approach

**All still BSOD'd.**

### Root Cause Discovery

After all registry attempts failed, the key insight came from checking **what Device Manager actually showed**:

```powershell
Invoke-Command -Session $s -ScriptBlock {
    Get-PnpDevice | Where-Object { $_.InstanceId -match "VEN_1AF4" } |
        Select-Object FriendlyName, Status, InstanceId
}
```

**Critical finding:**

> **The `Red Hat VirtIO SCSI pass-through controller` (VEN_1AF4&DEV_1004) did NOT appear in Device Manager at all.**

The VirtIO SCSI **PCI controller** only appears in Device Manager **when at least one VirtIO SCSI disk is attached to the VM**. When Windows boots from `sata0` with no `scsi0` attached, the VirtIO SCSI PCIe controller is completely invisible to the Windows PnP subsystem. No PnP = driver can never be properly bound = BSOD when you switch to scsi0.

The registry manipulations were patching the right service keys, but since Windows's own PnP stack had never actually seen the hardware, the driver binding was incomplete.

### The Fix That Worked: Dummy Disk Trick

The solution was to let Windows's own PnP manager install the driver properly, by making the controller visible:

#### Step 1: Create 1 GB dummy LV

```bash
lvcreate -T pve/data -V 1G -n vm-106-disk-2
```

#### Step 2: Attach as scsi0 while sata0 still present

```bash
qm set 106 --scsi0 local-lvm:vm-106-disk-2
# sata0 still has the main 127 GB disk
qm config 106 | grep -E 'sata|scsi'
# sata0: local-lvm:vm-106-disk-0,cache=writeback,size=127G
# scsi0: local-lvm:vm-106-disk-2,size=1G
```

#### Step 3: Boot Windows — controller becomes visible

```bash
qm start 106
```

With the dummy `scsi0` disk attached, the **VirtIO SCSI PCI controller now appeared** in Windows Device Manager. Windows PnP automatically found and installed `vioscsi.sys` using the pre-installed driver from `virtio-win.iso`.

#### Step 4: Verify via WinRM

```powershell
Invoke-Command -Session $s -ScriptBlock {
    Get-PnpDevice | Where-Object { $_.FriendlyName -match "VirtIO SCSI" } |
        Select-Object FriendlyName, Status
    # Red Hat VirtIO SCSI pass-through controller  OK ✅

    sc.exe qc vioscsi | Select-String "START_TYPE|BINARY_PATH"
    # START_TYPE: 0  BOOT_START ✅
    # BINARY_PATH_NAME: \SystemRoot\System32\drivers\vioscsi.sys ✅
}
```

#### Step 5: Shut down Windows

```powershell
Invoke-Command -Session $s -ScriptBlock { Stop-Computer -Force }
```

#### Step 6: Switch main disk from sata0 to scsi0

```bash
# Move main disk to scsi0
qm set 106 --scsi0 local-lvm:vm-106-disk-0,cache=writeback
# Remove sata0
qm set 106 --delete sata0
# Remove dummy disk (now pushed to scsi1)
qm set 106 --delete scsi1
# Set boot order
qm set 106 --boot order=scsi0
```

#### Step 7: Boot and verify

```bash
qm start 106
sleep 120
ping -c 4 -W 2 192.168.0.92
# 4/4 packets — PING OK ✅
```

```powershell
Invoke-Command -Session $s -ScriptBlock {
    hostname                         # dev ✅
    sc.exe qc vioscsi | Select-String "START_TYPE|BINARY_PATH"
    # START_TYPE: 0 BOOT_START ✅
    Get-PhysicalDisk | Select-Object FriendlyName, Size, BusType
    # QEMU HARDDISK  136365211648  SAS ✅
}
```

#### Step 8: Cleanup

```bash
lvremove -f pve/vm-106-disk-2
# Logical volume vm-106-disk-2 successfully removed ✅
```

### Final VM 106 Config

```
bios: ovmf
boot: order=scsi0
efidisk0: local-lvm:vm-106-disk-1,efitype=4m,pre-enrolled-keys=0
machine: q35
net0: virtio=BC:24:11:72:88:0A,bridge=vmbr0
scsi0: local-lvm:vm-106-disk-0,cache=writeback,size=127G   ← VirtIO SCSI ✅
scsihw: virtio-scsi-pci
```

Windows version: Windows Server 2019  
Hostname: `dev`  
IP: `192.168.0.92`  
User: `farid` / `<password>`

---

## 11. Phase 9 — VM 105 (guacamole) Linux Boot Fix

### Overview

VM 105 runs Apache Guacamole (HTML5 remote-desktop gateway) as four Docker containers: `guacamole`, `guacd`, `nginx`, and `guac-db` (MySQL 8.0). Target IP: `192.168.0.86`.

### Problem: Thin LV inactive — guestfish cannot open disk

```bash
guestfish -a /dev/pve/vm-105-disk-0 -i ls /etc/netplan/
# libguestfs: error: could not create appliance
```

The LV was a thin provisioned volume in an inactive state (`Vwi---tz--`).

**Fix:** Activate before using:

```bash
lvchange -ay pve/vm-105-disk-0
lvs pve | grep vm-105   # Should now show: Vwi-a-tz--
```

### Guestfish offline patching

Same pattern as VM 104 (see Phase 5). Key difference: MAC is `BC:24:11:EA:C0:FD`, IP is `192.168.0.86`.

```bash
guestfish -a /dev/pve/vm-105-disk-0 -i <<FISH
# Disable cloud-init network management
write /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg "network: {config: disabled}\n"

# Mask boot-stalling units
ln-sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln-sf /dev/null /etc/systemd/system/cloud-init-local.service
ln-sf /dev/null /etc/systemd/system/cloud-init.service
ln-sf /dev/null /etc/systemd/system/cloud-final.service
ln-sf /dev/null /etc/systemd/system/cloud-config.service

# Write static netplan
write /etc/netplan/99-static.yaml "network:\n    version: 2\n    ethernets:\n        eth0:\n            match:\n                macaddress: bc:24:11:ea:c0:fd\n            set-name: eth0\n            addresses:\n                - 192.168.0.86/24\n            routes:\n                - to: default\n                  via: 192.168.0.1\n            nameservers:\n                addresses: [8.8.8.8]\n            dhcp4: false\n"

# Enable serial console
ln-sf /lib/systemd/system/serial-getty@.service \
  /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
FISH
```

### VM hardware config

```bash
qm set 105 --bios ovmf --machine q35 --cpu host
qm set 105 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 105 --serial0 socket --vga std
qm set 105 --balloon 512
```

> **`--cpu host` is required** — see lesson below about x86-64-v2.

### Install SSH key

```bash
PUBKEY=$(cat ~/.ssh/authorized_keys | head -1)

guestfish -a /dev/pve/vm-105-disk-0 -i <<FISH
mkdir-p /root/.ssh
write /root/.ssh/authorized_keys "${PUBKEY}\n"
chmod 0700 /root/.ssh
chmod 0600 /root/.ssh/authorized_keys
FISH
```

> **Always write the actual key from `~/.ssh/authorized_keys`.** Using a redacted placeholder from documentation causes SSH auth to fail on first boot.

### First boot

```bash
qm start 105
sleep 80
ping -c 2 192.168.0.86   # PING OK ✅
```

### Problem: Filesystem dirty flag after force-kill

A force-kill (`kill -9` on the QEMU process) without graceful shutdown left the filesystem with a dirty flag. Next boot: PING FAILED.

**Fix:** Stop VM, expose inner partitions with kpartx, fsck both partitions:

```bash
# Expose partition devices inside the LV
kpartx -av /dev/pve/vm-105-disk-0
# Creates: /dev/mapper/pve-vm--105--disk--0p1  (EFI)
#          /dev/mapper/pve-vm--105--disk--0p2  (boot /ext4)

# Activate ubuntu-vg from within the LV
vgscan
vgchange -ay ubuntu-vg

# fsck both ext4 filesystems
e2fsck -p /dev/mapper/pve-vm--105--disk--0p2    # /boot partition
e2fsck -p /dev/ubuntu-vg/ubuntu-lv              # root partition

# Cleanup
kpartx -dv /dev/pve/vm-105-disk-0
```

### Problem: MySQL 8.0 crashing — CPU does not support x86-64-v2

After restart, three Docker containers came up fine but `guac-db` (MySQL 8.0) kept crashing:

```
Fatal glibc error: CPU does not support x86-64-v2
```

**Root cause:** The default Proxmox CPU model is `kvm64`, which emulates a baseline x86-64 CPU without AVX/POPCNT instructions. MySQL 8.0 (and any modern glibc binary) requires x86-64-v2 feature level (SSE4.2, POPCNT, etc.).

**Fix:**

```bash
qm stop 105
qm set 105 --cpu host    # Expose all host CPU features to VM
qm start 105
```

### Final state

```bash
ssh root@192.168.0.86 "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
# guacamole   Up    8080/tcp
# nginx       Up    0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
# guac-db     Up (healthy)    3306/tcp
# guacd       Up    4822/tcp
```

### Final VM 105 config

```
bios: ovmf
cpu: host
efidisk0: local-lvm:vm-105-disk-1,efitype=4m,pre-enrolled-keys=0
machine: q35
net0: virtio=BC:24:11:EA:C0:FD,bridge=vmbr0
scsi0: local-lvm:vm-105-disk-0,size=40G
serial0: socket
vga: std
balloon: 512
```

Guacamole web UI: `http://192.168.0.86` / `https://192.168.0.86`

---

## 12. Final VM States

| VM | Name | Status | Disk | IP | Notes |
|----|------|--------|------|----|-------|
| 100 | dc | Stopped | scsi0 (20GB) | — | Needs OVMF + VirtIO SCSI driver install |
| 101 | rds | Stopped | scsi0 (22GB) | — | Needs OVMF + VirtIO SCSI driver install |
| 102 | rds2 | Stopped | scsi0 (90GB) | — | Base vhdx only, checkpoint NOT merged |
| 103 | arthur | Stopped | scsi0 (54GB) + scsi1 (55GB) | — | Linux, needs netplan + IP config |
| **104** | **arthur-server2** | **Running** | scsi0 (90GB) + scsi1 (180GB) | **192.168.0.87** | **GPU+AI fully working ✅** |
| **105** | **guacamole** | **Running** | scsi0 (40GB) | **192.168.0.86** | **All Docker containers healthy ✅** |
| **106** | **yt** | **Running** | scsi0 (127GB) | **192.168.0.92** | **VirtIO SCSI working ✅** |

### VM 104 — Full Spec
```
Cores:    6
RAM:      40 GB (balloon min 1 GB)
GPU:      RTX 5060 Ti (16GB VRAM) via PCIe passthrough
CUDA:     12.8
PyTorch:  2.11.0+cu128
SSH:      ssh arthur@192.168.0.87 (passwordless key)
AI env:   /home/arthur/ai-env
```

### VM 105 — Full Spec
```
Cores:    2
RAM:      2 GB (balloon min 512 MB)
CPU:      host (required for x86-64-v2 / MySQL 8.0)
OS:       Ubuntu Linux
Disk:     40 GB (LVM on LVM: ubuntu-vg/ubuntu-lv)
NIC:      VirtIO Ethernet
IP:       192.168.0.86
SSH:      ssh root@192.168.0.86 (passwordless key)
Docker:   guacamole, guacd, nginx, guac-db (MySQL 8.0)
Web UI:   http://192.168.0.86 / https://192.168.0.86
```

### VM 106 — Full Spec
```
Cores:   2
RAM:     4 GB
OS:      Windows Server 2019
Disk:    VirtIO SCSI, 127 GB (cache=writeback)
NIC:     VirtIO Ethernet
```

---

## 13. Remaining Work

### VMs 100 (dc) and 101 (rds) — Need VirtIO SCSI driver install

Use the dummy disk trick (same as VM 106):

```bash
# For each of 100 and 101:
VM=100   # or 101

# 1. Add OVMF
qm set $VM --bios ovmf --machine q35
qm set $VM --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0

# 2. Currently scsi0 but Windows doesn't have vioscsi — move back to sata0 first
qm set $VM --sata0 local-lvm:vm-${VM}-disk-0,cache=writeback
qm set $VM --delete scsi0
qm set $VM --boot order=sata0

# 3. Attach virtio-win ISO
qm set $VM --cdrom local:iso/virtio-win.iso

# 4. Create dummy 1GB disk as scsi0
lvcreate -T pve/data -V 1G -n vm-${VM}-disk-dummy
qm set $VM --scsi0 local-lvm:vm-${VM}-disk-dummy

# 5. Boot → let Windows install VirtIO SCSI from ISO
qm start $VM

# 6. After driver installs (verify via WinRM), shut down and switch
qm set $VM --scsi0 local-lvm:vm-${VM}-disk-0,cache=writeback
qm set $VM --delete sata0
qm set $VM --delete scsi1 2>/dev/null || true
qm set $VM --boot order=scsi0
lvremove -f pve/vm-${VM}-disk-dummy
qm start $VM
```

### VM 102 (rds2) — Checkpoint merge

```bash
# Copy both vhdx files to ext4 (avoids ntfs3 read issues)
cp '/mnt/nvme/vhds/rds2/Virtual Hard Disks/rds2.vhdx' /tmp/rds2-base.vhdx
cp '/mnt/nvme/vhds/rds2/Virtual Hard Disks/rds2_25E6B8CF-312E-49E9-B21E-26227247B5E2.avhdx' /tmp/rds2.avhdx

# Merge
qemu-img rebase -u -b /tmp/rds2-base.vhdx -F vhdx -f vhdx /tmp/rds2.avhdx
qemu-img convert -p -f vhdx /tmp/rds2.avhdx -O raw /dev/pve/vm-102-disk-0

# Cleanup
rm /tmp/rds2-base.vhdx /tmp/rds2.avhdx

# Then apply dummy disk trick for VirtIO SCSI
```

### VM 103 (arthur) — Linux config

Linux VMs support VirtIO SCSI natively (no driver install needed):

```bash
# Need OVMF + static IP via guestfish, and --cpu host
MAC=$(qm config 103 | grep net0 | grep -oP '[0-9A-F:]{17}')

# Apply same guestfish netplan patch as VM 104 / 105
# Assign an IP (TBD), set --cpu host
qm set 103 --bios ovmf --machine q35 --cpu host
qm set 103 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm set 103 --serial0 socket --vga std
qm start 103
```

---

## 14. Key Lessons Learned

### 1. VirtIO SCSI PCI controller is invisible without a scsi disk

**The single most important finding of this project.**

The VirtIO SCSI controller `VEN_1AF4&DEV_1004` only enumerates in Windows Device Manager when at least one VirtIO SCSI disk is attached to the VM. Without a scsi disk, the PCI controller doesn't appear, Windows PnP never binds the driver, and no amount of registry manipulation will fix the BSOD.

**Solution:** Attach a dummy scsi disk while the main disk is still on sata0. Let Windows install the driver via its own PnP stack. Then switch.

### 2. ntfs-3g (FUSE) causes qemu-img VHDX header read failures

Always use the kernel-native `ntfs3` driver for NVMe/SSD NTFS volumes on Proxmox. If `qemu-img info` on a `.vhdx` or `.avhdx` fails, try copying to ext4 first.

```bash
umount /mnt/nvme && mount -t ntfs3 /dev/nvme0n1p1 /mnt/nvme
```

### 3. Secure Boot must be OFF for NVIDIA open kernel module

`pre-enrolled-keys=0` in the efidisk config disables Secure Boot at the OVMF level. Required for `nvidia-driver-580-open`.

### 4. `x-vga=1` breaks noVNC

GPU passthrough with `x-vga=1` makes the GPU claim primary display, which disables the virtual `vga` device used by noVNC/SPICE. Use `hostpci0 ...,pcie=1` (without x-vga) and keep `--vga std` for remote console access.

### 5. The correct LVM thin pool name is `pve/data` not `pve/pve-data`

```bash
lvs pve           # Shows actual LV names
lvextend -l +100%FREE pve/data   # Correct ✅
```

### 6. Activate thin LVs before guestfish

Proxmox thin-provisioned LVs start in an inactive state (`Vwi---tz--`). guestfish will fail to open them until activated:

```bash
lvchange -ay pve/vm-105-disk-0
lvs pve | grep vm-105   # Confirm: Vwi-a-tz--
```

### 7. Always use `--cpu host` for any VM running Docker with MySQL 8.0+ or modern glibc

The default `kvm64` CPU model does not expose x86-64-v2 instructions (SSE4.2, POPCNT). MySQL 8.0 and newer glibc binaries fail with:
```
Fatal glibc error: CPU does not support x86-64-v2
```

`--cpu host` passes all physical CPU features through to the VM. Apply it to all Linux VMs running modern software:

```bash
qm set <vmid> --cpu host
```

### 8. After force-killing a QEMU process, fsck the VM's filesystems before restarting

```bash
kpartx -av /dev/pve/vm-105-disk-0     # Expose inner partitions
vgscan && vgchange -ay ubuntu-vg       # Activate nested LVM if present
e2fsck -p /dev/mapper/pve-vm--105--disk--0p2
e2fsck -p /dev/ubuntu-vg/ubuntu-lv
kpartx -dv /dev/pve/vm-105-disk-0     # Clean up
```

### 9. WinRM authentication for Workgroup VMs

```powershell
# Must use .\username (dot-backslash for local account)
# Must use -Authentication Negotiate (not NTLM or Default)
# TrustedHosts must include the target IP (requires admin elevation)
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.0.92" -Force

$so   = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
$cred = New-Object PSCredential(".\farid", (ConvertTo-SecureString "YOUR_PASSWORD_HERE" -AsPlainText -Force))
$s    = New-PSSession -ComputerName 192.168.0.92 -Credential $cred `
        -SessionOption $so -Authentication Negotiate
```

---

## 15. Quick Reference — All Commands

### NVMe mount
```bash
mount -t ntfs3 /dev/nvme0n1p1 /mnt/nvme
```

### Check storage
```bash
pvesm status
lvs pve
vgdisplay pve | grep Free
```

### VM operations
```bash
qm list                          # List all VMs
qm status <vmid>                 # VM status
qm start/stop/reboot <vmid>      # Power control
qm config <vmid>                 # Show VM config
qm terminal <vmid>               # Serial console (requires serial0: socket)
qm set <vmid> --key value        # Modify config
qm importdisk <vmid> file.vhdx local-lvm  # Import VHDX
```

### LVM thin pool
```bash
lvcreate -T pve/data -V 1G -n vm-106-disk-2   # Create thin LV
lvremove -f pve/vm-106-disk-2                   # Remove LV
```

### guestfish offline disk inspection/patching
```bash
guestfish --ro -a /dev/pve/vm-104-disk-0 -i ls /etc/netplan/
guestfish --ro -a /dev/pve/vm-104-disk-0 -i cat /etc/netplan/50-cloud-init.yaml
guestfish -a /dev/pve/vm-104-disk-0 -i upload /local/file /remote/path
guestfish -a /dev/pve/vm-104-disk-0 -i download /remote/file /local/path
```

### VHDX checkpoint merge
```bash
# 1. Link child to parent
qemu-img rebase -u -b base.vhdx -F vhdx -f vhdx child.avhdx
# 2. Convert merged chain to raw
qemu-img convert -p -f vhdx child.avhdx -O raw /dev/pve/vm-XYZ-disk-0
```

### SSH to VMs
```bash
ssh arthur@192.168.0.87   # VM 104 (passwordless key)
ssh root@192.168.0.86      # VM 105 guacamole (passwordless key)
```

### WinRM to VM 106
```powershell
# (Elevated PowerShell on management machine)
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "192.168.0.92" -Force
$so   = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
$cred = New-Object PSCredential(".\farid", (ConvertTo-SecureString "YOUR_PASSWORD_HERE" -AsPlainText -Force))
$s    = New-PSSession -ComputerName 192.168.0.92 -Credential $cred -SessionOption $so -Authentication Negotiate
Invoke-Command -Session $s -ScriptBlock { hostname; sc.exe qc vioscsi }
```

---

## Scripts Reference

| Script | Purpose |
|--------|---------|
| [scripts/import-vms.sh](scripts/import-vms.sh) | Create all 7 VMs and import VHDX disks |
| [scripts/setup-vfio.sh](scripts/setup-vfio.sh) | Configure VFIO passthrough for RTX 5060 Ti |
| [scripts/fix-linux-vm-networking.sh](scripts/fix-linux-vm-networking.sh) | Offline-patch Linux VM disk for static IP + serial console |
| [scripts/vioscsi-registry-fix.ps1](scripts/vioscsi-registry-fix.ps1) | PowerShell: set all registry keys for vioscsi BOOT_START |
| [scripts/vioscsi-dummy-disk-trick.sh](scripts/vioscsi-dummy-disk-trick.sh) | Full automated dummy disk workflow for Windows VirtIO SCSI |
| [scripts/install-ai-stack.sh](scripts/install-ai-stack.sh) | Install CUDA 12.8 + PyTorch 2.11 + AI libs on Ubuntu |
