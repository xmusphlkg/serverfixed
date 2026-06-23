# Zabbix Agent 2 一键安装说明文档

本文档用于说明 `serverfixed` 仓库中的 `zabbix-agent2-install.sh` 脚本。该脚本用于在 Debian、Ubuntu、PVE 等 Linux 主机上自动安装、修复、配置和验证 Zabbix Agent 2。

仓库地址：

```text
https://github.com/xmusphlkg/serverfixed
```

脚本地址：

```text
https://github.com/xmusphlkg/serverfixed/blob/main/zabbix-agent2-install.sh
```

Raw 下载地址：

```text
https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh
```

---

## 1. 脚本用途

`zabbix-agent2-install.sh` 是一个本机安装脚本，用于在当前 Linux 主机上完成以下工作：

1. 自动识别系统类型和版本；
2. 自动判断 Debian/Ubuntu/PVE 的 Zabbix 官方仓库地址；
3. 修复常见的 APT/Dpkg 依赖异常；
4. 安装 Zabbix 7.0 LTS 的 `zabbix-agent2`；
5. 自动配置 `Server`、`ServerActive`、`Hostname`；
6. 自动启动并启用 `zabbix-agent2` 服务；
7. 如果检测到 `ufw` 或 `firewalld` 正在运行，自动放行 Zabbix Server 访问 `10050/tcp`；
8. 输出安装日志、检测结果和操作摘要。

这个脚本只负责安装当前机器，不负责批量 SSH 分发。如果后续需要批量安装，可以在管理机上用 `for` 循环、Ansible、PSSH 或自定义 SSH 脚本调用它。

---

## 2. 适用系统

当前脚本支持以下系统：

| 系统 | 支持版本 |
|---|---|
| Debian | 10 / 11 / 12 / 13 |
| Ubuntu | 20.04 / 22.04 / 24.04 / 26.04 |
| Proxmox VE | 基于 Debian 的 PVE 系统 |

说明：

- PVE 本质上基于 Debian，因此按 Debian 逻辑处理。
- TrueNAS SCALE 主机系统不建议直接运行该脚本，因为 TrueNAS 是 Appliance OS，不适合直接用 apt 安装第三方 agent。建议在 VM 中安装 Zabbix Agent 2，或者通过 SNMP/API 监控 TrueNAS。

---

## 3. 前置条件

目标主机需要满足：

1. 当前用户具备 `sudo` 权限；
2. 目标主机可以访问互联网，至少可以访问：

```text
https://repo.zabbix.com
https://raw.githubusercontent.com
```

3. Zabbix Server 或 Zabbix Proxy 已经部署完成；
4. Zabbix Server 能访问 Agent 主机的 `10050/tcp` 端口；
5. Agent 主机能访问 Zabbix Server 的地址。

检查当前用户是否有 sudo 权限：

```bash
sudo -v
```

检查系统版本：

```bash
cat /etc/os-release
```

---

## 4. 推荐安装方式

### 4.1 普通安装

假设 Zabbix Server 地址是：

```text
192.168.10.57
```

当前主机在 Zabbix 里希望叫：

```text
server06
```

执行：

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh
bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```

参数含义：

```text
第一个参数：Zabbix Server 或 Zabbix Proxy 地址
第二个参数：Zabbix Hostname，也就是 Zabbix Web 里主机名必须填写的值
```

---

### 4.2 使用环境变量安装

也可以使用环境变量方式：

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh
SERVER=192.168.10.57 ZBX_HOST=server06 bash /tmp/zabbix-agent2-install.sh
```

这种方式适合写入批量安装脚本。

---

### 4.3 GitHub 访问慢时使用加速地址

如果目标服务器访问 GitHub 较慢，可以尝试使用代理加速地址：

```bash
curl -fsSL https://g.blfrp.cn/https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh
bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```

如果加速地址不可用，换回官方 Raw 地址即可。

---

## 5. 参数和环境变量

脚本支持命令行参数，也支持环境变量。

### 5.1 命令行参数

