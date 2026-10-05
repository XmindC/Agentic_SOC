# SOC Lab change set 2026-09-30: full-fleet ingestion, DNS visibility, high-severity email

Status (updated 2026-09-30 end of day): **Tasks 1, 2, 3, 4, 5 (wired, email node disabled pending SMTP credential) and 7 APPLIED and validated by Claude. Task 6 (Mac) still manual; follow the Task 6 section below.**
Real agent names: Mac = `MacOS` (002), victim01 = `sensor` (003), Kali = `kali` (001). Suricata alerts arrive via syslog on the manager, so they show as `wazuhserver` (000).
The real n8n node names are `HTTP Request` (create case), `Code in JavaScript` (observables) and `HTTP Request1` (comment). Parse Verdict returns `severity` and `noteBody`.

Original status: **PREPARED, NOT YET APPLIED.** Claude could not reach the systems safely on 2026-09-30:
- Wazuh manager (<WAZUH_IP>), services01 (<SERVICES_IP>) and OPNsense (<OPNSENSE_WAN_IP>): SSH is password-only; no key installed, and Kali holds no onward keys.
- n8n: no API key on file, and the n8n MCP connector timed out.
- Mac: `sudo` needs a password; `/Library/Ossec` is root-only.
- Kali: key login and sudo work. It is only needed for Task 7, after the changes are applied.

Per the guardrail, these are the exact manual steps. Every file referenced lives next to this runbook.
Order matters: **1 → 2 → 3 → 5 → 4 → 6 → 7**. Task 5 moves ahead of Task 4 so the n8n work is done in one sitting and the email branch exists before em0 adds traffic.

Design gate (unchanged by anything below): the AI agent node has no tools and no credentials besides the model key n8n holds for it. It returns text only. Only n8n acts: it creates a case, posts a comment, and (new) sends a notification email. Cases stay **New, unassigned**. Nothing here blocks, isolates, disables or deletes.

---

## Task 1: Full-fleet Wazuh ingestion (manager <WAZUH_IP>)

```bash
ssh socadmin@<WAZUH_IP>
sudo cp -p /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak-20260930
sudo grep -n -B1 -A8 '<integration>' /var/ossec/etc/ossec.conf      # note the current block (record it for the report)
sudo ls -l /var/ossec/integrations/custom-n8n*                       # expect custom-n8n and custom-n8n.py, root:wazuh, x bit set
sudo nano /var/ossec/etc/ossec.conf
```
Replace the whole existing `custom-n8n` `<integration>` block with `wazuh/integration-block.xml`: no `<rule_id>`, no `<group>`, level 5, json.

Validate **before** restarting:
```bash
sudo /var/ossec/bin/wazuh-analysisd -t && echo ANALYSISD_OK
sudo /var/ossec/bin/wazuh-integratord -t && echo INTEGRATORD_OK
sudo diff /var/ossec/etc/ossec.conf.bak-20260930 /var/ossec/etc/ossec.conf   # this is the diff for the report
```
If either test fails, roll back:
`sudo cp -p /var/ossec/etc/ossec.conf.bak-20260930 /var/ossec/etc/ossec.conf`

Apply the change and confirm it took:
```bash
sudo systemctl restart wazuh-manager && sleep 20 && sudo systemctl is-active wazuh-manager
sudo grep -iE 'integrat|error' /var/ossec/logs/ossec.log | tail -20       # expect "Enabling integration for: 'custom-n8n'"
sudo /var/ossec/bin/agent_control -l                                    # all agents listed; 003 Active
```
Confirm in n8n: **Executions** should now show runs whose `body.agent.name` is not victim01 (Kali, the Mac, the manager itself).

> **Before Task 2 is done, n8n's existing Filter still drops group `ossec`.** Some fleet alerts are also filtered by it. That is intended; keep it.
> **Volume and cost:** every level ≥5 alert now makes one TheHive case, runs two Cortex lookups (VirusTotal free tier is about 4/min) and makes one OpenAI call. If testing shows a flood, raising `<level>` later is the lever. It is not raised here, per the brief.

---

## Task 2: n8n "Normalize" node (http://<SERVICES_IP>:5678)

1. **Back up first.** Open the workflow → `⋯` menu → **Download** (save as `wazuh-pipeline-bak-20260930.json`).
   Or on services01: `docker exec n8n n8n export:workflow --all --output=/home/node/.n8n/backup-20260930.json`
2. Add a **Code** node named `Normalize`, mode *Run Once for All Items*. Paste `n8n/normalize.js`, which was tested against Suricata, sshd, file-integrity and empty alerts.
3. Rewire: `Webhook → Normalize → Filter → (existing chain)`.
4. **Update the Filter node.** It currently reads the raw body; it must now read the normalized fields:
   - `{{ $json.rule_level }}` *Number* ≥ `5`
   - `{{ $json.rule_groups.includes('ossec') }}` *Boolean* is false
5. Any downstream expression that read `$json.body.X` or `$('Webhook')...body.X` now reads `$('Normalize').item.json.raw.X`, or better, the flat field (`source_ip`, `agent_name`, …). Search each node for `body.`
6. Do not touch Parse Verdict.

Validate: click **Test workflow**. Then fire one alert (Task 7 low test, or re-run a past execution via *Executions → Retry*). The Normalize output shows `agent_name`, `source_ip`, etc.; Filter passes it; a case is created. **Suricata path check:** a Kali nmap still produces a case.

### ⚠ Mismatch with the brief's flow
The brief assumes `… → AI Agent → Parse Verdict → Create Case`. The lab's documented flow is:
```
Webhook → Normalize(new) → Filter → Create Case → Build Observables → Cortex (AbuseIPDB, VT) → Wait 10s
        → Fetch Report → Enrichment Summary → L1 Agent → Parse Verdict → Post Comment → [IF severity → Email] (new)
```
The case is created **before** the verdict exists, which is why the verdict lands as a case comment. Tasks 3 and 5 below work with this real order rather than restructuring a working pipeline.

---

## Task 3: Create Case node

- **Title** (expression): `[{{ $json.agent_name }}] {{ $json.rule_desc }}`
- **Description** (suggested, expression):
  ```
  Agent: {{ $json.agent_name }} | Rule {{ $json.rule_id }} (level {{ $json.rule_level }})
  Signature: {{ $json.signature }}
  Source: {{ $json.source_ip || 'n/a' }} → Dest: {{ $json.dest_ip || 'n/a' }}
  User: {{ $json.user || 'n/a' }} | File: {{ $json.file || 'n/a' }} | Time: {{ $json.timestamp }}
  L1 triage is posted as a case comment below. Awaiting analyst approval.
  ```
  The L1 verdict and reasoning **keep going to the case as the comment** they already use; the verdict is not known when the case is created.
