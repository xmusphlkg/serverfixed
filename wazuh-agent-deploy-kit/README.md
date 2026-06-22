# Wazuh Agent Local Deploy Kit

This directory contains local installers for Wazuh Agent. Each script installs or reconfigures Wazuh Agent on the current machine only.

It does not support SSH batch deployment, does not use `hosts.txt`, and does not deploy to remote machines.

## Default Wazuh manager

The default manager address is:

```text
192.168.30.102
```

You can override it with `SERVER` on Linux or `-Server` on Windows.

## Important: TrueNAS SCALE host OS is not supported

Do not run the Linux installer on the TrueNAS SCALE appliance host OS.

TrueNAS SCALE is Debian-based, but its appliance OS disables package management tools such as `apt`. Installing packages directly on the host OS can break the system or future upgrades.

For TrueNAS monitoring, use one of these safer approaches:

1. Install Wazuh Agent inside a normal Debian/Ubuntu VM running on TrueNAS.
2. Forward TrueNAS syslog/logs to Wazuh or another syslog receiver.
3. Monitor TrueNAS using supported interfaces such as SNMP/syslog/API, and keep Zabbix/Grafana for performance and availability metrics.

The Linux installer detects common TrueNAS/SCALE markers and exits before package installation.

## Linux local install

Run as root or with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/wazuh-agent-deploy-kit/install-linux.sh -o /tmp/install-linux.sh
sudo bash /tmp/install-linux.sh
```

Override the Wazuh manager when needed:

```bash
sudo SERVER=100.64.0.X bash /tmp/install-linux.sh
```

Optional variables:

```bash
sudo SERVER=192.168.30.102 \
  AGENT_NAME=$(hostname -s) \
  GROUP=default \
  TIMEZONE=Asia/Shanghai \
  TEST_FIM=1 \
  bash /tmp/install-linux.sh
```

The Linux installer supports Debian, Ubuntu, Proxmox VE, RHEL, Rocky Linux, AlmaLinux, CentOS, and SUSE/openSUSE style systems when the corresponding package manager is available.

## Windows local install

Run PowerShell as Administrator:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/xmusphlkg/serverfixed/main/wazuh-agent-deploy-kit/install-windows.ps1 -OutFile $env:TEMP\install-windows.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-windows.ps1
```

Override the Wazuh manager when needed:

```powershell
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-windows.ps1 -Server 100.64.0.X
```

Optional parameters:

```powershell
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-windows.ps1 `
  -Server 192.168.30.102 `
  -AgentName $env:COMPUTERNAME `
  -Group default `
  -TimeZone "China Standard Time" `
  -TestFim $true
```

## What Linux configures

- Time zone: `Asia/Shanghai`
- Wazuh manager: default `192.168.30.102`
- Protocol: TCP
- Enrollment check through port `1515` when local `client.keys` is missing
- FIM monitoring:
  - `/etc/ssh`
  - `/etc/sudoers.d`
  - `/etc/pam.d`
  - `/etc/cron.d`
  - `/etc/systemd/system`
  - `/root/.ssh`
  - existing `/home/*/.ssh` directories
  - `/var/spool/cron`
  - `/dev/shm`
  - `/tmp`
  - `/var/tmp`
- Auth log collection:
  - `/var/log/auth.log` on Debian/Ubuntu/PVE
  - `/var/log/secure` on RHEL-style systems
- Service status, process status, connection details, recent agent log, final summary report
- Optional FIM create/modify/delete test under `/etc/ssh/sshd_config.d`

## What Windows configures

- Time zone: `China Standard Time`
- Wazuh manager: default `192.168.30.102`
- Protocol: TCP
- Event channels:
  - `Application`
  - `Security`
  - `System`
- FIM monitoring:
  - `C:\ProgramData\ssh`
  - `C:\Windows\System32\drivers\etc`
  - `C:\Windows\System32\Tasks`
  - `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup`
  - existing user `.ssh` directories
  - existing user Startup directories
- Service status, process status, connection details, recent agent log, final summary report
- Optional FIM create/modify/delete test under `C:\ProgramData\ssh`

## Reports

Linux report directory:

```text
/var/tmp/wazuh-agent-install-report/
```

Windows report directory:

```text
C:\Windows\Temp\wazuh-agent-install-report\
```

Each run creates a full log and a short summary file.

## Check on Wazuh server

On the Wazuh server `192.168.30.102`, run:

```bash
sudo /var/ossec/bin/agent_control -l
sudo tail -n 500 /var/ossec/logs/alerts/alerts.log | egrep -i 'syscheck|fim|sshd|sudo|wazuh_fim_test|authentication'
```

In the Wazuh Dashboard, use `Last 24 hours` and search for:

```text
rule.groups:syscheck
```

or:

```text
wazuh_fim_test
```
