# serverfixed Linux 初始化脚本说明

文件：`linux_init_cn.sh`

这个脚本用于新装 Linux 服务器或新建 VM/CT 后的基础初始化，重点面向中国大陆网络环境下的 Debian、Ubuntu、Proxmox VE，也兼容部分 dnf/yum 系统的基础 SSH/sudo 初始化。

## 功能

1. 自动识别 Linux 发行版、版本号和 codename。
2. 对常见中国境内 apt mirror 进行延迟测试，自动选择最低延迟源。
3. 备份并替换系统 apt 源。
4. 执行 `apt update`，安装基础组件。
5. 默认执行 `apt upgrade -y`，可通过参数关闭。
6. 启动并启用 SSH 服务。
7. 新建或更新管理员用户，默认用户为 `likangguo`。
8. 交互式设置或修改 `likangguo` 密码。
9. 配置 sudo 权限。
10. 写入 SSH 基础安全配置。
11. 在 Proxmox VE 上可自动禁用 enterprise 源并添加 no-subscription 源。

## 支持范围

优先支持：

- Debian 10/11/12/13
- Ubuntu 20.04/22.04/24.04/26.04 及类似发行版
- Proxmox VE，基于 Debian
- Raspbian/Raspberry Pi OS，基础兼容

有限支持：

- Rocky Linux / AlmaLinux / CentOS / Fedora 等 dnf/yum 系统

说明：dnf/yum 系统目前不会自动替换国内 mirror，只会尝试更新缓存、安装 `sudo` 和 `openssh-server`，然后继续创建用户和配置 SSH。

## 一键运行

推荐在服务器控制台、PVE Console、iDRAC/iKVM 或稳定 SSH 会话中运行。首次运行会提示为 `likangguo` 设置密码。

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/linux_init_cn.sh -o /tmp/linux_init_cn.sh
sudo bash /tmp/linux_init_cn.sh
```

或者直接管道运行：

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/linux_init_cn.sh | sudo bash
```

注意：管道运行时通常不是交互式终端，可能无法输入密码。更推荐先下载脚本再执行。

## 推荐运行方式

```bash
cd /tmp
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/linux_init_cn.sh -o linux_init_cn.sh
chmod +x linux_init_cn.sh
sudo ./linux_init_cn.sh
```

## 常用参数

脚本通过环境变量控制行为。

### 指定用户名

默认创建或配置 `likangguo`。

```bash
INIT_USER=likangguo sudo bash /tmp/linux_init_cn.sh
```

### 跳过系统升级

如果是 PVE、生产服务器、GPU 服务器或不希望自动升级内核，建议先跳过 `apt upgrade`。

```bash
RUN_UPGRADE=0 sudo bash /tmp/linux_init_cn.sh
```

### 强制指定 mirror

如果自动测速失败，可以手动指定。

Debian：

```bash
MIRROR_FORCE=https://mirrors.ustc.edu.cn/debian sudo bash /tmp/linux_init_cn.sh
```

Ubuntu：

```bash
MIRROR_FORCE=https://mirrors.ustc.edu.cn/ubuntu sudo bash /tmp/linux_init_cn.sh
```

### SSH 密码登录策略

首次初始化建议保留密码登录：

```bash
SSH_PASSWORD_AUTH=yes sudo bash /tmp/linux_init_cn.sh
```

稳定后如果已经配置 SSH key，可以关闭密码登录：

```bash
SSH_PASSWORD_AUTH=no sudo bash /tmp/linux_init_cn.sh
```

### root SSH 登录策略

默认值：

```bash
SSH_ROOT_LOGIN=prohibit-password
```

含义是禁止 root 用密码登录，但仍允许 root 使用 SSH key 登录。

更严格的设置：

```bash
SSH_ROOT_LOGIN=no sudo bash /tmp/linux_init_cn.sh
```

### Proxmox VE enterprise 源处理

默认开启：

```bash
PVE_FIX_REPOS=1
```

脚本会尝试禁用：

- `/etc/apt/sources.list.d/pve-enterprise.list`
- 含 `enterprise.proxmox.com` 的 Ceph enterprise 源

并添加：

- `pve-no-subscription.list`
- 如果检测到 Ceph enterprise 源，也会添加对应的 Ceph no-subscription 源

如果不希望脚本处理 PVE 源：

```bash
PVE_FIX_REPOS=0 sudo bash /tmp/linux_init_cn.sh
```

## 脚本会修改哪些文件

### apt 源

