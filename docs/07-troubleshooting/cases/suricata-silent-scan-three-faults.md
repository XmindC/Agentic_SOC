> Source: `soc_lab_3_suricata_wazuh.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

**SOC Agent Lab**

Suricata scan detection and Wazuh forwarding

*Session notes, 5 September 2026*

This document records two pieces of work. First, finding out why an nmap scan from Kali produced no Suricata alert, which turned out to be three separate faults stacked on top of each other. Second, wiring Suricata alerts into Wazuh so network detection and endpoint data sit in one place. Every command run during the session is listed with its purpose, along with the screenshots taken along the way.

In brief

Two things were completed. The scan alert problem from the continuation brief is solved, and phase one of the remaining build, forwarding Suricata output into Wazuh, is done and verified in the dashboard.

The scan alert problem

Three faults were found, and any one of them alone would have produced complete silence. That is why the early single cause theories kept failing.

| **Fault** | **Effect** | **Fix** |
|----|----|----|
| Kali lost its static route to the lab | Scan traffic went to the VMware NAT gateway at <NAT_GATEWAY_IP> and never reached OPNsense at all. This was the root cause. | Route restored and made permanent in NetworkManager |
| HOME_NET included 192.168.0.0/16 | Kali counted as internal, so every rule written EXTERNAL to HOME could never match | HOME_NET narrowed to <LAB_LAN_CIDR> |
| Rule 2009582 shipped commented out | The one signature matching a plain SYN scan was never loaded | Uncommented directly in the rules file |

The forwarding work

Suricata alerts now travel from OPNsense to Wazuh over syslog, get parsed by a custom decoder, raise alerts through three custom rules, and appear as searchable documents in the dashboard with all fields intact.

------------------------------------------------------------------------

Where we started

The continuation brief left one open task. A Kali nmap scan against victim01 produced no Suricata alert, even though Suricata was running and had 31 alerts already on disk from earlier activity. The brief listed two suspects: the scan being too fast to trip a threshold, and the scan detection ruleset possibly not being installed.

Both suspects turned out to be wrong. The real explanation was different, and it took a long sequence of checks to reach it. That sequence is worth recording because the wrong turns are as instructive as the fix.

The thing that misled us for hours

The very first diagnostic run was a packet capture without an interface flag:

```
tcpdump -ni <lan_if> host <ATTACKER_IP> and host <VICTIM_IP>
```

It returned 50,491 packets captured. That looked like solid proof that Kali traffic was reaching the firewall, so attention moved straight to rules and rule loading. In fact the capture had defaulted to an interface that was not the one Suricata watches. Once captures were repeated with an explicit interface, both em0 and em1 were completely silent during a scan, and the real problem became visible.

**Lesson:** always name the interface in a packet capture when you are trying to prove that a sensor can see traffic. A capture without an interface flag proves only that packets exist somewhere on the box.

------------------------------------------------------------------------

Part one: why the scan produced no alert

Checks that came back clean

Before the faults were found, a series of checks ruled out the obvious causes. These are worth keeping because they form a reusable checklist for any future Suricata problem.

Is the engine running

```
service suricata status
```

Returned a live PID. The engine was up throughout.

Is the command socket available

```
suricatasc -c dump-counters
```

Failed with a missing socket error. This is normal on OPNsense, which ships with the unix command socket disabled. It is not a fault. Counters have to come from the stats log instead.

Is the engine dropping packets

```
grep -E 'capture.kernel_drops|decoder.pkts' /var/log/suricata/stats.log | tail -20
```

*Packet counters from stats.log. Drops sit flat at 36,867 then jump to 78,244 in the same interval that decoder.pkts leaps from 248k to 483k.*

This shows roughly 16 percent packet loss, but only in bursts, and only when a lot of traffic arrives at once. That burst was the scan itself. It is high for a production sensor but tolerable in a lab, and it was not the reason no alert appeared. A full port sweep still puts tens of thousands of packets through the engine.

Are the scan rules on disk

```
ls /usr/local/etc/suricata/rules/ | grep -i scan
grep -c . /usr/local/etc/suricata/rules/*scan*
```

Returned emerging-scan.rules with 406 lines. Present and populated.

Did the engine actually load them

This is a different question from whether the file exists, and it caused some confusion. The main config only lists one rule file:

```
grep -n -A40 'rule-files' /usr/local/etc/suricata/suricata.yaml
385:rule-files:
386- - suricata.rules
392-include:
393- - installed_rules.yaml
```

The file named on line 386 does not exist on disk, which looked alarming. It is harmless. The include on line 393 pulls in installed_rules.yaml, which redefines the rule-files key and replaces that stub list entirely. The real load list is in that second file:

```
cat /usr/local/etc/suricata/installed_rules.yaml
```

It listed 44 rule files including emerging-scan.rules. So the ruleset was loaded all along, and the second suspect from the brief was eliminated.

How many signatures were loaded

OPNsense does not write to the upstream suricata.log filename, and the startup output goes to a date stamped file. A config test writes the same information:

```
suricata -T -c /usr/local/etc/suricata/suricata.yaml
tail -30 /var/log/suricata/suricata_20260905.log
```

Result: 44 rule files processed, 161,607 rules successfully loaded, 0 rules failed, 0 rules skipped. The engine was completely healthy.

Fault one: the rule was shipped disabled

Suricata has no port scan preprocessor. Snort had sfPortscan; Suricata never shipped an equivalent. Most Emerging Threats scan rules are content matches on tool fingerprints, and a bare SYN scan carries no payload for them to match. But the packet capture showed every probe using a window size of 1024, which is nmap default behaviour, and ET does ship a rule for exactly that.

```
grep -in 'window:1024' /usr/local/etc/suricata/rules/emerging-scan.rules
```

Line 162 held sid 2009582, ET SCAN NMAP window 1024, and it began with a hash. Commented out. The rule that matched the traffic perfectly was disabled by the ruleset vendor default.

Compare the rule against the captured traffic:

| **Rule condition**     | **What the capture showed**    |
|------------------------|--------------------------------|
| flags:S,12 (plain SYN) | Flags \[S\] on every probe     |
| window:1024            | win 1024 on every probe        |
| dsize:0                | length 0                       |
| ack:0                  | No acknowledgement on the SYNs |

Why the graphical toggle did not work

The obvious fix was to enable the rule in Services, Intrusion Detection, Administration, Rules. That was done, and the override saved correctly. It appeared in three places:

```
grep -rn '2009582' /usr/local/etc/suricata/ | grep -v emerging-scan.rules
/usr/local/etc/suricata/rules.config:9:sid=2009582
grep -n '2009582' /conf/config.xml
673: <sid>2009582</sid>
1290: <description>/api/ids/settings/set_rule/2009582 made changes</description>
```

The override file showed exactly the right values:

```
[rule_3b54a5e7d15e47b0b05d02158fd2eee0]
enabled=1
action=alert
sid=2009582
```

Despite this, line 162 stayed commented out through a service restart and through a full Download and Update Rules cycle. The override was stored but never applied to any file the engine reads. This appears to be a fault in the OPNsense integration on this version.

The User defined tab could not help either

*The User defined tab exists and is the documented place for custom rules.*

*But the add dialog only offers Source IP, Destination IP, Action and Bypass. There is no field for rule text, so a rule needing window:1024 cannot be expressed here.*

The fix that worked

Editing the rules file directly. Note the empty quotes after the flag, which FreeBSD sed requires and Linux sed does not.

```
sed -i '' '162s/^#alert/alert/' /usr/local/etc/suricata/rules/emerging-scan.rules
grep -n 'sid:2009582' /usr/local/etc/suricata/rules/emerging-scan.rules
```

**Caution:** this edit lives in a file that rule updates overwrite. Check line 162 again after any Download and Update Rules run.

Fault two: HOME_NET included the attacker

With the rule enabled and the engine restarted, the scan still produced nothing. The next check was the address variables:

```
grep -n -A8 'HOME_NET' /usr/local/etc/suricata/suricata.yaml
6: HOME_NET: "[192.168.0.0/16,10.0.0.0/8,172.16.0.0/12]"
7: EXTERNAL_NET: "!$HOME_NET"
```

Kali sits at <ATTACKER_IP>, which falls inside 192.168.0.0/16. So Kali was classed as internal. EXTERNAL_NET is defined as everything that is not HOME_NET, which excluded Kali entirely. Rule 2009582 is written EXTERNAL to HOME, so it was structurally incapable of matching the scan no matter how well every other condition fit.

The same would have been true of any custom threshold rule using those variables. This is a quiet failure mode: nothing errors, nothing warns, the rule simply never fires.

The fix is in the graphical interface under Services, Intrusion Detection, Administration, Settings. The Home networks field was narrowed from the default private ranges to the lab LAN only.

```
grep -n 'HOME_NET:' /usr/local/etc/suricata/suricata.yaml
6: HOME_NET: "[<LAB_LAN_CIDR>]"
```

Fault three: the missing route, and the real root cause

Rule enabled, HOME_NET corrected, engine restarted, and the scan still produced nothing. At this point interface specific packet captures were run during a scan:

```
tcpdump -ni em1 -c 20 host <ATTACKER_IP>
tcpdump -ni em0 -c 20 host <ATTACKER_IP>
```

Both were completely silent. Kali packets were not arriving on either interface. No rule anywhere could have fired.

A first theory was that Kali had a second adapter on the lab network, letting it reach victim01 without crossing the firewall. The VMware settings did show two adapters:

*Kali has two network adapters, which raised the possibility of a path that bypasses OPNsense entirely.*

That theory was wrong. Checking from inside Kali settled it:

```
ip -br addr
eth0 UP <ATTACKER_IP>/24
eth1 UP <OTHER_NET_IP>/24
ip route get <VICTIM_IP>
<VICTIM_IP> via <NAT_GATEWAY_IP> dev eth0 src <ATTACKER_IP>
```

The second adapter was on <OTHER_NET_SUBNET>, unrelated to the lab. The real problem was in the route. Traffic for <VICTIM_IP> was going via <NAT_GATEWAY_IP>, which is the VMware NAT gateway, not OPNsense at <OPNSENSE_WAN_IP>. The NAT gateway has no idea where <LAB_LAN_CIDR> is, so it dropped the packets. Nothing ever reached the firewall.

**Why it broke:** the continuation brief records this route being added with ip route add. Routes added that way live only in the running kernel table and disappear on reboot. Kali had been rebooted since, and the route went with it.

Restoring the route and making it permanent

```
sudo ip route add <LAB_LAN_CIDR> via <OPNSENSE_WAN_IP>
ip route get <VICTIM_IP>
<VICTIM_IP> via <OPNSENSE_WAN_IP> dev eth0 src <ATTACKER_IP>
```

That fixes the running system. To survive a reboot the route has to go into the connection profile. First find out which manager owns the interface:

```
nmcli device status
eth0 ethernet connected Wired connection 1
```

NetworkManager owns it, so the route goes into that profile. The plus sign in front of ipv4.routes appends rather than replacing, which protects any existing routes:

```
sudo nmcli connection modify "Wired connection 1" +ipv4.routes "<LAB_LAN_CIDR> <OPNSENSE_WAN_IP>"
nmcli connection show "Wired connection 1" | grep -i ipv4.routes
ipv4.routes: { ip = <LAB_LAN_CIDR>, nh = <OPNSENSE_WAN_IP> }
sudo nmcli connection up "Wired connection 1"
```

Bringing the connection up reloads the profile from disk, which is the same thing a reboot does. The route survived, so it is genuinely persistent. Note that this briefly drops the interface, so run it from the virtual machine console rather than over an SSH session on that interface.

Confirmation

With all three faults fixed, the scan was run again:

```
sudo nmap -sS -T3 -p1-10000 <VICTIM_IP>
```

Then the alert count and signatures were read from disk:

```
grep -c '"event_type":"alert"' /var/log/suricata/eve.json
6
grep '"event_type":"alert"' /var/log/suricata/eve.json | grep -o '"signature":"[^"]*"'
```

Six alerts, listing:

- ET SCAN NMAP window 1024, the rule that was uncommented

- ET SCAN Suspicious inbound to mySQL port 3306

- ET SCAN Potential VNC Scan 5800 to 5820

- ET SCAN Suspicious inbound to PostgreSQL port 5432

- ET SCAN Suspicious inbound to MSSQL port 1433

- ET SCAN Suspicious inbound to Oracle SQL port 1521

The five database port rules were already enabled and fired the moment traffic actually reached the sensor. That is a useful detail: it confirms the ruleset was working the whole time and the traffic simply was not arriving.

------------------------------------------------------------------------

Part two: forwarding Suricata alerts into Wazuh

This is phase one of the remaining build from the continuation brief. The goal is for network alerts to land in the SIEM beside the endpoint data, so a single search covers both.

Choosing the transport

The first decision was whether to install a Wazuh agent on OPNsense and have it read eve.json directly, or to use syslog. A quick check settled it:

```
pkg info | grep -i wazuh
ls /usr/local/etc/ossec.conf
```

Both returned nothing, so there was no agent. Installing one on FreeBSD is more trouble than it is worth, and the Suricata configuration already had a syslog output block enabled. Syslog was the better route.

Worth understanding: the Suricata config has two separate eve-log blocks. The first writes to eve.json on disk and includes alert, anomaly, http and tls event types. The second sends to syslog and is configured for alerts only. So the syslog feed into Wazuh carries alerts and nothing else, which keeps the volume sensible.

Receiver side: the Wazuh manager

The default configuration only listens for agent traffic. Checking first:

```
sudo grep -n -A10 '<remote>' /var/ossec/etc/ossec.conf
34: <remote>
35- <connection>secure</connection>
36- <port>1514</port>
```

Only a secure block for agents on 1514. A syslog listener had to be added. Backup first, which is a habit worth keeping:

```
sudo cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak
sudo nano /var/ossec/etc/ossec.conf
```

The new block was added directly after the existing one, as a sibling not a child:

```
<remote>
<connection>syslog</connection>
<port>514</port>
<protocol>udp</protocol>
<allowed-ips><OPNSENSE_WAN_IP></allowed-ips>
</remote>
```

**The allowed-ips element is the security control here.** Without it, anything on the network could inject arbitrary events into the SIEM. Restricting it to the OPNsense WAN address means only the firewall can feed this listener.

Then restart and confirm the port is open:

```
sudo systemctl restart wazuh-manager
sudo ss -ulnp | grep 514
UNCONN 0 0 0.0.0.0:514 0.0.0.0:* users:(("wazuh-remoted",pid=28826,fd=4))
```

wazuh-remoted is bound to UDP 514. The receiver is ready.

Sender side: OPNsense

This lives under System, Settings, Logging, and specifically on the Remote tab. The Local tab looks similar but controls log files on OPNsense itself, not forwarding.

*The Local tab, which is not the one you want. Note the Remote tab beside it.*

On the Remote tab, a new target was added with these values:

| **Field** | **Value** | **Reason** |
|----|----|----|
| Transport | UDP(4) | Matches the protocol in the Wazuh remote block |
| Applications | suricata | Forwards only Suricata output, not all system logs |
| Levels | empty | All levels. Scan alerts are low severity and would be filtered out otherwise |
| Facilities | empty | No facility filter needed |
| Hostname | <WAZUH_IP> | The Wazuh manager |
| Port | 514 | Matches the listener |
| rfc5424 | unticked | Wazuh parses the older BSD syslog format more reliably |

Confirming the transport works

Before touching decoders, it is worth proving packets actually arrive. This capture on the Wazuh server shows them landing, and the -A flag prints the payload as text so you can see the exact format:

```
sudo tcpdump -ni ens33 -c 3 -A udp port 514 and host <OPNSENSE_WAN_IP>
```

The payload looked like this, wrapped for readability:

```
<174>Sep 5 22:21:57 OPNsense.lab.local suricata[87371]: {"timestamp":
"2026-09-05T22:21:57.860627+0100","in_iface":"em1","event_type":"alert",
"src_ip":"<ATTACKER_IP>","src_port":61058,"dest_ip":"<VICTIM_IP>",
"dest_port":443,"proto":"TCP","alert":{"signature_id":2009582,
"signature":"ET SCAN NMAP -sS window 1024","category":
"Attempted Information Leak","severity":2}}
```

This is a BSD format syslog header followed by the full Suricata JSON. Wazuh receives it, but its generic syslog decoders have no idea the payload is JSON, so without a custom decoder the events arrive and match nothing.

The decoder

```
sudo nano /var/ossec/etc/decoders/local_decoder.xml
```

Two decoders, a parent that matches on the program name in the syslog header and a child that hands the payload to the built in JSON decoder:

```
<decoder name="suricata-opnsense">
<program_name>suricata</program_name>
</decoder>
<decoder name="suricata-opnsense-json">
<parent>suricata-opnsense</parent>
<plugin_decoder>JSON_Decoder</plugin_decoder>
</decoder>
```

The JSON decoder flattens every field into searchable data, which is why the dashboard later shows 692 available fields.

The rules

A decoder only parses. Without rules nothing raises an alert.

```
sudo nano /var/ossec/etc/rules/local_rules.xml
<group name="suricata,opnsense,">
<rule id="100200" level="0">
<decoded_as>suricata-opnsense</decoded_as>
<description>Suricata event from OPNsense</description>
</rule>
<rule id="100201" level="5">
<if_sid>100200</if_sid>
<field name="event_type">alert</field>
<description>Suricata alert: $(alert.signature)</description>
</rule>
<rule id="100202" level="10">
<if_sid>100201</if_sid>
<field name="alert.category">Attempted Information Leak</field>
<description>Suricata recon detected: $(alert.signature) from $(src_ip)</description>
</rule>
</group>
```

What each rule does and why

| **Rule** | **Level** | **Behaviour** |
|----|----|----|
| 100200 | 0 | Catches every Suricata event from OPNsense regardless of type. Level 0 means parsed and stored but no alert raised. Nothing is filtered out, but routine events do not flood the alert log. |
| 100201 | 5 | Raises an alert for any event where event_type is alert. All signatures, no exceptions. |
| 100202 | 10 | Escalates recon activity so scans stand out. Interpolates the signature name and source address into the description. |

So all logs are decoded and searchable, and only alerts notify. More rules can be added later to escalate other categories, such as Trojan activity or attempted privilege gain, without touching these three.

A structural mistake worth avoiding

The first attempt nested the new group inside the existing sshd group. Wazuh does not support nested groups, and the sshd group tags would have been misapplied to the Suricata rules.

*Wrong. The suricata group opens before the sshd group has closed, so the two are nested.*

*Right. The sshd group closes first, then the suricata group opens. Two siblings, not a nest.*

Testing before trusting

Rather than restart and hope, Wazuh has a tool that runs a single message through the whole decoder and rule chain and shows exactly what happens at each phase:

```
sudo /var/ossec/bin/wazuh-logtest
```

Paste one real syslog line and press enter. The output confirmed all three phases:

```
**Phase 1: Completed pre-decoding.
program_name: 'suricata'
**Phase 2: Completed decoding.
name: 'suricata-opnsense'
alert.category: 'Attempted Information Leak'
alert.signature: 'ET SCAN NMAP -sS window 1024'
src_ip: '<ATTACKER_IP>'
**Phase 3: Completed filtering (rules).
id: '100202'
level: '10'
description: 'Suricata recon detected: ET SCAN NMAP -sS window 1024
from <ATTACKER_IP>'
**Alert to be generated.
```

**This tool is the single most useful thing in this whole document.** It isolates decoder and rule problems from transport problems in one step, and it does not require a restart or a live event.

Verification

One trap here cost time. Watching the alert log live with tail -f repeatedly showed nothing, which looked like failure. Searching the file directly told a different story:

```
sudo grep -c 'ET SCAN' /var/ossec/logs/alerts/alerts.log
36
sudo grep -c 'ET SCAN' /var/ossec/logs/alerts/alerts.json
13
```

The alerts had been arriving all along. The live tail simply kept being stopped before events flushed. Confirming which rules produced them:

```
sudo grep -B3 'ET SCAN' /var/ossec/logs/alerts/alerts.log | grep 'Rule:' | sort | uniq -c
2 Rule: 100201 (level 5) -> Suricata alert: ET SCAN Suspicious inbound to MSSQL port 1433
2 Rule: 100201 (level 5) -> Suricata alert: ET SCAN Suspicious inbound to mySQL port 3306
2 Rule: 100202 (level 10) -> Suricata recon detected: ET SCAN NMAP -sS window 1024
```

Both custom rules firing exactly as designed. The last check was the dashboard, because that is what a human analyst and the future agent will actually look at.

*Threat Hunting, Events, filtered on rule.id:100202. Four hits at level 10 with the signature and source address in the description, and 692 available fields from the parsed JSON.*

Indexed and searchable, which confirms the path from alerts.json through Filebeat into the indexer is healthy. Phase one is complete.

------------------------------------------------------------------------

An unrelated find worth recording

While checking the alert log, a grep for the word suricata returned 2,425 hits. None were from OPNsense. They were victim01 reporting that a local Suricata service was failing to start, over and over:

```
Rule: 40704 (level 5) -> Systemd: Service exited due to a failure.
victim01 systemd[1]: suricata.service: Main process exited, code=exited, status=1/FAILURE
```

This was leftover from the abandoned sensor build recorded in the continuation brief. When the sensor VM became victim01, the Suricata installation stayed behind. Its configuration referenced eth0, but the machine now uses ens33 and ens37, so it could never start.

```
sudo systemctl disable --now suricata
sudo systemctl status suricata --no-pager
```

The status output showed the scale of it: restart counter at 3,411. It had crash looped over three thousand times, each cycle burning CPU and generating a level 5 alert. On a server that has already filled its disk once, that matters.

**This is a real lesson rather than a lab curiosity.** A service that fails loudly and repeatedly produces exactly the kind of high volume, low value alert that trains analysts to ignore a severity level. Finding it was luck, but looking for it should be routine.

------------------------------------------------------------------------

Command reference

Every command run during this session, grouped by machine, with what it does and why it was needed. Flags inside commands are shown exactly as typed.

OPNsense: checking the engine

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| service suricata status | Reports whether Suricata is running and its process ID | First check for any Suricata problem. A changed PID also confirms a restart actually took effect |
| service suricata restart | Stops and starts the process outright | Forces a clean reload after editing rules or config. Apply in the interface sometimes reloads in place and keeps the same PID, which makes it unclear whether changes landed |
| suricata -T -c /usr/local/etc/suricata/suricata.yaml | Loads the full config and ruleset, reports the result, then exits without touching the running instance | Validates changes safely before restarting the live engine |
| suricatasc -c dump-counters | Queries the running engine through its unix command socket | Would give live counters, but OPNsense ships with the socket disabled so this fails. Use stats.log instead |

OPNsense: rules and configuration

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| ls /usr/local/etc/suricata/rules/ \| grep -i scan | Lists rule files matching scan | Confirms a ruleset file was downloaded to disk |
| grep -c . /usr/local/etc/suricata/rules/\*scan\* | Counts non empty lines in the file | A quick sanity check that the file has content rather than being an empty placeholder |
| grep -n -A40 'rule-files' /usr/local/etc/suricata/suricata.yaml | Shows which rule files the main config references | The starting point for finding out what the engine loads. On OPNsense this list is a stub |
| cat /usr/local/etc/suricata/installed_rules.yaml | Shows the real rule file load list | This is the file OPNsense generates from the ticked checkboxes. It redefines rule-files and overrides the stub |
| grep -n 'sid:2009582' .../emerging-scan.rules | Shows a specific rule and whether it begins with a hash | The only reliable way to tell if a rule is actually enabled. Vendor rulesets ship many rules commented out |
| grep -rn '2009582' /usr/local/etc/suricata/ | Searches every Suricata file for a rule id | Finds where an interface override was stored, and whether it reached anything the engine reads |
| sed -n '1,20p' /usr/local/etc/suricata/rules.config | Prints the first 20 lines of the override file | Shows the enabled and action values OPNsense recorded for each toggled rule |
| sed -i '' '162s/^#alert/alert/' \<file\> | Removes the hash from line 162 in place | Enables a rule directly when the interface toggle does not apply. The empty quotes are required by FreeBSD sed |
| grep -n -A8 'HOME_NET' /usr/local/etc/suricata/suricata.yaml | Shows the address variables | Reveals which networks count as internal. If your attacker sits inside HOME_NET, no EXTERNAL to HOME rule can ever match |

OPNsense: logs and traffic

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| grep -E 'capture.kernel_drops\|decoder.pkts' /var/log/suricata/stats.log \| tail -20 | Shows packet counters over recent intervals | Reveals whether the engine is losing packets. Drops climbing near total packets means capture problems, not rule problems |
| ls -la /var/log/suricata/ | Lists log files with sizes and modification times | Comparing timestamps across files shows whether one output has stalled while others continue |
| tail -1 /var/log/suricata/eve.json | Shows the most recent event written | The timestamp tells you immediately whether the file is current or frozen |
| grep -c '"event_type":"alert"' /var/log/suricata/eve.json | Counts alerts in the event file | The quickest way to tell if a test produced anything, and more reliable than watching a live tail |
| grep '"event_type":"alert"' eve.json \| grep -o '"signature":"\[^"\]\*"' | Lists just the signature names of every alert | Turns raw JSON into a readable summary of what fired |
| grep -n -A20 'eve-log' /usr/local/etc/suricata/suricata.yaml | Shows output configuration | Reveals which event types go to file and which go to syslog. They can differ |
| tcpdump -ni em1 -c 20 host <ATTACKER_IP> | Captures packets on a named interface from a specific host | Proves whether traffic reaches the interface the sensor watches. The interface flag is essential |
| ifconfig \| grep -E '^\[a-z\]\|inet ' | Lists interfaces with their addresses | Maps friendly names such as LAN and WAN to device names such as em0 and em1 |
| grep -i suricata /var/log/system/latest.log \| tail -30 | Shows Suricata entries in the system log | Where OPNsense records rule downloads and service starts, since it does not use the upstream log filename |

Kali: routing and testing

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| ip -br addr | Compact list of interfaces and addresses | Quick view of how many interfaces a machine has and which networks it sits on |
| ip route get <VICTIM_IP> | Asks the kernel which path it would use for one destination | The single most useful routing command. It answers what will actually happen rather than what the table implies |
| sudo ip route add <LAB_LAN_CIDR> via <OPNSENSE_WAN_IP> | Adds a route to the running kernel table | Restores connectivity immediately. Does not survive a reboot |
| nmcli device status | Shows which manager owns each interface | Determines where a permanent route needs to go. NetworkManager, systemd-networkd and interfaces files all differ |
| sudo nmcli connection modify "Wired connection 1" +ipv4.routes "<LAB_LAN_CIDR> <OPNSENSE_WAN_IP>" | Writes a route into the connection profile on disk | Makes the route permanent. The plus appends rather than replacing, protecting existing routes |
| nmcli connection show "Wired connection 1" \| grep -i ipv4.routes | Shows routes stored in the profile | Confirms the write succeeded before activating |
| sudo nmcli connection up "Wired connection 1" | Reloads the profile from disk | Applies the change and tests persistence in one step, since this is what a reboot does. Drops the interface briefly |
| sudo nmap -sS -T3 -p1-10000 <VICTIM_IP> | SYN scan of the first 10,000 ports at moderate speed | The test traffic. T3 and a narrower range reduce the burst that was overflowing the capture buffer at T4 |

Wazuh server

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| sudo grep -n -A10 '\<remote\>' /var/ossec/etc/ossec.conf | Shows the manager listener configuration | Reveals whether a syslog listener exists alongside the agent listener |
| sudo cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak | Copies the config to a backup | Always before editing. A syntax error stops the manager starting |
| sudo systemctl restart wazuh-manager | Restarts the manager | Applies config, decoder and rule changes |
| sudo ss -ulnp \| grep 514 | Shows what is listening on UDP 514 | Confirms the syslog listener actually opened, rather than the config merely being accepted |
| sudo tcpdump -ni ens33 -c 3 -A udp port 514 and host <OPNSENSE_WAN_IP> | Captures syslog packets and prints their payload as text | Shows the exact message format arriving, which determines what the decoder must match |
| sudo /var/ossec/bin/wazuh-logtest | Runs one message through decoding and rules, showing each phase | Isolates decoder and rule problems from transport problems. The most useful diagnostic in the Wazuh toolkit |
| sudo grep -i 'syslog\\remoted' /var/ossec/logs/ossec.log \| tail -20 | Shows listener activity and errors | Confirms the allowed address and whether anything is being rejected |
| sudo grep -n -A5 '\<alerts\>' /var/ossec/etc/ossec.conf | Shows the minimum alert level written to logs | If this threshold sits above your rule level, alerts fire but are never recorded |
| sudo /var/ossec/bin/wazuh-control status | Lists every Wazuh daemon and its state | A stopped analysisd would explain received events never becoming alerts |
| sudo grep -c 'ET SCAN' /var/ossec/logs/alerts/alerts.log | Counts matching alerts in the log | More reliable than watching a live tail, which is easy to stop at the wrong moment |
| sudo grep -B3 'ET SCAN' alerts.log \| grep 'Rule:' \| sort \| uniq -c | Groups alerts by the rule that produced them | Confirms your custom rules are the source rather than something else matching the text |
| date -u | Prints the time in UTC | The only fair way to compare clocks across machines in different timezones |

victim01

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| sudo systemctl disable --now suricata | Stops the service and prevents it starting at boot | Ends a crash loop. The --now flag combines stop and disable |
| sudo systemctl status suricata --no-pager | Shows service state and recent log lines | Confirms the stop worked and reveals the restart counter, which shows how long a loop has been running |

------------------------------------------------------------------------

Tips and lessons

Name the interface in every packet capture

A capture without an interface flag proves only that packets exist somewhere on the machine. It cannot prove your sensor sees them. This one omission sent the investigation down the wrong path for hours.

Ruleset enabled is not the same as rule enabled

Vendor rulesets ship many rules commented out. Ticking a ruleset in an interface downloads and references the file, but the individual rules inside keep whatever state the vendor chose. A rule that is disabled by default is invisible until you go looking for it.

Check the address variables before blaming the rule

HOME_NET defaults to all private ranges. In a lab where the attacker also sits on a private network, that makes the attacker internal and silently breaks every rule written from external to home. Nothing errors. The rule simply never matches.

Routes added on the command line do not survive reboots

ip route add writes only to the running kernel table. If a lab depends on a route, put it in the connection profile the same day you create it, or it will vanish at the least convenient moment and look like a detection failure.

Test decoders with the tool, not with live traffic

wazuh-logtest answers in seconds what live testing takes many restarts to answer, and it separates parsing problems from delivery problems cleanly. Reach for it first.

Search the log file rather than watching it

A live tail is easy to start too late or stop too early, and a quiet tail looks exactly like failure. grep with a count answers the same question without timing risk. During this session a working pipeline looked broken for a long time purely because of this.

Stacked faults defeat single cause reasoning

Three independent faults each produced identical symptoms: complete silence. Fixing any one changed nothing visible, which made each fix look wrong. When a fix that should work produces no change, consider that it may have worked and something else is also broken.

Watch for noise before it becomes a disk problem

A crash looping service generated over three thousand level 5 alerts. On a server that has already filled its disk once, that is worth catching early. This command ranks alerts by frequency and shows what dominates:

```
grep -o '"signature":"[^"]*"' /var/log/suricata/eve.json | sort | uniq -c | sort -rn | head -20
```

------------------------------------------------------------------------

Housekeeping and open items

Things that are done, things that need watching, and things worth doing before the next phase.

Needs attention

| **Item** | **Detail** | **What to do** |
|----|----|----|
| The rule edit is fragile | Line 162 of emerging-scan.rules was edited directly. OPNsense overwrites vendor rule files during Download and Update Rules. | Recheck with grep -n 'sid:2009582' after every rule update. If it reverts, uncomment it again. |
| eve.json froze once | The file stopped being written at 19:13 while stats.log continued normally. Deleting it restored writing. | Watch for a recurrence. If eve.json stops growing while Suricata runs, delete it and restart rather than assuming a rule problem. |
| Packet loss around 16 percent | Bursts of loss during fast scans. OPNsense exposes no pcap buffer setting, and no pcap block exists in the config. | Accepted for now. Scan at T3 rather than T4. Be aware this is a possible cause when an expected alert does not appear. |
| Alerts attributed to the manager | Because OPNsense sends by syslog rather than an agent, agent.name shows wazuhserver rather than the firewall. | Workable with one sensor. Add a rule field to tag the source before adding a second sensor. |

Worth knowing

- HOME_NET is now <LAB_LAN_CIDR> only. The Wazuh server at <WAZUH_IP> and the Mac are now classed as external. That is intentional and correct for detecting attacks against the lab, but any future rule meant to protect those machines will not apply.

- The Suricata package is still installed on victim01, only the service is disabled. If you want it gone entirely rather than just stopped, remove the package. Leaving it disabled is fine.

- A backup of the Wazuh config sits at /var/ossec/etc/ossec.conf.bak from before the syslog block was added.

- The syslog output from Suricata carries alerts only. The richer http and tls events stay in eve.json on OPNsense and do not reach Wazuh. If you want them later, add those types to the syslog eve-log block, but expect a large volume increase.

Checked and found fine

- Clock synchronisation. OPNsense displays local time and the Wazuh server displays a different local time, which looked like an hour of drift. Comparing with date -u on both showed them within five seconds of each other. Wazuh indexes in UTC, so correlation will be accurate. There was nothing to fix.

- The missing suricata.rules file referenced at line 386 of suricata.yaml. Harmless, because installed_rules.yaml redefines that key.

- The missing Suricata command socket. Normal on OPNsense, which ships with it disabled.

------------------------------------------------------------------------

Lab state after this session

| **Component** | **State** |
|----|----|
| Wazuh SIEM | Working. Three agents: kali, MacOS, victim01 |
| OPNsense firewall | Working. Gateway for the lab network |
| Suricata on OPNsense | Working. Detects scans from Kali end to end |
| Kali route to lab | Persistent through NetworkManager |
| Suricata to Wazuh forwarding | Working and verified in the dashboard. Phase one complete |
| victim01 leftover Suricata | Disabled. Crash loop stopped |
| Zeek | Deferred |
| n8n orchestration | Not built |
| MISP, Cortex, threat intel | Not built |
| TheHive case management | Not built |
| Agent brain | Not built |

The detection path as it now stands

```
Kali <ATTACKER_IP>
route via <OPNSENSE_WAN_IP>
OPNsense WAN, forwarded to LAN em1
Suricata IDS on em1, HOME_NET <LAB_LAN_CIDR>
eve-log syslog output, alerts only
UDP 514 to <WAZUH_IP>
Wazuh remoted syslog listener, allowed-ips restricted
decoder suricata-opnsense, JSON_Decoder
rules 100200, 100201, 100202
alerts.json, Filebeat, indexer
Wazuh dashboard, Threat Hunting
```

Next phases

1.  Zeek for rich connection logging. Deferred. Run it on OPNsense or a machine that sees the traffic.

2.  Build the services host virtual machine with Docker running n8n, MISP, Cortex and TheHive.

3.  Enrichment: MISP with OTX and AbuseIPDB feeds, Cortex analysers, a VirusTotal free API key.

4.  Case management and the human approval gate with TheHive.

5.  Agent brain on the Copilot free tier, wired in through n8n, using the level one and level two prompts from the plan document.

6.  The human in the loop approval gate, where every state changing action waits for the analyst.

Before starting the orchestration phases, attach the five detailed documents listed in the continuation brief to the new conversation. Only the brief itself was available during this session, which was enough for the detection and forwarding work but will not be enough for the build phases.
