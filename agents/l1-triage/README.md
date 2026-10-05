# L1 triage agent

Runs inside n8n (AI Agent node + OpenAI Chat Model, gpt-4o-mini, temperature 0.2, Responses API off, no tools).

| File | What |
|---|---|
| `system-prompt.txt` | The system message, exported from the live workflow |
| `user-prompt.n8n-expression.txt` | The n8n expression that builds the per-alert message (agent, rule, groups, addresses, user, file, signature, enrichment) |

The JSON it returns is parsed by [configs/n8n/code-nodes/parse-verdict.js](../../configs/n8n/code-nodes/parse-verdict.js), which falls back to "manual triage required" on bad output. To change the prompt, edit it in n8n, then export the workflow and update both files here.
