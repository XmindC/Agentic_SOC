# Troubleshooting

Every problem below happened while building this lab. Each row is symptom, cause, fix. The long write-ups with every command are in [cases/](cases/).

The lesson from the hardest session: several faults can stack, and each one alone produces the same silence. Fix one, test, and expect to find the next.

## Where did the alert stop?

Walk the chain from the source. The first step that shows nothing is where to look.

| Step | Check | Healthy |
|---|---|---|
| 1. Traffic reaches the firewall | Kali: `ip route \| grep <LAB_LAN_NET>` | route via <OPNSENSE_WAN_IP> |
| 2. Suricata saw it | OPNsense: `tail -3 /var/log/suricata/eve.json` | a fresh `"event_type":"alert"` |
| 3. Syslog arrives | Wazuh: `sudo tcpdump -ni any -c 3 -A udp port 514` | BSD syslog line with Suricata JSON |
| 4. Wazuh decoded and matched it | Wazuh: `sudo /var/ossec/bin/wazuh-logtest`, paste the line | decoder `suricata-opnsense`, rule 100201/100202 |
| 5. Alert written | Wazuh: `sudo grep -c Suricata /var/ossec/logs/alerts/alerts.log` (count, do not `tail -f`) | count goes up |
| 6. Sent to n8n | Wazuh: `sudo grep -i integrat /var/ossec/logs/ossec.log \| tail` | no new errors |
| 7. n8n ran | n8n > Executions | a green run; click a red node for the error |
| 8. Case exists | TheHive | `[suricata] ...`, New, unassigned, L1 comment |

## Installing OPNsense

| Symptom | Cause | Fix |
|---|---|---|
| The VM will not install | VGA `.img` used | Use the amd64 DVD `.iso` (unpack the `.bz2`) |
| "No operating system was found" | No ISO on the CD/DVD drive | Settings > CD/DVD, connect the ISO |
| "Could not get vm files", 0-byte disk | Half-created VM | Delete it, recreate from the right ISO |
| Odd VM defaults | Guest OS set to Linux | Other > FreeBSD 14 64-bit |
| Mac cannot open the OPNsense GUI | GUI blocked on WAN by default | Console shell `pfctl -d`, then add a WAN rule |
| Locked out again after Apply or the wizard | Filter back on, "Block private networks" on, rule on port 80 | Untick Block private networks, pass HTTPS 443, save both, Apply once |
| GUI gone after a shutdown | `shutdown now` typed in the wrong terminal | Restart the VM; shut down from the GUI |

Details: [opnsense-vm-install.md](../04-installation/reference/opnsense-vm-install.md), [opnsense-network-and-suricata.md](../05-configuration/reference/opnsense-network-and-suricata.md).

## Lab network (VMware Fusion)

| Symptom | Cause | Fix |
|---|---|---|
| Lab subnet would break the Mac's routing | Home LAN uses the same `<HOME_LAN_SUBNET>` | Move the lab to <LAB_LAN_CIDR> |
| Cannot set a subnet on "Private to my Mac" | The built-in network has no fields | Create custom `vmnet2` (<LAB_LAN_CIDR>, host connected) |
| Cannot set a subnet with Fusion DHCP off | This Fusion build couples the two | Leave DHCP on, use static addresses |
| A promiscuous sensor VM only sees broadcast and multicast | The Fusion switch does not mirror unicast | Run Suricata on OPNsense instead |
| victim01 cannot ping OPNsense or the internet, but OPNsense can ping it | `reply-to` on the LAN rule | Tick "Disable reply-to" on the LAN rule |
| victim01 agent offline, logs clean, ARP shows a different MAC | OPNsense em1 vNIC stuck receive-only (49 RX, 12 TX, 0 errors) | Power off, remove the adapter, add a new one. [Case](cases/victim01-adapter-receive-only.md) |
| "Fusion networking stopped", no `vmnet2` interface | Newer Fusion names them `vmenetN` / `bridgeN` | Check `ifconfig -a`; not a fault |
| Whole lab unreachable after the night | Mac idle sleep froze the VMs | `caffeinate -s` during lab hours |

## Suricata detection

| Symptom | Cause | Fix |
|---|---|---|
| Kali scan, no alert in the GUI | The Log File view filters to Emergency/Alert/Critical | Select all severity levels |
| Kali scan, no alert | Kali's route (added with `ip route add`) was lost at reboot; traffic went to the NAT gateway <NAT_GATEWAY_IP> | Persist it with `nmcli ... +ipv4.routes`. [Case](cases/suricata-silent-scan-three-faults.md) |
| Kali scan, no alert | HOME_NET 192.168.0.0/16 made Kali internal | Narrow HOME_NET; EXTERNAL_NET any via the drop-in |
| Kali scan, no alert | ET sid 2009582 ships commented out; the GUI toggle never applies | Uncomment it in `emerging-scan.rules` |
| A capture "proves" traffic arrives when it does not | `tcpdump` without `-i` | Always name the interface |
| sid 2009582 disabled again | Rule update overwrote the vendor file | Self-repair cron every 6 h and at boot. [Housekeeping](../06-operations/suricata-housekeeping.md) |
| `echo '#!/bin/sh' >` fails with "Event not found" | tcsh history expansion of `!` on OPNsense | Write the file with an editor |
| eve.json stopped updating | Unknown; happened once | Watchdog restarts Suricata after 6 h stale (15 min false-fired on an idle file) |
| About 16% packet drops on fast scans | Capture buffer overflow | Detect Profile High, packet size 1518; read the `em1: packets` summary line, not stats.log |
| `suricatasc` socket error, `suricata.rules` missing | OPNsense defaults | Harmless; use stats.log and `installed_rules.yaml` |
| Kali scanning <SERVICES_IP> gives no alert | The VMware switch never sends it through OPNsense | Structural; not fixable by config |

