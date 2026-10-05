# Cold-start checklist

After any Mac restart or long sleep. A cold start looks exactly like total failure for the first few minutes. Wait, then check from the bottom up.

1. Start the VMs in this order: OPNsense, Wazuh, services01, victim01, Kali.
2. Wait about 5 minutes. Cassandra, the indexer and the agents reconnect slowly.
3. On services01:
   ```bash
   cd ~/soc-stack && docker compose start
   docker exec cassandra nodetool status        # UN = up and normal
   docker compose ps                            # six services Up
   ```
4. On the Wazuh manager:
   ```bash
   sudo /var/ossec/bin/agent_control -l         # 000-003 Active
   ```
   If victim01 (003) is disconnected, on victim01: `sudo systemctl restart wazuh-agent`.
5. On OPNsense: `tail -1 /var/log/suricata/eve.json` shows a recent timestamp.
6. On Kali: `ip route | grep <LAB_LAN_NET>` shows the route via <OPNSENSE_WAN_IP>.
7. From the Mac: `scripts/healthcheck.sh` (pings every machine and opens every web interface).
8. Test scan from Kali, with a port you have not used recently (identical alerts are suppressed):
   ```bash
   sudo nmap -sS -p<NEW_PORT> <VICTIM_IP>
   ```
9. A new `[suricata] ...` case appears in TheHive: New, unassigned, with the L1 comment.

If step 9 fails, work back up the chain in [troubleshooting](../07-troubleshooting/README.md#where-did-the-alert-stop): eve.json on OPNsense, alerts.log on the manager, n8n Executions, TheHive.
