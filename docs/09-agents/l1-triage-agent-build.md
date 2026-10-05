> Source: `soc_lab_10_agent.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

**SOC Agent Lab 10: The Agent**

*Building the Level 1 triage agent, and recovering the lab after a restart*

------------------------------------------------------------------------

Session dates 13 and 19 September 2026. Companion to continuation brief 5. *Prose avoids hyphens so it reads easily. Commands and web links must be typed exactly as shown, including any hyphens they contain.*

1\. What this note covers

Two things. First, how the Level 1 agent was built: the piece that reads an alert and writes an analyst verdict onto the case. Second, how to bring the lab back after the host has slept or restarted, because that caused an hour of false alarm and is worth writing down so it never does again.

By the end of the agent build, the lab does the whole job on its own: an attack is detected, a case is opened, the addresses are enriched, an AI agent triages the alert, and its verdict is posted to the case. Nothing acts. A human reads the verdict and decides. That last sentence is the entire point of the project.

2\. What the agent is, in plain terms

The agent is a small piece of reasoning dropped into the middle of the pipeline. Everything before it gathers facts. The agent reads those facts and writes an opinion. Everything after it is a human.

It is given two things: the alert (what happened, from where, to where) and the enrichment (what the reputation services said about the addresses). It returns a verdict in a fixed shape: is this real or noise, how bad, what kind, a plain summary, its reasoning, whether to escalate, and what a human should check next.

The agent holds no passwords and can reach nothing. It returns text. That is the whole of its power. It is explained further in section 8, because it is the most important design decision in the lab.

3\. Choosing where the reasoning runs

The original plan was to use GitHub Models, tied to the same account as GitHub Copilot. That plan is dead.

GitHub Models was retired on 30 July 2026. Its address still answers, but only with a misleading message about a "temporary brownout" and "scheduled retirement". It is not temporary and it is not coming back on a free tier. Do not spend time on it.

The lab now uses OpenAI instead, through the small model gpt-4o-mini, which is fast, cheap and more than capable of triage. Any provider with an OpenAI-compatible interface would work the same way.

One lesson from the build: rather than hand-building the web request to the model, use the workflow tool's own agent node. It handles the request shape, the reply parsing and the credential for you. The hand-built version kept failing on small formatting mistakes; the dedicated node does not.

4\. Building the agent, step by step

The agent is added to the end of the existing workflow, after the enrichment step. Five parts: connect the model, feed the agent the facts, give it its instructions, parse its answer, and post the answer to the case.

Step 1. Connect the model

Add an agent node to the workflow. Underneath it, attach a chat-model node and point it at the model provider with an API key. The key is stored once, in the workflow tool's own credential store, not typed into every node.

Step 2. Feed it the facts

Set the agent's prompt source to "define below" rather than waiting for a chat message, then build the user message from the alert and the enrichment the earlier nodes produced. Only the fields that matter are sent, to keep the request small.

Step 3. Give it its instructions

The system message is the Level 1 analyst brief. It tells the agent it never acts, to work only from the evidence, to say "unknown" rather than guess, to weigh reputation as evidence and not proof, and to return one JSON object in a fixed shape. The full text lives in the prompts document (document 9), which is the intellectual core of the project.

Step 4. See the first verdict

Run the whole chain against a scan. The agent reads the alert plus enrichment and returns a verdict. Given an nmap scan from the lab's own Kali machine, it correctly called it a false positive, high confidence, low severity, reconnaissance; it recognised the source as the authorised test machine, treated the safe reputation score as supporting evidence rather than proof, and chose not to escalate.

Step 5. Parse the answer

The agent returns its verdict as a block of JSON text. A small code node turns that text into clean fields and builds a readable note. It does this inside a safety net: if the agent ever returns something unparseable, the note becomes "manual triage required" and the case is still created. The pipeline never dies because the model had a bad moment.

Step 6. Post it to the case

The final node posts the note to the case as a comment, so an analyst reads it in the case tool rather than inside the workflow. The address uses the case's internal id.

5\. The result

The verdict now sits on the case, written as an analyst would write it. The case stays New and unassigned. Nothing has acted. A human reads it and decides.

6\. Recovering the lab after a restart

On the second session the lab appeared completely broken: no cases, the victim seemingly unreachable, no logs. After an hour of investigation the truth was that nothing was broken. The host had restarted, and the lab had not finished settling when it was first checked. By the time it was investigated it was already working.

**The lesson: after a restart, assume the lab is still settling before assuming it is broken. Wait, then verify each layer in order.**

The cold-start checklist

1.  Start every VM in the virtualisation tool: firewall, Wazuh, services host, victim, attacker.

2.  Wait about five minutes. The databases and agents reconnect slowly.

3.  Check the victim's agent reconnected.

```
sudo /var/ossec/bin/agent_control -l
```

The sensor agent (victim01) must show Active. If it shows Disconnected, on the victim:

```
sudo systemctl restart wazuh-agent
```

4.  Check the sensor is writing. On the firewall:

```
tail -1 /var/log/suricata/eve.json
```

A stale timestamp here usually means no fresh traffic has crossed the sensor yet, not that the sensor froze. Fire a scan and check again before restarting anything.

5.  Only now run a test scan and expect it to flow through to a case.

How the false alarm was diagnosed

The diagnosis worked from the bottom of the chain upward, which is the right habit when several things look broken at once. Each layer was checked before blaming the one above it.

| **Check** | **What it proved** |
|----|----|
| Containers up | All six services were running, so the services layer was fine. |
| Wazuh receiving | Live traffic was reaching Wazuh, so collection worked. |
| Webhook answers | The workflow endpoint returned a healthy code, so the workflow was listening. |
| Kali reaches victim | The attacker could reach the target, so the network route was up. |
| Suricata running | The sensor process was alive and its rules loaded. |
| eve.json current | A fresh scan produced a fresh alert, so nothing was frozen. |
| Workflow ran | New workflow runs matched the scans, so the pipeline was intact. |
| Cases created | New cases appeared, so the whole chain worked. |

Proof it was working all along

7\. Things that will catch you out

- Do not use GitHub Models. It was retired and its endpoint returns a misleading "temporary" message that is not temporary.

- Prefer the workflow tool's own agent node over a hand-built web request to the model. It handles formatting that the manual version keeps getting wrong.

- Turn off "Use Responses API" on the OpenAI model node; the standard chat path is what the agent node expects.

- A field with double braces needs the expression marker or the braces are sent as literal text. The toggle only shows on hover.

- Do not put a leading equals sign in a field that is already in expression mode. The tool adds it internally; a literal one makes the address start with "=" and fail. This bit the build twice.

- The model returns its verdict as a JSON string. Parse it inside a safety net so a bad reply degrades to "manual triage required" instead of breaking the run.

- A cold start looks exactly like total failure. Wait and verify before diagnosing.

- Watching a filtered live log shows nothing until a new matching line arrives. An empty result is not a frozen log.

- Machine clocks differ by timezone. The same event shows very different times on different machines; do not read this as events being hours apart.

8\. Why the agent cannot do harm

This is the point worth making out loud, because it is the strongest part of the design and it answers the obvious question: how do you stop the AI doing something dangerous.

Authority in the system is split four ways. The workflow tool acts. The case tool stores. The agent advises. The human decides.

The agent has no passwords and no tools. It can only return text, which the workflow writes onto a case as a comment. It cannot create, change, close or assign a case. It cannot reach the firewall or any machine. So the approval gate is not a rule the agent is trusted to follow; it is a fact of the wiring. Even a completely compromised model cannot act, because nothing downstream will accept an instruction from it. The least trustworthy component holds the least power.

The honest limitation to state alongside this: the reputation services are public, so against the lab's private addresses they can only ever say "safe". They prove the enrichment works, not real threat intelligence. In a real deployment the source would be a public address and the lookup would carry real weight.

9\. Command reference

List agents and their status (Wazuh server)

```
sudo /var/ossec/bin/agent_control -l
```

Restart the victim's agent (on victim01)

```
sudo systemctl restart wazuh-agent
sudo systemctl status wazuh-agent
```

Check the sensor is writing (on the firewall)

```
tail -1 /var/log/suricata/eve.json
```

Watch scan alerts live (on the firewall)

```
tail -f /var/log/suricata/eve.json | grep --line-buffered SCAN
```

Restart the sensor only if truly frozen (on the firewall)

```
configctl ids restart
```

Fire a test scan (on Kali)

```
sudo nmap -sS -T4 -p1-1000 <VICTIM_IP>
```

Check the services are all up (on the services host)

```
cd ~/soc-stack
docker compose ps
```

Test the workflow endpoint answers (on the services host)

```
curl -s -o /dev/null -w "%{http_code}\n" -X POST \
http://<SERVICES_IP>:5678/webhook/wazuh-alert \
-H "Content-Type: application/json" -d '{}'
```

Reset the workflow login if locked out (on the services host)

```
cd ~/soc-stack
docker compose exec n8n n8n user-management:reset
```

10\. What is left to build

- The Level 2 agent, which runs only when Level 1 decides to escalate: timeline, root cause, and a containment proposal for the human to approve. Its instructions are already written in document 9.

- One reversible response action, gated on human approval, so the approval gate has something real to hold back. Blocking an address at the firewall is the natural first one.

- An identity system, to add login events and the ability to disable an account as a third response action.

- Threat intelligence correlation and richer network logging remain deferred by choice.
