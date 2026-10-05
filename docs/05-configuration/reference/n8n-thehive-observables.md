> Source: `soc_lab_7_observables.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

**SOC Agent Lab**

Adding observables to automated cases

*Session notes, 12 September 2026*

Cases were arriving with the attacking address written in the description as prose. That is readable by a person and useless to software. This session turned those addresses into structured observables, which is what enrichment tools operate on. The work took far longer than it should have, and the reasons are recorded here because they are the kind of thing that repeats.

| **Before** | **After** |
|----|----|
| Attacking address as text in the case description | Two structured observables per case, typed as ip |
| Nothing downstream could act on it | Cortex analysers will have something to analyse |
| No correlation between cases | TheHive links the same address across cases |

The design

Why two API calls are needed

An observable belongs to a case, so the case must exist and have returned its identifier before an observable can be attached. There is no single request that does both. The sequence is create the case, take the id from the response, then use that id to attach each observable.

**This is the shape most automation takes once it stops being a single step.** A call that does something, then a call that uses the result. Each node in n8n is one request, so a task needing two requests needs two nodes.

Which observables are worth having

| **Field** | **Type** | **Why** |
|----|----|----|
| data.src_ip | ip | The attacker. Reputation lookups run against this |
| data.dest_ip | ip | The target. Lets you find every case touching that host |
| data.src_port | skipped | Ephemeral and different every scan, so it will never correlate |
| data.dest_port | skipped | TheHive has no port observable type, see below |

One node per observable, or a loop

Three separate nodes would have worked and would have been easier to read. A Code node building a list, feeding one request node, was chosen instead because adding a fourth observable later becomes one line in an array rather than a new node, a new connection and another credential selection.

**One consequence worth knowing.** The case creation node outputs one item and the Code node turns that into several. Anything added after the observable node will therefore run once per observable rather than once per alert. Not a problem today, but it matters when the Cortex phase is built on top.

*The workflow before the Code node was inserted. Webhook, Filter, case creation, then the observable node.*

The Code node

```
const alert = $('Webhook').first().json.body;
const caseId = $input.first().json._id;
const observables = [
{ dataType: 'ip', data: alert.data.src_ip, message: 'Source address' },
{ dataType: 'ip', data: alert.data.dest_ip, message: 'Target address' },
];
return observables
.filter(o => o.data)
.map(o => ({ json: { caseId, ...o } }));
```

What each part does

| **Line** | **Purpose** |
|----|----|
| \$('Webhook').first() | Reaches back to a named node. The case id comes from the previous node, but the alert fields are only in the original webhook payload |
| \$input.first().json.\_id | The case id returned by the node immediately before this one |
| .filter(o =\> o.data) | Drops any observable with a missing value, so an alert lacking a destination address does not produce an empty entry |
| .map(o =\> ({ json: ... })) | Wraps each entry in the shape n8n expects. This is what turns one input item into several output items |

*The Code node with mode set to Run Once for All Items, which is correct since it produces the list itself.*

------------------------------------------------------------------------

Four hours on one field

The observable request was first built with an HTTP Request node, matching the case creation node that already worked. It failed repeatedly, and the reasons were not what they appeared to be.

Error one, invalid URL

*The Code node works, producing 3 items from 1. The request node reports an invalid URL beginning with an equals sign.*

The URL had been entered with a leading equals sign, which n8n uses internally to mark an expression. Typed into a field that is in Fixed mode, that character is literal text and becomes part of the URL.

Error two, forbidden

Removing the equals sign produced a 403 instead. The obvious reading was a permissions problem, and a long detour followed: checking the service account permissions, testing the key by hand, checking for duplicate observables, and testing whether the tilde in the case id needed encoding.

```
curl -s -X POST \
-H "Authorization: Bearer <THEHIVE_API_KEY>" \
-H "Content-Type: application/json" \
-d '{"dataType":"ip","data":"<ATTACKER_IP>","message":"test",
"tlp":2,"ioc":false}' \
http://localhost:9000/api/v1/case/~4304/observable
201 Created
```

**Every test by hand succeeded.** Same endpoint, same key, same payload, same case. Only n8n failed. That should have prompted an earlier look at what n8n was actually sending rather than more theories about what it might be sending.

The log that settled it

```
cd ~/soc-stack
docker compose logs -f thehive
```

Running that while the workflow executed produced the answer in one line.

```
POST /api/v1/case/%7B%7B%20$json.caseId%20%7D%7D/observable
returned 403
```

**Decoded, that path reads /case/{{ \$json.caseId }}/observable.** The expression was reaching TheHive as literal text. n8n had never evaluated it. TheHive could not find a case with braces for a name and refused the request. The payload had been correct the whole time and the URL was nonsense.

Fixed against Expression

Every n8n field has two modes, and the control only appears when the mouse hovers over the field.

| **Mode** | **Behaviour** |
|----|----|
| Fixed | The value is literal text. Braces are characters, not code |
| Expression | Anything in double braces is evaluated before the request is sent |

*The URL field in Fixed mode. No fx marker on the left edge, and the braces are not highlighted.*

*The same field in Expression mode. The fx marker appears, the braces highlight, and the Fixed and Expression toggle is visible above the field.*

**The fx marker is the reliable check.** If a field contains double braces and has no fx marker, the braces will be sent as text. Comparing a field against another one known to be correct is the fastest way to spot it.

Error three, the leftover character

*The expression now evaluates, resolving to a real case id, but the equals sign typed earlier is still present and being treated as part of the URL.*

Two separate faults in the same field, fixed in the wrong order. The equals sign was needed when the field was in Fixed mode and became wrong once the mode changed.

------------------------------------------------------------------------

Switching to the dedicated node

n8n has a TheHive 5 node. It should have been the first choice and was not suggested early enough.

*The TheHive 5 node offers 48 actions grouped by resource. Searching for observable goes straight to the right operation.*

Why it is better here

- No URL to construct, so no Fixed against Expression question on the most error prone field

- It knows the API shape, so field names cannot be wrong

- The Data Type list is fetched from TheHive itself, which both prevents invalid values and proves the credential works

The trade off

You cannot see the request it builds. When something fails there is less to work with, and the node is pinned to whichever API version it targets. For a step that is failing in an unclear way, the HTTP Request node remains the better diagnostic tool even if the dedicated node is the better final answer.

Setting it up

The credential comes first, because the Data Type field stays empty until it exists.

| **Field**          | **Value**                       |
|--------------------|---------------------------------|
| Credential URL     | http://thehive:9000             |
| Credential API Key | the service account key         |
| Resource           | Observable                      |
| Operation          | Create                          |
| Create in          | Case                            |
| Case               | By ID, then {{ \$json.caseId }} |
| Data Type          | {{ \$json.dataType }}           |
| Data               | {{ \$json.data }}               |

*The credential connected. Data Type has populated from TheHive, which confirms the connection works before anything else is attempted.*

*The three mapped fields, each showing the fx marker and each resolving correctly in the preview beneath.*

One more error, and a useful one

*ObservableType port not found. The first two observables would have succeeded. The third used a type TheHive does not have.*

**TheHive has no port observable type.** That was an error in the original Code node rather than anything to do with n8n. The port observable was dropped, which costs nothing since a port number on its own cannot be analysed by anything.

This error was much better than the ones before it. It named the exact problem rather than reporting a generic failure, which is the dedicated node earning its place.

Success

*Two observables created, both type ip, created by the n8n service account.*

------------------------------------------------------------------------

The fields that carry meaning

An observable with no context is barely better than the prose it replaced. Four fields decide how useful it is.

*The configured fields. Description driven from the Code node, tags fixed, TLP and PAP set to Amber, Sighted on, IOC off.*

Description

Set from the Code node with {{ \$json.message }} rather than typed, because the source address and the target address deserve different text. The Code node already carries a message field for exactly this.

TLP, the Traffic Light Protocol

Says who this may be shared with. Amber means it may be shared within the organisation and with those who need to act on it, but not published.

PAP, the Permissible Actions Protocol

A different question from TLP. It says what may be done with the information without alerting whoever it concerns.

| **Level** | **Meaning** |
|----|----|
| White | Act freely, no risk of detection |
| Green | Passive research only, such as existing records |
| Amber | Active research allowed, but nothing the other party would notice |
| Red | Do not act without approval |

**Amber is right for this lab, and the reasoning matters for the Cortex phase.** Looking an address up against VirusTotal or AbuseIPDB is passive and safe. Scanning it back, or blocking it at the firewall, would tell whoever owns it that they were noticed. Amber permits the first and discourages the second, and Cortex analysers are expected to respect it.

IOC, left off

An indicator of compromise is something concluded to be malicious. An address that appeared in an alert is not that yet. Marking everything as an indicator is how threat intelligence becomes noise.

Sighted, turned on

**This is the flag that makes the observable worth having.** It means the value was genuinely observed in this environment, which is exactly what a Suricata alert establishes. It separates things you have actually seen from things you merely know about, and it is the basis of any later correlation.

Ignore Similarity, left off

Off means TheHive links this observable to the same value appearing in other cases. That linking is the point, so it stays off.

------------------------------------------------------------------------

Command reference

The commands used to diagnose this, with what each one told us.

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| cd ~/soc-stack && docker compose logs -f thehive | Follows TheHive server log while the workflow runs | The command that solved it. Showed the literal braces arriving after every client side theory had failed |
| curl -s -X POST -H "Authorization: Bearer <THEHIVE_API_KEY>" -H "Content-Type: application/json" -d '{...}' URL | Sends the same request by hand | Establishes whether the endpoint, key and payload are correct, separating them from how the client builds the request |
| curl -s -o /dev/null -w "%{http_code}\n" ... | Prints only the HTTP status code | Faster to read than full output when the question is simply whether it worked |
| curl ... http://localhost:9000/api/v1/case/~45280 | Fetches one case by id | Confirms whether a case exists, separating a bad id from a bad path |
| curl ... http://localhost:9000/api/v1/case/%7E4304/observable | Same request with the tilde percent encoded | Ruled out URL encoding as the cause. Both forms returned 201 |

A note on reading these errors

| **What n8n showed** | **What it actually meant** |
|----|----|
| Invalid URL, must start with http | A literal equals sign at the start of the URL |
| Forbidden, perhaps check your credentials | The case id was literal braces, so no case matched |
| The resource you are requesting could not be found | Progress. The URL was now valid and reaching the server |
| ObservableType port not found | An accurate error, from the dedicated node |

**Notice the pattern.** The generic client errors described the symptom. The server log and the dedicated node named the cause. When a client error is vague, the server usually knows more.

------------------------------------------------------------------------

Lessons worth keeping

Read the server log, not just the client error

**This is the main lesson and it cost several hours.** Four different theories were tested against the client error message, all wrong. One command against the server log gave the answer immediately. When a client says something vague and the server is reachable, ask the server.

The fx marker is the check, not the mode toggle

A field containing double braces without an fx marker will send those braces as text. That marker is visible at a glance and can be compared against a field known to be correct. Trusting that a toggle was clicked is not the same as confirming the result.

When the same fix fails twice, change approach

The same instruction was repeated several times after it had visibly not worked. Repetition is not diagnosis. Editing the workflow JSON directly, or switching to the dedicated node, would have resolved it far sooner.

Dedicated nodes exist for a reason

The TheHive node removed the entire class of problem by having no URL to construct. It should have been offered before the HTTP Request node had failed four times.

A generic tool is still the better diagnostic

The opposite is also true. Because the HTTP Request node exposes the request, the server log could be matched against what was being sent. A dedicated node would have hidden that. Use the specific node for the final answer, the generic one when you need to see what is happening.

Structure is what makes data useful

The address was always present in the case. Turning it from a phrase in a sentence into a typed observable with a sighted flag changes nothing for a human reader and everything for what the system can do next.

Know when to stop

**There was a point in this session where continuing was the wrong call and the suggestion to step back was correct.** It was not taken quickly enough. A long relay of screenshots against a stubborn problem is a signal to change method rather than to keep relaying.

------------------------------------------------------------------------

Lab state

| **Component** | **State** |
|----|----|
| Wazuh SIEM | Working, three agents active |
| OPNsense and Suricata | Working, detecting on em1 |
| Suricata to Wazuh forwarding | Working |
| n8n | Working, filters alerts and creates cases |
| TheHive | Working, cases created automatically |
| Observables on cases | Working. Two per case, typed as ip, with context |
| Human approval gate | In place, cases arrive New and unassigned |
| Cortex | Not built. This is the next step |
| MISP | Not built |
| Agent brain | Not built |
| Zeek | Deferred |

The workflow as it now stands

```
Webhook receives the Wazuh alert
Filter keeps level 10 and above
HTTP Request creates the case, returns _id
Code builds two observables from the alert
TheHive 5 creates each observable on the case
```

Addresses

| **Service**     | **Address**                 | **Account**           |
|-----------------|-----------------------------|-----------------------|
| Wazuh dashboard | https://<WAZUH_IP>      | admin                 |
| OPNsense        | https://<OPNSENSE_WAN_IP>     | root                  |
| n8n             | http://<SERVICES_IP>:5678  | owner account         |
| TheHive         | http://<SERVICES_IP>:9000  | <THEHIVE_ANALYST_USER> |
| victim01        | <VICTIM_IP> behind OPNsense | sensor                |
| Kali            | <ATTACKER_IP>             | attacker              |

------------------------------------------------------------------------

What comes next

Cortex

Now worth building, because there is finally something for it to analyse. It runs analysers against observables and writes the results back to TheHive.

1.  Add Cortex as a fourth container in the same Compose stack. Bring it up alone and confirm it is healthy before connecting anything, as was done with TheHive.

2.  Connect it to TheHive. Note the current TheHive config already references a Cortex host that does not exist, visible in its log as a name resolution failure for cortex. That will resolve once the container exists.

3.  Add a VirusTotal free API key and configure the analyser.

4.  Respect PAP. Passive reputation lookups are appropriate at Amber. Anything that touches the observed address is not.

Then MISP

With OTX and AbuseIPDB feeds, giving Cortex more to look up against. Expect it to be the heaviest addition and the one most likely to grow the disk.

Then the agent

Sitting between enrichment and case creation, so a case arrives with a summary and a suggested next step already attached. Everything built so far keeps it on the correct side of the approval gate.

Open items carried forward

- The TheHive API key has appeared in chat transcripts more than once and should be rotated, with the n8n credential updated to match.

- Kali's second adapter is still disconnected from the adapter fault diagnosis. Reconnect it if the <OTHER_NET_SUBNET> network is wanted.

- Whether the OPNsense crontab entries survive a firmware update, still untested.

- eve.json froze once with no known cause. The watchdog handles the symptom.

- agent.name shows wazuhserver for syslog sourced alerts, a limitation of syslog ingestion rather than a fault.

A note for whoever continues this

**Consider working through a tool that can read the files directly.** Much of the time lost in this session went to relaying screenshots of a single field back and forth. Something able to read the workflow JSON, run commands and check the server log in one place would have found the literal braces in minutes. The lab itself is in good order; the bottleneck was the method.
