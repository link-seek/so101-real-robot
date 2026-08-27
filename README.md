# SO101 真机 (Real Robot) 部署文档

本项目记录 **SO-ARM101 真实机械臂** 通过 **WSL2 + LeRobot v0.6.0 + R2C SDK** 接入华为云 **CloudRobo** 具身智能平台、进行云端推理真机执行的完整过程。

包含：环境搭建、USB 透传、标定、相机配置、CloudRobo 连接、云侧操作，以及搭建过程中遇到的所有坑与解决方案。

---

## 1. 硬件清单

| 设备 | 接口 | Windows 标识 | WSL 标识 | 说明 |
|------|------|-------------|----------|------|
| SO-ARM101 从臂 (Follower) | USB 转串口 (CH343) | COM24 (busid `5-2`) | `/dev/ttyACM0` | 执行云端动作 |
| 相机 1 (前置) | USB UVC | busid `4-1` | `/dev/video0` | 发送观测 |
| 相机 2 (腕部) | USB UVC | busid `5-4` | `/dev/video1`(元数据)/`/dev/video2`(画面) | 发送观测 |
| 主机 | — | Windows 11 25H2 (build 26200) | WSL2 Ubuntu 24.04 | 运行边缘客户端 |

> 注：主臂 (Leader, COM22, busid `5-1`) 仅用于遥操/采集数据，**CloudRobo 推理不需要**。

---

## 2. 整体架构

```
[SO-ARM101 从臂 + 2 相机]
        │ (USB over usbipd-win)
        ▼
[WSL2 Ubuntu 24.04]  ← LeRobot v0.6.0 + R2C SDK 边缘客户端 (cloudroboclient)
        │ (Zenoh over TLS, 7447)
        ▼
[华为云 CloudRobo]  ← 云端模型推理，下发 action
```

边缘客户端 (`cloudroboclient`) 负责：
- 采集相机图像 + 关节状态 → 封装为 observation → 发布到云端
- 订阅云端下发的 action → 驱动从臂执行

---

## 3. 环境搭建步骤

### 3.1 安装 WSL2 + Ubuntu 24.04

**问题**：Windows 11 25H2 (build 26200) 上，旧版 `wsl_update_x64.msi` 安装报 **错误 1603**（不兼容新内核）。

**解决**：使用 **WSL 2.7.12** 的 MSI 安装包（`wsl-2.7.12.0.x64.msi`），再用 rootfs tar 导入：

```powershell
# 1. 安装 WSL 2.7.12 MSI（双击运行）
# 2. 导入 Ubuntu 24.04 rootfs 到 D:\WSL\Ubuntu2404
wsl --import Ubuntu2404 D:\WSL\Ubuntu2404 .\Ubuntu2404-rootfs.tar.gz
wsl -d Ubuntu2404
```

> 由于 GitHub 直连不稳定，所有安装包（WSL MSI、rootfs、Miniforge 等）通过 `link-seek/url2hc` 的
> GitHub Actions 工作流中转下载到 OBS（`robotwin-assets` 桶）后再拉回本地。

### 3.2 配置 WSL 常驻 + DNS

为让 USB 透传稳定，需让 WSL 始终保持运行并修复 DNS。

`/etc/wsl.conf`：

```ini
[boot]
systemd=true
[network]
generateResolvConf = false
```

启用 systemd 后 `systemd-resolved` 会接管 `/etc/resolv.conf` 导致解析失败，**需禁用并锁定静态 DNS**：

```bash
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved
sudo rm -f /etc/resolv.conf
echo 'nameserver 8.8.8.8'  | sudo tee /etc/resolv.conf
echo 'nameserver 114.114.114.114' | sudo tee -a /etc/resolv.conf
sudo chattr +i /etc/resolv.conf   # 锁定，防止被覆盖
```

### 3.3 安装 usbipd-win (Windows 侧)

