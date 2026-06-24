# serverfixed Linux 初始化脚本说明

文件：`linux_init_cn.sh`

这个脚本现在采用 **分层初始化** 设计：默认只做最稳定、最关键的第一步——自动识别系统、测试中国境内 apt mirror、选择最快 mirror、备份旧源并写入新的系统 apt 源。后续的 `apt update`、安装 SSH/sudo、创建用户、修改 SSH 配置等步骤，由管理员按本文档手动执行。

这样做的原因是：新装系统、PVE VM、校园网、IPv6 异常、DNS 异常、Ubuntu 短周期版本、apt 锁、第三方源损坏等场景非常常见。如果全部串联自动执行，任意一步失败都会导致初始化脚本中断。现在脚本只负责先把系统 apt 源修好，后面的动作清晰列出，便于人工判断和回滚。

## 默认功能

1. 自动识别 Linux 发行版、版本号和 codename。
2. 对常见中国境内 apt mirror 进行延迟测试。
3. 自动选择最低延迟 mirror。
4. 备份原 apt 源。
5. 清理 `/etc/apt/sources.list.d/` 中会导致 apt 提示 `Ignoring file ... invalid filename extension` 的 `.bak*`、`.disabled*`、`.save`、`.distUpgrade` 文件。
6. 将旧系统源移出到 `/etc/apt/serverfixed-disabled-*`。
7. 写入新的 `/etc/apt/sources.list`。
8. 写入 apt IPv4/超时配置，避免 IPv6 可解析但不可达导致 `apt update` 长时间卡住。
9. 打印后续手动初始化命令。

## 支持范围

优先支持：

- Debian 10/11/12/13
- Ubuntu 20.04/22.04/24.04/25.04/26.04 及类似发行版
- Proxmox VE，基于 Debian
- Raspberry Pi OS，基础兼容

说明：当前脚本只负责 apt 系统换源。Rocky Linux、AlmaLinux、CentOS、Fedora 等 dnf/yum 系统不建议使用此脚本。

## 推荐运行方式

```bash
cd /tmp
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/linux_init_cn.sh -o linux_init_cn.sh
chmod +x linux_init_cn.sh
sudo ./linux_init_cn.sh
```

如果当前系统没有 `curl`，但有 `wget`：

```bash
cd /tmp
wget -O linux_init_cn.sh https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/linux_init_cn.sh
chmod +x linux_init_cn.sh
sudo ./linux_init_cn.sh
```

如果 `curl` 和 `wget` 都没有，先手动写一个国内源，然后再安装 curl/wget。以 Ubuntu 为例：

```bash
. /etc/os-release
CODENAME="${VERSION_CODENAME}"
cat > /etc/apt/sources.list <<EOF
deb http://mirrors.ustc.edu.cn/ubuntu/ $CODENAME main restricted universe multiverse
deb http://mirrors.ustc.edu.cn/ubuntu/ $CODENAME-updates main restricted universe multiverse
deb http://mirrors.ustc.edu.cn/ubuntu/ $CODENAME-backports main restricted universe multiverse
deb http://mirrors.ustc.edu.cn/ubuntu/ $CODENAME-security main restricted universe multiverse
EOF
apt update
apt install -y curl wget
```

## 常用参数

### 强制指定 mirror

如果自动测速结果不理想，可以强制指定。

Ubuntu：

```bash
MIRROR_FORCE=https://mirrors.ustc.edu.cn/ubuntu sudo ./linux_init_cn.sh
```

Debian：

```bash
MIRROR_FORCE=https://mirrors.ustc.edu.cn/debian sudo ./linux_init_cn.sh
```

### 调整测速超时和次数

```bash
MIRROR_TIMEOUT=5 MIRROR_REPEAT=3 sudo ./linux_init_cn.sh
```

### 关闭 apt 强制 IPv4

默认会写入：

```text
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "10";
Acquire::https::Timeout "10";
Acquire::Retries "2";
```

如果确认 IPv6 正常，可以关闭：

```bash
FORCE_IPV4_APT=0 sudo ./linux_init_cn.sh
```

### 指定后续示例中的管理员用户名

脚本默认在输出的后续命令中使用 `likangguo`：

```bash
INIT_USER=likangguo sudo ./linux_init_cn.sh
```

## 换源后应该怎么做

### 1. 更新 apt 索引

```bash
apt clean
apt update
```

如果 `apt update` 卡住，先检查网络和 DNS：

```bash
ping -c 3 223.5.5.5
ping -c 3 mirrors.ustc.edu.cn
getent hosts mirrors.ustc.edu.cn
ip route
cat /etc/resolv.conf
```

如果仍然卡住，可以临时强制 IPv4：

```bash
apt -o Acquire::ForceIPv4=true update
```

### 2. 安装基础组件