会备份：

```bash
/etc/apt/serverfixed-backup-YYYYMMDD-HHMMSS/
```

可能会移动旧系统源到类似文件：

```bash
/etc/apt/sources.list.serverfixed.bak.YYYYMMDD-HHMMSS
/etc/apt/sources.list.d/debian.sources.serverfixed.bak.YYYYMMDD-HHMMSS
/etc/apt/sources.list.d/ubuntu.sources.serverfixed.bak.YYYYMMDD-HHMMSS
```

然后生成新的：

```bash
/etc/apt/sources.list
```

第三方源通常会保留，例如 Zabbix、Tailscale、Docker、Wazuh 等。PVE enterprise 源例外，默认会禁用。

### SSH 配置

会写入：

```bash
/etc/ssh/sshd_config.d/99-serverfixed-init.conf
```

默认内容包括：

```text
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
```

如果主配置没有 include drop-in 目录，会在 `/etc/ssh/sshd_config` 顶部加入：

```text
Include /etc/ssh/sshd_config.d/*.conf
```

并自动执行：

```bash
sshd -t
systemctl restart ssh || systemctl restart sshd
```

### sudo 配置

会写入：

```bash
/etc/sudoers.d/90-serverfixed-likangguo
```

内容：

```text
likangguo ALL=(ALL:ALL) ALL
```

并用 `visudo -cf` 验证语法。

## 初始化后验证

### 检查用户

```bash
id likangguo
getent passwd likangguo
sudo -l -U likangguo
```

### 检查 SSH

```bash
systemctl status ssh --no-pager || systemctl status sshd --no-pager
sshd -T | egrep 'permitrootlogin|passwordauthentication|pubkeyauthentication|x11forwarding|maxauthtries|clientalive'
```

### 检查 apt

```bash
cat /etc/apt/sources.list
sudo apt update
```

### 从另一台机器测试登录

```bash
ssh likangguo@服务器IP
sudo -v
```

## 回滚 apt 源

脚本会备份 apt 源。假设备份目录为：

```bash
/etc/apt/serverfixed-backup-20260624-120000/
```

可以手动回滚：

```bash
sudo cp -a /etc/apt/serverfixed-backup-20260624-120000/sources.list /etc/apt/sources.list
sudo rm -rf /etc/apt/sources.list.d
sudo cp -a /etc/apt/serverfixed-backup-20260624-120000/sources.list.d /etc/apt/sources.list.d
sudo apt update
```

## 回滚 SSH 配置

删除脚本生成的 SSH drop-in：

```bash
sudo rm -f /etc/ssh/sshd_config.d/99-serverfixed-init.conf
sudo sshd -t
sudo systemctl restart ssh || sudo systemctl restart sshd
```

## 建议的安全流程

首次初始化时可以暂时允许密码登录，方便部署：

```bash
SSH_PASSWORD_AUTH=yes sudo bash /tmp/linux_init_cn.sh
```

登录成功后，给 `likangguo` 添加 SSH 公钥：

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

确认公钥登录正常后，关闭密码登录：

```bash
sudo sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/99-serverfixed-init.conf
sudo sshd -t
sudo systemctl restart ssh || sudo systemctl restart sshd
```

## 常见问题

### 1. 自动测速全部失败

可能是 DNS、证书、时间或出站网络问题。可以强制指定 mirror：

```bash
MIRROR_FORCE=https://mirrors.ustc.edu.cn/debian sudo bash /tmp/linux_init_cn.sh
```

### 2. 管道运行后没有提示输入密码

这是因为管道运行不是交互式终端。请执行：

```bash
sudo passwd likangguo
```

### 3. PVE apt update 仍然出现 enterprise 401

检查是否还有 enterprise 源：

```bash
grep -R "enterprise.proxmox.com" /etc/apt/sources.list /etc/apt/sources.list.d || true
```

如仍存在，可以手动禁用对应文件后再运行：

```bash
sudo apt update
```

### 4. SSH 重启失败

先检查语法：

```bash
sudo sshd -t
```

如果失败，删除脚本生成的 drop-in 并恢复：

```bash
sudo rm -f /etc/ssh/sshd_config.d/99-serverfixed-init.conf
sudo sshd -t
sudo systemctl restart ssh || sudo systemctl restart sshd
```

## 日志

脚本日志默认写入：

```bash
/var/log/serverfixed-init.log
```

查看最近日志：

```bash
sudo tail -n 200 /var/log/serverfixed-init.log
```
