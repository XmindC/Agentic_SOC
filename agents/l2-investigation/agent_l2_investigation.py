#!/usr/bin/env python3
"""agent_l2_investigation.py — SOC Level 2 investigation agent.
Reads an escalated alert, returns a written investigation + containment PROPOSAL.
Takes no action. A human approves everything.
"""

import argparse
import json
import re
import os
import sys
import urllib.request
from pathlib import Path

L2_SYSTEM_PROMPT = """
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
"""


def env_value(name):
    """Return a setting from the environment, or from the repo's .env (git-ignored).
    Unset values and unfilled <PLACEHOLDERS> count as missing."""
    value = os.environ.get(name, "").strip()
    if value and not value.startswith("<"):
        return value
    env_path = Path(__file__).resolve().parents[2] / ".env"
    if env_path.exists():
        for line in env_path.read_text(encoding="utf-8").splitlines():
            if line.startswith(name + "="):
                value = line.split("=", 1)[1].split("#", 1)[0].strip()
                if value and not value.startswith("<"):
                    return value
    return None


def load_key():
    """The OpenAI key. Never printed, logged or passed on a command line."""
    key = env_value("OPENAI_API_KEY")
    if not key:
        raise SystemExit("OPENAI_API_KEY is not set. Export it, or fill it in .env (copied from .env.example).")
    return key


def fill_placeholders(text):
    """Replace <LAB_LAN_CIDR>-style placeholders with values from the environment or .env.
    The repository holds no lab addresses; they are supplied at run time."""
    def sub(match):
        return env_value(match.group(1)) or match.group(0)
    return re.sub(r"<([A-Z][A-Z0-9_]*)>", sub, text)


def call_model(system_prompt, user_message, api_key):
    """Call the OpenAI Chat Completions API and return the JSON content."""
    body = json.dumps(
        {
            "model": "gpt-4o-mini",
            "temperature": 0.2,
            "response_format": {"type": "json_object"},
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_message},
            ],
        }
    ).encode("utf-8")

    request = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )

    with urllib.request.urlopen(request, timeout=60) as response:
        data = json.load(response)

    return data["choices"][0]["message"]["content"]


def safe_parse(raw_output):
    """Parse model output safely. If parsing fails, return a conservative fallback."""
    try:
        return json.loads(raw_output)
    except Exception:
        return {
            "assessment": "The agent output could not be parsed. Manual investigation required.",
            "confidence": "low",
            "timeline": [],
            "root_cause_hypothesis": "Evidence is insufficient to support a root cause hypothesis.",
            "alternative_hypothesis": "The evidence is incomplete or noisy; a manual review is required.",
            "scope": {
                "hosts_involved": [],
                "accounts_involved": [],
                "spread_assessment": "Unknown; insufficient evidence for scope assessment.",
            },
            "indicators": [],
            "containment_proposals": [
                {
                    "action": "no_action",
                    "target": "manual_review_required",
                    "rationale": "Agent output unreadable; escalate to a human for manual investigation.",
                    "reversible": True,
                    "collateral_risk": "None for the agent itself; risk is a delayed analyst decision.",
                    "urgency": "soon",
                }
            ],
            "if_no_action_taken": "The alert remains unresolved and may continue to escalate without a human triage decision.",
            "analyst_decision_required": "Investigate this alert manually?",
        }


def build_user_message(payload):
    """Create the user prompt for the L2 model call."""
    return "Investigate this escalated alert.\n\n" + json.dumps(payload, indent=2)


def print_case_comment_notice(case_id):
    """Print a human-readable notice acknowledging optional case posting without acting."""
    print(
        f"[dry-run] --case-id '{case_id}' received. The agent would print the investigation first, "
        "then optionally post a comment to the case, but this script does not perform any live action."
    )


def main():
    parser = argparse.ArgumentParser(
        description="Level 2 SOC investigation agent. Advisory only; no live action if used."
    )
    parser.add_argument("--input", help="Path to a JSON alert file; omit to read from stdin")
    parser.add_argument(
        "--case-id",
        help="Optional TheHive case ID. This script prints the result first and never performs a live action.",
    )
    args = parser.parse_args()

    if args.input:
        input_path = Path(args.input)
        if not input_path.exists():
            raise SystemExit(f"Input file not found: {args.input}")
        raw_input = input_path.read_text(encoding="utf-8")
    else:
        raw_input = sys.stdin.read()

    if not raw_input.strip():
        raise SystemExit("No input provided. Pass --input or pipe JSON to stdin.")

    try:
        payload = json.loads(raw_input)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Input is not valid JSON: {exc}") from exc

    api_key = load_key()
    system_prompt = fill_placeholders(L2_SYSTEM_PROMPT)
    if re.search(r"<LAB_(LAN|INFRA)_CIDR>", system_prompt):
        raise SystemExit("Set LAB_LAN_CIDR and LAB_INFRA_CIDR (environment or .env); the prompt needs the lab subnets.")
    user_message = fill_placeholders(build_user_message(payload))
    result_raw = call_model(system_prompt, user_message, api_key)
    result = safe_parse(result_raw)

    print(json.dumps(result, indent=2))

    if args.case_id:
        print_case_comment_notice(args.case_id)


if __name__ == "__main__":
    main()
