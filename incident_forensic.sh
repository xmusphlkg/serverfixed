#!/bin/bash

echo "==================== INCIDENT FORENSIC REPORT ===================="
echo "HOST: $(hostname)"
echo "TIME: $(date)"
echo "==============================================================="

echo ""
echo "===== [1] TIME / SYSTEM INFO ====="
uptime
uname -a
date
whoami

echo ""
echo "===== [2] /dev/shm CHECK ====="
ls -lah /dev/shm
find /dev/shm -maxdepth 2 -type f -ls 2>/dev/null

echo ""
echo "===== [3] SUSPICIOUS PROCESSES ====="
ps aux | egrep "dev/shm|xmrig|kinsing|kdevtmpfsi|cryptonight|monero|stratum|\.kw|worker" | grep -v grep

echo ""
echo "===== [4] NETWORK CONNECTIONS ====="
ss -tunap | head -200

echo ""
echo "===== [5] OUTBOUND CONNECTIONS (TOP) ====="
ss -tunap | awk '{print $5}' | sort | uniq -c | sort -nr | head -30

echo ""
echo "===== [6] CRON CHECK ====="
echo "--- root cron ---"
crontab -l 2>/dev/null
echo "--- system cron ---"
grep -RIn "dev/shm\|wget\|curl\|base64\|bash -c\|worker\|xmrig" /etc/crontab /etc/cron* /var/spool/cron* 2>/dev/null

echo ""
echo "===== [7] RC.LOCAL / PERSISTENCE ====="
grep -RIn "dev/shm\|worker\|xmrig\|kinsing\|kdevtmpfsi" /etc/rc.local /etc/init.d /etc/profile* 2>/dev/null

echo ""
echo "===== [8] SYSTEMD CHECK ====="
systemctl list-unit-files --type=service | grep enabled
grep -RIn "dev/shm\|worker\|xmrig\|kinsing" /etc/systemd/system /lib/systemd/system 2>/dev/null

echo ""
echo "===== [9] SSH LOGIN HISTORY ====="
last -a | head -50

echo ""
echo "===== [10] NETWORK INTERFACES ====="
ip a

echo ""
echo "===== [11] LISTENING PORTS ====="
ss -lntup

echo ""
echo "==================== END REPORT ===================="