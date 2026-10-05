> Source: `soc_lab_6_adapter_fault.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

**SOC Agent Lab**

A virtual adapter that could receive but not send

*Incident notes, 12 September 2026*

victim01 had stopped reporting to Wazuh. It took roughly three hours to find, and the cause was none of the four things it appeared to be along the way. This document records the wrong turns as carefully as the fix, because each one was a reasonable reading of the evidence available at the time and each will look tempting again.

| **Theory** | **Why it looked right** | **Why it was wrong** |
|----|----|----|
| The Wazuh agent had failed | The dashboard showed victim01 disconnected | All five agent processes were running and had been for hours |
| A firewall rule was blocking it | Traffic crosses OPNsense to reach Wazuh, and firewall rules had recently changed | Packets never reached the firewall at all, so no rule could act on them |
| Fusion networking was not running | No interface named vmnet2 existed on the Mac | This Fusion version does not create vmnet interfaces. It uses vmenet and bridge instead |
| Another machine had taken the gateway address | victim01 resolved <OPNSENSE_LAN_IP> to a MAC that was not OPNsense | No second device answered when the exchange was captured |

The symptom

*The Wazuh endpoints view. Two agents active, victim01 disconnected. The only machine actually inside the monitored network was the one not reporting.*

Worth noting what this costs. victim01 is the only host on <LAB_LAN_CIDR>, so with it disconnected the lab had network detection through Suricata but no endpoint telemetry at all.

First checks

The agent itself was healthy.

```
sudo systemctl status wazuh-agent --no-pager
Active: active (running) since Fri 2026-09-11 20:31:52 UTC
wazuh-execd, wazuh-agentd, wazuh-syscheckd,
wazuh-logcollector, wazuh-modulesd all present
```

Five processes up, running for four hours. So the agent was not the problem, and attention moved to what it was saying.

```
sudo tail -20 /var/ossec/logs/ossec.log
ERROR: (1216): Unable to connect to '[<WAZUH_IP>]:1514/tcp'
ERROR: (1208): Unable to connect to enrollment service at '[<WAZUH_IP>]:1515'
WARNING: Unable to connect to any server.
```

**Two different ports failing matters.** A single blocked port suggests a firewall rule. Both the agent port and the enrolment port failing together suggests the path itself, not a rule about one service.

------------------------------------------------------------------------

Working down the path

Can victim01 reach the Wazuh network

*Ping fails, and a direct TCP test to port 1514 reports blocked. Note the ping went to <MAC_NAT_IP> rather than <WAZUH_IP>, but both are on the far side of the firewall so the conclusion held.*

The bash test is worth keeping for machines without netcat installed.

```
timeout 5 bash -c "cat < /dev/null > /dev/tcp/<WAZUH_IP>/1514" && echo open || echo blocked
```

Can it reach its own gateway

*The gateway does not answer either, but the routing table is correct. Default via <OPNSENSE_LAN_IP> on ens37, with its own address <VICTIM_IP>.*

**This narrowed things considerably.** A machine that cannot reach its own gateway has a problem on the local segment, not a routing or firewall problem further out. Everything after this point was about the link between victim01 and OPNsense.

The clue that misled us for an hour

```
ip neigh
<MAC_LAN_IP> dev ens37 lladdr <HOST_BRIDGE_MAC> REACHABLE
<OPNSENSE_LAN_IP> dev ens37 lladdr 00:50:56:ea:14:0e REACHABLE
```

Both neighbours resolved, which means ARP was being answered and the segment was alive. But OPNsense reported its own em1 address as follows:

```
ifconfig em1
ether 00:0c:29:79:b2:b1
inet <OPNSENSE_LAN_IP> netmask 0xffffff00
status: active
```

**The MAC addresses did not match.** victim01 believed the gateway lived at 00:50:56:ea:14:0e while OPNsense reported 00:0c:29:79:b2:b1. The obvious reading was that something else on the network had claimed the gateway address and was answering for it, which would explain why packets vanished. That reading was wrong, and chasing it consumed the next hour.

------------------------------------------------------------------------

A detour through Fusion networking

Both VMs were configured correctly

*OPNsense Network Adapter 2, set to the custom network vmnet2 with subnet <LAB_LAN_NET> and connected.*

*victim01 Network Adapter 2, the same settings. On paper both machines were on the same virtual switch.*

The Mac appeared to have no such network

```
ifconfig | grep vmnet
(nothing)
```

**This produced a confident and incorrect conclusion: that Fusion networking had stopped.** Restarting the service did not change anything, which should have prompted a rethink sooner than it did.

```
sudo "/Applications/VMware Fusion.app/Contents/Library/services/services.sh" --stop
sudo "/Applications/VMware Fusion.app/Contents/Library/services/services.sh" --start
Stopped DHCP service on vmnet1, vmnet2, vmnet8
Started network services
```

What was actually happening

Listing every interface rather than grepping for one name showed the answer.

```
ifconfig -a | grep -E "^[a-z]"
vmenet5 ... vmenet12
bridge100, bridge101, bridge103
```

**This Fusion version does not create interfaces named vmnet.** It uses Apple's virtualisation framework, which produces one vmenet interface per virtual machine adapter, joined into a bridge per network. Note the spelling: vmenet, not vmnet. The absence of vmnet2 was normal rather than a fault.

Inspecting the bridge showed the lab network intact, with both machines present.

```
ifconfig bridge100
inet <MAC_LAN_IP> netmask 0xffffff00
member: vmenet9, vmenet11, vmenet2
Address cache:
0:c:29:79:b2:b1 vmenet11 (OPNsense em1)
0:c:29:ee:86:13 vmenet9 (victim01 ens37)
0:50:56:f3:1c:c8 vmenet2 (unidentified)
```

So layer two was working. Both machines were on the correct bridge and the switch had learned both addresses. The third entry remained unexplained and attracted more attention than it deserved.

------------------------------------------------------------------------

The evidence that settled it

Capturing the ARP exchange from both ends

The decisive step was watching the same exchange from two vantage points at once.

From the Mac, on the bridge

```
sudo tcpdump -ni bridge100 -e arp host <OPNSENSE_LAN_IP>
Request who-has <OPNSENSE_LAN_IP> tell <VICTIM_IP>
(no reply)
```

From OPNsense, on em1

```
tcpdump -ni em1 arp
Request who-has <OPNSENSE_LAN_IP> tell <VICTIM_IP>
Reply <OPNSENSE_LAN_IP> is-at 00:0c:29:79:b2:b1
```

**OPNsense received the question and answered it correctly. The reply never reached the bridge.** No second device answered either, which eliminated the address conflict theory. The fault was one directional: broadcasts reached OPNsense, and unicast replies did not come back.

Confirmation from the counters

```
netstat -i | grep em1
em1 1500 <Link#2> 00:0c:29:79:b2:b1 49 0 0 12 0 0
```

Reading those columns: 49 packets received, 12 transmitted, and zero errors in either direction. An interface on a working network carries roughly balanced traffic. This one was listening and barely speaking, with nothing reporting a problem.

A ping from OPNsense to victim01 also failed, confirming the break was outbound from OPNsense rather than anything on victim01.

------------------------------------------------------------------------

The fix

The adapter had entered a state where it could receive but not transmit. Nothing in software reported an error, which is why every log based check came back clean.

What did not work

- Unticking and reticking Connect Network Adapter on both machines

- Rebooting victim01

- Rebooting OPNsense

- Restarting Fusion networking services on the host

- Flushing the ARP cache on victim01, repeatedly

What did work

Removing the adapter entirely and adding a new one, which rebuilds the attachment rather than reusing it.

```
1\. Shut OPNsense down cleanly: halt -p
2\. Settings, Network Adapter 2, Remove Network Adapter
3\. Add Device, Network Adapter, set to vmnet2, tick Connect
4\. Start OPNsense
```

The result was immediate.

```
ifconfig em1
ether 00:50:56:22:3b:ca
inet <OPNSENSE_LAN_IP> netmask 0xffffff00
status: active
ping -c 3 <VICTIM_IP>
64 bytes from <VICTIM_IP>: icmp_seq=0 ttl=64 time=0.736 ms
3 packets transmitted, 3 packets received, 0.0% packet loss
```

A loose end that resolved itself

**Note the new MAC begins 00:50:56, the same prefix as the mystery device on vmenet2.** Fusion assigns from that range when generating an address for an adapter added after the machine was built, while 00:0c:29 belongs to adapters created at build time. The unidentified device was therefore most likely another re-added adapter rather than a rogue machine, which is why searching the VM configuration files never found it.

------------------------------------------------------------------------

Verifying the whole chain

The adapter changed underneath Suricata, so the full path was worth checking rather than assuming.

Agents

*Three agents active, none disconnected. victim01 reconnected without any change to the agent itself.*

Detection

*Suricata still detecting on em1. ET SCAN NMAP window 1024 from <ATTACKER_IP>, captured at 11:08:52.*

Case creation

*Cases 3 and 4 created automatically from the scans at 11:06 and 11:08. Cases 1 and 2 are from two days earlier. Every case shows Observables: 0, which is the gap still to close.*

So the chain from Kali through Suricata, syslog, Wazuh, n8n and into TheHive survived the adapter rebuild intact.

------------------------------------------------------------------------

Command reference

Every command used during this incident, with what it does and what it told us.

On the affected machine, victim01

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| sudo systemctl status wazuh-agent --no-pager | Shows the agent service and its processes | Separates a dead agent from a healthy agent that cannot reach anything |
| sudo tail -20 /var/ossec/logs/ossec.log | Shows recent agent messages | Named both failing ports, which pointed at the path rather than one blocked service |
| ping -c 3 <OPNSENSE_LAN_IP> | Tests the gateway | A machine that cannot reach its own gateway has a local segment problem, not a routing one |
| ip route | Shows the routing table | Confirmed the default route was correct, eliminating misconfiguration on this machine |
| ip neigh | Shows resolved neighbour addresses | Revealed the MAC mismatch. Useful, though it led us down the wrong path for an hour |
| sudo ip neigh flush dev ens37 | Clears cached neighbour entries | Forces a fresh ARP request so you can watch the exchange happen |
| timeout 5 bash -c "cat \< /dev/null \> /dev/tcp/HOST/PORT" | Tests one TCP port without netcat | Works on any machine with bash, which netcat is not always installed on |

On OPNsense

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| ifconfig em1 | Shows the interface, its address and its MAC | The MAC here is what a working client should resolve for the gateway |
| netstat -i \| grep em1 | Shows packet counts and errors per interface | The decisive evidence. 49 received against 12 transmitted with zero errors |
| tcpdump -ni em1 arp | Captures ARP on the interface | Proved OPNsense heard the request and answered it correctly |
| tcpdump -ni em1 | Captures everything on the interface | An empty capture on a live segment means the interface is not seeing traffic |
| pfctl -sr | Prints every loaded firewall rule | Eliminated the firewall theory by showing the LAN rule was present and correct |
| halt -p | Shuts the system down and powers off | Needed before removing a virtual adapter |

On the Mac host

| **Command** | **What it does** | **Why we ran it** |
|----|----|----|
| ifconfig -a \| grep -E "^\[a-z\]" | Lists every interface name | Revealed that this Fusion version uses vmenet and bridge rather than vmnet |
| ifconfig bridge100 | Shows one bridge, its members and address cache | Confirmed both machines were on the correct virtual switch |
| sudo tcpdump -ni bridge100 -e arp host <OPNSENSE_LAN_IP> | Captures ARP on the bridge with ethernet addresses | The -e flag shows which MAC sent each frame. Capturing here and on em1 at once located the break |
| sudo "/Applications/VMware Fusion.app/Contents/Library/services/services.sh" --stop | Stops Fusion networking services | Note the path includes a services directory. Older guidance omits it |
| ps aux \| grep -i vmware-vmx | Lists running virtual machines | Shows which VMs are powered on and where their configuration lives |
| grep -ril "MAC" /path/to/vms/ | Searches VM configuration for a MAC address | Returns nothing for dynamically generated addresses, which is most of them |

------------------------------------------------------------------------

Lessons worth keeping

An interface with zero errors can still be broken

**This is the main lesson.** Every log was clean, every service reported healthy, and the error counters were zero. The fault only became visible by comparing received against transmitted packets and noticing the imbalance. When software reports no problem and the network still does not work, count packets.

Capture from both ends of a link

Watching only victim01 suggested the gateway was silent. Watching only OPNsense suggested it was answering fine. Both were true, and only running both captures at once revealed that the reply never arrived.

Grep for one name proves less than listing everything

Searching for vmnet returned nothing and produced a confident wrong conclusion. Listing every interface showed vmenet and bridge, which was the actual naming. When a search comes back empty, widen it before drawing conclusions from the absence.

MAC prefixes carry information

| **Prefix** | **Meaning in Fusion**                                        |
|------------|--------------------------------------------------------------|
| 00:0c:29   | Adapter created when the virtual machine was built           |
| 00:50:56   | Adapter added or regenerated later, or a host side interface |

Knowing this would have resolved the mystery device in minutes rather than an hour. It was another re-added adapter, not a rogue machine.

Removing and re-adding beats reconnecting

Unticking and reticking the adapter reuses the same attachment. Removing it and adding a new one builds a fresh one. For a virtual adapter in a stuck state, only the second works, and it takes about two minutes with the machine powered off.

Know when to stop

The fix happened after a break. Three hours in, with several wrong theories behind us, continuing to poke at a running system would more likely have added a second fault than found the first. The adapter rebuild needed the machine powered off, which is not work to do while tired.

------------------------------------------------------------------------

Lab state after the fix

| **Component** | **State** |
|----|----|
| Wazuh SIEM | Working, three agents active |
| victim01 agent | Reconnected, no change needed to the agent itself |
| OPNsense | Working, LAN adapter rebuilt with MAC 00:50:56:22:3b:ca |
| Suricata | Working, detecting on em1 |
| Suricata to Wazuh forwarding | Working |
| n8n | Working, filtering and creating cases |
| TheHive | Working, four cases |
| Observables on cases | Still zero. The open task |
| Cortex, MISP, agent brain | Not built |

Changes to record

- OPNsense LAN adapter has a new MAC, 00:50:56:22:3b:ca, replacing 00:0c:29:79:b2:b1. Anything keyed to the old address will need updating, though nothing in this lab is.

- Kali's second adapter was disconnected during testing and has not been reinstated. That was the <OTHER_NET_SUBNET> network. Reconnect it if you want that back.

- victim01 was disconnected from Wazuh between roughly 20:31 on 11 September and 10:03 on 12 September. There is a gap in endpoint telemetry across that window.

What comes next

The observable work was interrupted by this incident and is ready to resume. The design agreed was a Code node building a list of three observables, followed by one HTTP Request that runs once per item.

```
const alert = $('Webhook').first().json.body;
const caseId = $input.first().json._id;
const observables = [
{ dataType: 'ip', data: alert.data.src_ip, message: 'Source address' },
{ dataType: 'ip', data: alert.data.dest_ip, message: 'Target address' },
{ dataType: 'port', data: String(alert.data.dest_port), message: 'Port probed' },
];
return observables
.filter(o => o.data)
.map(o => ({ json: { caseId, ...o } }));
```

The HTTP Request that follows posts to an expression based URL, since each case has its own identifier.

```
Method: POST
URL: =http://thehive:9000/api/v1/case/{{ $json.caseId }}/observable
{
"dataType": "{{ $json.dataType }}",
"data": "{{ $json.data }}",
"message": "{{ $json.message }}",
"tlp": 2,
"ioc": false,
"tags": ["wazuh", "automated"]
}
```

**One thing to be aware of before building it.** The case creation node outputs one item and the Code node turns that into three. Anything added after the observable node will therefore run three times rather than once. That is not a problem today but it matters when the Cortex phase is built on top.

The field paths were confirmed against a real alert. Wazuh places src_ip, dest_ip and dest_port directly under body.data, and also repeats src_ip inside body.data.flow. The top level fields are the ones to use.
