# Endpoints (Wazuh agents)

Machines: victim01 (<VICTIM_IP>) and Kali (<ATTACKER_IP>). Installer role: `agent`. The Mac agent is installed from the dashboard (step 3).

## 1. victim01

Linked clone of `clean base`, 1 vCPU, 2 GB RAM, network adapter on `vmnet2`. Static address <VICTIM_IP>/24, gateway <OPNSENSE_LAN_IP>. If the VM has a second adapter on the NAT network, leave it without an IPv4 address so all traffic goes through OPNsense.

Do not install Suricata here. An old sensor install on this VM crash-looped 3,411 times against a missing `eth0` and flooded Wazuh with level-5 alerts. If it is present: `sudo systemctl disable --now suricata`.

## 2. Install the agent (victim01 and Kali)

```bash
cd ~/Agentic_SOC
sudo ./install.sh agent victim01      # on victim01; use "kali" on Kali
```

The script adds the Wazuh apt repository, installs `wazuh-agent` at the manager's version (`WAZUH_VERSION`; an agent newer than the manager is refused), enrols it with `WAZUH_IP`, and adds file-integrity monitoring of `/root/.ssh` and every `/home/*/.ssh` with `known_hosts` ignored. New `authorized_keys` entries are a classic persistence trick; the n8n Filter lets these through as cases.

## 3. The Mac agent

Wazuh dashboard > Agents > Deploy new agent > macOS, enter <WAZUH_IP>, run the command it shows on the Mac. Then add the macOS persistence folders to its file-integrity monitoring, inside `<syscheck>` in `/Library/Ossec/etc/ossec.conf`:

```xml
<directories>/Library/LaunchDaemons,/Library/LaunchAgents,/Users/<user>/Library/LaunchAgents</directories>
```

Test with `sudo /Library/Ossec/bin/wazuh-syscheckd -t`, then `sudo /Library/Ossec/bin/wazuh-control restart`.

## 4. Check

On the manager:

```bash
sudo /var/ossec/bin/agent_control -l
```

Expect 000 wazuhserver, 001 kali, 002 MacOS, 003 sensor, all Active.

File-integrity changes are only alerted by the next scheduled scan, every 12 hours. The first scan after an agent restart is a silent baseline, so a test right after a restart shows nothing. To test quickly, set `<frequency>300</frequency>` in `<syscheck>`, restart, wait for the baseline, make the change, wait 5 minutes, then put 43200 back.
