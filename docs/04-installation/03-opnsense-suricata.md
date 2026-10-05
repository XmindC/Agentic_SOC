# OPNsense and Suricata

Machine: OPNsense VM. Manual (FreeBSD console and web GUI). `./install.sh opnsense` prints this list.

The full console walkthrough, with every prompt, is in [reference/opnsense-vm-install.md](reference/opnsense-vm-install.md). Network and IDS setup, including the lockout and routing problems met along the way, is in [../05-configuration/reference/opnsense-network-and-suricata.md](../05-configuration/reference/opnsense-network-and-suricata.md).

## 1. Create the VM

- Use the **amd64 DVD ISO** (`OPNsense-<version>-dvd-amd64.iso`, unpack the `.bz2` first). The VGA `.img` does not boot in Fusion.
- Guest OS: Other > FreeBSD 14 64-bit. 2 vCPU, 4 GB RAM (Suricata needs the headroom at Detect Profile High), 20 GB disk.
- Two network adapters: adapter 1 on "Share with my Mac" (WAN, em0), adapter 2 on `vmnet2` (LAN, em1).
- Attach the ISO to the CD/DVD drive before first boot.

## 2. Install and assign interfaces

1. Log in at the console as `installer` with the vendor default password (OPNsense documentation), choose ZFS, stripe, the single disk.
2. After reboot, assign em0 = WAN, em1 = LAN.
3. Set addresses: WAN <OPNSENSE_WAN_IP>/24 (gateway <NAT_GATEWAY_IP>, the VMware NAT router), LAN <OPNSENSE_LAN_IP>/24.
4. Change the root password immediately.

## 3. Reach the GUI from the Mac

The GUI is blocked on WAN by default. From the console shell, `pfctl -d` disables the filter until the next Apply. In the GUI:

- Interfaces > WAN: untick "Block private networks" (the whole lab is private addressing).
- Firewall > Rules > WAN: pass TCP from the Mac to "This firewall" port 443.
- Save both, then Apply once. Applying earlier re-enables the filter and locks you out again.
- Firewall > Rules > LAN: on the default allow rule, tick "Disable reply-to". Without it victim01 cannot reach OPNsense or the internet even though OPNsense can ping it.

## 4. Route Kali through the firewall

On Kali, add a persistent route so attacks on the LAN cross OPNsense:

```bash
sudo nmcli connection modify "Wired connection 1" +ipv4.routes "<LAB_LAN_CIDR> <OPNSENSE_WAN_IP>"
sudo nmcli connection up "Wired connection 1"
ip route | grep <LAB_LAN_NET>                  # <LAB_LAN_CIDR> via <OPNSENSE_WAN_IP>
```

On OPNsense add a WAN rule passing traffic from <LAB_INFRA_CIDR> to the LAN net.

## 5. Suricata (Services > Intrusion Detection > Administration)

| Setting | Value | Why |
|---|---|---|
| Enabled | on | |
| IPS mode | **off** | IPS would drop traffic by itself, an action without approval |
| Promiscuous mode | on | em0 otherwise only sees traffic addressed to OPNsense |
| Interfaces | LAN (em1) and WAN (em0) | |
| Detect Profile | **High** | The default dropped about 16% of packets during fast scans; High gave zero drops across 272,447 packets |
| Default packet size | 1518 | |
| Home networks | <LAB_LAN_CIDR>, <LAB_INFRA_CIDR> | Must not include Kali's range as a whole /16, or EXTERNAL-to-HOME rules never match |
| Log package | eve syslog output on | Sends alerts to the Wazuh manager |

Download tab: enable the ET Open rulesets (at least `emerging-scan`), Download and Update. Schedule a daily update.

Sid 2009582 (NMAP -sS window 1024) ships commented out and the GUI toggle does not apply it. Enable it by editing the rule file, and install the self-repair cron so rule updates do not silently undo it: [../06-operations/suricata-housekeeping.md](../06-operations/suricata-housekeeping.md).

For `EXTERNAL_NET = any` (so traffic between the two lab segments is matched both ways) use the drop-in in [configs/suricata/soc-lab-netvars.yaml.example](../../configs/suricata/soc-lab-netvars.yaml.example). Read its header first: it replaces the whole `vars` key.

## 6. Send alerts to Wazuh

System > Settings > Logging, **Remote** tab (the Local tab only controls files on OPNsense). Add a target:

| Field | Value | Why |
|---|---|---|
| Transport | UDP(4) | Matches the Wazuh listener |
| Applications | suricata | Only Suricata output, not every system log |
| Levels | empty (all) | Scan alerts are low severity and would otherwise be filtered out |
| Hostname / Port | <WAZUH_IP> / 514 | The Wazuh manager |
| rfc5424 | unticked | Wazuh parses BSD syslog more reliably |

The Wazuh side was configured by `install.sh wazuh`.

## 7. Check

From Kali (vary the port each time; Wazuh suppresses repeated identical alerts):

```bash
sudo nmap -sS -p8443 <VICTIM_IP>
```

On OPNsense: `tail -1 /var/log/suricata/eve.json` shows a fresh alert. On the Wazuh manager: `sudo grep -c 'Suricata recon' /var/ossec/logs/alerts/alerts.log` increases. A Suricata restart takes about 2 minutes to load the rules before anything is detected.
