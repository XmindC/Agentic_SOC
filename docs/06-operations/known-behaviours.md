# Known behaviours (not faults)

| What you see | Why | What to do |
|---|---|---|
| A repeated scan makes no new case | Wazuh suppresses repeated identical alerts (`firedtimes`) | Change the port |
| A lookup returns instantly with an old result | Cortex caches identical analyses for 10 minutes | Wait, or use another address |
| VirusTotal "unavailable" | Free tier allows about 4 lookups a minute | Expected during bursts; the summary says unavailable, never clean |
| Reputation always looks harmless | Public services know nothing about private lab addresses | The enrichment flags RFC1918 addresses for the agent |
| The same event shows different times | Clocks: Mac UTC+1, Kali UTC-4, OPNsense UTC+1, Wazuh and n8n UTC | Compare with `date -u` |
| No detections for 2 minutes after a Suricata restart | Rules are still loading | Wait |
| Suricata alerts show agent `wazuhserver` | They arrive by syslog, which carries no agent identity | The rule description names the sensor and interface |
| One Kali scan makes two cases | The traffic crosses both em0 and em1 | Expected; deduplicate by `flow_id` later if needed |
| Kali scanning <SERVICES_IP> is not detected | The VMware switch never sends that traffic through OPNsense | Structural blind spot; only LAN-bound traffic is visible |
| `custom-n8n` logs "Exit status was: 7" around 03:27 UTC | Burst of rootcheck/SCA alerts during the daily scan | Alerts are still delivered; do not add `--retry` (it would duplicate cases) |
| The L1 severity differs between runs on the same alert | Model variation | Escalation emails do not depend on it alone |
| File-integrity test right after an agent restart shows nothing | The first scan is a silent baseline | Wait for the next scheduled scan |
| Kali 40101 / 5301 alerts at midnight Kali time | `locate.service` runs `su nobody`; disabled `locate.timer` (plocate does the job) | Fixed; check if `locate.timer` is re-enabled by an update |
| The whole lab is unreachable overnight | The Mac slept and froze the VMs | `caffeinate -s` while the lab is in use |
| Python on the Mac cannot reach the lab, curl can | macOS Local Network privacy | Use curl, or grant the terminal Local Network access |
