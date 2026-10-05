> Source: `opnsense_network_detection_notes.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

# SOC Agent Lab: OPNsense Configuration and Network Detection

**From reaching the web interface through working Suricata detection and the Kali attack**

This continues from the previous note, which ended at the OPNsense console menu showing WAN on <OPNSENSE_WAN_IP> and LAN on <OLD_LAB_LAN_IP>. Everything below covers getting into the web interface, redesigning the lab network, building network detection, and testing it with a real attack. The failed attempts are kept in on purpose, because they are the most useful part.

```
Note on typing: the writing avoids hyphens so it reads easily, but commands, file names, package names, ruleset names, and web links must be typed exactly as shown, including any hyphens they contain.
```

Assumed layout at the start: Intel Mac, VMware Fusion, a Wazuh server at <WAZUH_IP>, Kali, and an OPNsense firewall just installed.

---

## Part 1: Reaching the web interface (the lockout problem)

The OPNsense web interface lives on the LAN side at the LAN address. The Mac sits on the WAN side (the shared NAT network), and by default OPNsense blocks its own web interface on the WAN side for security. So the Mac could not reach the GUI at first, even though it could reach the firewall on the network.

The temporary way in is to turn the firewall off from the console. In the OPNsense console, choose option 8 for the Shell and run:

```
pfctl -d
```

This disables packet filtering, which drops the WAN block long enough to log in. It is a temporary lab move that resets when the firewall reloads. Then from the Mac browser open the WAN address and log in as root:

```
https://<OPNSENSE_WAN_IP>
```

Accept the self signed certificate warning. You reach the setup wizard.

*In on the WAN address after disabling the packet filter.*

---

## Part 2: Making the Mac's access permanent

Here is the trap: the only reason the GUI is reachable is that `pfctl -d` switched the firewall off. The moment OPNsense applies any change, including when the setup wizard finishes, the firewall turns back on and blocks the GUI on WAN again, locking the Mac out. So two changes must be made and saved together, then applied once.

**Change one.** Interfaces, then WAN. Under Generic configuration, untick **Block private networks**. The WAN sits on a private 192.168 network, so that setting would block the Mac itself. Save, but do not apply yet.

**Change two.** Firewall, then Rules, then WAN. Add a pass rule so the Mac's network can reach the GUI.

*Source is the Mac's network, destination is This Firewall, port HTTPS.*

**The mistake here:** the destination port was first set to HTTP (80). The OPNsense web interface runs on HTTPS (443), not 80, so that rule would have allowed a port nobody uses and left 443 blocked, locking the Mac out anyway. The fix was to set the port to **HTTPS (443)**.

*The corrected rule, allowing the Mac network to the firewall on https.*

The ordering matters: save both changes without applying, then click Apply once. That single reload turns the firewall on with both the port 443 allow and private networks unblocked, so the Mac keeps access. After the apply, the page still responded, which proved the access was now permanent. No more `pfctl -d` needed.

---

## Part 3: The setup wizard

With permanent access, the wizard was safe to run. System, Configuration, Wizard.

**General information.** Hostname `opnsense`, domain `lab.local`, DNS servers `8.8.8.8` and `1.1.1.1`, with Override DNS unticked so the DNS stays fixed. Timezone set to the local zone.

**WAN page.** Type left as DHCP. The important field is at the bottom: **Block private networks** must stay unticked. The wizard tends to switch it back on, and if it is ticked at the end, the firewall reload locks the Mac out again.

*Block RFC1918 Private Networks unticked, which is what keeps access.*

**LAN page.** Left at <OLD_LAB_LAN_IP> with a DHCP server, for now. This changes in Part 4.

**Deployment type.** Untick **Optimize for Multiwan**, since there is only one WAN and leaving it on causes gateway flapping. Keep **Automatic DHCP/DNS registration** on, so machines can be reached by name later. Leave **Optimize for IPsec** off.

A useful distinction: "Optimize for IPsec" is a performance tuning setting for a box carrying heavy IPsec traffic. It is not the IPsec VPN feature, which stays available under the VPN menu regardless. So leaving it off does not remove IPsec, it just avoids tuning for a workload that is not there.

**Root password.** Left blank to keep the password set during install.

After Reload, the dashboard came up fully.

*Working firewall: WAN <OPNSENSE_WAN_IP>, LAN <OLD_LAB_LAN_IP>, all services green, timezone correct.*

---

## Part 4: Redesigning the lab network

The plan was to put the machines to be monitored behind OPNsense so their traffic crosses the firewall. Two decisions shaped this.

**Decision one: what moves inside.** After weighing it, the Wazuh server stays where it is at <WAZUH_IP> on the NAT network, because moving it would change its address and force all agents to be repointed, with real risk to a working SIEM. Kali and the Mac stay outside as attacker and admin. Only the sensor and a target machine move inside. This is the attacker outside, victim inside layout.

**Decision two: the subnet.** The intended LAN was <HOME_LAN_SUBNET>, but a check on the Mac revealed the Mac's own home network already uses <HOME_LAN_SUBNET>:

```
ifconfig | grep "inet 192.168"
```

That returned a <HOME_LAN_IP> address on the Mac's real interface. Putting the lab on <HOME_LAN_SUBNET> too would give the Mac two interfaces on the same subnet and break its routing. So the lab moved to **<LAB_LAN_CIDR>**, which sits outside the 192.168 space entirely.

New addressing: OPNsense LAN <OPNSENSE_LAN_IP>, Mac <MAC_LAN_IP>, and static addresses for the machines inside.

**Moving OPNsense's LAN.** Interfaces, LAN, set the IPv4 address to <OPNSENSE_LAN_IP>/24.

*LAN moved to <OPNSENSE_LAN_IP>, gateway rules disabled, since the LAN is the inside.*

**The Fusion network problem.** The private network in Fusion, "Private to my Mac", had no editable fields at all, only an MTU dropdown. It cannot set a subnet or connect the host, so it was useless for this.

*This built in private network has no subnet or DHCP options.*

The fix was a new custom network. Fusion, Settings, Network, the plus button, which created vmnet2 with real fields: Subnet IP <LAB_LAN_NET>, mask 255.255.255.0, and Connect the host Mac ticked.

*The new custom network vmnet2, the one the lab machines attach to.*

**A Fusion quirk worth knowing.** The goal was to turn Fusion's own DHCP off so OPNsense would be the only DHCP server. But on this Fusion build, unticking "Provide addresses on this network via DHCP" greys out the Subnet IP field and shows "Auto-Generated". This build ties the ability to set a subnet to having DHCP on.

*Unticking DHCP removes the ability to choose the subnet on this version.*

The resolution: keep Fusion's DHCP on so the subnet stays <LAB_LAN_NET>, but do not rely on it. Every lab machine gets a static address by hand pointing at OPNsense as its gateway. Static addressing avoids the two DHCP servers fighting, and the Mac gets its <MAC_LAN_IP> from the "connect the host" setting, not from DHCP.

After applying, the Mac had a foot on the lab network and reached OPNsense:

```
ifconfig | grep "inet 10.10"
ping -c 3 <OPNSENSE_LAN_IP>
```

The Mac showed <MAC_LAN_IP> and the ping to <OPNSENSE_LAN_IP> answered, which closed this phase.

---

## Part 5: An accidental shutdown

While moving between terminals, `sudo shutdown now` was run in the OPNsense console by mistake, which powered the firewall off. The browser then could not reach it.

*Not a fault, the VM was simply off.*

The fix was to start the OPNsense VM again from Fusion. Lesson: a clean halt from the GUI (Power, Halt system) or the console power option is the safe way, and typing shutdown in the wrong terminal is easy to do with several sessions open.

---

## Part 6: The network sensor and the promiscuous mode wall

The original plan was for a dedicated sensor VM to run Suricata and Zeek and sniff the LAN in promiscuous mode. The sensor kept its management adapter on the NAT network and got a second adapter on vmnet2 for monitoring, with a static <VICTIM_IP> on that interface and deliberately no gateway, so the management interface kept the default route and SSH stayed working.

The problem: in promiscuous mode the sensor saw only its own traffic plus broadcast and multicast, never the unicast traffic between other machines. A network sensor is useless if it cannot see the traffic it is meant to watch.

Attempts, all of which failed to fix it:

1. Setting `ethernet1.noPromisc = "FALSE"` in the VM's vmx file. This allows the guest to request promiscuous mode, but did not make the switch flood unicast to it.
2. The Fusion "Require authentication to enter promiscuous mode" checkbox, which governs the password prompt but not the flooding.

*Turning this off permits promiscuous mode but does not make the switch mirror unicast.*

3. Creating the system authorization file that VMware's own engineering documents as required for VMs to see inter VM traffic on macOS:

```
sudo touch "/Library/Preferences/VMware Fusion/promiscAuthorized"
```

After this file was created and Fusion networking restarted, the sensor did start seeing more, but a careful test proved the limit precisely. Running a capture on the sensor while pinging from the Mac:

```
sudo tcpdump -ni ens37 icmp
```

showed the sensor seeing multicast from the Mac, but never the unicast ICMP between the Mac and OPNsense. So on this Fusion networking backend, the virtual switch delivers broadcast and multicast to a promiscuous port but does not mirror unicast between two other machines. This is a documented limitation, confirmed by research and by direct test, not a configuration mistake.

**Decision:** stop trying to sniff, and run the network detection on OPNsense itself. OPNsense is the one machine every packet of lab traffic passes through as the gateway, so it inspects all of it, unicast included, natively, with no promiscuous mode and no mirroring. This is a standard way to run network detection.

---

## Part 7: Suricata on OPNsense (the pivot that worked)

Suricata is built into OPNsense, under Services, Intrusion Detection. No plugin to install.

**Step 1: relax interface offloading.** Interfaces, Settings. Tick the boxes that disable hardware checksum, TCP segmentation, and large receive offload. On virtual NICs these features make the engine see merged packets, so turning them off gives clean inspection.

*Hardware offloading disabled for clean packet inspection.*

**Step 2: enable Intrusion Detection.** Services, Intrusion Detection, Administration, Settings tab. Enabled ticked, Capture mode PCAP live mode (IDS) which is detection only, Promiscuous mode ticked, Interface LAN, Pattern matcher Hyperscan. The Home networks field already covered 10.0.0.0/8, which includes the lab.

*Detection only mode on the LAN interface, the side the victim traffic crosses.*

**Step 3: logging.** In the Logging section, tick **Enable eve syslog output**, which is the path to forward alerts into Wazuh later.

*Eve syslog output on, so alerts can reach the SIEM.*

**Step 4: rulesets.** The Download tab lists rules as dozens of separate categories, all showing not installed. Enabling every one would flood a small box and cause false positives, so a lean set was picked: the ET open categories for scan, exploit, attack response, malware, web server and web specific apps, dns, and user agents, plus the small abuse.ch feeds.

*A focused ruleset rather than everything.*

**Step 5: RAM and richer logging.** Suricata prefers around 4 GB of RAM and the OPNsense VM had 2 GB. It was shut down cleanly (Power, Halt system), given 4096 MB in Fusion, and started again. With the headroom, the richer eve HTTP and TLS logging was turned on, which records the URLs and TLS certificates a host touches. After the restart the service showed running with rules loaded.

---

## Part 8: Converting the sensor into victim01

With detection now on OPNsense, the sensor VM was repurposed as the victim, avoiding building a fresh machine.

Suricata and Zeek were stopped on the box, since detection lives on OPNsense now. The networking was reworked so the LAN interface became the only active one, with OPNsense as the gateway, making it a true victim whose traffic crosses the firewall. The netplan file gave ens37 the static address and gateway, and disabled ens33:

```
network:
  ethernets:
    ens33:
      dhcp4: false
      dhcp6: false
      optional: true
    ens37:
      dhcp4: false
      dhcp6: false
      addresses:
        - <VICTIM_IP>/24
      routes:
        - to: default
          via: <OPNSENSE_LAN_IP>
      nameservers:
        addresses:
          - <OPNSENSE_LAN_IP>
          - 8.8.8.8
  version: 2