```bash
bash zabbix-agent2-install.sh <Zabbix_Server> <Zabbix_Hostname>
```

示例：

```bash
bash zabbix-agent2-install.sh 192.168.10.57 server06
```

### 5.2 环境变量

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `SERVER` | `192.168.10.57` | Zabbix Server 或 Zabbix Proxy 地址 |
| `ZBX_SERVER` | 空 | `SERVER` 的兼容变量 |
| `ZBX_HOST` | 当前系统 hostname | Zabbix Agent 配置中的 `Hostname` |
| `ZBX_HOSTNAME` | 空 | `ZBX_HOST` 的兼容变量 |
| `ZBX_VERSION` | `7.0` | Zabbix 主版本，默认使用 7.0 LTS |
| `TIMEZONE` | `Asia/Shanghai` | 自动设置系统时区；设为 `skip` 可跳过 |
| `REPAIR_APT` | `1` | 是否尝试修复 APT/Dpkg 依赖问题 |
| `CONFIGURE_FIREWALL` | `1` | 是否自动配置 ufw/firewalld 放行规则 |
| `REPORT_DIR` | `/var/tmp/zabbix-agent2-install-report` | 安装日志和摘要目录 |

示例：

```bash
SERVER=192.168.10.57 \
ZBX_HOST=server06 \
TIMEZONE=Asia/Shanghai \
REPAIR_APT=1 \
CONFIGURE_FIREWALL=1 \
bash /tmp/zabbix-agent2-install.sh
```

如果不希望脚本修改时区：

```bash
TIMEZONE=skip bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```

如果不希望脚本处理防火墙：

```bash
CONFIGURE_FIREWALL=0 bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```

---

## 6. 脚本执行后会修改哪些内容

脚本会修改或创建以下内容：

```text
/etc/apt/sources.list.d/zabbix.list
/etc/zabbix/zabbix_agent2.conf
/etc/zabbix/zabbix_agent2.conf.bak.<时间戳>
/var/tmp/zabbix-agent2-install-report/install-<时间戳>.log
/var/tmp/zabbix-agent2-install-report/summary-<时间戳>.txt
```

主要配置项：

```ini
Server=<Zabbix Server 地址>
ServerActive=<Zabbix Server 地址>
Hostname=<Zabbix Hostname>
```

注意：

- `Hostname` 必须和 Zabbix Web 前端创建主机时的 `Host name` 完全一致。
- 大小写、横线、下划线都必须一致。
- 如果 Zabbix Web 里的主机名和 Agent 配置不一致，主动检查会失败。

---

## 7. 安装完成后的本机验证

安装完成后，脚本会自动输出验证结果。你也可以手动执行以下命令检查。

### 7.1 查看服务状态

```bash
sudo systemctl status zabbix-agent2 --no-pager
```

正常情况应看到：

```text
Active: active (running)
```

### 7.2 测试 Agent 本地响应

```bash
zabbix_agent2 -t agent.ping
```

正常情况应返回：

```text
agent.ping [s|1]
```

### 7.3 查看配置

```bash
grep -E '^(Server|ServerActive|Hostname)=' /etc/zabbix/zabbix_agent2.conf
```

示例输出：

```text
Server=192.168.10.57
ServerActive=192.168.10.57
Hostname=server06
```

### 7.4 查看监听端口

```bash
sudo ss -lntp | grep 10050
```

正常情况应能看到 `10050` 端口。

### 7.5 查看日志

```bash
sudo tail -n 100 /var/log/zabbix/zabbix_agent2.log
```

---

## 8. 在 Zabbix Web 里添加主机

进入 Zabbix Web 后，按以下方式添加主机。

### 8.1 添加主机

路径：

```text
Data collection -> Hosts -> Create host
```

填写：

```text
Host name: server06
Visible name: server06
Groups: Linux servers
Interfaces: Agent
IP address: 目标主机 IP
DNS name: 可留空
Port: 10050
```

其中 `Host name` 必须等于脚本里传入的第二个参数，例如：

```bash
bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```

那么 Zabbix Web 里的 `Host name` 就必须是：

```text
server06
```

