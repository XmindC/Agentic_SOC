# SOC Lab — Central Reference (single source of truth)

Updated 2026-10-01 from `lab-changes-20260930/RUNBOOK.md` (full change history, backups and rollbacks live there).

## Machines
| Machine    | Address           | Access |
|------------|-------------------|--------|
| OPNsense   | <OPNSENSE_WAN_IP>   | ssh root@<OPNSENSE_WAN_IP> (key from Kali) ; GUI https://<OPNSENSE_WAN_IP> |
| OPNsense LAN | <OPNSENSE_LAN_IP>    | lab gateway |
| Wazuh      | <WAZUH_IP>    | ssh socadmin@<WAZUH_IP> (key from Kali; sudo needs password) ; dashboard https://<WAZUH_IP> |
| services01 | <SERVICES_IP>    | ssh socadmin@<SERVICES_IP> (Docker host, dir ~/soc-stack) |
| Kali       | <ATTACKER_IP>   | attacker; `ssh kali` from the Mac (key + passwordless sudo); single NIC, reaches <LAB_LAN_CIDR> via <OPNSENSE_WAN_IP> |
| victim01   | <VICTIM_IP>       | from Kali: ssh sensor@<VICTIM_IP> (key; sudo needs password) |
| Mac        | <MAC_LAN_IP> / <MAC_NAT_IP> | VMware Fusion host; Wazuh agent at /Library/Ossec |

## Wazuh agents (agent_control -l)
| ID | Name | What |
|----|------|------|
| 000 | wazuhserver | the manager itself. **Suricata alerts also show as `wazuhserver`** (they arrive via syslog 514 on the manager) |
| 001 | kali | Kali |
| 002 | MacOS | the Mac host |
| 003 | sensor | victim01 (<VICTIM_IP>) |

## Web interfaces
- Wazuh:    https://<WAZUH_IP>   (admin)
- OPNsense: https://<OPNSENSE_WAN_IP>  (root)
- n8n:      http://<SERVICES_IP>:5678 (workflow "My workflow", id iyHu7OIXelaZAC1K)
- TheHive:  http://<SERVICES_IP>:9000 (<THEHIVE_ANALYST_USER>) ; case URL: /cases/<_id>/details
- Cortex:   http://<SERVICES_IP>:9001
- Wazuh indexer: https://127.0.0.1:9200 **on the manager only** (not exposed); read-only user `claude_ro`

## Containers (services01, ~/soc-stack — six services)
n8n | cassandra | elasticsearch | thehive (5.2) | cortex (4.1.0-1) | dockerproxy
Start: `cd ~/soc-stack && docker compose start`  |  Status: `docker compose ps`
Cassandra ready = `docker exec cassandra nodetool status` shows UN.

## Detection sources
- **Suricata** (OPNsense, IDS/pcap mode, **IPS OFF**) on em1 (<LAB_LAN_CIDR>) **and em0** (<LAB_INFRA_CIDR>).
  HOME_NET = <LAB_LAN_CIDR>,<LAB_INFRA_CIDR> ; EXTERNAL_NET = any (drop-in `conf.d/soc-lab-netvars.yaml`).
  DNS events logged to eve.json (drop-in `conf.d/soc-lab-dns.yaml`); only alerts go to Wazuh (syslog).
  Limit: Kali <-> <LAB_INFRA_CIDR> traffic and the Mac's own internet traffic never cross OPNsense (VMware vswitch).
- **Wazuh integration**: every alert **level >= 5** from **all agents** -> n8n webhook (`custom-n8n`, no rule_id/group filter).
- **Mac DNS**: launchd `com.soc.dnslog` (tcpdump, read-only, Umask 027) -> /var/log/dns-queries.log -> Mac agent
  -> rule **100300 level 3** (decoder soc-mac-dns). **Never reaches n8n/OpenAI** (below level 5), by design.
- **FIM (syscheck)**, scheduled every 12 h (the first scan after an agent restart is a silent baseline):
  Mac: /etc, /usr/bin, /usr/sbin, /bin, /sbin, **/Library/LaunchDaemons, /Library/LaunchAgents, /Users/<user>/Library/LaunchAgents**.
  Kali: /etc, /usr/bin, /usr/sbin, /bin, /sbin, /boot, **/root/.ssh, /home/{kali,<LAB_USER_1>,<LAB_USER_2>}/.ssh** (known_hosts ignored).
  victim01: /etc, /usr/bin, /usr/sbin, /bin, /sbin, /boot, **/root/.ssh, /home/sensor/.ssh** (known_hosts ignored).
- **Zeek** (victim01): standalone on ens37, JSON logs in /opt/zeek/logs (7-day expiry), /etc/cron.d/zeek keeps it running; conn.log read by the Wazuh agent -> rule **100310 level 3** (searchable alerts, never n8n). Zeek uses "_" field names (id_orig_h) because dotted names collide with data.id in the index.

