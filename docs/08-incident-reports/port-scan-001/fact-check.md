> Source: `fact-check-port-scan-001-20260927.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

# Fact Check: Executive Report Alignment

Case reviewed: port-scan-001  
Review date: 2026-09-27

## Scope
This review checks whether the leadership report matches the available investigation evidence and the case materials. The purpose is to confirm claims, remove unsupported statements, and document what remains uncertain.

## Verified facts

- The source IP is <ATTACKER_IP>. This is confirmed in the sample alert and lab reference.
- The destination host is <VICTIM_IP>. This is confirmed in the sample alert, lab reference, and network notes.
- The notification and enrichment describe reconnaissance and failed SSH access attempts from the same source IP.
- The observed services/probes include port 22 and additional service checks on 80, 443, and 445, as recorded in the sample alert and lab notes.
- The failed access events include the text: "Failed password for invalid user root from <ATTACKER_IP> port 22" and "Failed password for invalid user admin from <ATTACKER_IP> port 22".
- The lab notes state that a fast SYN scan was run from Kali to <VICTIM_IP> and that the scan completed in under a second.
- The lab notes also state that the host had SSH enabled and that the detection was not obvious because the alert view was restricted to narrower severity levels.
- The evidence reviewed does not show a confirmed successful login to the host.
- The evidence reviewed does not show data exfiltration, data theft, or a confirmed compromise.

## Report alignment check

### Executive summary
Aligned with evidence. The wording says the activity was reconnaissance and attempted access, not a confirmed compromise. This matches the file evidence.

### What happened
Aligned with evidence. It reflects a source-host port scan and failed SSH access attempts against <VICTIM_IP>.

### Business impact
Aligned with evidence. It correctly states that no confirmed data loss or successful compromise was identified in the evidence reviewed. The phrase "none identified" is appropriate given the sample data and lab environment.

### Response actions taken and pending approval
Aligned with the lab design. The report correctly says no live containment action was taken without human approval. The current workflow model requires approval before state-changing actions.

### Risk if no action is taken
Reasonable but conservative. The evidence supports continued scanning or follow-on attempts as a risk, but not a confirmed ongoing compromise. The wording is appropriately framed as risk rather than proven impact.

### Recommendations
Aligned with evidence and with the human approval model. The first recommendation is a targeted block or restriction, which is consistent with the containment logic for a reconnaissance and failed access sequence.

### Appendix: technical summary
Aligned with evidence. It lists the relevant host, source IP, ports, and ATT&CK-style categories in a concise way. It does not claim beyond the available evidence.

## Known unknowns

- No evidence in the sample materials shows whether other internal hosts were scanned beyond <VICTIM_IP>.
- No evidence shows whether the source attempted additional tactics after the failed SSH access attempts.
- No direct proof exists that the attacker intended to compromise the host, because the investigation did not show successful access.
- The lab notes say the exact reason the scan did not trigger a more obvious alert is still being confirmed; therefore, the detection gap is a known uncertainty.

## Conclusion
The executive report is substantively aligned with the investigation evidence. It is not overstating impact, and it stays within the bounds of what is known. The single most important correction is to preserve the distinction between "suspected follow-on risk" and "confirmed compromise"; the evidence supports the former, not the latter.
