# n8n pipeline and the L1 agent

Machine: services01. Installer role: `workflow`.

## 1. Import the workflow

```bash
sudo ./install.sh workflow
```

This imports [configs/n8n/wazuh-alert-pipeline.workflow.json](../../configs/n8n/wazuh-alert-pipeline.workflow.json) with `SERVICES_IP` and `ALERT_EMAIL` filled in. It arrives inactive and without credentials.

Manual alternative: in n8n, Workflows > Import from file, choose the JSON, then replace `<SERVICES_IP>` and `<ALERT_EMAIL>` in the Format Email and Send Email nodes.

## 2. Create the credentials

n8n > Credentials > New. Type every key into the form yourself. Never into a node field, a file or a chat.

| Credential (name exactly) | Type | Value | Used by |
|---|---|---|---|
| The Hive 5 account | TheHive 5 API | URL `http://thehive:9000`, API key of TheHive `n8n` user | Create an observable, Unassign Case, HTTP Request1 |
| TheHive Authorization header | Header Auth | Name `Authorization`, value `Bearer <THEHIVE_API_KEY>` | HTTP Request (create case) |
| Cortex account | Cortex API | URL `http://cortex:9001`, API key of the Cortex `n8n` user | Execute an analyzer, Get Cortex Report |
| OpenAI account | OpenAI | Your OpenAI API key | OpenAI Chat Model |
| SMTP account | SMTP | `smtp.gmail.com`, port 465, SSL on, Gmail address, Gmail App Password | Send Email |

Containers reach each other by service name (`thehive:9000`, `cortex:9001`), never by IP or localhost.

Open each node with a red warning and select its credential. Then check two settings that are easy to lose:

- OpenAI Chat Model: model `gpt-4o-mini`, temperature 0.2, **Use Responses API off**.
- Any field holding `{{ }}` must be in Expression mode (the fx marker). In Fixed mode n8n sends the braces literally and TheHive answers 403.

## 3. Activate

Toggle the workflow Active. The production webhook is now `http://<SERVICES_IP>:5678/webhook/wazuh-alert`, which is where the Wazuh integration already points.

## 4. Check

From Kali, `sudo nmap -sS -p<NEW_PORT> <VICTIM_IP>`. Within about a minute:

- n8n Executions shows a successful run.
- TheHive has a case `[suricata] ET SCAN ... (<ATTACKER_IP> -> <VICTIM_IP>)`, status New, no assignee, two observables, and an L1 comment with verdict, confidence, severity and next steps.
- No email (a single scan rates low or medium). The email path is tested in [validation-tests.md](../06-operations/validation-tests.md).

The full build story of the L1 agent, including why the hand-built HTTP request was replaced by the AI Agent node, is in [../09-agents/l1-triage-agent-build.md](../09-agents/l1-triage-agent-build.md).
