#!/bin/bash
# ============================================================
# setup-vfio.sh
# Configure VFIO-PCI passthrough for RTX 5060 Ti (10de:2d04)
# and its audio device (10de:xxxx) on Proxmox host
# Run as root on Proxmox host, triggers a reboot
# ============================================================

set -e

GPU_ID="10de:2d04"       # RTX 5060 Ti GFX
AUDIO_ID="10de:22bc"     # RTX 5060 Ti HD Audio (adjust if different)
PCI_SLOT="0000:05:00"    # Confirm with: lspci | grep -i nvidia

echo "=== Step 1: Enable IOMMU in GRUB ==="
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_iommu=on iommu=pt"/' \
    /etc/default/grub
update-grub

echo "=== Step 2: Load VFIO kernel modules at boot ==="
cat >> /etc/modules <<'EOF'
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF

echo "=== Step 3: Bind GPU to vfio-pci ==="
echo "options vfio-pci ids=${GPU_ID},${AUDIO_ID}" > /etc/modprobe.d/vfio.conf

echo "=== Step 4: Blacklist nouveau/nvidia on host ==="
cat > /etc/modprobe.d/blacklist-nvidia.conf <<'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
EOF

echo "=== Step 5: Rebuild initramfs ==="
update-initramfs -u -k all

echo "=== Rebooting in 3s ==="
sleep 3
reboot
