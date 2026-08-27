#!/usr/bin/env bash
# SO101 真机 WSL 侧一键环境搭建（WSL 已导入并可联网后运行）
set -e

# 1. 修复 DNS（防止 systemd-resolved 覆盖）
sudo systemctl disable systemd-resolved 2>/dev/null || true
sudo systemctl stop systemd-resolved 2>/dev/null || true
sudo rm -f /etc/resolv.conf
echo 'nameserver 8.8.8.8'  | sudo tee /etc/resolv.conf
echo 'nameserver 114.114.114.114' | sudo tee -a /etc/resolv.conf
sudo chattr +i /etc/resolv.conf 2>/dev/null || true

# 2. 基础工具
sudo apt-get update
sudo apt-get install -y git git-lfs
git lfs install

# 3. Miniforge
source /root/miniforge3/etc/profile.d/conda.sh
conda create -y -n lerobot python=3.12.14
conda activate lerobot

# 4. LeRobot v0.6.0
git clone https://gitee.com/huggingface/lerobot.git /root/lerobot
cd /root/lerobot && git checkout v0.6.0
pip install -e ".[feetech]"

# 5. PyTorch (CUDA 13.0)
pip install torch==2.11.0+cu130 torchvision --index-url https://download.pytorch.org/whl/cu130

# 6. ffmpeg
conda install -y -c conda-forge ffmpeg

echo '=== 环境搭建完成 ==='
echo 'R2C SDK 需在 /root/r2c_sdk_python 手动 pip install -e .'