- **Status** stays `New`. **Assignee**: make sure the field is absent or empty. This is the human gate.
- **Build Observables** node: build only non-null IPs from Normalize. The pattern is below; keep your node's existing output keys.
  ```js
  const n = $('Normalize').item.json, caseId = $json._id, out = [];
  for (const [ip, role] of [[n.source_ip,'source'],[n.dest_ip,'destination']])
    if (ip) out.push({ json: { caseId, dataType: 'ip', data: ip, message: `${role} IP (${n.agent_name})` } });
  return out;
  ```
- **⚠ Required guard, a new failure mode created by Task 1.** Host alerts with no IP (Mac file-integrity, local sudo, etc.) produce **zero observables**. n8n then stops the branch, and the L1 agent never runs: a case with no triage. Fix: put an **IF** node `has IPs?` (`{{ !!($json.source_ip || $json.dest_ip) }}` is true) right after Create Case.
  - **true** → the existing Observables → Cortex chain.
  - **false** → a **Set** node that outputs the same field your Enrichment Summary node outputs (e.g. `enrichment_summary = "No IP observables on this alert; no reputation lookup performed."`), wired into the **L1 Agent** input.

  n8n allows two connections into one input.

Validate: a Suricata alert produces a case titled `[victim01] …` with 2 observables. A host alert (Task 7 SSH test, or `sudo` failures on Kali) produces `[kali] …` with 1 or 0 observables **and still gets its L1 comment**.

---

## Task 5: High-severity email (n8n)

1. Back up the workflow again (Download) before editing.
2. **Credentials → New → SMTP**: host `smtp.gmail.com`, port `465`, SSL/TLS **on**, user `<ALERT_EMAIL>`, password = your Gmail **App Password**.
   Type it into the n8n form yourself. Never into chat, a file or a node. It needs Google 2-Step Verification enabled.
3. Open one past execution's **Parse Verdict** output and note the exact key names (expected: `verdict, confidence, severity, summary, reasoning, next_steps`). Adjust the expressions below if they differ.
4. After **Post Comment** (so the case already carries the triage when the mail lands), add an **IF** node `Severity high/critical?`. One Boolean condition, case-insensitive and safe on parse failure:
   `{{ ['high','critical'].includes(String($('Parse Verdict').item.json.severity || '').toLowerCase()) }}` **is true**

   This equals the brief's `high OR critical`, plus lowercase handling. The FALSE branch connects to nothing.
5. On the TRUE branch add **Send Email** (SMTP credential above, format *Text*):
   - From / To: `<ALERT_EMAIL>`
   - Subject: `[SOC ESCALATION] {{ $('Parse Verdict').item.json.severity }} on {{ $('Normalize').item.json.agent_name }} - {{ $('Normalize').item.json.rule_desc }}`
   - Text:
     ```
     Verdict:    {{ $('Parse Verdict').item.json.verdict }}
     Confidence: {{ $('Parse Verdict').item.json.confidence }}
     Severity:   {{ $('Parse Verdict').item.json.severity }}

     Summary:
     {{ $('Parse Verdict').item.json.summary }}

     Reasoning:
     {{ $('Parse Verdict').item.json.reasoning }}

     Recommended next steps (for a human to decide):
     - {{ [].concat($('Parse Verdict').item.json.next_steps || ['(none given)']).join('\n- ') }}

     Case: http://<SERVICES_IP>:9000/cases/{{ $('Create Case').item.json._id }}/details
     Status New, unassigned. This email is a notification only; nothing has been actioned.
     ```
6. The email node has no outgoing connections. It triggers nothing.

Validate without an attack: in the IF node, pin a test item with `severity: "high"` (Executions → open a past run → *Debug in editor*, edit the pinned Parse Verdict data) and execute. Expect one email, with a case link that opens. Repeat with `severity: "low"`: the IF goes false and no email is sent. Then unpin.

---

## Task 4: Suricata on em0 + DNS logging (OPNsense <OPNSENSE_WAN_IP>)

**Backup first:**
- GUI: *System → Configuration → Backups → Download configuration*.
- SSH (tcsh):
  ```tcsh
  cp -p /conf/config.xml /conf/config.xml.bak-20260930
  cp -p /usr/local/etc/suricata/suricata.yaml /root/suricata.yaml.bak-20260930
  ```

**Interfaces:** *Services → Intrusion Detection → Administration → Settings*
- **IPS mode must stay UNCHECKED** (IDS only). IPS on em0 would put the lab's WAN path inline and could drop traffic. That would be an automated block, which breaks the gate.
- **Interfaces:** select **both** LAN (em1) **and** WAN (em0).
- **Promiscuous mode:** on. Without it, em0 only sees traffic addressed to OPNsense itself.
- Save → **Apply**.

**DNS in eve.json:** on OPNsense 26.x, first look in the same page (advanced mode, *Logging / Eve* section) for an eve event-type selector and tick **DNS**. If your build has no such selector, use the supported override file:
```tcsh
grep -n -A25 'eve-log' /usr/local/etc/suricata/suricata.yaml     # see the generated outputs/types
grep -n 'include' /usr/local/etc/suricata/suricata.yaml          # confirm custom.yaml is included
```
Then copy the **entire** generated `outputs:` block into `/usr/local/etc/suricata/custom.yaml` and add `- dns` under the eve-log `types:` list. An include replaces the whole key, so a partial `outputs:` would drop the alert output and **break the Suricata→case pipeline**. If unsure, stop here and keep em1-only DNS off.

**Validate, then restart:**
```tcsh
/usr/local/bin/suricata -T -c /usr/local/etc/suricata/suricata.yaml && echo CONFIG_OK
```
Then *Apply* in the GUI (or `configctl ids restart`).

On failure, roll back and apply:
```tcsh
cp -p /conf/config.xml.bak-20260930 /conf/config.xml ; rm /usr/local/etc/suricata/custom.yaml
```

**Confirm:**
```tcsh
ps auxww | grep '[s]uricata'                  # command line lists em0 AND em1
tail -50 /var/log/suricata/suricata.log | grep -iE 'em0|em1|error'   # or the dated log in /var/log/suricata/
```
- From victim01, generate DNS through OPNsense: `dig example.com` (goes out via <OPNSENSE_LAN_IP>, crossing em1 and em0).
- Then `grep -c '"event_type":"dns"' /var/log/suricata/eve.json` should be greater than 0.
- **em1 regression:** Kali `sudo nmap -sS -p<NEW_PORT> <VICTIM_IP>` still produces a case.