### 8.2 绑定模板

推荐模板：

```text
Linux by Zabbix agent
```

或者如果你主要使用主动模式：

```text
Linux by Zabbix agent active
```

### 8.3 保存并等待数据

保存后等待 1 到 3 分钟，观察：

```text
Monitoring -> Latest data
```

选择该主机，检查是否出现 CPU、内存、磁盘、网络等数据。

---

## 9. Server、ServerActive 和 Hostname 的含义

### 9.1 Server

`Server` 表示允许哪些 Zabbix Server 或 Proxy 主动连接 Agent。

示例：

```ini
Server=192.168.10.57
```

这表示只允许 `192.168.10.57` 访问当前 Agent 的 `10050/tcp`。

### 9.2 ServerActive

`ServerActive` 表示 Agent 主动把数据上报给哪个 Zabbix Server 或 Proxy。

示例：

```ini
ServerActive=192.168.10.57
```

### 9.3 Hostname

`Hostname` 是 Zabbix Agent 向 Server 报告自己身份时使用的名字。

示例：

```ini
Hostname=server06
```

Zabbix Web 里创建主机时的 `Host name` 必须也是 `server06`。

---

## 10. 常见使用场景

### 10.1 安装到普通 Debian/Ubuntu 服务器

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh
bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```

### 10.2 安装到 PVE 节点

假设 PVE 节点名是 `pve01`：

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh
bash /tmp/zabbix-agent2-install.sh 192.168.10.57 pve01
```

说明：

- PVE 基于 Debian，脚本会按 Debian 仓库处理。
- 如果 PVE 使用企业源但没有订阅，建议先处理 PVE 源问题，否则 `apt update` 可能失败。

### 10.3 重新配置已有 Agent

如果已经安装过 `zabbix-agent2`，但想修改 Server 和 Hostname，可以直接重新执行：

```bash
bash /tmp/zabbix-agent2-install.sh 192.168.10.57 new-hostname
```

脚本会备份旧配置并重写以下配置项：

```ini
Server=
ServerActive=
Hostname=
```

---

## 11. 常见故障处理

### 11.1 误识别为 Ubuntu 11 或下载 404

如果看到类似错误：

```text
zabbix-release_latest_7.0+ubuntu11_all.deb
404 Not Found
```

说明系统实际上可能是 Debian 11，而不是 Ubuntu。

本脚本会读取 `/etc/os-release` 中的 `ID` 和 `VERSION_ID`，自动区分：

```text
ID=debian -> debian11
ID=ubuntu -> ubuntu22.04 / ubuntu24.04
```

因此不要手工把 `VERSION_ID=11` 拼到 Ubuntu URL 里。

---

### 11.2 APT 依赖损坏

如果出现：

```text
E: Unmet dependencies. Try 'apt --fix-broken install'
```

或者：

```text
gnupg depends on dirmngr ... but another version is to be installed
```

说明当前系统 APT 依赖状态不一致。脚本默认会执行修复流程：

```bash
sudo dpkg --configure -a
sudo apt-get update
sudo apt-get -y --fix-broken install
```

如果第一次修复失败，脚本会尝试同步 GnuPG 相关包：

```text
gnupg
dirmngr
gnupg-utils
gpg
gpg-agent
gpg-wks-client
gpg-wks-server
gpgsm
gpgv
```

如果仍然失败，手动查看：

```bash
apt-mark showhold
apt-cache policy gnupg dirmngr gnupg-utils gpg gpg-agent gpg-wks-client gpg-wks-server gpgsm gpgv
sudo apt-get -o Debug::pkgProblemResolver=yes --fix-broken install
```

---

### 11.3 找不到 zabbix-agent2 包

如果出现：

```text
E: Unable to locate package zabbix-agent2
```

通常表示 Zabbix 官方仓库没有正确安装，或者 `apt update` 没有成功。

检查：

```bash
ls -l /etc/apt/sources.list.d/ | grep zabbix
apt-cache policy zabbix-agent2
sudo apt update
```

重新运行脚本即可：

```bash
bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```

---

