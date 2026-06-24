# ZeroTier Linux 卸载清理工具

本目录用于在 Linux 服务器上卸载并清理 ZeroTier。适用于 Debian、Ubuntu、Proxmox VE、CentOS、RHEL、Rocky Linux、AlmaLinux、Arch Linux、openSUSE、Alpine 等常见发行版。

> **重要提醒**：如果你当前是通过 ZeroTier 远程 SSH 登录到服务器，执行卸载后可能会立刻断线。请先确认你还有其他可用管理入口，例如公网 SSH、Tailscale、内网 IP、iDRAC/IPMI、PVE/TrueNAS 控制台或云厂商 VNC 控制台。

## 文件说明

```text
zerotier-remove-kit/
├── remove_zerotier_linux.sh   # Linux ZeroTier 卸载与残留清理脚本
└── README.md                  # 使用说明
```

## 快速使用

在目标服务器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zerotier-remove-kit/remove_zerotier_linux.sh -o remove_zerotier_linux.sh
chmod +x remove_zerotier_linux.sh
sudo bash remove_zerotier_linux.sh
```

或者克隆仓库后执行：

```bash
git clone https://github.com/xmusphlkg/serverfixed.git
cd serverfixed/zerotier-remove-kit
sudo bash remove_zerotier_linux.sh
```

## 脚本会做什么

脚本主要执行以下操作：

1. 显示当前 ZeroTier 状态和加入的网络。
2. 停止并禁用 `zerotier-one` 服务。
3. 根据发行版自动卸载 `zerotier-one` 软件包。
4. 删除 ZeroTier 软件源和 GPG key。
5. 删除常见配置目录和 systemd drop-in 配置。
6. 默认删除 `/var/lib/zerotier-one`，包括节点身份、网络配置和运行状态。
7. 清理残留的 `zt*` 网络接口。
8. 输出验证信息，帮助判断是否清理干净。

## 可选参数

### 保留 ZeroTier 节点身份

如果你只是临时卸载软件，但希望以后恢复同一个 ZeroTier 节点身份，可以保留 `/var/lib/zerotier-one`：

```bash
sudo bash remove_zerotier_linux.sh --keep-identity
```

### 跳过 apt update

在 Debian、Ubuntu、PVE 上，脚本删除 ZeroTier apt 源之后默认会运行 `apt-get update`。如果当前源有问题，或者你希望稍后手动更新，可以跳过：

```bash
sudo bash remove_zerotier_linux.sh --no-apt-update
```

### 查看帮助

```bash
bash remove_zerotier_linux.sh --help
```

## 卸载后验证

脚本结尾会自动输出验证信息。你也可以手动执行：

```bash
which zerotier-cli || true
which zerotier-one || true
ps aux | grep -i '[z]erotier' || true
systemctl list-units --type=service --all | grep -i zerotier || true
systemctl list-unit-files | grep -i zerotier || true
ip addr | grep -i zt || true
ip route | grep -i zt || true
ip -6 route | grep -i zt || true
```

如果以上命令基本没有输出，通常说明 ZeroTier 已经清理干净。

## 常见问题

### 1. 卸载后 SSH 断开怎么办？

如果你是通过 ZeroTier 地址连接，卸载后断线是正常现象。需要通过其他入口重新登录，例如：

- 公网 IP SSH
- Tailscale 地址
- 内网地址
- PVE/TrueNAS 控制台
- 云服务器 VNC 控制台
- iDRAC/IPMI

### 2. 是否一定要删除 `/var/lib/zerotier-one`？

如果你希望彻底清理，建议删除。该目录包含 ZeroTier 节点身份、加入过的网络和本地状态。

如果你未来还想让这台机器以同一个 ZeroTier 节点身份重新加入网络，可以使用：

```bash
sudo bash remove_zerotier_linux.sh --keep-identity
```

### 3. 为什么卸载后还看到 `ztxxxx` 网卡？

少数情况下服务停止后虚拟网卡仍然残留。脚本会尝试自动删除。如果仍然存在，可以手动执行：

```bash
for i in $(ip -o link show | awk -F': ' '/zt/{print $2}' | cut -d'@' -f1); do
  sudo ip link delete "$i" 2>/dev/null || true
done
```

### 4. 适合被入侵服务器吗？

这个脚本只负责卸载和清理 ZeroTier 本身。若服务器曾经被入侵，还需要继续检查：

```bash
sudo crontab -l
crontab -l
sudo systemctl list-timers --all
sudo systemctl list-unit-files | grep enabled
ls -la /etc/systemd/system/
ls -la /tmp /dev/shm
ps aux --sort=-%cpu | head -30
ps aux --sort=-%mem | head -30
ss -tulpn
```

对于确认被入侵的服务器，建议优先隔离、备份证据、轮换密码和密钥，并评估是否需要重装系统。
