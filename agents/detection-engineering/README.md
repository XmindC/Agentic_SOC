# Detection-engineering agent

[prompt.md](prompt.md) is the system prompt. Give it a described threat, a missed detection or a set of events, and it returns one advisory JSON rule proposal (Suricata, Wazuh or both) with logic, an example rule, false-positive risk, tuning notes and a validation plan.

Not wired into n8n yet. Use it from any chat interface or API call with the prompt as the system message. A person tests every proposal (`wazuh-logtest`, `suricata -T`, a controlled nmap or login test) and enables it by hand.