**Honest limitations (report, do not work around):**
- **The Mac's** own internet/DNS never crosses OPNsense; only its traffic *into* the lab is visible. Task 6 covers it.
- **Kali's own DNS and Kali↔<WAZUH_IP>/<SERVICES_IP> traffic** use the VMware vmnet directly and the VMware NAT resolver (<NAT_GATEWAY_IP>), not OPNsense. They are visible on em0 only if promiscuous mode works on the VMware Fusion vmnet. Test: Kali `dig @<NAT_GATEWAY_IP> kali-dns-test.example` then grep eve.json for `kali-dns-test`. If it is absent, that traffic is structurally invisible to Suricata.
- **Duplicate alerts:** Kali→victim01 now crosses em0 *and* em1, so one scan can make **two cases**. Expected; deduplicate later (e.g. by `flow_id`) if it bothers students.
- **Volume:** DNS events add eve volume. The Wazuh default Suricata rule for non-alert events is level 0, so they do not reach n8n.

---

## Task 6: Mac DNS logger (run in your own Terminal on the Mac)

All files are in `mac/`. Run from this directory: `cd ~/Documents/INCIDENT_RESPONSE_AGENT/lab-changes-20260930/mac`

Two small, deliberate changes from the brief:
1. tcpdump runs through a 2-line wrapper that writes a pid file, so newsyslog can rotate the log. tcpdump never reopens its stdout; at rotation newsyslog stops it, launchd (`KeepAlive`) restarts it, and launchd opens a fresh log.
2. `-tttt` adds full dates to each line.

```bash
# 1. logger
sudo mkdir -p /usr/local/sbin
sudo install -o root -g wheel -m 755 soc-dnslog.sh /usr/local/sbin/soc-dnslog.sh
sudo install -o root -g wheel -m 644 com.soc.dnslog.plist /Library/LaunchDaemons/com.soc.dnslog.plist
sudo install -o root -g wheel -m 644 soc-dnslog.newsyslog.conf /etc/newsyslog.d/soc-dnslog.conf
sudo newsyslog -nv 2>&1 | grep dns-queries        # dry run: rotation entry parsed
sudo launchctl load /Library/LaunchDaemons/com.soc.dnslog.plist
sudo launchctl list | grep com.soc.dnslog         # has a PID, exit status 0
nslookup example.com; sleep 2; sudo tail -3 /var/log/dns-queries.log   # expect "... A? example.com. (29)"

# 2. Wazuh agent: add ONE <localfile> block, touch nothing else
sudo cp -p /Library/Ossec/etc/ossec.conf /Library/Ossec/etc/ossec.conf.bak-20260930
sudo nano /Library/Ossec/etc/ossec.conf            # paste ossec-localfile-snippet.xml inside <ossec_config>, next to the other <localfile> blocks
sudo /Library/Ossec/bin/wazuh-logcollector -t && echo LOGCOLLECTOR_OK   # on failure: restore the .bak
sudo diff /Library/Ossec/etc/ossec.conf.bak-20260930 /Library/Ossec/etc/ossec.conf
sudo /Library/Ossec/bin/wazuh-control restart
sudo grep dns-queries /Library/Ossec/logs/ossec.log | tail -2   # "Analyzing file: '/var/log/dns-queries.log'"
```

**3. Make it visible on the manager.** A raw tcpdump line matches no stock rule, so without this it is silently dropped. On <WAZUH_IP>:
```bash
sudo grep -rn 'id="1003' /var/ossec/etc/rules/                    # confirm 100300 is free
sudo cp -p /var/ossec/etc/decoders/local_decoder.xml /var/ossec/etc/decoders/local_decoder.xml.bak-20260930
sudo cp -p /var/ossec/etc/rules/local_rules.xml /var/ossec/etc/rules/local_rules.xml.bak-20260930
# append wazuh/local_decoder-mac-dns.xml and wazuh/local_rules-mac-dns.xml to those two files
sudo /var/ossec/bin/wazuh-logtest     # paste a real line from the Mac's /var/log/dns-queries.log
                                      # expect: decoder soc-mac-dns, rule 100300 level 3
sudo /var/ossec/bin/wazuh-analysisd -t && sudo systemctl restart wazuh-manager
```
Rule 100300 is **level 3**, below the n8n threshold, so Mac DNS appears in the Wazuh dashboard but never opens a case or calls the model. Keep it below 5.

**Validate:** on the Mac, `nslookup soc-dnstest.example.com`. On the manager:
`sudo grep 'soc-dnstest' /var/ossec/logs/alerts/alerts.log | tail -2` shows rule 100300 with the Mac's agent name.

**Limitations:**
- Browsers using encrypted DNS (DoH/DoT) bypass port 53, so those lookups are invisible here.
- `-i any` also captures VM DNS crossing the Mac's vmnet interfaces. That is intended.
- The logger only reads packets.

**Rollback:**
```bash
sudo launchctl unload /Library/LaunchDaemons/com.soc.dnslog.plist
sudo rm /Library/LaunchDaemons/com.soc.dnslog.plist /etc/newsyslog.d/soc-dnslog.conf /usr/local/sbin/soc-dnslog.sh
sudo cp -p /Library/Ossec/etc/ossec.conf.bak-20260930 /Library/Ossec/etc/ossec.conf
```
Then restart the agent.

---

## Task 7: End-to-end validation (Kali; Claude can run these once 1–6 are applied)

**Low severity:**
```bash
sudo nmap -sS -p8443 <VICTIM_IP>
```
Vary the port each run: Wazuh dedups identical alerts.
- **Expected:** one or two cases (em1, plus em0 after Task 4) titled `[victim01] …`, L1 comment with severity low.
- In n8n the IF `Severity high/critical?` goes **false**. **No email.**

**High severity:** SSH brute force against **victim01 only** (agent 003 reads its sshd auth log). Use a tiny list of wrong passwords, so no login can succeed and no production host is hit:
```bash
printf 'x1\nx2\nx3\nx4\nx5\nx6\nx7\nx8\nx9\nx10\nx11\nx12\n' > /tmp/wrong.txt
hydra -l root -P /tmp/wrong.txt -t 4 -I ssh://<VICTIM_IP>
```
- **Expected:** Wazuh 5710/5712/5763-class alerts (level ≥ 10) → case `[victim01] sshd: brute force…`.

**⚠ This may NOT email, and that would be correct behaviour.** The L1 prompt recognises <ATTACKER_IP> as the authorised test machine; lab-10 documents it rating Kali activity low and not escalating. Do **not** weaken the prompt to force an email. The email path is proven by the pinned-data test in Task 5. If you want a live high rating, record in the case which evidence the agent weighed.

