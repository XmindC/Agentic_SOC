# Plan

## Goal

Build a self-hosted SOC and incident response lab on one Mac, using free and open-source tools, with AI agents that do Level 1 and Level 2 analyst work while a human approves every action. The lab is used to teach enterprise SOC workflows: students attack it, watch the detections, read the agent's reasoning and decide what to do.

Level 1 is triage and enrichment. Is the alert real or noise, what kind is it, how bad, what do the reputation services say, does it need escalating.

Level 2 is investigation and response. Connect the alert to others, build a timeline, find the likely cause, pull out the indicators, and propose containment for a person to approve.

## Build order

Each piece had to work before the next depended on it. Three stacked faults that each produced the same silence cost a full session early on (see [the troubleshooting case](../07-troubleshooting/cases/suricata-silent-scan-three-faults.md)), so services are brought up one at a time.

| Phase | What | State |
|---|---|---|
| 1 | Host, VMware networks (NAT <LAB_INFRA_CIDR>, vmnet2 <LAB_LAN_CIDR>), base VM to clone | Done |
| 2 | Wazuh server and agents on Kali, the Mac and victim01 | Done |
| 3 | OPNsense firewall with Suricata IDS on LAN and WAN, alerts to Wazuh by syslog | Done |
| 4 | services01: Docker with n8n, TheHive 5.2, Cortex 4.1 | Done |
| 5 | Wazuh alerts to n8n, n8n opens TheHive cases | Done |
| 6 | Enrichment: AbuseIPDB and VirusTotal through Cortex | Done |
| 7 | L1 agent (gpt-4o-mini) writes a verdict on every case, read-only | Done |
| 8 | Escalation email for high-severity cases | Done |
| 9 | Full-fleet ingestion, Mac DNS visibility, persistence FIM, Zeek | Done (1 Oct 2026) |
| 10 | Detection-engineering agent (proposes rules, human enables) | Prompt written, not wired |
| 11 | L2 investigation agent wired into the workflow on escalation | Script works standalone, not wired |
| 12 | One approval-gated response action: block an address at OPNsense | Not started |
| 13 | Validation with simulated attacks, false-positive tuning | Ongoing |

The first milestone was phases 1 to 7 with the agent in read-only mode for a couple of weeks, to judge how far a cheap model can be trusted on real alerts before it is allowed to propose anything.

## Roadmap

1. **Detection-engineering agent.** Given a described threat or a missed detection, it proposes a Suricata or Wazuh rule with its logic, false-positive risk and a test plan. A person reviews and enables it. Prompt: [agents/detection-engineering/prompt.md](../../agents/detection-engineering/prompt.md).
2. **L2 in the pipeline.** When the L1 verdict escalates, run [the L2 agent](../../agents/l2-investigation/) and post its timeline and containment proposals to the case.
3. **The approval gate, made real.** A single reversible action (an OPNsense alias that blocks one address) that n8n runs only after a person approves it in TheHive. Everything is logged: who approved what and when.
4. **Network segmentation exercise.** services01 sits on the same flat segment as Kali. In production, SOC tooling belongs on its own management segment, firewalled from both the monitored network and any offensive tooling. Moving it is a planned exercise, not an oversight.
5. **Always-on option.** The lab pauses when the Mac sleeps (the VMs freeze). Either keep the Mac awake during lab hours (`caffeinate -s`) or move the services host to hosted infrastructure.

## Changes from the original design

The original design is kept in [original-design.md](original-design.md). What changed while building:

| Original | Now | Why |
|---|---|---|
| Copilot free tier as the agent model | OpenAI gpt-4o-mini via the n8n AI Agent node | GitHub Models was retired on 30 July 2026 |
| Separate network sensor VM in promiscuous mode | Suricata on OPNsense | The VMware Fusion virtual switch does not deliver other VMs' unicast traffic to a promiscuous VM |
| MISP and Authentik on the services host | Not deployed yet | Cortex with AbuseIPDB and VirusTotal covered enrichment; Authentik waits for the account-disable use case |
| Zeek deferred | Zeek on victim01 | Added once CPU headroom allowed; level-3 rule keeps it out of the case pipeline |
