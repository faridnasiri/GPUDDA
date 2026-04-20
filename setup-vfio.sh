#!/bin/bash
set -e

echo "=== Stopping VM 104 ==="
qm stop 104 2>/dev/null || true
sleep 2

echo "=== Adding intel_iommu=on iommu=pt to GRUB ==="
if ! grep -q "iommu=pt" /etc/default/grub; then
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_iommu=on iommu=pt"/' /etc/default/grub
  echo "GRUB updated"
else
  echo "iommu=pt already present"
fi
grep GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub

echo "=== Configuring vfio-pci IDs ==="
cat > /etc/modprobe.d/vfio.conf << 'EOF'
options vfio-pci ids=10de:2d04,10de:22eb disable_vga=1
EOF
cat /etc/modprobe.d/vfio.conf

echo "=== Blacklisting nouveau/nvidia ==="
cat > /etc/modprobe.d/blacklist-gpu.conf << 'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist snd_hda_codec_hdmi
options nouveau modeset=0
EOF
cat /etc/modprobe.d/blacklist-gpu.conf

echo "=== Adding vfio modules to /etc/modules ==="
for mod in vfio vfio_iommu_type1 vfio_pci; do
  grep -qx "$mod" /etc/modules || echo "$mod" >> /etc/modules
done
grep -E "vfio" /etc/modules

echo "=== Updating initramfs ==="
update-initramfs -u -k all 2>&1 | tail -5

echo "=== Updating GRUB ==="
update-grub 2>&1 | tail -3

echo "=== ALL DONE — rebooting in 5s ==="
sleep 5
reboot
