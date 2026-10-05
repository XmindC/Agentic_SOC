# Incident reports

Reports produced from lab cases, as a model for students. Each report is paired with a fact check that compares every claim with the evidence in the case.

| Case | Date | Summary | Files |
|---|---|---|---|
| port-scan-001 | 27 Sep 2026 | SYN scan and failed SSH logins from the authorised Kali machine against victim01. Detected by Suricata and Wazuh; no compromise. | [executive report](port-scan-001/executive-report.md), [fact check](port-scan-001/fact-check.md) |

## Writing a new one

1. Start from the TheHive case: alerts, observables, the L1 comment and any analyst notes.
2. Executive report: what happened, impact, what was done, recommendations. No jargon a manager would have to look up.
3. Fact check: list each claim, the evidence for it (case, alert ID, log line) and whether it holds. List the known unknowns.
4. Lab data only. Never put details from a real employer's or client's incident in this repository.
