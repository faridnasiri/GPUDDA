#!/bin/bash
# ============================================================
# fix-linux-vm-networking.sh
# Offline-patch a Linux VM disk (Ubuntu/Debian with netplan)
# via guestfish to:
#   - Disable cloud-init network management
#   - Mask cloud-init/networkd-wait-online systemd units
#   - Write static netplan config (eth0 with correct MAC)
#   - Enable serial console (serial-getty@ttyS0)
#   - Fix GRUB for serial + console output
# Run on Proxmox host while the VM is stopped.
#
# Usage: VM_ID=104 MAC=bc:24:11:0a:15:e6 IP=192.168.0.200 bash fix-linux-vm-networking.sh
# ============================================================

set -e

VM_ID="${VM_ID:-104}"
MAC="${MAC:-bc:24:11:0a:15:e6}"
IP="${IP:-192.168.0.200}"
GW="${GW:-192.168.0.1}"
DISK="/dev/pve/vm-${VM_ID}-disk-0"

echo "=== Patching VM $VM_ID disk: $DISK ==="

guestfish -a "$DISK" -i <<FISH
# -- Cloud-init: disable network config
write /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg "network: {config: disabled}\n"

# -- Mask units that stall boot when no DHCP is answered
ln-sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln-sf /dev/null /etc/systemd/system/cloud-init-local.service
ln-sf /dev/null /etc/systemd/system/cloud-init.service
ln-sf /dev/null /etc/systemd/system/cloud-final.service
ln-sf /dev/null /etc/systemd/system/cloud-config.service

# -- Remove any conflicting netplan files
-rm /etc/netplan/50-cloud-init.yaml

# -- Write static IP netplan (eth0 matched by MAC)
write /etc/netplan/99-static.yaml "network:\n    version: 2\n    ethernets:\n        eth0:\n            match:\n                macaddress: ${MAC}\n            set-name: eth0\n            addresses:\n                - ${IP}/24\n            routes:\n                - to: default\n                  via: ${GW}\n            nameservers:\n                addresses: [8.8.8.8]\n            dhcp4: false\n"

# -- Enable serial-getty@ttyS0 (so 'qm terminal' works)
ln-sf /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
FISH

echo "=== Patching GRUB for serial console ==="
guestfish --ro -a "$DISK" -i download /boot/grub/grub.cfg /tmp/vm${VM_ID}-grub.cfg

# Add serial init if not present
grep -q "serial --speed" /tmp/vm${VM_ID}-grub.cfg || \
  sed -i "1s/^/serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\n/" \
    /tmp/vm${VM_ID}-grub.cfg

# Enable serial terminal in grub menu
sed -i "s/terminal_input console/terminal_input serial console/"   /tmp/vm${VM_ID}-grub.cfg
sed -i "s/terminal_output console/terminal_output serial console/" /tmp/vm${VM_ID}-grub.cfg

# Clear recordfail if stuck
sed -i "s/recordfail=1/recordfail=0/" /tmp/vm${VM_ID}-grub.cfg

guestfish -a "$DISK" -i upload /tmp/vm${VM_ID}-grub.cfg /boot/grub/grub.cfg
echo "=== Done. Start VM with: qm start $VM_ID ==="