## The pipeline (n8n, current order)
Webhook -> **Normalize** (flat fields: agent_name, source_ip/dest_ip from src_ip|srcip, user, file, rule_*, signature, raw)
-> **Filter**: rule_level >= 5 AND ( group not `ossec` OR (group `syscheck` AND file on a persistence path) )
-> **Create case** (`HTTP Request`): title `[suricata] <signature> (<src> -> <dst>)` for Suricata, else `[agent_name] rule_desc`; status New
-> **Unassign Case** (PATCH assignee null: TheHive assigns API cases to the creator by default)
-> **Has IPs?** yes: observables -> **Fan out analyzers** -> Cortex **AbuseIPDB + VirusTotal_GetReport** -> `waitreport` (<= 60 s)
                no: **No-IP Enrichment**
-> **Build Enrichment Summary** (Success / analyzer error / "unavailable (did not finish)"; never "clean";
   VT resolution counts relabelled info; RFC1918 addresses flagged)
-> **AI Agent** (gpt-4o-mini, temperature 0.2, no tools, text only) -> **Parse Verdict** (safe fallback)
-> **Post comment** (`HTTP Request1`) -> **Escalate?** -> Format Email (HTML + text) -> **Send Email** (Gmail SMTP, notification only)
Escalation email fires when: (rule_level >= 10 AND (AI severity high/critical OR group `authentication_failures`))
OR Suricata `data.alert.severity == 1`.
Cases stay **New and unassigned**; agents advise only; a human approves every action.

## Connectors
- n8n -> TheHive: "The Hive 5 account" (+ "Authorization" header credential for case creation)
- n8n -> Cortex:  "Cortex account" (Cortex 'n8n' user's key)
- n8n -> OpenAI:  "OpenAI account" (gpt-4o-mini, Responses API off)
- n8n -> Gmail:   "SMTP account" (owner-managed; do not edit)
- Webhook in:    POST http://<SERVICES_IP>:5678/webhook/wazuh-alert
- TheHive comment: POST http://thehive:9000/api/v1/case/<_id>/comment
- Cortex report:   GET  http://cortex:9001/api/job/<id>/waitreport?atMost=1minute

## Cortex accounts
kali (superadmin) | soclabadmin (orgadmin) | n8n (API only, key in n8n)

## Secrets (NEVER commit — config/config-secrets.env, mode 600)
Variables: OPENAI_API_KEY (ROTATE if not done — was exposed) | N8N_API_KEY | WAZUH_INDEXER_USER / WAZUH_INDEXER_PASS (read-only).
Other secrets live only in n8n's credential store or the services themselves.
Never put a secret on a command line: pass it to curl via stdin (`curl -K -`).

## Working rules learned
- Fetch the LIVE n8n workflow right before any API update (the owner also edits in the UI); back up first.
- Root on the manager or the Mac: temporary, scoped `/etc/sudoers.d/claude-*` rule, deleted after use.
- On this Mac, Python cannot reach the lab LAN (macOS Local Network privacy); use curl.

## Cold-start checklist (after any Mac restart)
1. Start VMs: OPNsense first, then Wazuh, services01, victim01, Kali.
2. Wait ~5 min. `cd ~/soc-stack && docker compose start`.
3. Cassandra ready: `docker exec cassandra nodetool status` shows UN.
4. Agents Active: on Wazuh `sudo /var/ossec/bin/agent_control -l` (000-003).
   If victim01 is disconnected: on victim01 `sudo systemctl restart wazuh-agent`.
5. eve.json current: on OPNsense `tail -1 /var/log/suricata/eve.json`.
6. Test scan (vary the port so it isn't deduplicated): Kali `sudo nmap -sS -p<PORT> <VICTIM_IP>`.
7. Confirm a new `[suricata] ...` case appears in TheHive (New, unassigned, L1 comment).

## Known behaviours (not faults)
- Wazuh suppresses repeated identical alerts (firedtimes) — vary the scan port.
- Cortex caches identical lookups for 10 minutes (cacheTag); VirusTotal free tier is about 4 lookups/min.
- Clock skew between machines (Mac UTC+1, Kali UTC-4, OPNsense UTC+1, manager/n8n UTC).
- Suricata restart takes ~2 min to load rules before it detects anything.
- `custom-n8n` logs "Exit status was: 7" in a burst during the daily 03:27 UTC scan; alerts are still delivered.
- The L1 agent's severity rating varies between runs; brute-force emails don't depend on it.

## Reference documents (in this workspace)
lab-changes-20260930/RUNBOOK.md (all changes since 2026-09-30) · soc_lab_1_plan.md · soc_lab_2_infrastructure.md ·
soc_lab_3..8 (docx) · soc_lab_9_agent_prompts.md · soc_lab_10_agent.docx · soc_lab_continuation_brief_5.md