**Gate check:**
- In TheHive, every new case is **New, unassigned**.
- On OPNsense, no new firewall rules or aliases (*Firewall → Rules*, *Firewall → Aliases*) and IPS mode is off.
- On Wazuh, no active-response triggered: `sudo grep -c . /var/ossec/logs/active-responses.log` is unchanged.
- In n8n, the only outbound actions are Create Case, observables, Cortex lookups, comment, and email.

---

## Final report template (fill in as you go)

| Task | Changed (diff) | Validated | Skipped / why |
|---|---|---|---|
| 1 Full-fleet | `diff ossec.conf.bak-20260930 ossec.conf` | analysisd/integratord -t; non-victim alerts in n8n | |
| 2 Normalize | node added, Filter repointed | test run; Suricata case still made | |
| 3 Create Case | title/description/observables + has-IPs guard | host alert gets case + L1 comment | |
| 4 Suricata em0+DNS | config.xml / custom.yaml diff | suricata -T; both ifaces; dns events; em1 nmap → case | |
| 5 Email | IF + Send Email (SMTP cred) | pinned high → email; pinned low → none | |
| 6 Mac DNS | plist, wrapper, newsyslog, 1 localfile, decoder+rule 100300 | nslookup → log → manager alert | |
| 7 E2E | none | low no email; high path | |

Confirmations to state explicitly:
- Low severity does not email; high/critical does.
- The em1 Suricata path still creates cases.
- Agents hold no credentials or tools.
- Cases are New and unassigned.
- No auto-actions anywhere.

---

## Post-rollout changes (2026-09-30, applied by Claude via n8n API / SSH)

Every n8n change fetched the LIVE workflow immediately before the PUT, exported it to `backups/`, and re-verified afterwards that the owner-set Send Email fields (enabled, SMTP credential, From/To) were untouched.

### Email throttle (owner-approved, in order)
- `Severity high/critical?` → added `escalate` + `rule_level >= 10` → dropped `escalate` (the AI set it inconsistently) → added the brute-force rollup rule.
- Final node: `Escalate? ((AI high/critical OR brute-force rollup) + level>=10)`:
  ```
  rule_level >= 10 && (severity in [high, critical] || rule_groups includes 'authentication_failures')
  ```
- The owner added the Gmail SMTP credential and enabled Send Email in the UI. First live send: execution #496, case #298, rule 5763, SMTP `250 OK`.

### Cleanup batch
1. **AI Agent prompt:** removed the stray leading `=` from the prompt **text** field (`=={{` → `={{`). The system message never had one. No wording changed. Backup `…T175122-pre-item1-prompt-equals.json`.
2. **Temperature:** OpenAI Chat Model temperature was unset (default 1.0); now `0.2`. Responses API still off. Backup `…T175305-pre-item2-temperature.json`.
3. **Cortex enrichment:** removed the fixed 3 s `Wait`.
   - `Get Cortex Report` now calls `/api/job/<id>/waitreport?atMost=1minute`: Cortex returns as soon as the job finishes, at most after 60 s. HTTP timeout is 75 s, and on error it continues (the analyzer is then shown as unavailable).
   - `Build Enrichment Summary` reports three states: Success → taxonomies; Failure → "analyzer finished with an error: …"; anything else → "unavailable (job did not finish within 60s)". It never says clean.
   - Only AbuseIPDB is configured; there is no VirusTotal analyzer in the workflow.
   - Backup `…T175344-pre-item3-cortex-waitreport.json`.
4. **HTML email:** new `Format Email` Code node (true branch → Format Email → Send Email). It converts the L1 markdown note to HTML with a clickable case link, plus a plain-text fallback. Send Email is set to `emailFormat: both`; subject unchanged; first line kept. Backup `…T175641-pre-item4-html-email.json`.
5. **Suricata networks (OPNsense):**
   - `homenet` set to `<LAB_LAN_CIDR>,<LAB_INFRA_CIDR>` via the IDS settings model.
   - New drop-in `/usr/local/etc/suricata/conf.d/soc-lab-netvars.yaml`: a full copy of the generated `vars` block with `EXTERNAL_NET: "any"`. EXTERNAL_NET is hardcoded in OPNsense's template, which was not edited. Because the drop-in pins HOME_NET, keep it in sync if homenet changes in the GUI.
   - IPS mode `pcap` before and after.
   - Backups: `/conf/config.xml.bak-20260930T190652-pre-item5`, `/root/suricata.yaml.bak-20260930T190652-pre-item5`.
   - Noise: 0 cases in 10 idle minutes before, 0 after.
   - Kali→victim01 nmap: exactly one case.
   - **Kali→<SERVICES_IP> nmap: no alert. This is structural, not a config problem:** a capture on em0 during the scan saw only the broadcast ARP, because VMware's virtual switch does not deliver unicast between other VMs to OPNsense.
   - Revert: `rm /usr/local/etc/suricata/conf.d/soc-lab-netvars.yaml`, restore config.xml, then `configctl template reload OPNsense/IDS && configctl ids restart`.
