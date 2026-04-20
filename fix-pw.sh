#!/bin/bash
HASH=$(openssl passwd -6 'YOUR_PASSWORD_HERE')
echo "HASH generated"
guestfish -a /dev/pve/vm-104-disk-0 -i <<INNERFISH
command "usermod -p $HASH arthur"
command "usermod -p $HASH root"
INNERFISH
echo "pw fix done: $?"
echo "=== Verifying GRUB ==="
guestfish --ro -a /dev/pve/vm-104-disk-0 -i cat /etc/default/grub | grep -E 'CMDLINE|TIMEOUT|TERMINAL'
echo "=== cloud-init symlinks ==="
guestfish --ro -a /dev/pve/vm-104-disk-0 -i ls /etc/systemd/system/ | grep cloud