```

Because changing the default route drops the current SSH session, the change was applied from a second Mac terminal connected to the new address at <VICTIM_IP>, which survives the switch.

**The reply-to problem.** After the switch, the victim could not ping OPNsense and could not route out to the internet or the Wazuh server. The firewall and NAT were both correct, so the cause was something more specific.

The LAN allow rule was present:

*The LAN pass rule exists and is enabled, so the firewall was not the block.*

Source NAT was already on Automatic, so it was translating the <LAB_LAN_CIDR> network:

*NAT was correct too, so translation was not the block.*

The deciding test: OPNsense's own Ping tool reached the victim with zero loss.

*OPNsense could reach the victim, so the link worked both ways. OPNsense was receiving the victim's packets but not replying.*

The explanation: the victim uses OPNsense as its default gateway, so its traffic is routed traffic. OPNsense's reply handling, the reply-to feature, mishandles replies to a client that uses it as a gateway on a freshly built LAN. The Mac never hit this because the Mac does not route through OPNsense.

The fix was to disable reply-to on the LAN rule itself, which is different from the WAN setting tried earlier. Firewall, Rules, LAN, edit the default rule, advanced mode, Source Routing section, tick **Disable reply-to**, with Gateway None and Reply-to None.

*Disable reply-to on the LAN rule, which lets OPNsense answer a gateway client.*

After applying, the victim reached both the internet and the Wazuh server:

```
ping -c 3 8.8.8.8
ping -c 3 <WAZUH_IP>
```

Both answered with zero loss. The TTL values, 127 to the internet and 63 to the Wazuh server, confirmed the packets passed through OPNsense as a router hop. The inside path was proven.

**Agent through the firewall.** The victim's Wazuh agent, which had reached the manager over the old NAT path, reconnected over the new path through OPNsense. In the dashboard the agent returned to active at its new address.

*Agent 003 now at <VICTIM_IP>, active, reporting to the server through the firewall. All three agents active.*

The box was renamed:

```
sudo hostnamectl set-hostname victim01
sudo systemctl restart wazuh-agent
```

---

## Part 9: First Suricata alert on live traffic

Before any attack, the victim's own outbound package traffic tripped a rule on its own. In Services, Intrusion Detection, Log File, an alert appeared.

*An ET INFO alert on the victim's APT traffic, with the full HTTP detail parsed. Network detection working end to end.*

The alert shows src_ip <VICTIM_IP> (the victim), the signature "ET INFO GNU/Linux APT User-Agent Outbound likely related to package management", and the parsed HTTP fields including the hostname archive.ubuntu.com and the user agent. The `in_iface: em1` confirms Suricata saw it on the LAN interface. Both the network detection and the richer HTTP logging were working.

---

## Part 10: Attacker versus victim (the Kali attack)

Kali sits on the WAN side network (<LAB_INFRA_CIDR>) and the victim is at <VICTIM_IP> on the LAN. For Kali to reach the victim, its traffic must cross OPNsense, which is exactly where Suricata inspects it. Two changes are needed, plus a route on Kali.

**A WAN rule to allow Kali to the victim.** By default OPNsense blocks WAN to LAN.

**The mistake:** the rule was first built with **Invert Source** ticked, which reverses the meaning to "from everything except this source". That had to be unticked.

*Invert Source ticked reverses the rule. It must be off.*

Also, this OPNsense version does not let you type a host address into the Source field, only pick from a list. So instead of pinning exact hosts, the rule used the named options: Source WAN network, Destination LAN network, which for a closed lab is fine.

*Pass from WAN network to LAN network, Invert Source unticked.*

**A route on Kali.** Kali's default gateway knows nothing about <LAB_LAN_CIDR>, so Kali needs a route to the victim's network through OPNsense's WAN address:

```
sudo ip route add <LAB_LAN_CIDR> via <OPNSENSE_WAN_IP>
ip route | grep <LAB_LAN_NET>
```

*The route via <OPNSENSE_WAN_IP>, out Kali's eth0.*

**The scan.** From Kali:

```
sudo nmap -sS -T4 -p 1-1000 <VICTIM_IP>
```

The scan ran and found port 22 open, but it completed in under a second. That is a factor in what followed.

---

## Part 10b: Why the scan did not alert (in progress)

The scan produced no alert in the log, and working out why exposed several things.

**The severity filter.** The Log File view defaults to showing only Emergency, Alert, and Critical. Scan and info alerts are lower severity, so they are hidden. The filter had to be opened to all levels.

*All severity levels selected, so nothing is filtered out.*

**No Alerts tab and no Policy.** This version has no separate Alerts tab, only Log File. The Policy list was also empty, which is normal, since a Policy is optional and only overrides rule actions in bulk. Rules still run with their default action of alert without a policy, so an empty policy does not stop detection.

*An empty policy list is normal and does not prevent alerts.*

**Ground truth from the shell.** SSH was enabled on OPNsense (System, Settings, Administration, Secure Shell, permit root and password login), and the shell showed the real state:

```
pgrep -f suricata
grep -c '"event_type":"alert"' /var/log/suricata/eve.json
tail -n 3 /var/log/suricata/eve.json
```

These confirmed Suricata was running and had 31 alerts on disk, the newest being the earlier APT alert. So the engine works, and the scan simply did not trip a rule.

**The likely cause, still being confirmed.** Two things point at why a real scan was quiet. First, the scan was very fast and small, a thousand ports in under a second against a mostly closed host, which can slip under the scan rule threshold. Second, and more likely, the specific scan detection ruleset (ET open/emerging-scan) may not have been among the focused set enabled earlier, in which case no port scan can alert at all. The next step is to confirm that ruleset is installed on the Download tab, enable it if not, and rerun a louder scan such as:

```
sudo nmap -sS -T4 -p- <VICTIM_IP>
```

which scans all 65535 ports for a much stronger signature.

---

## Where the build stands

Working:

- OPNsense firewall installed, configured, and reachable from the Mac, with permanent GUI access.
- The lab network moved to <LAB_LAN_CIDR> with the Mac and OPNsense on it, and static addressing on the machines inside.
- A victim (victim01) fully behind the firewall, routing all traffic through OPNsense, reaching the internet and the Wazuh server, and still monitored by its Wazuh agent through the firewall.
- Suricata running on OPNsense, inspecting the victim's traffic, alerting on live traffic, with rich HTTP and TLS logging.
- Three Wazuh agents active: Kali, the Mac, and victim01.

Pending:

- Confirming and enabling the scan detection ruleset so the Kali scan fires an alert.
- Forwarding Suricata's eve output into Wazuh so network alerts land in the SIEM alongside the endpoint data.
- Connecting the agent brain for triage.

---

## Lessons from the hard parts

**The Fusion promiscuous limit.** On this Fusion networking backend on macOS, a virtual switch delivers broadcast and multicast to a promiscuous port but does not mirror unicast between two other machines. A passive sniffing sensor cannot see the traffic it needs. Running detection on the firewall, which every packet crosses as the gateway, sidesteps this entirely.

**The reply-to gateway issue.** A machine that uses OPNsense as its default gateway can fail to get replies until reply-to is disabled on the LAN rule. The tell is that OPNsense can ping the machine but the machine cannot ping OPNsense, while the firewall and NAT are both correct.

**The subnet clash.** Check the Mac's own networks before choosing a lab subnet. If the home network uses <HOME_LAN_SUBNET>, the lab must not, or the Mac's routing breaks. Using <LAB_LAN_CIDR> avoids the common 192.168 ranges.

**The Fusion DHCP and subnet coupling.** On this Fusion build, you cannot set a custom subnet with Fusion's DHCP off. Keeping Fusion DHCP on but assigning static addresses to the machines, pointing at OPNsense as the gateway, works around it.

---

## Quick reference

**Temporary GUI access from the console**
```
pfctl -d
```

**Add a route on Kali to the victim network**
```
sudo ip route add <LAB_LAN_CIDR> via <OPNSENSE_WAN_IP>
```

**Shell checks on OPNsense**
```
pgrep -f suricata
grep -c '"event_type":"alert"' /var/log/suricata/eve.json
tail -n 3 /var/log/suricata/eve.json
```

**Addresses**

| Machine | Address | Where |
|---|---|---|
| OPNsense WAN | <OPNSENSE_WAN_IP> | NAT side, faces the Mac and internet |
| OPNsense LAN | <OPNSENSE_LAN_IP> | Inside, the gateway for the lab |
| Mac | <MAC_LAN_IP> | On the lab network, plus its own home network |
| victim01 | <VICTIM_IP> | Behind the firewall |
| Wazuh server | <WAZUH_IP> | Stays on the NAT side, unchanged |
| Kali | <ATTACKER_IP> | Outside, the attacker |
