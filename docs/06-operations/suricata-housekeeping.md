> Source: `soc_lab_4_housekeeping.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

**SOC Agent Lab**

Housekeeping addendum

*Fixes to the four open items, 6 September 2026*

The main session notes closed with four items flagged for attention. This addendum records how each was resolved. It supersedes the housekeeping section of that document and leaves the rest of it unchanged.

| **Item** | **Was** | **Now** |
|----|----|----|
| Fragile rule edit | Rule updates would silently revert the enabled scan rule | Self repairing script on a six hourly schedule plus a boot hook |
| eve.json freeze | Output stalled once with no known cause | Watchdog restarts Suricata if output stops for six hours |
| Packet loss | Roughly 16 percent dropped during fast scans | Zero drops across 272,447 packets |
| Alert attribution | Alerts appeared to come from the Wazuh server | Sensor name and interface now shown and searchable |

Item one: protecting the rule edit

The problem, simply

Rule 2009582 was enabled by editing the Emerging Threats rule file directly, because the graphical toggle in OPNsense saved the setting but never applied it. That file belongs to the rule vendor. Every time OPNsense runs Download and Update Rules, it fetches a fresh copy and overwrites the edit. The rule goes back to disabled, scan detection stops working, and nothing warns you. The first sign would be a scan that produces no alert, which is exactly the problem that took a full session to solve the first time.

The fix

A small script that checks whether the rule has been reverted and repairs it if so. When the rule is already enabled it does nothing at all, so it is safe to run often.

```
nano /root/fix_suricata_rules.sh
#!/bin/sh
RULEFILE=/usr/local/etc/suricata/rules/emerging-scan.rules
if grep -q '^#alert.*sid:2009582' $RULEFILE; then
sed -i '' 's/^#\(alert.*sid:2009582\)/\1/' $RULEFILE
service suricata restart
logger -t suricata-fix "Re-enabled sid 2009582 after rule update"
fi
```

What each line does

| **Line** | **Purpose** |
|----|----|
| grep -q | Checks whether the rule is currently commented out. The q flag means quiet, so it produces no output and only returns a yes or no answer |
| sed -i '' | Strips the leading hash. The empty quotes are required by FreeBSD sed and are not needed on Linux |
| service suricata restart | Reloads the engine so the repaired rule is actually loaded |
| logger -t | Writes a line to the system log so you have a record that the repair happened |

Testing it

First the harmless case, where the rule is already fine:

```
chmod +x /root/fix_suricata_rules.sh
sh /root/fix_suricata_rules.sh
echo $status
0
```

Exit code zero and no action taken, which is correct. Then the case that matters, breaking it deliberately to prove the repair works:

```
sed -i '' '162s/^alert/#alert/' /usr/local/etc/suricata/rules/emerging-scan.rules
grep -n 'sid:2009582' /usr/local/etc/suricata/rules/emerging-scan.rules
162:#alert tcp $EXTERNAL_NET any ...
sh /root/fix_suricata_rules.sh
Stopping suricata.
Starting suricata.
grep -n 'sid:2009582' /usr/local/etc/suricata/rules/emerging-scan.rules
162:alert tcp $EXTERNAL_NET any ...
```

Detected, repaired, engine restarted.

Scheduling it

```
crontab -e
0 */6 * * * /root/fix_suricata_rules.sh
```

Every six hours. Rule updates happen roughly daily, so the rule is never disabled for long, and since the script does nothing when there is nothing to fix, running it often costs nothing.

The backup, and why it is needed

OPNsense generates its crontab from config.xml, so a manual crontab edit can be wiped when the system regenerates it, typically after a firmware update. A boot hook covers that case:

```
nano /usr/local/etc/rc.syshook.d/start/99-suricata-rulefix
#!/bin/sh
/root/fix_suricata_rules.sh
chmod +x /usr/local/etc/rc.syshook.d/start/99-suricata-rulefix
```

The 99 prefix makes it run last, after Suricata has started. Understand the difference though: a boot hook runs once at startup, not on a schedule. It is insurance for the crontab being wiped, not a replacement for the six hourly check.

A trap worth remembering

**The OPNsense root shell is tcsh, and it treats the exclamation mark in a shebang as history expansion.** Writing the file from the command line fails:

```
echo '#!/bin/sh' > /usr/local/etc/rc.syshook.d/start/99-suricata-rulefix
/bin/sh: Event not found.
```

Single quotes do not help, and printf fails the same way. Use an editor for any file containing a shebang. This cost three attempts before the file was written correctly.

------------------------------------------------------------------------

Item two: the eve.json watchdog

The problem, simply

During the previous session eve.json stopped being written at 19:13 while Suricata kept running normally and stats.log kept updating. Every alert count checked after that point was reading a dead file, which made a working detection pipeline look broken for a long stretch. Deleting the file restored writing. The cause was never found.

Since an unknown cause cannot be fixed, the practical answer is to detect the symptom. A stalled eve.json is easy to spot because the file stops growing while the engine is still up.

A useful detour

The first version of the script used a fifteen minute threshold. Checking the file age at the time showed 1,078 seconds, already past that limit, which looked like the freeze had recurred. It had not. A simple test settled it:

```
wc -c /var/log/suricata/eve.json
63513
# then from victim01: curl -s https://www.google.com > /dev/null
sleep 10
wc -c /var/log/suricata/eve.json
63762
```

**The file grew by 249 bytes.** It was not frozen, it was idle. Suricata only writes when there is traffic to report, and at two in the morning the lab was quiet. A fifteen minute threshold would have restarted Suricata every quiet night for no reason, which is worse than the problem it was meant to catch, since each restart is a brief gap in detection.

The final script

```
nano /root/check_eve.sh
#!/bin/sh
EVE=/var/log/suricata/eve.json
service suricata status > /dev/null 2>&1
if [ $? -ne 0 ]; then
exit 0
fi
NOW=`date +%s`
MOD=`stat -f %m $EVE`
AGE=`expr $NOW - $MOD`
if [ $AGE -gt 21600 ]; then
logger -t suricata-watchdog "eve.json stale for $AGE seconds, restarting Suricata"
service suricata restart
fi
```

What each part does

| **Part** | **Purpose** |
|----|----|
| service suricata status check | Exits quietly if Suricata is already stopped, so the script never restarts a service you shut down deliberately |
| stat -f %m | Returns the file last modification time as a Unix timestamp. The f flag is the FreeBSD form |
| date +%s | Returns the current time in the same format so the two can be subtracted |
| expr \$NOW - \$MOD | Gives the file age in seconds |
| 21600 | Six hours. The lab can plausibly be quiet overnight but not for six hours straight, since victim01 does periodic package checks |

Scheduling it

```
chmod +x /root/check_eve.sh
crontab -e
30 */2 * * * /root/check_eve.sh
```

Every two hours, so a genuine freeze is caught within a couple of hours. The thirty minute offset stops it running at the same moment as the rule fix job. Verify with:

```
crontab -l | tail -3
0 */6 * * * /root/fix_suricata_rules.sh
30 */2 * * * /root/check_eve.sh
```

A matching boot hook was added at /usr/local/etc/rc.syshook.d/start/99-suricata-evecheck for the same crontab wipe risk, written with an editor for the shebang reason above.

------------------------------------------------------------------------

Item three: eliminating packet loss

The problem, simply

During a fast scan Suricata dropped roughly 16 percent of packets. The engine reads packets from a buffer, and when they arrive faster than it can process them the buffer overflows and packets are lost. A lost packet is one no rule can ever match, so this produces exactly the symptom that wastes hours: an alert that should have fired and did not, for reasons that look like a rule problem.

What the interface offers

The Settings tab was checked in full for anything relating to threads, workers or buffers.

*Top of the Settings tab. Capture mode, interfaces, pattern matcher, Detect Profile and Home networks. Note Home networks correctly showing only <LAB_LAN_CIDR> from the earlier fix.*

*Lower half. Default packet size was empty, and the logging options confirm eve syslog output is enabled.*

**There is no thread count, ring buffer or worker setting anywhere.** OPNsense does not expose them, and there is no pcap block in suricata.yaml to edit either. But two fields on this page do help.

The two changes

| **Field** | **From** | **To** | **Why** |
|----|----|----|----|
| Detect Profile | Default | High | Controls how much memory the detection engine allocates to its internals. More room means better ability to keep up during bursts. The virtual machine has 4 GB allocated, so there is headroom |
| Default packet size | empty | 1518 | Matches the Ethernet MTU of 1500 plus the 14 byte header and 4 byte checksum. Reduces how often Suricata handles fragmented reassembly, which costs cycles during a flood |

Apply, then restart the engine so the new profile takes effect:

```
service suricata restart
sleep 10
service suricata status
```

Measuring it properly

This is the part that caused confusion and is worth recording carefully. The obvious approach is to read the counters from stats.log:

```
grep -E 'capture.kernel_drops|decoder.pkts' /var/log/suricata/stats.log | tail -4
```

**That approach is misleading.** stats.log appends across restarts rather than being truncated, so a tail can show old blocks from a previous session. The packet counter appeared stuck at 69,854 across four intervals, which looked like Suricata had stopped processing traffic entirely. It had not. Those were stale numbers from before the restart.

The reliable figure is the per session summary Suricata writes when it shuts down. Restart before the test, run the scan, then restart again to force the summary:

```
service suricata restart
# from Kali: sudo nmap -sS -T4 -p- <VICTIM_IP>
service suricata restart
grep 'em1: packets' /var/log/suricata/latest.log | tail -2
```

The result

```
em1: packets: 272447, drops: 0 (0.00%), invalid chksum: 0
```

Zero drops across 272,447 packets, measured on a full 65,535 port sweep at T4, which is the aggressive scan that caused the original loss. Previously the same conditions produced 78,244 drops against 483,250 packets.

**Practical note:** the em1 packets line is now the correct way to check drop rate. It covers exactly one engine session and cannot be confused with older data.

------------------------------------------------------------------------

Item four: attributing alerts to the sensor

The problem, simply

In the Wazuh dashboard the Suricata alerts showed agent.name as wazuhserver. That is wrong, since the alerts came from OPNsense. It happens because syslog carries no agent identity, so Wazuh attributes anything received that way to the manager itself. With one sensor it is a cosmetic annoyance. With two it becomes a real problem, because you cannot tell which firewall saw what, and the planned agent would have no way to know where an alert originated.

What can and cannot be changed

**Being straight about the limit:** agent.name is set by the Wazuh ingestion layer and cannot be overwritten from a rule. Short of installing an agent on FreeBSD, it will keep saying wazuhserver. What can be done is to put the sensor identity into the alert description and add group tags, so the source is visible at a glance and filterable in searches.

First confirm what fields are available to work with:

```
sudo /var/ossec/bin/wazuh-logtest
```

Pasting one real syslog line showed both fields we need:

```
**Phase 1: Completed pre-decoding.
hostname: 'OPNsense.lab.local'
program_name: 'suricata'
**Phase 2: Completed decoding.
in_iface: 'em1'
```

hostname comes from the syslog header, in_iface from the Suricata JSON. Together they identify both the sensor and the network segment.

The rule changes

```
sudo nano /var/ossec/etc/rules/local_rules.xml
<rule id="100201" level="5">
<if_sid>100200</if_sid>
<field name="event_type">alert</field>
<description>Suricata alert on $(hostname) $(in_iface): $(alert.signature)</description>
<group>sensor_opnsense,</group>
</rule>
<rule id="100202" level="10">
<if_sid>100201</if_sid>
<field name="alert.category">Attempted Information Leak</field>
<description>Suricata recon on $(hostname) $(in_iface): $(alert.signature) from $(src_ip)</description>
<group>sensor_opnsense,recon,</group>
</rule>
```

*The edited rules file. Note the group structure is still two siblings, with the sshd group closing before the suricata group opens.*

Testing before restarting

```
sudo /var/ossec/bin/wazuh-logtest
```

Phase 3 confirmed both the new description and the group tags:

```
**Phase 3: Completed filtering (rules).
id: '100202'
level: '10'
description: 'Suricata recon on OPNsense.lab.local em1:
ET SCAN NMAP -sS window 1024 from <ATTACKER_IP>'
groups: '['suricata', 'opnsense', 'sensor_opnsense', 'recon']'
**Alert to be generated.
```

Confirming with live traffic

```
sudo systemctl restart wazuh-manager
# from Kali: sudo nmap -sS -T3 -p1-10000 <VICTIM_IP>
sudo grep -A2 'Suricata recon on' /var/ossec/logs/alerts/alerts.log | tail -10
```

Real alerts arriving in the new format:

```
Rule: 100202 (level 10) -> 'Suricata recon on OPNsense.lab.local em1:
ET SCAN NMAP -sS window 1024 from <ATTACKER_IP>'
```

The group tags also make sensors filterable in the dashboard with a search on rule.groups:sensor_opnsense, which is how you will separate them once a second sensor exists.

------------------------------------------------------------------------

Command reference for these fixes

OPNsense

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| chmod +x /root/fix_suricata_rules.sh | Makes a script executable | Required before cron or a boot hook can run it |
| sh /root/fix_suricata_rules.sh | Runs the script once by hand | Tests it without waiting for the schedule |
| echo \$status | Shows the exit code of the last command | The tcsh equivalent of \$? in bash. Zero means success |
| sed -i '' '162s/^alert/#alert/' \<file\> | Comments out line 162 | Used to break the rule deliberately so the repair script could be tested |
| crontab -e | Opens the scheduled task list for editing | Where the two recurring jobs were added |
| crontab -l \| tail -3 | Shows the last few scheduled entries | Confirms the jobs were saved. Worth rerunning after any firmware update |
| stat -f %m \<file\> | Prints a file last modification time as a Unix timestamp | The basis of the freeze detection. The f flag is the FreeBSD form |
| date +%s | Prints the current time as a Unix timestamp | Subtracted from the file time to get its age in seconds |
| wc -c /var/log/suricata/eve.json | Counts bytes in the file | Run twice with a pause between to tell whether a file is growing or genuinely stalled |
| grep 'em1: packets' /var/log/suricata/latest.log \| tail -2 | Shows the per session packet and drop summary | The reliable way to measure drop rate. Written at shutdown, so it covers exactly one engine session |
| logger -t \<tag\> "\<message\>" | Writes a line to the system log | Lets a script leave a record of what it did and when |

Wazuh server

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| sudo /var/ossec/bin/wazuh-logtest | Runs one message through decoding and rules, showing each phase | Confirms rule changes work before restarting anything. Used here to check the new descriptions and group tags |
| sudo systemctl restart wazuh-manager | Restarts the manager | Applies rule file changes |
| sudo grep -A2 'Suricata recon on' /var/ossec/logs/alerts/alerts.log \| tail -10 | Finds recent alerts matching the new description format | Confirms live traffic produces the expected output, not just the test tool |

------------------------------------------------------------------------

Status and what to watch

All four items closed

| **Item** | **Resolution** | **Where it lives** |
|----|----|----|
| Fragile rule edit | Self repairing script, six hourly, plus boot hook | /root/fix_suricata_rules.sh |
| eve.json freeze | Watchdog with a six hour threshold, two hourly, plus boot hook | /root/check_eve.sh |
| Packet loss | Detect Profile High, packet size 1518. Zero drops across 272,447 packets | Intrusion Detection Settings tab |
| Alert attribution | Sensor hostname and interface in descriptions, group tags added | local_rules.xml rules 100201 and 100202 |

Two things to verify later

- Whether the crontab entries survive the next firmware update. Check with crontab -l. If they are gone, the boot hooks will still run the scripts at startup, but you will want to re add the schedule.

- Whether the rule fix script actually fires the next time Emerging Threats pushes an update. Check line 162 with grep -n 'sid:2009582' on the rules file, and look for the suricata-fix tag in the system log.

Still open, by choice

- agent.name continues to show wazuhserver for syslog sourced alerts. This is a limitation of syslog ingestion rather than a configuration error. Installing a Wazuh agent on FreeBSD would fix it properly, but the effort is not justified for one sensor.

- The eve.json freeze cause remains unknown. The watchdog handles the symptom. If it fires, the system log entry tagged suricata-watchdog will tell you when and for how long the file was stale, which is useful data if the problem recurs and needs proper diagnosis.

Nothing else in the main session notes has changed. The detection path, the forwarding configuration and the command reference in that document all remain accurate.
