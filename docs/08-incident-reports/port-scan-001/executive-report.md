> Source: `report-exec-port-scan-001-20260927.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

# Executive Incident Report

Case ID: port-scan-001  
Date: 2026-09-27

## 1. Executive summary

The investigation found a single source device repeatedly testing a lab host for exposed services and attempting password-based access. The activity targeted a single internal system, <VICTIM_IP>, and the evidence indicates reconnaissance and attempted access rather than a confirmed compromise. The available evidence does not show successful access to data or ongoing unauthorized activity, and the investigation is contained to the observed lab environment; no customer or regulatory exposure was identified. The key decision is whether to approve a targeted containment step on the affected host and restrict the source network before any further scanning or access attempts continue.

## 2. What happened

A single source system, <ATTACKER_IP>, was observed repeatedly testing the internal host <VICTIM_IP>. The evidence shows service probing on ports 22, 80, 443, and 445, followed by failed password attempts against SSH on port 22. This pattern is consistent with an attacker checking which services were exposed and then trying basic access methods before deciding whether to continue.

The investigation also found that the scan was short and fast, and the initial detection was not obvious in the lab logs because the relevant alerts were filtered to a narrower view. The source activity aligns with a reconnaissance sequence from a known lab attacker host, and the available evidence does not show a successful login or data theft. The lab notes confirm that a scan from Kali to the internal host was run and that the host had SSH enabled, which is consistent with the observed failed access attempts.

## 3. Business impact

- Data impact: none identified in the available evidence. There is no evidence of successful authentication, data access, or data theft from the host in the investigated logs.
- System impact: the host <VICTIM_IP> was probed for open services and was the subject of failed SSH access attempts. No evidence was identified of a successful takeover or service disruption.
- Operational impact: no sustained service outage or business interruption was identified. The activity was limited to reconnaissance and failed login attempts against one host.
- Regulatory or customer exposure: none identified in the lab scenario. No customer data, production systems, or external exposure were present in the evidence reviewed.

## 4. Response actions taken and pending human approval

The following actions were taken in the investigation process, consistent with the lab’s human approval model:

- The alert was triaged and escalated for investigation after repeated failed access activity and reconnaissance pattern matching.
- The source and destination addresses were validated against the lab evidence, including the observed source IP, destination host, and the recorded failed password events.
- The investigation reviewed the relevant host and network evidence, including port scan behavior and failed SSH access attempts, to establish the likely scope and containment options.
- No live containment action was taken automatically without human approval. The system is designed to pause for a decision before any state-changing response.

Pending approval, the next decision is whether to block or restrict the source host and to isolate the affected server from further scanning or access attempts. This matters because the observed behavior shows the source is still active in the lab environment and could continue to probe if not contained.

## 5. Risk if no action is taken

If no action is taken, the main risk is that the source continues reconnaissance against the affected host and may escalate from low-level probing to a more direct access attempt. The evidence in this case is limited to scanning and failed logins, but the lab environment shows that the same path can be used for further intrusion attempts if the host remains exposed.

The more immediate risk is operational rather than material: continued probing can create noise, increase security exposure, and make the host more vulnerable if a weak service or credential is left exposed. In this specific investigation, the evidence does not show that the host was successfully compromised, but the risk increases if the source continues without a targeted block or restricted access rule.

## 6. Recommendations

1. Approve a targeted block on the source and restrict network access to the affected host.  
   Business rationale: this is the most direct way to reduce the risk of continued probing or follow-on access attempts while preserving normal operations for the rest of the environment.  
   Rough effort: low; expected to take less than 1 business day.

2. Review the exposed service state on <VICTIM_IP>, especially SSH and any other internet-facing access points.  
   Business rationale: the evidence shows the host was probed and then targeted with failed SSH attempts. Removing unnecessary exposure is the most effective and least disruptive control.  
   Rough effort: low to medium; 1 to 2 days depending on service validation.

3. Validate detection and alerting rules so short, fast, low-noise reconnaissance is not missed in future.  
   Business rationale: this reduces the chance that a similar event is hidden by filtering or low-severity settings, which increases the likelihood of timely detection and investigation.  
   Rough effort: medium; likely 2 to 5 days depending on rule tuning and testing.

4. Confirm whether any additional internal systems were tested from the same source.  
   Business rationale: the current evidence is limited to one destination host, but the reconnaissance pattern suggests the source may have tested other systems if not interrupted.  
   Rough effort: low; 1 day for focused review.

## 7. Appendix: technical summary

Evidence reviewed: laboratory alert and host/network investigation indicate a source IP of <ATTACKER_IP> targeting <VICTIM_IP>; the source was observed scanning ports 22, 80, 443, and 445; SSH failed password events were recorded for invalid user names root and admin from the same source; the lab notes confirm a Kali-hosted reconnaissance scan using a fast SYN scan against the victim host. The investigation did not identify successful authentication, file access, or data theft. Affected hosts: <VICTIM_IP>. Relevant ATT&CK techniques: Reconnaissance (active scanning), Credential Access (brute-force or password guessing), and Initial Access attempt (network service probing against an exposed SSH service). Indicators: source IP <ATTACKER_IP>; destination IP <VICTIM_IP>; destination ports 22, 80, 443, and 445; repeated failed SSH attempts; short-duration SYN scan behavior.

---

This report is written for executive decision-making. It is based on the investigation evidence available in the lab. It does not claim broader exposure than the evidence supports, and it does not suggest that any live response action was taken without explicit human approval.
