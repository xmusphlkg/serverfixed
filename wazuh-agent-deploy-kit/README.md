# Wazuh Agent Deploy Kit

This kit installs and configures Wazuh agents on Linux and Windows endpoints.

## Wazuh manager

Default lab manager example:

```bash
SERVER=192.168.10.102
```

## One-host Linux install

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/refs/heads/main/wazuh-agent-deploy-kit/deploy-ssh.sh -o /tmp/install-linux.sh
sudo SERVER=192.168.10.102 bash /tmp/install-linux.sh
```

## One-host Windows install

Run PowerShell as Administrator:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/xmusphlkg/serverfixed/tree/main/wazuh-agent-deploy-kit/main/install-windows.ps1 -OutFile $env:TEMP\install-windows.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-windows.ps1 -Server 192.168.10.102
```

## SSH batch deployment

Prepare `hosts.txt`:

```text
root@192.168.30.120
likangguo@192.168.30.121
Administrator@192.168.3.50
```

Run from Linux, macOS, or WSL:

```bash
SERVER=192.168.10.102 ./deploy-ssh.sh hosts.txt
```

Windows targets require OpenSSH Server enabled and the SSH user must have Administrator privileges. Linux non-root users need sudo.

## What it configures

Linux:
- Time zone: Asia/Shanghai
- Wazuh manager: `$SERVER`
- Protocol: TCP
- FIM: `/etc/ssh`, `/etc/sudoers.d`, `/etc/pam.d`, `/etc/cron.d`, `/etc/systemd/system`, `/root/.ssh`, `/var/spool/cron`, `/dev/shm`, `/tmp`, `/var/tmp`
- Auth logs: `/var/log/auth.log` or `/var/log/secure`
- Service/process/report output
- Optional FIM create/modify/delete test

Windows:
- Time zone: China Standard Time
- Wazuh manager: `$SERVER`
- Event channels: Application, Security, System
- FIM: `C:\ProgramData\ssh`, `C:\Windows\System32\drivers\etc`, `C:\Windows\System32\Tasks`, Startup directories, existing user `.ssh` directories
- Service/process/report output
- Optional FIM create/modify/delete test

## Check on Wazuh server

```bash
sudo /var/ossec/bin/agent_control -l
sudo tail -n 500 /var/ossec/logs/alerts/alerts.log | egrep -i 'syscheck|fim|sshd|sudo|wazuh_fim_test'
```
