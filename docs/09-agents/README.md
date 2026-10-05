# Agents

## The pattern every agent follows

```
gather facts -> agent advises (returns JSON text) -> parse safely (fallback on bad output)
             -> post to the case -> a human decides
```

- The agent has no tools, no credentials and no network access of its own. It receives facts and returns text.
- n8n, not the agent, makes every call to TheHive, Cortex or email.
- Bad output never breaks the run: parsing falls back to a fixed "manual triage required" object.
- Proposals are written as proposals, never as completed actions.
- The prompt states the lab context (<LAB_LAN_CIDR> protected, <LAB_INFRA_CIDR> lab infrastructure with an authorised Kali) so the model weighs benign explanations first.

Authority is split four ways: the workflow acts, the case system stores, the agent advises, the human decides. A fully compromised model still cannot act, because nothing downstream accepts an instruction from it.

## The agents

| Agent | State | Model | Where |
|---|---|---|---|
| L1 triage | Live in the n8n pipeline | gpt-4o-mini, temperature 0.2 | [agents/l1-triage](../../agents/l1-triage/) |
| L2 investigation | Works standalone from the command line | gpt-4o-mini, JSON mode | [agents/l2-investigation](../../agents/l2-investigation/) |
| Detection engineering | Prompt written, not wired | any | [agents/detection-engineering](../../agents/detection-engineering/) |

### L1 triage

Runs once per alert after enrichment. Returns `verdict` (true_positive, false_positive, needs_investigation), `confidence`, `severity`, `alert_class`, `summary`, `reasoning` (including the benign explanation it considered), `escalate` and two to four read-only `recommended_next_steps`. The verdict lands on the case as a comment.

The build story, including the move from GitHub Models to OpenAI and the cold-start recovery, is in [l1-triage-agent-build.md](l1-triage-agent-build.md).

### L2 investigation

For alerts the L1 agent escalates. Builds a timeline from the timestamps it is given (labelled established or inferred), a root-cause hypothesis and the best competing one, scope, indicators, and containment proposals, each marked reversible or not with its collateral risk and urgency. It ends with one yes/no question for the analyst.

```bash
export OPENAI_API_KEY=...        # or fill it in .env
python3 agents/l2-investigation/agent_l2_investigation.py --input tests/fixtures/sample-escalated-alert.json
```

It prints the investigation and stops. `--case-id` only prints a notice; the script never posts or acts. The original build brief is in [l2-agent-build-brief.md](l2-agent-build-brief.md) (it predates the move from `config/config-secrets.env` to `.env`).

### Detection engineering

Given a described threat, a missed detection or an alert pattern, it proposes a Suricata or Wazuh rule: the logic, an example rule, why it works, false-positive risk, tuning notes and a validation plan. Output is marked `advisory` and `human_approval_required: true`. A person tests the rule with `wazuh-logtest` or `suricata -T` and enables it.

## Adding a new agent

1. Write the system prompt with the same limits: no tools, proposals only, JSON with fixed keys, a safe fallback.
2. Wire it into n8n after the facts it needs exist, with a Code node that parses its output in try/catch.
3. Post the result to the case as a comment. Never let it change case status, assignee or anything outside TheHive.
4. Test it against a real alert and against garbage input.
5. Document it here and in `agents/<name>/README.md`.