```bash
apt install -y sudo openssh-server ca-certificates curl wget gnupg lsb-release
```

### 3. 启动 SSH

Ubuntu/Debian 通常服务名是 `ssh`，部分系统是 `sshd`：

```bash
systemctl enable --now ssh || systemctl enable --now sshd
systemctl status ssh --no-pager || systemctl status sshd --no-pager
```

检查 SSH 监听：

```bash
ss -tlnp | grep -E ':22\s'
```

### 4. 新建用户 `likangguo`

```bash
adduser likangguo
usermod -aG sudo likangguo
```

验证：

```bash
id likangguo
```

### 5. 配置 sudo

```bash
echo 'likangguo ALL=(ALL:ALL) ALL' > /etc/sudoers.d/90-likangguo
chmod 0440 /etc/sudoers.d/90-likangguo
visudo -cf /etc/sudoers.d/90-likangguo
```

### 6. 设置 SSH 基础配置

首次初始化建议先允许密码登录，确认 `likangguo` 能登录后，再切换到 SSH key-only。

```bash
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-serverfixed-init.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
```

如果主配置没有 include drop-in 目录，需要补充：

```bash
grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config || \
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
```

检查并重启 SSH：

```bash
sshd -t
systemctl restart ssh || systemctl restart sshd
```

### 7. 从另一台机器测试

```bash
ssh likangguo@服务器IP
sudo -v
```

确认可登录后，不要关闭当前 root 会话，先开一个新窗口测试登录成功，再继续安全加固。

## 稳定后建议关闭 SSH 密码登录

先给 `likangguo` 配置 SSH 公钥：

```bash
su - likangguo
mkdir -p ~/.ssh
chmod 700 ~/.ssh
nano ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
exit
```

确认公钥登录成功后，关闭密码登录：

```bash
sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/99-serverfixed-init.conf
sshd -t
systemctl restart ssh || systemctl restart sshd
```

## Ubuntu 25.04 / plucky 特别说明

Ubuntu 25.04 是短周期版本。若未来进入 EOL，普通 mirror 可能逐步移除该版本，表现为 `apt update` 出现 404、Release 文件缺失或安全源不可用。此时有两种选择：

1. 推荐：升级到仍受支持版本，例如 LTS。
2. 临时：改用 Ubuntu old-releases 源。

临时 old-releases 示例：

```bash
cat > /etc/apt/sources.list <<'EOF'
deb http://old-releases.ubuntu.com/ubuntu/ plucky main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ plucky-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ plucky-backports main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ plucky-security main restricted universe multiverse
EOF
apt clean
apt update
```

## apt 源备份和回滚

脚本会备份到：

```bash
/etc/apt/serverfixed-backup-YYYYMMDD-HHMMSS/
```

旧系统源会移出到：

```bash
/etc/apt/serverfixed-disabled-YYYYMMDD-HHMMSS/
```

回滚示例：

```bash
BACKUP=/etc/apt/serverfixed-backup-YYYYMMDD-HHMMSS
cp -a "$BACKUP/sources.list" /etc/apt/sources.list 2>/dev/null || true
rm -rf /etc/apt/sources.list.d
cp -a "$BACKUP/sources.list.d" /etc/apt/sources.list.d
apt update
```

## 常见问题

### 1. `Notice: Ignoring file ... invalid filename extension`

这是因为 `/etc/apt/sources.list.d/` 中存在 `.bak.时间戳` 之类文件。新版脚本会自动把它们移到 `/etc/apt/serverfixed-disabled-*`。

也可以手动清理：

```bash
mkdir -p /etc/apt/manual-disabled
mv /etc/apt/sources.list.d/*.bak* /etc/apt/manual-disabled/ 2>/dev/null || true
mv /etc/apt/sources.list.d/*.disabled* /etc/apt/manual-disabled/ 2>/dev/null || true
apt update
```

### 2. `apt update` 一直卡在 Connecting

常见原因是 DNS 问题、IPv6 路由异常、网关不能出公网或被代理阻断。先强制 IPv4：

```bash
apt -o Acquire::ForceIPv4=true update
```

再检查：

```bash
ping -c 3 223.5.5.5
getent hosts mirrors.ustc.edu.cn
ip route
cat /etc/resolv.conf
```

### 3. 没有 curl，无法下载脚本

使用 wget；如果 wget 也没有，先手动写入 USTC 源，再安装 curl/wget。

### 4. SSH 重启失败

先检查语法：

```bash
sshd -t
```

如果失败，删除 drop-in：

```bash
rm -f /etc/ssh/sshd_config.d/99-serverfixed-init.conf
sshd -t
systemctl restart ssh || systemctl restart sshd
```

## 日志

脚本日志默认写入：

```bash
/var/log/serverfixed-init.log
```

查看最近日志：

```bash
tail -n 200 /var/log/serverfixed-init.log
```
