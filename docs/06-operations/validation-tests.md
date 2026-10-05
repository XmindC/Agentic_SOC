# Validation tests

Run after any change to rules, the workflow or the services. Every test uses Kali against victim01 only, with settings that cannot succeed or harm anything.

## 1. Low severity: port scan, no email

```bash
sudo nmap -sS -p8443 <VICTIM_IP>          # change the port each run
```

Expected:
- One case (or two: the scan crosses em0 and em1) titled `[suricata] ET SCAN ... (<ATTACKER_IP> -> <VICTIM_IP>)`.
- Two observables, AbuseIPDB and VirusTotal results in the comment, an L1 verdict rated low or medium.
- In n8n the `Escalate?` node goes false. No email.

## 2. High severity: SSH brute force, email

A short list of wrong passwords, so no login can succeed:

```bash
printf 'x1\nx2\nx3\nx4\nx5\nx6\nx7\nx8\nx9\nx10\nx11\nx12\n' > /tmp/wrong.txt
hydra -l root -P /tmp/wrong.txt -t 4 -I ssh://<VICTIM_IP>
```

Expected:
- Wazuh 5710/5712/5763 alerts (level 10 and above, group `authentication_failures`), cases `[sensor] sshd: brute force ...`.
- Suricata may add `ET SCAN LibSSH Based Frequent SSH Connections Likely BruteForce Attack` (severity 1).
- Exactly two emails per brute-force run in the reference lab: one for the Suricata severity-1 alert, one for the Wazuh 5763 rollup. HTML with a working case link.

The L1 agent knows <ATTACKER_IP> is the authorised test machine and may rate the activity low. That is correct behaviour. Do not weaken the prompt to force an email; the rule-based conditions send it.

## 3. Email path without an attack

In n8n, open a past execution > Debug in editor, pin Parse Verdict output with `"severity": "high"` and a Normalize output with `rule_level` 10, execute. One email. Repeat with `"severity": "low"`: none. Unpin afterwards.

## 4. Host alert with no IP

Change a watched persistence path on Kali (`sudo touch /etc/cron.d/soc-test` then remove it after the scan). After the next scheduled file-integrity scan:
- A case `[kali] File added to the system` with no observables, enrichment "No IP observables on this alert", and an L1 comment.

## 5. Below-threshold sources stay out of n8n

```bash
nslookup soc-e2e-$(date +%H%M%S).example.com     # on the Mac
curl -s http://<VICTIM_IP> >/dev/null             # from Kali (Zeek)
```

Both appear in the Wazuh dashboard (rules 100300 and 100310, level 3). Neither creates an n8n execution.

## 6. The gate is intact

- Every new case in TheHive is New and unassigned.
- OPNsense: no new firewall rules or aliases, IPS mode off.
- Wazuh: `sudo grep -c . /var/ossec/logs/active-responses.log` unchanged.
- n8n: the only outbound actions are create case, unassign, observables, Cortex lookups, comment and email.
- The AI Agent node has no tools attached.