6. **Suricata case titles:** alerts in the `suricata` rule group are titled `[suricata] <signature> (<src_ip> -> <dest_ip>)`; host alerts keep `[agent_name] rule_desc`. Backup `…T182738-pre-item6-suricata-titles.json`.
7. **Report only, not applied:** adding `data.alert.severity == 1` would add 4 emails today, all "ET SCAN LibSSH Based Frequent SSH Connections Likely BruteForce Attack" (#363, #423, #449, #476). That is one extra email per brute force, on top of the 5763 rollup.

---

## Task 6 applied (2026-10-01, by Claude, scoped sudo rules)

Access: temporary `/etc/sudoers.d/claude-task6` on the Mac and on the manager, with fixed paths and arguments only (drafts in `sudoers/`). Claude deleted both at the end; sudo asks for a password again on both machines.

**Change from the plan above:** no wrapper script. `/usr/local/sbin` on this Mac is user-writable, so a root daemon running a script from there would allow privilege escalation. The pid-file + `exec tcpdump` lines are inline in the root-owned plist (`/bin/sh -c "echo $$ > /var/run/soc-dnslog.pid; exec /usr/sbin/tcpdump -l -n -tttt -i any 'udp port 53 or tcp port 53'"`). `mac/soc-dnslog.sh` was removed from the package.

1. **Mac DNS logger**
   - Installed `/Library/LaunchDaemons/com.soc.dnslog.plist` (root:wheel 644; RunAtLoad + KeepAlive; out `/var/log/dns-queries.log`, err `/var/log/dns-queries.err`) and `/etc/newsyslog.d/soc-dnslog.conf` (log: 7 × 10 MB, J, pid file, SIGTERM; err: 3 × 1 MB). Neither existed before, so there was nothing to back up.
   - `plutil -lint` OK on the installed plist; loaded.
   - tcpdump runs as root on `any` (PKTAP).
   - `newsyslog -nvv` lists both entries.
   - Kill test: TERM to PID 29631; launchd restarted it as 29747, which logged the next lookup.
   - Note: launchd created the log as 644 root:wheel (readable by any local user) until the first rotation recreates it as 640 root:admin.
2. **Mac Wazuh agent**
   - Backup `/Library/Ossec/etc/ossec.conf.bak-20261001`.
   - Added one `<localfile>` (syslog, `/var/log/dns-queries.log`) after the last existing `<localfile>`. The diff is that block only.
   - `wazuh-logcollector -t` passed; agent restarted; all 5 daemons running; agent log shows `Analyzing file: '/var/log/dns-queries.log'`.
   - Name, ID, key, manager address and other monitored files unchanged.
3. **Manager**
   - Backups `/var/ossec/etc/decoders/local_decoder.xml.bak-20261001` and `/var/ossec/etc/rules/local_rules.xml.bak-20261001`.
   - Appended decoders `soc-mac-dns` / `soc-mac-dns-query` (13 lines) and rule **100300 level 3**, group `soc_lab,mac_dns` (12 lines). 100300 was unused.
   - `wazuh-logtest` on 4 real Mac lines: all decoded and matched 100300 level 3.
   - `analysisd -t` passed; restart OK; all 4 agents Active.

**Validation**
- `nslookup soc-e2e-050428.example.com` on the Mac:
  - line in `/var/log/dns-queries.log`
  - manager alert rule 100300, level 3, agent MacOS (002), "Mac DNS query: soc-e2e-050428.example.com (A) from <HOME_LAN_IP>"
- **Never reaches n8n/OpenAI:** level 3 is below the integration threshold (5). 28 n8n executions after the change; none carried Mac DNS (110 Mac DNS alerts on the manager in the same period).

**Rollback** (needs sudo):
1. `launchctl unload /Library/LaunchDaemons/com.soc.dnslog.plist`
2. Remove the plist and `/etc/newsyslog.d/soc-dnslog.conf`.
3. Restore `ossec.conf.bak-20261001` and restart the agent.
4. On the manager, restore both `.bak-20261001` files and restart wazuh-manager.

---

## Investigation: custom-n8n "Exit status was: 7" (2026-10-01): no change made

- **Script** (`/var/ossec/integrations/custom-n8n`, root:wazuh 750, 126 B): `curl -s -X POST -H "Content-Type: application/json" -d @"$1" "$3"`. It passes only the hook URL, so the "extra numeric argument" theory was wrong and the proposed replacement (`wazuh/custom-n8n.new`) was **not** applied. Sudo rule `claude-n8nfix` was installed, used read-only, then deleted.
- **When it happens:** 6 failures since log rotation, all at 03:27:12-16 UTC. That is exactly the burst of `wazuhserver` rule 510 alerts produced by the daily rootcheck/FIM/SCA scan (03:27:10), which coincides with the wazuh-db backup.
- **Impact: none on delivery.** Each failing run printed n8n's `{"message":"Workflow was started"}`, and n8n shows 34 executions for 34 unique Wazuh alert IDs in 03:26-03:30 UTC, all successful, no duplicates. The errors are false alarms.
- **Not reproduced:** 30 rapid sequential posts and 20 concurrent posts from the manager with the identical curl command all returned exit 0.
- **Do NOT add curl `--retry` on connect errors:** the failing runs had already delivered, so a retry would create duplicate cases.
- **If it matters later:** enable integratord debug (`integrator.debug=2` in `/var/ossec/etc/local_internal_options.conf`, restart) before 03:27 to capture curl's stderr on the next occurrence, then turn it back off.

---

## Mac DNS log permissions (2026-10-01)

- `/var/log/dns-queries.log` and `/var/log/dns-queries.err` are now `640 root:wheel` (were 644, world-readable). The owner ran the chmod; no sudo rule was used.
- Permanent fix: `mac/com.soc.dnslog.plist` now sets `Umask` 23 (= 027), so any log file launchd recreates is 640. The owner reinstalled the plist and reloaded the daemon at 05:44:18 (new tcpdump PID 51674).
- Verified by Claude:
  - perms 640 on both files
  - installed plist identical to the package, Umask = 23
  - daemon running as root
  - log still growing after test lookups
- Not verified (no manager root): that new lines still reach the manager. Agent config was untouched; check with `sudo grep soc-perm-check /var/ossec/logs/alerts/alerts.log` on <WAZUH_IP> (expect rule 100300, agent MacOS).
- Side effect: the owner's normal account needs `sudo` to read the log. newsyslog already recreates rotated files as 640.

---

## Kali 40101/5301 alerts and read-only alert access (2026-10-01)

**Kali 40101 ("System user successfully logged", L12) + 5301 (L5) every night at 00:00:02 Kali time (04:00 UTC):**
- Source: `locate.service`, i.e. `/etc/cron.daily/locate`, i.e. GNU `updatedb --localuser=nobody`. It runs `su nobody` three times (two `su -s` capability probes, then the real run).
- 5301 is a misread `pam_wtmpdb ... readonly database` line.
- Benign, but it made 6 cases and 6 OpenAI calls per night, with a possible email if the AI ever rated 40101 high.
- `locate` resolves to plocate (`plocate-updatedb.timer` still enabled), so the owner disabled the redundant `locate.timer`. Verified disabled/inactive.

**Read-only indexer user `claude_ro`:**
- The indexer listens on `127.0.0.1:9200` only. Left that way; Claude queries it over SSH as socadmin, with no root or network change.
- Role `claude_alerts_readonly`: `index_patterns ["wazuh-alerts-*"]`, `allowed_actions ["read"]`, no cluster or tenant permissions, no DLS/FLS. Mapped to user `claude_ro` only.
- **Gotcha:** the dashboard form had saved the pattern as `" wazuh-alerts-*"` (leading space), which matched nothing. Fixed with a Dev Tools `PUT _plugins/_security/api/roles/claude_alerts_readonly`. Verify with `GET` if it is edited again.
- Credentials are in `config/config-secrets.env` (`WAZUH_INDEXER_USER/PASS`, file now 600). The password is passed to curl only via stdin (`curl -K -`), never on a command line.
- Verified:
  - reads: 21,892 alert docs
  - refused (403): both write attempts, `wazuh-states-*`, `.opendistro_security`, `_cluster/settings`, `_cat/indices`
  - `wazuh-archives-*` returns an empty 200 because no archive indices exist
- Confirmed with it that Mac DNS still reaches the manager after the 640/Umask change:
  - `soc-perm-check.example.com`: rule 100300 L3, agent MacOS, 2026-10-01T04:44:56Z
  - latest Mac DNS alert at 05:58:58Z
- Query tips: `data.dns_query` is a keyword field (exact match); `full_log` is text.

---

## n8n Filter: file-integrity alerts on persistence paths (2026-10-01)

- **Before:** `rule_level >= 5 AND groups not contains 'ossec'`. All file-integrity (syscheck) alerts were dropped, because they carry the `ossec` group.
- **After:** `rule_level >= 5 AND ( 'ossec' not in groups OR ('syscheck' in groups AND file matches PERSIST) )`, where PERSIST is:
  ```
  ^(\/private)?\/etc\/(cron[^\/]*|crontab|anacrontab|systemd\/system|init\.d|rc[0-9S]\.d|rc\.local|profile|profile\.d|bash\.bashrc|zshrc|zprofile|environment|ld\.so\.preload|ld\.so\.conf(\.d)?|sudoers|sudoers\.d|passwd|shadow|group|gshadow|ssh\/sshd_config(\.d)?|pam\.d|hosts|launchd\.conf|periodic)(\/|$)|^\/Library\/Launch(Daemons|Agents)\/|^\/Users\/[^\/]+\/Library\/LaunchAgents\/|^\/(root|home\/[^\/]+)\/\.ssh\/authorized_keys
  ```
  It covers /etc cron*, systemd/system, init.d, rc*.d, rc.local, profile(.d), bash.bashrc, zshrc/zprofile, environment, ld.so.preload, ld.so.conf(.d), sudoers(.d), passwd/shadow/group/gshadow, ssh/sshd_config(.d), pam.d, hosts, launchd.conf, periodic (each with an optional /private prefix for macOS), plus /Library/LaunchDaemons, /Library/LaunchAgents, /Users/*/Library/LaunchAgents and root/home .ssh/authorized_keys.
- **Why a persistence list instead of all of /etc:** last 7 days, Kali raised 182 /etc FIM alerts, 178 of them in one package-upgrade burst (09-25).
  - All /etc: 1-3 extra cases on normal days and about 180 per apt upgrade.
  - Persistence list: 0 on normal days and 38 on the upgrade day (new services, PAM, profile.d, sshd config).
- **Validation (synthetic, labelled PIPELINE TEST):**
  - `/etc/cron.d` L7 passed (case #336, no-IP branch, L1 comment, no email).
  - `/etc/alternatives`, rootcheck 510 and an L3 FIM alert were all filtered.
  - Offline replay of 196 real alerts: 65 passed before and after, 0 lost, 0 gained.
- **Backup:** `backups/workflow-iyHu7OIXelaZAC1K-bak-20261001T062609-pre-fim-persistence-filter.json`
- **Gap:** the agents only monitor /etc, /usr/bin, /usr/sbin, /bin, /sbin (Kali also /boot), every 12 h. **/Library/LaunchDaemons, /Library/LaunchAgents, ~/Library/LaunchAgents and .ssh are NOT monitored**, so the filter is ready for them but no alerts can arrive until the agents' <syscheck> config adds those directories. That needs root on the Mac.
- Mac FIM cases (path names, no file contents; report_changes is off) would go to the L1 agent / OpenAI like any other case.

---

## Mac agent: Launch folders added to FIM (2026-10-01)

- **Change** (Mac `/Library/Ossec/etc/ossec.conf`, `<syscheck>`): one line added:
  `<directories>/Library/LaunchDaemons,/Library/LaunchAgents,/Users/<user>/Library/LaunchAgents</directories>`
  - Default checks: size, perms, owner, group, mtime, inode, md5/sha1/sha256. Scheduled scans only; no report_changes, so no file contents leave the Mac.
  - Final diff vs backup is that line plus a comment.
  - Backup: `/Library/Ossec/etc/ossec.conf.bak-20261001-prelaunch`. Copy of the new config: `mac/ossec.conf.launch-fim`.
- **Access:** temporary `/etc/sudoers.d/claude-launchfim` (draft in `sudoers/`). Claude deleted it; sudo asks for a password again.
- **Key finding:** the first FIM scan after an agent restart is a baseline and raises **no alerts**. Restart-triggered tests show nothing, and it explains why the frequently-restarted Mac had 0 FIM alerts in 7 days while Kali had 2,527. Changes are only alerted by the next **scheduled** scan, every 12 h (43200 s).
- **Test:**
  - Temporarily set the FIM `<frequency>` to 300 and restart (baseline).
  - Added `com.soc.fimtest2.plist` and modified `com.soc.fimtest.plist` (disabled, `/usr/bin/true`, never loaded).
  - The scheduled scan at 06:42:52Z raised 554 L5 "File added" and 550 L7 "Integrity checksum changed". Both passed the n8n persistence Filter: cases #338 and #337, `[MacOS] …`, no-IP branch, L1 comment (needs_investigation/medium), unassigned, no email.
  - Then deleted the test files, restored 43200 and restarted, so the deletions fell in the baseline and created no cases.
- **Slip:** the first `sed` for the test also changed rootcheck's `<frequency>` (5 min for about 30 s). It was corrected and restarted immediately; the final config has rootcheck at 43200.
- **Expect** occasional `[MacOS]` FIM cases when apps update their launchd plists (Google/Grammarly updaters, other user launchd jobs). Paths go to the L1 agent/OpenAI, not contents.

---

## "Solve all" batch (2026-10-01)

Tooling note: macOS Local Network privacy now blocks Python on this Mac from the lab LAN (curl/nc are fine). The n8n helper was switched to curl, with the API key passed on stdin (`-K -`).

1. **Suricata networks (item 5):** decision = **keep** (owner accepted the recommendation). No change.
2. **Test cases closed:** #200, #202, #336, #337, #338 set to status `Other` / stage Closed, with summary "Pipeline test case ... Closed by Claude at the owner's request".
   - Done via a temporary allowlisted n8n workflow. Real case #199 was refused at the allowlist (exec #732).
   - The workflow was deleted afterwards; its definition is in `backups/tmp-close-test-cases-workflow-removed.json`.
   - Cases #1–#201 untouched (still assigned to n8n@thehive.local, as before).
3. **SSH persistence FIM on Kali:** added `/root/.ssh,/home/kali/.ssh,/home/<LAB_USER_1>/.ssh,/home/<LAB_USER_2>/.ssh` plus `<ignore type="sregex">/.ssh/known_hosts</ignore>`. Config test passed; agent restarted.
   - Backup: Kali `/var/ossec/etc/ossec.conf.bak-20261001-pressh`.
   - **victim01 not done:** sensor@<VICTIM_IP> accepts passwords only. Manual steps are in the final report.
4. **VirusTotal enrichment:** `VirusTotal_GetReport_3_1` was already enabled in Cortex but unused.
   - New `Fan out analyzers` Code node (Create an observable → Fan out → Execute an analyzer, whose analyzer is now `{{ $json.analyzer }}`) runs AbuseIPDB **and** VirusTotal for each IP.
   - The L1 agent still runs once per alert.
   - `Build Enrichment Summary` relabels VT "N resolution(s)" (which Cortex tags as level *malicious*) as info, and flags RFC1918 addresses.
   - Backups: `…T071652-pre-virustotal-fanout.json`, `…T071806-pre-enrichment-vt-labels.json`.
5. **Email on Suricata severity 1:** the escalation condition now ORs in `String(raw.data.alert.severity) === '1'`. Backup `…T071410-pre-email-suricata-sev1.json`.
6. **lab-reference.md:** rewritten for the current lab (backup `config/lab-reference.md.bak-20261001`).
7. **custom-n8n exit-7 debug:** scoped manager rule `sudoers/claude-n8ndebug.manager` drafted; waiting for the owner to install it.

**Final check (2026-10-01 07:19Z):**
- Brute force: 24 cases, **exactly 2 emails**, both SMTP 250, HTML with a clickable link:
  - #742 / case #341: Suricata sev-1 LibSSH
  - #763 / case #363: Wazuh 5763
- Enrichment shows both analyzers with the corrected VT labels.
- nmap #765 / case #364: medium, no email, 4 Cortex jobs.

**victim01 SSH persistence FIM (2026-10-01, completes item 3):**
- The owner added Kali's key for sensor@<VICTIM_IP>. The first attempt didn't take (the offered key was rejected), and was fixed with `ssh-copy-id`.
- Scoped rule `claude-victimfim` (draft in `sudoers/`) was staged in sensor's home, installed by the owner with `sudo install -m 440`, and deleted by Claude afterwards.
- Added `<directories>/root/.ssh,/home/sensor/.ssh</directories>` plus `<ignore type="sregex">/.ssh/known_hosts</ignore>`. The only login accounts are root and sensor.
  - `wazuh-syscheckd -t` passed; agent restarted; log shows both paths monitored; agent reconnected to the manager at 07:41:41.
  - Backup: victim01 `/var/ossec/etc/ossec.conf.bak-20261001-pressh`.
- Pre-existing, not changed:
  - systemd says the wazuh-agent unit changed on disk (run `sudo systemctl daemon-reload` when convenient).
  - The agent's `<localfile>` for `/opt/zeek/logs/current/conn.log` fails because the file doesn't exist, so Zeek is not feeding Wazuh.
- VirusTotal: the owner confirmed the API key is configured in Cortex; VT already returned Success reports in the 07:19Z test.

**custom-n8n exit-7: one-night debug ENABLED (2026-10-01 07:51 UTC, completes item 7 setup):**
- Scoped rule `claude-n8ndebug` (draft in `sudoers/`): staged in socadmin's home, installed by the owner with `sudo install -m 440`.
- `/var/ossec/etc/local_internal_options.conf` now has `integrator.debug=2` appended (it previously held only comments). Backup: `local_internal_options.conf.bak-20261001`.
- Manager restarted; 000-003 Active.
- Baseline successful run in debug: `File /tmp/custom-n8n-<id>.alert was written` → `{"message":"Workflow was started"}` → `Command ran successfully.`
- Follow-up job `f3c9aa6b` at 2026-10-02 03:43 UTC (session-only) will:
  1. read the 03:27 burst
  2. restore the .bak and restart the manager
  3. delete the sudo rule
  4. record the cause and a proposed fix here (no fix applied without the owner)
- **If the session ended before then, run those steps by hand. Until reverted, debug stays on (noisier ossec.log).**

---

## Zeek check, close all cases, Kali PAM log (2026-10-01)

**All open TheHive cases closed (owner request; overrides the earlier "don't touch #1-201"):**
- Snapshot: 366 open cases (#1-#371, all stage New), listed read-only (exec #800).
- Bulk-closed exactly that snapshot as status `Other` with summary "Bulk-closed by Claude at the owner's request on 2026-10-01 (lab cleanup after pipeline testing). Not individually reviewed; reopen if needed."
  - Batches of 5, every case read back: `{"requested":366,"closed":366,"failed":[]}`.
  - A made-up ID was refused at the allowlist.
  - Re-list afterwards (exec #804): 0 open.
- Cases created later still open as New (pipeline unchanged).
- **Still to delete (Claude's deletion was blocked by the permission classifier):** two temporary n8n workflows
  - "TMP claude list open cases (read-only, delete after 2026-10-01)"
  - "TMP claude bulk-close snapshot of open cases (delete after 2026-10-01)"

  The owner should delete them in the n8n UI. The bulk one only accepts the 366 already-closed IDs, so it is low risk but still an active webhook.

**Kali `pam_wtmpdb ... readonly database`: no change needed.**
- All 15 occurrences in 7 days came from `su` inside `locate.service`, which is sandboxed (`ProtectSystem=strict`, only /var/cache/locate writable), so `/var/log/wtmp.db` (target of /var/lib/wtmpdb/wtmp.db) was read-only there.
- Normal su/sudo are unaffected. Disabling `locate.timer` removed the source. Confirm with tomorrow's Kali check.

**Zeek on victim01: installed but never running (read-only findings, nothing changed):**
- `/opt/zeek` is 8.2.2.
- No zeek process and no systemd unit.
- `/opt/zeek/etc/node.cfg` says `interface=eth0`, which does not exist. The interfaces are `ens33` (up, no IPv4) and `ens37` (<VICTIM_IP>/24).
- `/opt/zeek/logs` is root:zeek 2770.
- So `/opt/zeek/logs/current/conn.log` never exists, which is why the Wazuh agent logs "Could not open file".
- Fix options are in the report; they need root on victim01 and an interface choice.

**Zeek on victim01 FIXED (2026-10-01, owner chose ens37):**
- Scoped rule `claude-zeek` (draft in `sudoers/`): staged in sensor's home, installed by the owner, deleted by Claude afterwards.
- Changes (backups `*.bak-20261001-zeek` next to each file):
  - `/opt/zeek/etc/node.cfg`: active line `interface=eth0` → `interface=ens37` (commented examples untouched).
  - `/opt/zeek/etc/zeekctl.cfg`: `LogExpireInterval = 0` → `7day`, so archived logs no longer grow forever (disk 4.4 GB free).
  - `/opt/zeek/share/zeek/site/local.zeek`: appended `@load policy/tuning/json-logs.zeek`.
  - New `/etc/cron.d/zeek` (root 644): `@reboot zeekctl start` + `*/5 * * * * zeekctl cron`.
  - Wazuh `ossec.conf`: **unchanged**. conn.log was already `log_format json`. The `<localfile>` appears twice (logcollector warns "duplicated" and reads it once).
- Validation:
  - `zeekctl check` → "zeek scripts are ok"; `deploy` → zeek standalone running (PID 8548).
  - `logs/current/conn.log` is JSON and captured Kali→victim01 traffic on 22/80.
  - After an agent restart: "Analyzing file: '/opt/zeek/logs/current/conn.log'".
- Warnings: zeekctl's optional Python `websockets` module is missing, so only `zeekctl print/netstats` are disabled.
- **Zeek events reach the manager but there are no Zeek rules, so they are not alerts or cases** (no n8n/OpenAI load). Add a level-3 rule like Mac DNS 100300 to make them searchable as alerts.
- Pending on victim01: `sudo systemctl daemon-reload` (the wazuh-agent unit changed on disk).

**Zeek level-3 rule 100310 (2026-10-01): working.**
- **Manager** `local_rules.xml` (backup `local_rules.xml.bak-20261001-zeek`): group `soc_lab,zeek`, rule **100310 level 3**.
  - Matches `decoded_as json` + `uid` `^C\w+$` + `conn_state` `\w` (Zeek's own fields, not the file path).
  - Description: `Zeek conn: $(id_orig_h):$(id_orig_p) -> $(id_resp_h):$(id_resp_p) $(proto) $(conn_state)`.
  - Rule text: `wazuh/local_rules-zeek.xml`.
- **Root cause of "no alerts" (worth teaching):** Zeek's default dotted field names (`id.orig_h`) become `data.id.orig_h`, but the Wazuh alerts template maps `data.id` as **keyword**. The indexer silently rejected every Zeek alert, while logtest and the agent looked fine. Diagnosis path:
  1. logtest matched the rule
  2. the agent's logcollector state showed events shipped (no drops)
  3. other sensor alerts arrived
  4. the `data.id` mapping was keyword
- **Fix on victim01** `local.zeek` (backup `local.zeek.bak-20261001-scopesep`): `redef Log::default_scope_sep = "_";`, so fields are now `id_orig_h`, `id_orig_p`, `id_resp_h`, `id_resp_p`. `zeekctl check` ok; deployed (PID 13022).
- **Validated:**
  - 13+ alerts indexed from agent sensor, including Kali→victim01 22/80/443/8103.
  - **0 reached n8n** (level 3 < 5).
  - One 09:09:05 alert has a blank description: it arrived in the minute between the Zeek change and the rule update. Harmless.
- **Volume:** an early sample of about 11/min was inflated by a test burst and the post-restart NTP sync. Mostly NTP (123) and the agent's own 1514 link. If too noisy, add child rules at level 0 for `id_resp_p` 123/1514.
- **Temporary sudo rules all deleted:** claude-zeek, claude-zeeksep, claude-zeekdiag (victim01) and claude-zeekrule (manager). Only `claude-n8ndebug` remains on the manager, for tonight's exit-7 debug.

**Zeek NTP silenced (2026-10-01):**
- Manager rule **100311 level 0**, `if_sid 100310` + `proto ^udp$` + `id_resp_p ^123$` (text: `wazuh/local_rules-zeek-ntp.xml`). Backup: `local_rules.xml.bak-20261001-ntp`.
- logtest: a real NTP record gives 100311 L0; a Kali SSH record still gives 100310 L3. `analysisd -t` passed; manager restarted; 4 agents Active.
- Index check: NTP 100310 alerts were 49 in the ~12 min before the restart and **0** in ~4 min after. Non-NTP Zeek alerts kept arriving (9 after, including Kali's 09:20 tests).
- NTP is still recorded in Zeek's own conn.log on victim01.
- Sudo rule `claude-zeekntp` deleted.

**victim01 daemon-reload: DONE later the same morning** (owner installed `claude-reload`; `daemon-reload` run, `NeedDaemonReload` yes→no, wazuh-agentd and zeek still running, rule deleted). Earlier note, kept for history: The staged rule `~/claude-reload` was not installed (only README in /etc/sudoers.d), so `NeedDaemonReload=yes` remains. The owner needs to rerun the install command, or simply `sudo systemctl daemon-reload` on victim01.

**Temporary n8n workflows removed (2026-10-01):** the owner deleted "TMP claude list open cases…" and "TMP claude bulk-close snapshot…". Verified read-only: n8n lists only "My workflow" (active); both TMP webhook paths return 404.

---

## 2026-10-02 03:43 UTC: exit-7 debug follow-up BLOCKED (Mac asleep, lab unreachable)

- The scheduled follow-up (`f3c9aa6b`) fired, but every lab VM was unreachable from the Mac:
  - `No route to host`; ARP incomplete for <WAZUH_IP>/<SERVICES_IP>/<ATTACKER_IP>; <OPNSENSE_LAN_IP>/<VICTIM_IP> and <OPNSENSE_WAN_IP> don't answer ping.
  - VMware reports 5 VMs running, and Kali's VMware Tools still report "running" (cached IP).
- Cause: macOS went to sleep at 02:31 local (01:31 UTC, "Idle Sleep") and was only in a maintenance dark-wake when the job ran. A sleeping host freezes the guests. The 03:27 UTC burst most likely never happened, so **no exit-7 data was captured**.
- **Nothing was changed.** Still in place on the manager:
  - `integrator.debug=2` (backup `local_internal_options.conf.bak-20261001`)
  - sudo rule `/etc/sudoers.d/claude-n8ndebug`
- To finish once the Mac is awake and the lab answers:
  1. Either keep debug on through one more 03:27 UTC burst (keep the Mac awake, e.g. `caffeinate -s`), or skip the investigation.
  2. Revert: `sudo cp -p /var/ossec/etc/local_internal_options.conf.bak-20261001 /var/ossec/etc/local_internal_options.conf && sudo systemctl restart wazuh-manager`.
  3. `sudo rm /etc/sudoers.d/claude-n8ndebug`.
- Lab note: the Mac sleeping overnight pauses all detection (VMs frozen). For unattended runs, prevent idle sleep while the lab is in use.

**2026-10-02 04:23 UTC: Kali 40101 follow-up (`0c8de17c`) also BLOCKED.** The lab is still unreachable (Mac in idle/dark-wake sleep since 02:31 local), so the read-only query `wazuh/check-kali-40101.sh` could not run. Nothing was changed. Run it on request once the lab is awake. If Kali was frozen at its own 00:00 too, tonight's result is inconclusive and the next clean night is the real test.
