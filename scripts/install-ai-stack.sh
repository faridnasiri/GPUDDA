#!/bin/bash
# ============================================================
# install-ai-stack.sh
# Run as `arthur` user on VM 104 (Ubuntu with NVIDIA GPU).
# Installs CUDA 12.8, PyTorch 2.11 (cu128), and common AI libs.
# ============================================================

set -e
LOG="/tmp/ai-setup.log"
exec > >(tee -a "$LOG") 2>&1

echo "[$(date)] === Starting AI stack install ==="

# ---- CUDA Toolkit 12.8 ----
echo "[$(date)] Installing CUDA 12.8 keyring..."
wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cuda-toolkit-12-8
echo "[$(date)] CUDA toolkit installed"

# ---- Python venv ----
echo "[$(date)] Creating Python venv at ~/ai-env..."
python3 -m venv ~/ai-env
source ~/ai-env/bin/activate

# ---- PyTorch 2.11 with CUDA 12.8 ----
echo "[$(date)] Installing PyTorch 2.11+cu128..."
pip install --upgrade pip -q
pip install torch==2.11.0+cu128 torchvision torchaudio \
    --index-url https://download.pytorch.org/whl/cu128

# ---- Common AI libraries ----
pip install \
    transformers \
    accelerate \
    datasets \
    numpy \
    scipy \
    pillow \
    huggingface-hub \
    bitsandbytes \
    peft

echo "[$(date)] === Verifying CUDA availability ==="
python - <<'PY'
import torch
print(f"PyTorch: {torch.__version__}")
print(f"CUDA available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"GPU: {torch.cuda.get_device_name(0)}")
    print(f"VRAM: {torch.cuda.get_device_properties(0).total_memory // 1024**2} MB")
PY

echo "[$(date)] === AI stack install COMPLETE ==="