## Wazuh

| Symptom | Cause | Fix |
|---|---|---|
| Flood of level-5 alerts from victim01 | Leftover Suricata install crash-looping on `eth0` (3,411 restarts) | `sudo systemctl disable --now suricata` on victim01 |
| Syslog events arrive but match nothing | No decoder for JSON inside syslog | Decoder `suricata-opnsense` with `JSON_Decoder` |
| Rules behave strangely | Suricata group nested inside the sshd group | Close each `<group>` before opening the next |
| `tail -f alerts.log` shows nothing | Watching from the wrong moment | `grep -c` the file instead |
| Suricata alerts show `agent.name = wazuhserver` | Syslog carries no agent identity | `$(hostname) $(in_iface)` in rule descriptions |
| Events look an hour apart | Display timezones differ | Compare `date -u` |
| Dashboard broken, retention policy FORBIDDEN, disk 100% | Vulnerability Detector feed (about 20 GB) on a 31 GB root LV | [Case](cases/wazuh-disk-full.md): disable VD, stop and mask the manager, remove the feed dirs, `lvextend` + `resize2fs` |
| `lvextend` says "No space left" | Full disk cannot write LVM metadata | Free space first |
| Deleting the feed frees nothing | The manager refills it | Mask and stop the manager first |
| Admin gets `security_exception` after recovery | Indexer security index damaged | Run `securityadmin.sh` |
| Indices stay read-only after freeing space | Flood-stage block persists | `PUT _all/_settings {"index.blocks.read_only_allow_delete": null}` |
| Zeek events reach the manager, `wazuh-logtest` matches, but no alerts in the dashboard | Zeek dotted fields (`id.orig_h`) collide with `data.id` (keyword) and the indexer rejects them | `redef Log::default_scope_sep = "_";` in `local.zeek` |
| Zeek installed but `conn.log` never exists | `node.cfg` said `interface=eth0`, which does not exist | Set the real interface, `zeekctl deploy` |
| File-integrity test shows nothing | First scan after a restart is a silent baseline | Wait for the next scheduled scan, or test with a 300 s frequency |
| No file-integrity cases at all | All syscheck alerts carry group `ossec`, which the Filter dropped | Filter now passes syscheck on persistence paths |
| Mac DNS lines never alert | No decoder for raw tcpdump lines | Decoder `soc-mac-dns` and rule 100300 |
| `custom-n8n` "Exit status was: 7" | Burst during the 03:27 UTC daily scan; alerts still delivered | No change; enable `integrator.debug=2` for one night to capture details |
| Indexer role matches nothing | Pattern saved as `" wazuh-alerts-*"` (leading space) | Fix via `PUT _plugins/_security/api/roles/...` |

## n8n, TheHive, Cortex

| Symptom | Cause | Fix |
|---|---|---|
| n8n "Invalid URL" | A literal `=` typed into a Fixed-mode field | Remove it |
| TheHive 403 on observable POST | Field in Fixed mode, so `{{ }}` was sent literally (visible in `docker compose logs thehive`) | Switch to Expression (fx), or use the TheHive 5 node. [Notes](../05-configuration/reference/n8n-thehive-observables.md) |
| "ObservableType port not found" | TheHive has no port type | Drop the port observable |
| Host alert gets a case but no L1 comment | Zero observables stops the n8n branch | `Has IPs?` node routes to No-IP Enrichment |
| Every API case assigned to the n8n user | TheHive assigns API cases to the creator | `Unassign Case` PATCH `{"assignee": null}` |
| Docker breaks on the host after Cortex starts | Cortex chowns the mounted `docker.sock` to 1001 | Restart `docker.socket docker`; use the socket proxy. [Notes](../04-installation/reference/cortex-with-docker-socket-proxy.md) |
| Cortex "Docker is not available" (403) | A proxy permission is missing | Enable CONTAINERS, IMAGES, POST, INFO, EXEC |
| `--docker-host` prints help and exits | It is not a CLI flag | Put it in `application.conf` |
| Cortex job AccessDeniedException | Jobs folder not owned by 1001 | `sudo chown -R 1001:1001 /opt/cortex/jobs` |
| Cortex keeps an old Docker error after a fix | `up -d` does not restart an unchanged container | `docker compose restart cortex` |
| Cortex user password will not save | No save button; under 8 characters fails silently | 8+ characters, press Enter |
| Analyzer never runs | Max TLP/PAP below the observable's Amber | Set both to AMBER |
| `cortex_6` index-not-found, "No analyzers found" | Database not initialised, nothing enabled yet | Press Update database; enable analyzers |
| A socket fault looks a day old | `chown` changes ctime, not mtime | Use `stat` and read ctime |

## The agent

| Symptom | Cause | Fix |
|---|---|---|
| GitHub Models "temporary brownout" | Service retired 30 Jul 2026 | OpenAI gpt-4o-mini |
| Hand-built model HTTP request keeps failing | JSON escaping in the request body | n8n AI Agent node, Responses API off |
| A bad model reply could break the run | Unparsed JSON | Parse in try/catch with a "manual triage required" fallback |
| Prompt sent with a stray leading `=` | `=={{` in the prompt field | One `=` only in expression fields |
| Answers vary more than expected | Temperature unset (default 1.0) | Temperature 0.2 |
| VirusTotal "N resolution(s)" tagged malicious | Cortex taxonomy level for passive DNS counts | Build Enrichment Summary relabels it info |
| Lab "completely broken" after a restart | Services still settling | Wait 5 minutes, then the [cold-start checklist](../06-operations/cold-start-checklist.md) |
