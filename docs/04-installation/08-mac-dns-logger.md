# Mac DNS logger

Machine: the macOS host. Installer role: `mac-dns`. Needs the Mac Wazuh agent ([06-endpoints](06-endpoints.md), step 3).

The Mac's own internet traffic never crosses OPNsense, so Suricata cannot see its DNS. A small launchd daemon runs `tcpdump` on port 53 and writes each query to `/var/log/dns-queries.log`. The Mac agent ships the log, and rule 100300 (level 3) makes each lookup searchable in Wazuh without opening a case.

## Install

```bash
cd Agentic_SOC
sudo ./install.sh mac-dns --dry-run
sudo ./install.sh mac-dns
```

| File | Purpose |
|---|---|
| `/Library/LaunchDaemons/com.soc.dnslog.plist` | Runs `tcpdump -l -n -tttt -i any 'udp port 53 or tcp port 53'` as root, KeepAlive, umask 027 so the log is not world-readable |
| `/etc/newsyslog.d/soc-dnslog.conf` | Rotates the log at 10 MB, keeps 7, stops tcpdump by pid file so launchd restarts it on a fresh file |
| `/Library/Ossec/etc/ossec.conf` | One `<localfile>` for `/var/log/dns-queries.log` |

The command is written inline in the root-owned plist on purpose. An earlier draft used a wrapper script in `/usr/local/sbin`, which is user-writable on this Mac: a root daemon running a user-writable script is a privilege-escalation path.

## Check

```bash
nslookup soc-dnstest.example.com
sudo tail -2 /var/log/dns-queries.log         # "... A? soc-dnstest.example.com. ..."
ls -l /var/log/dns-queries.log                 # -rw-r----- root
```

On the manager: `sudo grep soc-dnstest /var/ossec/logs/alerts/alerts.log | tail -1` shows rule 100300 with agent MacOS.

Limits: browsers using DNS over HTTPS bypass port 53, so those lookups are invisible here.

## Remove

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.soc.dnslog.plist
sudo rm /Library/LaunchDaemons/com.soc.dnslog.plist /etc/newsyslog.d/soc-dnslog.conf
# restore /Library/Ossec/etc/ossec.conf.bak-<timestamp> and restart the agent
```
