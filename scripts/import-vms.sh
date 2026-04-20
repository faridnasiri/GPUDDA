#!/bin/bash
# ============================================================
# import-vms.sh
# Import 7 Hyper-V VHDX/AVHDX disks into Proxmox local-lvm
# Run on Proxmox host after NVMe is mounted at /mnt/nvme
# ============================================================

LOG="/tmp/import.log"
STORAGE="local-lvm"
VHDS="/mnt/nvme/vhds"
VHDS2="/mnt/nvme/vhds2"
WORK="/mnt/nvme/proxmox-work"
mkdir -p "$WORK"
exec > >(tee -a "$LOG") 2>&1

echo "[$(date)] === Creating VMs ==="
qm create 100 --name dc             --memory 4096  --cores 2 --net0 virtio,bridge=vmbr0 --ostype win2k19 --scsihw virtio-scsi-pci
qm create 101 --name rds            --memory 4096  --cores 2 --net0 virtio,bridge=vmbr0 --ostype win2k19 --scsihw virtio-scsi-pci
qm create 102 --name rds2           --memory 4096  --cores 2 --net0 virtio,bridge=vmbr0 --ostype win2k19 --scsihw virtio-scsi-pci
qm create 103 --name arthur         --memory 4096  --cores 2 --net0 virtio,bridge=vmbr0 --ostype l26     --scsihw virtio-scsi-pci
qm create 104 --name arthur-server2 --memory 4096  --cores 2 --net0 virtio,bridge=vmbr0 --ostype l26     --scsihw virtio-scsi-pci
qm create 105 --name guacamole      --memory 2048  --cores 2 --net0 virtio,bridge=vmbr0 --ostype l26     --scsihw virtio-scsi-pci
qm create 106 --name yt             --memory 4096  --cores 2 --net0 virtio,bridge=vmbr0 --ostype l26     --scsihw virtio-scsi-pci
echo "[$(date)] VMs created"

echo "[$(date)] === dc (20GB) ==="
qm importdisk 100 "$VHDS/dc/dc/dc/Virtual Hard Disks/dc.vhdx" $STORAGE
qm set 100 --scsi0 ${STORAGE}:vm-100-disk-0 --boot order=scsi0
echo "[$(date)] dc done"

echo "[$(date)] === rds (22GB) ==="
qm importdisk 101 "$VHDS/rds/Virtual Hard Disks/rds.vhdx" $STORAGE
qm set 101 --scsi0 ${STORAGE}:vm-101-disk-0 --boot order=scsi0
echo "[$(date)] rds done"

echo "[$(date)] === arthur (54+55GB) ==="
qm importdisk 103 "$VHDS2/arthur/Virtual Hard Disks/arthur-os.vhdx" $STORAGE
qm importdisk 103 "$VHDS2/arthur/Virtual Hard Disks/arthur-seed.vhdx" $STORAGE
qm set 103 --scsi0 ${STORAGE}:vm-103-disk-0 --scsi1 ${STORAGE}:vm-103-disk-1 --boot order=scsi0
echo "[$(date)] arthur done"

echo "[$(date)] === arthur-server2 (55+55GB) ==="
qm importdisk 104 "$VHDS2/arthur-server2/Virtual Hard Disks/arthur-server2-os.vhdx" $STORAGE
qm importdisk 104 "$VHDS2/arthur-server2/Virtual Hard Disks/arthur-server2-seed.vhdx" $STORAGE
qm set 104 --scsi0 ${STORAGE}:vm-104-disk-0 --scsi1 ${STORAGE}:vm-104-disk-1 --boot order=scsi0
echo "[$(date)] arthur-server2 done"

echo "[$(date)] === guacamole (15GB) ==="
qm importdisk 105 "$VHDS2/guacamole/Virtual Hard Disks/guacamole-os.vhdx" $STORAGE
qm set 105 --scsi0 ${STORAGE}:vm-105-disk-0 --boot order=scsi0
echo "[$(date)] guacamole done"

echo "[$(date)] === rds2 - merging snapshot chain ==="
# rds2 has a checkpoint: rds2.vhdx (base) + rds2_25E6B8CF...avhdx (delta)
qemu-img rebase -u \
  -b "$VHDS/rds2/Virtual Hard Disks/rds2.vhdx" -F vhdx \
  -f vhdx "$VHDS/rds2/Virtual Hard Disks/rds2_25E6B8CF-312E-49E9-B21E-26227247B5E2.avhdx"
qemu-img convert -p -f vhdx \
  "$VHDS/rds2/Virtual Hard Disks/rds2_25E6B8CF-312E-49E9-B21E-26227247B5E2.avhdx" \
  -O raw /dev/pve/vm-102-disk-0
qm set 102 --scsi0 local-lvm:vm-102-disk-0 --boot order=scsi0
echo "[$(date)] rds2 done"

echo "[$(date)] === yt - merging snapshot chain ==="
# yt has a checkpoint: yt.vhdx (base) + yt_FB7CE1FA...avhdx (delta)
qemu-img rebase -u \
  -b "$VHDS2/yt/Virtual Hard Disks/yt.vhdx" -F vhdx \
  -f vhdx "$VHDS2/yt/Virtual Hard Disks/yt_FB7CE1FA-F4E1-4C04-A35D-DE63FFE66A1F.avhdx"
qemu-img convert -p -f vhdx \
  "$VHDS2/yt/Virtual Hard Disks/yt_FB7CE1FA-F4E1-4C04-A35D-DE63FFE66A1F.avhdx" \
  -O raw /dev/pve/vm-106-disk-0
qm set 106 --scsi0 local-lvm:vm-106-disk-0 --boot order=scsi0
echo "[$(date)] yt done"

echo "[$(date)] === ALL IMPORTS COMPLETE ==="
qm list
