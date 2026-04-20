#!/bin/bash
# ============================================================
# vioscsi-dummy-disk-trick.sh
# Install VirtIO SCSI driver in a Windows VM that currently
# boots from sata0 by briefly attaching a 1GB dummy scsi disk,
# letting Windows PnP detect the VirtIO SCSI controller and
# auto-install vioscsi.sys, then switching the main disk to scsi0.
#
# Prereqs:
#   - VM is running Windows, currently boots from sata0
#   - VirtIO ISO drivers visible inside Windows (ideally pre-installed)
#   - WinRM enabled inside Windows for verification (optional)
#
# Usage: VM_ID=106 bash vioscsi-dummy-disk-trick.sh
# ============================================================

set -e

VM_ID="${VM_ID:-106}"
MAIN_DISK="local-lvm:vm-${VM_ID}-disk-0"
EFI_DISK="local-lvm:vm-${VM_ID}-disk-1"

echo "=== [1/6] Stop VM ${VM_ID} ==="
qm stop "$VM_ID" --timeout 30 2>/dev/null || true
sleep 5
qm status "$VM_ID"

echo "=== [2/6] Create 1GB thin-provisioned dummy LV ==="
lvcreate -T pve/data -V 1G -n "vm-${VM_ID}-disk-2"
echo "Dummy LV created: pve/vm-${VM_ID}-disk-2"

echo "=== [3/6] Attach dummy as scsi0 (main disk stays on sata0) ==="
qm set "$VM_ID" --scsi0 "local-lvm:vm-${VM_ID}-disk-2"
qm config "$VM_ID" | grep -E "sata0|scsi0"

echo "=== [4/6] Boot VM — Windows PnP will detect the SCSI controller ==="
echo "    The VirtIO SCSI PCI controller (VEN_1AF4) is INVISIBLE to Windows"
echo "    until at least one scsi disk is attached. This boot makes it visible."
qm start "$VM_ID"

echo ""
echo "    >>> WAIT for Windows to fully boot and install the driver <<<"
echo "    >>> You can verify via WinRM:"
echo "        sc.exe qc vioscsi  →  should show START_TYPE: 0 BOOT_START"
echo ""
echo "    Press ENTER when Windows has booted and you confirmed vioscsi is BOOT_START..."
read -r _

echo "=== [5/6] Shut down Windows gracefully ==="
echo "    (Use WinRM: Stop-Computer -Force, or wait for user to shut down)"
echo "    Press ENTER once Windows is fully off..."
read -r _
qm status "$VM_ID"

echo "=== [6/6] Move main disk from sata0 to scsi0, remove dummy ==="
# Move main disk to scsi0
qm set "$VM_ID" --scsi0 "${MAIN_DISK},cache=writeback"
# Remove sata0
qm set "$VM_ID" --delete sata0
# Remove dummy scsi1 if it was pushed there
qm set "$VM_ID" --delete scsi1 2>/dev/null || true
# Set boot order
qm set "$VM_ID" --boot order=scsi0

echo "=== Verifying config ==="
qm config "$VM_ID" | grep -E "scsi|sata|boot"

echo "=== Starting VM ==="
qm start "$VM_ID"

echo "=== Waiting 120s for boot ==="
sleep 120
ping -c 4 -W 2 "$(qm config $VM_ID | grep -oP '192\.168\.[0-9]+\.[0-9]+' | head -1)" \
  && echo "PING_OK — VirtIO SCSI is working!" \
  || echo "PING_FAILED — check VM console"

echo ""
echo "=== Cleanup: remove dummy LV ==="
lvremove -f "pve/vm-${VM_ID}-disk-2" && echo "Dummy LV removed"
