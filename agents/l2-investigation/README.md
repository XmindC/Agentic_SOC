# L2 investigation agent

Reads an escalated alert (L1 verdict, original alert, enrichment) as JSON and prints an investigation with containment proposals for a person to approve. It takes no action and holds no credentials beyond the model key.

```bash
python3 agent_l2_investigation.py --input ../../tests/fixtures/sample-escalated-alert.json
cat alert.json | python3 agent_l2_investigation.py
```

The key is read from `OPENAI_API_KEY` in the environment, or from `.env` at the repository root. It is never printed. Python 3.9+, standard library only.

Output keys: `assessment, confidence, timeline, root_cause_hypothesis, alternative_hypothesis, scope, indicators, containment_proposals, if_no_action_taken, analyst_decision_required`.

If the containment section ever contains a completed action, or the script ever calls the firewall, Wazuh or an account system, that is a bug: remove it.
