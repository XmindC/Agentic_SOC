# Building the SOC Level 2 Agent in Copilot

Paste this to Copilot (or hand it to <ORG_NAME>) as the task. It produces **real, runnable Python**, not a prompt file. The L2 agent runs when Level 1 escalates: it builds a timeline, proposes a root cause, and drafts a containment proposal for a human to approve. It never acts.

---

## The task to give Copilot

> Write a real, runnable Python script named `agent-l2-investigation.py` in `agents/`. It is the Level 2 SOC investigation agent. It must not take any action. It only reads facts and returns a written proposal for a human to approve. Log the file in `logs/log-file-index.md`. The full L2 system prompt is at the bottom of this document; paste it into the script. There is no external file to find. Requirements below.

## What the script must do

1. Take input: an escalated alert (the L1 verdict, the original alert and any enrichment) as JSON, from a file path argument or stdin.
2. Call the model: send the L2 system prompt (in full at the bottom of this document) and the alert to the OpenAI API (`gpt-4o-mini`), reading the key from `config/config-secrets.env` (never hard-coded).
3. Get back a JSON investigation: assessment, timeline, root-cause hypothesis, alternative hypothesis, scope, indicators, containment proposals (each marked reversible + collateral risk), and the one question the human must answer.
4. Parse safely: wrap the JSON parse in try/except; on failure, return a fixed object that says "manual investigation required" so nothing breaks.
5. Output: print the structured result. Post it to a TheHive case as a comment only if a `--case-id` is given, and even then print first, post second, and never act on the environment.
6. Never block, isolate, disable, delete, or change any rule or setting. It has no credentials for those and must not be given any.

## Skeleton to build from

```python
#!/usr/bin/env python3
"""agent-l2-investigation.py: SOC Level 2 investigation agent.
Reads an escalated alert, returns a written investigation + containment PROPOSAL.
Takes no action. A human approves everything."""

import json, os, sys, argparse, urllib.request
from pathlib import Path

L2_SYSTEM_PROMPT = """<paste the full L2 SYSTEM PROMPT from the bottom of this document here>"""

def load_key():
    # read OPENAI key from config/config-secrets.env (KEY=value lines)
    env = Path(__file__).resolve().parent.parent / "config" / "config-secrets.env"
    for line in env.read_text().splitlines():
        if line.startswith("OPENAI_API_KEY="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("OPENAI_API_KEY not found in config/config-secrets.env")

def call_model(system, user, key):
    body = json.dumps({
        "model": "gpt-4o-mini",
        "temperature": 0.2,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    return data["choices"][0]["message"]["content"]

def safe_parse(raw):
    try:
        return json.loads(raw)
    except Exception:
        return {
            "assessment": "The agent output could not be parsed. Manual investigation required.",
            "confidence": "low",
            "containment_proposals": [{"action": "no_action",
                "rationale": "Agent output unreadable; escalate to a human."}],
            "analyst_decision_required": "Investigate this alert manually?",
        }

def build_user_message(payload):
    # payload = dict with l1 verdict, original alert, enrichment
    return "Investigate this escalated alert.\n\n" + json.dumps(payload, indent=2)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="path to JSON file; omit to read stdin")
    ap.add_argument("--case-id", help="TheHive case _id to post to (optional; prints first)")
    args = ap.parse_args()

    raw_in = Path(args.input).read_text() if args.input else sys.stdin.read()
    payload = json.loads(raw_in)

    key = load_key()
    result_raw = call_model(L2_SYSTEM_PROMPT, build_user_message(payload), key)
    result = safe_parse(result_raw)

    print(json.dumps(result, indent=2))   # human reads this first

    if args.case_id:
        # OPTIONAL: post as a case comment. This is advisory text only, never an action.
        # Fill in the TheHive comment POST here if wanted, using the key from secrets.
        pass

if __name__ == "__main__":
    main()
```

## After Copilot writes it

- Run it against a sample escalated alert: `python agents/agent-l2-investigation.py --input sample-alert.json`
- Confirm it prints a structured investigation with containment **proposals**, not actions.
- Confirm the key is read from `config/config-secrets.env`, never printed, never hard-coded.
- Log it: add `agents/agent-l2-investigation.py: Level 2 investigation agent (advisory only)` to `logs/log-file-index.md`.

## The guardrail to verify in the output

The containment section must be proposals a human approves, each with `reversible` and `collateral_risk`. If the script ever calls the firewall, Wazuh, or an account system directly, that is wrong: stop and remove it. L2 advises; n8n (with human approval) acts.

---

## THE L2 SYSTEM PROMPT (paste this into the script)

```
You are a Level 2 SOC analyst. You investigate escalated alerts and you propose containment. You never perform it.

Your role and its limits:
- You receive a Level 1 verdict, the original alert, and any enrichment data that was gathered.
- You have no tools, no credentials and no network access.
- Every containment measure you describe is a proposal awaiting human approval. Write them as proposals. Never write them as completed.
- If you are unsure whether an action is safe, say so and propose the cautious version.

How to reason:
- Build the timeline only from timestamps present in the input. Do not interpolate events you were not told about.
- Separate what is established from what is inferred. Label inference as inference.
- Reputation data is evidence, not proof. A clean reputation score does not clear an address, and a poor one does not convict it. Weigh it against the behaviour you observed.
- Consider the blast radius of each containment proposal. Blocking an address that turns out to be a monitoring system causes an outage. State that risk where it exists.
- Prefer reversible measures over irreversible ones, and narrow measures over broad ones.

Environment context:
- Small lab network. OPNsense firewall, Wazuh SIEM, Suricata sensor.
- <LAB_LAN_CIDR> is protected internal. <LAB_INFRA_CIDR> is flat lab infrastructure including an authorised Kali testing machine.
- Available response actions, all requiring human approval: block an address at the firewall, isolate a host via the Wazuh agent, disable a user account.

Output format:
Return one JSON object and nothing else. No markdown fences, no commentary. Use exactly these keys:
- assessment: a paragraph, what you believe happened and how confident you are, for a human who will decide.
- confidence: high | medium | low
- timeline: array of {time, event, basis} where basis is "established" or "inferred"
- root_cause_hypothesis: your best explanation, or plainly that the evidence does not support one.
- alternative_hypothesis: the most credible competing explanation and what would distinguish it.
- scope: {hosts_involved [], accounts_involved [], spread_assessment}
- indicators: array of {type, value, context}
- containment_proposals: array of {action (block_address|isolate_host|disable_account|no_action), target, rationale, reversible (true|false), collateral_risk, urgency (immediate|soon|routine)}
- if_no_action_taken: what is likely to happen if nothing is done.
- analyst_decision_required: the specific yes/no question the human must answer.

Rules for the fields:
- no_action is a legitimate proposal. Use it when containment would cause more harm than the threat.
- Never propose an action against an address in <LAB_INFRA_CIDR> without noting in collateral_risk that lab infrastructure lives there.
- analyst_decision_required must be answerable yes or no.
```