下载安装 [usbipd-win v5.3.0](https://github.com/dorssel/usbipd-win/releases)。
将 3 个 USB 设备 **bind (共享)**（只需一次，重启后保留）：

```powershell
usbipd bind --busid 5-2
usbipd bind --busid 4-1
usbipd bind --busid 5-4
```

### 3.4 安装 WSL USB Manager（稳定透传）

**问题**：`usbipd attach` 是**非持久**的——WSL 停止或 bat 窗口关闭后设备会断连，导致标定时电机通信闪断。

**解决**：使用 [WSL USB Manager](https://github.com/nickbeth/wsl-usb-manager)（托盘常驻 GUI），
对 3 个设备设置 **Auto-Attach**，开机自动重连、拔插自动恢复。

- 下载 `wsl-usb-manager.exe` 放桌面双击运行
- 右键 3 个设备 → Bind → Attach to WSL → 勾选 Auto-Attach

### 3.5 Miniforge + Conda 环境

```bash
# WSL 内
bash Miniforge3-Linux-x86_64.sh -b -p /root/miniforge3
source /root/miniforge3/etc/profile.d/conda.sh
conda create -y -n lerobot python=3.12.14
conda activate lerobot
```

### 3.6 LeRobot v0.6.0 + feetech 驱动

```bash
git clone https://gitee.com/huggingface/lerobot.git   # gitee 镜像
cd lerobot && git checkout v0.6.0
pip install -e ".[feetech]"
```

> R2C SDK 要求 LeRobot >= v0.5.1，本项目使用 **v0.6.0**。
> 注意：旧版 (v0.3.4) 标定文件**不兼容** v0.6.0（见 §5.1）。

### 3.7 PyTorch (CUDA 13.0)

```bash
pip install torch==2.11.0+cu130 torchvision --index-url https://download.pytorch.org/whl/cu130
```

### 3.8 ffmpeg

```bash
conda install -y -c conda-forge ffmpeg
```

### 3.9 R2C SDK v0.1.79

```bash
cd /root/r2c_sdk_python
pip install -e .
# 依赖
pip install huaweicloudsdkobs huaweicloudsdkcore   # 用于 OBS 下载（可选）
```

### 3.10 gh CLI + opencode（辅助工具）

```bash
# gh CLI
tar -xf gh_linux.tar.gz && cp gh_*/bin/gh /usr/local/bin/
gh auth login   # 用 token 登录

# opencode（通过 npm）
conda install -y -c conda-forge nodejs
npm install -g opencode-ai
```

---

## 4. 机器人配置

配置文件见 [`config/robot_so101_lerobot_config.yaml`](config/robot_so101_lerobot_config.yaml)。
关键字段：

```yaml
hardware:
  type: "lerobot"
  config:
    robot:
      type: so101_follower
      id: my_awesome_follower_arm
      port: /dev/ttyACM0
      cameras:
        front:
          type: opencv
          index_or_path: /dev/video0
          warmup_s: 5
        wrist:
          type: opencv
          index_or_path: /dev/video2   # 注意：不是 video1
          warmup_s: 5
```

**凭证包** `cert_config.zip` 含私钥/证书，**切勿提交到公开仓库**（见 `.gitignore`）。
其 `device_info.json` 提供：
- `account_id`: `846dd4516542410ca4b3f1c9e1f926a6`
- `robot_id`: `634db97e28ad415fbdbe8d0089ae85b7`
- CloudRobo Zenoh 端点：`tls/cloudrobo-r2c.cn-southwest-2.myhuaweicloud.com:7447`

---

## 5. 标定 (Calibration)

标定文件见 [`calibration/my_awesome_follower_arm.json`](calibration/my_awesome_follower_arm.json)。

> **重要**：LeRobot v0.6.0 把标定存在
> `~/.cache/huggingface/lerobot/calibration/robots/so_follower/`（注意是 `so_follower`，
> 不是 config 里的 `so101_follower`）。`so101_follower` 目录下的是旧版 v0.3.4 残留，应忽略。

### 5.1 标定不匹配问题

**问题**：v0.3.4 (Windows) 标定的电机值，v0.6.0 校验时报
`Mismatch between calibration values in the motor and the calibration file`。

**解决**：在 WSL 内重新标定（见下）。

### 5.2 重新标定步骤

在 WSL 终端运行（**交互式，需手动移动机械臂**）：

```bash
source /root/miniforge3/etc/profile.d/conda.sh
conda activate lerobot
cd /root/r2c_sdk_python
python -m r2c_sdk.cloudroboclient \
  --bundle config/cert_config.zip \
  --robot-config config/robot_so101_lerobot_config.yaml \
  --private-key-password 'xyc123..'
```

流程：
1. 出现 `Mismatch...` 提示 → 进入标定
2. `Move ... to the middle ... press ENTER` → 移到中位，回车
3. `Move all joints ... through their entire ranges` → **依次把每个关节从一端转到另一端**
4. `Press ENTER to stop` → 转完回车，标定保存

**问题（elbow_flex 变负）**：转动幅度过大时 `elbow_flex` 读数会变成 **-153**（负位置），
写回电机时报 `ValueError: Negative values are not allowed`。

**解决**：转动时不要转到极限导致读数越界，保持 MIN/MAX 在 **0~4095** 区间即可。

---

## 6. 相机配置坑

**问题 1**：配置 `wrist` 相机为 `/dev/video1` 时 `OpenCVCamera(/dev/video1)` 打不开。

**原因**：每个 USB 相机在 WSL 下会创建多个 `/dev/video*` 节点（1 个画面 + 1 个元数据）。
实际 2 个相机对应 `/dev/video0`(相机1画面) 和 `/dev/video2`(相机2画面)。

**解决**：`wrist` 相机改为 `/dev/video2`。

**问题 2**：相机连接超时 `Timed out waiting for frame after 1000 ms`。

**解决**：给相机加 `warmup_s: 5`（默认 1 秒太短，双相机并发时预热不足）。

---

## 7. 连接 CloudRobo

```bash
# WSL 终端（保持运行，不要关）
source /root/miniforge3/etc/profile.d/conda.sh
conda activate lerobot
cd /root/r2c_sdk_python
python -m r2c_sdk.cloudroboclient \
  --bundle config/cert_config.zip \
  --robot-config config/robot_so101_lerobot_config.yaml \
  --private-key-password 'xyc123..'
```

成功日志特征：
```
Zenoh connecting to router(s): tls/cloudrobo-r2c...:7447 ... Connected to Zenoh router successfully
Heartbeat auto publish started ... status=ONLINE
OpenCVCamera(/dev/video0) connected.
OpenCVCamera(/dev/video2) connected.
my_awesome_follower_arm SOFollower connected.
```

**问题**：偶发 `Failed to establish connection during OPEN_SESSION ... Timeout`。
**原因**：WSL 重启后 DNS 又被重置（见 §3.2）。**解决**：重做 DNS 锁定后重跑。

---

## 8. 云侧操作（CloudRobo 控制台）

1. 登录 https://console.huaweicloud.com/cloudrobo/
2. **部署模型**：`运行管理` → `模型部署` → `部署模型服务`，选 SO101 可用模型，等状态「运行中」
3. **智能体调试**：`运行管理` → `机器人` → 找到在线机器人 → `智能体调试`
4. 点 `选择模型技能`，选运行中的模型服务
5. 输入任务 Prompt（如 `pick the pen into the box`）或用默认技能
6. 点开始，从臂即执行云端下发动作

> 前提：WSL 内 §7 的客户端必须保持运行。

---

## 9. 已知问题 / 待办

- [ ] opencode 桌面端无法识别 WSL 内的 opencode（待排查，暂不影响真机流程）
- [ ] 主臂 (Leader) 未接入 WSL（仅遥操需要，CloudRobo 推理不需要）
- [ ] `so101_follower` 目录下的旧版 v0.3.4 标定文件可清理

---

## 10. 关键命令速查

```powershell
# Windows: 查看/绑定 USB
usbipd list
usbipd bind --busid 5-2
```

```bash
# WSL: 查看设备节点
ls /dev/ttyACM* /dev/video*
# 测试相机出图
python -c "import cv2; print(cv2.VideoCapture(2).read()[0])"
# 检查 DNS
cat /etc/resolv.conf
```