### 11.4 服务不存在

如果出现：

```text
Unit zabbix-agent2.service not found
```

说明 `zabbix-agent2` 实际没有安装成功。

检查：

```bash
dpkg -l | grep zabbix-agent2
apt-cache policy zabbix-agent2
```

然后重新执行脚本。

---

### 11.5 Zabbix Web 里显示红色 ZBX 或不可用

常见原因：

1. Zabbix Web 里的 `Host name` 和 Agent 配置里的 `Hostname` 不一致；
2. Server IP 填错；
3. 防火墙没有放行 `10050/tcp`；
4. Zabbix Server 无法访问 Agent 主机 IP；
5. Agent 日志里提示 active checks rejected。

排查命令：

```bash
grep -E '^(Server|ServerActive|Hostname)=' /etc/zabbix/zabbix_agent2.conf
sudo systemctl status zabbix-agent2 --no-pager
sudo ss -lntp | grep 10050
sudo tail -n 100 /var/log/zabbix/zabbix_agent2.log
```

在 Zabbix Server 上测试：

```bash
zabbix_get -s <Agent主机IP> -k agent.ping
```

返回 `1` 说明 Server 可以访问 Agent。

---

## 12. 批量安装示例

假设你有多台服务器：

```text
192.168.10.61 server01
192.168.10.62 server02
192.168.10.63 server03
```

可以在管理机上写一个简单循环：

```bash
cat > hosts.txt <<'EOF'
192.168.10.61 server01
192.168.10.62 server02
192.168.10.63 server03
EOF

while read -r IP HOST; do
  echo "===== $HOST $IP ====="
  ssh "$IP" "curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh && bash /tmp/zabbix-agent2-install.sh 192.168.10.57 $HOST"
done < hosts.txt
```

注意：

- 这个批量示例要求 SSH 已经能免密或能正常登录。
- 如果目标机 sudo 需要密码，批量执行时可能会卡在 sudo 密码输入。
- 更正式的批量部署建议使用 Ansible。

---

## 13. 推荐命名规范

为了后续在 Zabbix、Wazuh、Grafana 中统一管理，建议统一主机名：

| 类型 | 示例 |
|---|---|
| 云服务器 | `cloud-01`、`cloud-02` |
| PVE 节点 | `pve-01`、`pve-02` |
| NAS/存储 | `nas-01` |
| 监控主机 | `monitor-01` |
| 普通服务器 | `server-01`、`server-02` |
| 网络设备 | `router-01`、`switch-01` |

修改 Linux 系统主机名：

```bash
sudo hostnamectl set-hostname server-01
```

然后重新运行脚本：

```bash
bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server-01
```

---

## 14. 卸载方法

如果需要卸载 Zabbix Agent 2：

```bash
sudo systemctl disable --now zabbix-agent2
sudo apt purge -y zabbix-agent2
sudo rm -rf /etc/zabbix
sudo apt autoremove -y
```

如果还要删除 Zabbix 仓库：

```bash
sudo rm -f /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources
sudo apt update
```

---

## 15. 最终检查清单

安装完成后确认以下项目：

```text
[ ] zabbix-agent2 服务 active running
[ ] /etc/zabbix/zabbix_agent2.conf 中 Server 正确
[ ] /etc/zabbix/zabbix_agent2.conf 中 ServerActive 正确
[ ] /etc/zabbix/zabbix_agent2.conf 中 Hostname 与 Zabbix Web 主机名一致
[ ] 10050/tcp 已监听
[ ] Zabbix Server 能访问 Agent 主机的 10050/tcp
[ ] Zabbix Web 已添加主机并绑定 Linux by Zabbix agent 模板
[ ] Latest data 页面能看到 CPU、内存、磁盘、网络等数据
```

---

## 16. 最小可复制命令

最常用的一条命令如下：

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh && bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```

如果要跳过时区修改：

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/zabbix-agent2-install.sh -o /tmp/zabbix-agent2-install.sh && TIMEZONE=skip bash /tmp/zabbix-agent2-install.sh 192.168.10.57 server06
```
