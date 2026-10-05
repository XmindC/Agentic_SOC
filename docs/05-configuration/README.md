# Configuration

Every configuration file in [configs/](../../configs/), what it does, where it goes, how to test it and how to undo it. `install.sh` applies most of them; this page is for doing it by hand, changing one, or understanding what the installer did.

Rule for every change: back up the file first (`sudo cp -p FILE FILE.bak-$(date +%Y%m%d)`), test before restarting, and keep the diff.

## Wazuh manager

| File in repo | Goes to | What it does |
|---|---|---|
| `wazuh/decoders/suricata-opnsense.xml` | append to `/var/ossec/etc/decoders/local_decoder.xml` | Matches syslog program `suricata`, hands the JSON payload to the JSON decoder |
| `wazuh/decoders/mac-dns.xml` | same file | Parses tcpdump query lines from the Mac (`srcip, dstip, dns_type, dns_query`); responses do not match, so one event per lookup |
| `wazuh/rules/100200-suricata-opnsense.xml` | append to `/var/ossec/etc/rules/local_rules.xml` | 100200 L0 parent, 100201 L5 any Suricata alert, 100202 L10 reconnaissance. Descriptions carry `$(hostname) $(in_iface)` |
| `wazuh/rules/100300-mac-dns.xml` | same file | Mac DNS query, level 3. Keep it below 5 |
| `wazuh/rules/100310-zeek-conn.xml` | same file | Zeek connection record, level 3, matched on Zeek's own `uid` and `conn_state` fields |
| `wazuh/rules/100311-zeek-ntp-silence.xml` | same file | Child of 100310 at level 0 for udp/123 |
| `wazuh/ossec-remote-syslog.xml` | inside `<ossec_config>` in `/var/ossec/etc/ossec.conf` | UDP 514 listener, `allowed-ips` = OPNsense only |
| `wazuh/ossec-integration-n8n.xml` | same | Every alert level 5 and above, all agents, JSON, to the n8n webhook |
| `wazuh/integrations/custom-n8n` | `/var/ossec/integrations/custom-n8n`, root:wazuh 750 | `curl` POST of the alert file to the hook URL |

Groups in `local_rules.xml` must be siblings. A `<group>` left open around another group breaks matching without an error.

Test and apply:

```bash
sudo /var/ossec/bin/wazuh-logtest             # paste one real log line; check phases 1-3
sudo /var/ossec/bin/wazuh-analysisd -t && echo OK
sudo /var/ossec/bin/wazuh-integratord -t && echo OK
sudo systemctl restart wazuh-manager && sudo systemctl is-active wazuh-manager
```

`wazuh-logtest` is the most useful diagnostic here: it shows decoding and rule matching for one message without a restart or live traffic.

Rollback: restore the `.bak` files and restart the manager.

## Wazuh agents

| File in repo | Goes to | What it does |
|---|---|---|
| `wazuh/agent-fim-linux-persistence.xml` | inside `<syscheck>`, Linux agents | `.ssh` folders of every login account, `known_hosts` ignored |
| `wazuh/agent-localfile-zeek.xml` | inside `<ossec_config>`, victim01 | Reads `/opt/zeek/logs/current/conn.log` as JSON |
| `macos/ossec-fim-launch-folders.xml` | inside `<syscheck>`, Mac agent | LaunchDaemons and LaunchAgents |
| `macos/ossec-localfile-dns.xml` | inside `<ossec_config>`, Mac agent | Reads `/var/log/dns-queries.log` |

Test: `sudo /var/ossec/bin/wazuh-logcollector -t` (Mac: `/Library/Ossec/bin/...`), then restart the agent. Paths only leave the machine; `report_changes` is off, so file contents never do.

## OPNsense and Suricata

| File in repo | Goes to | What it does |
|---|---|---|
| `suricata/soc-lab-netvars.yaml.example` | `/usr/local/etc/suricata/conf.d/soc-lab-netvars.yaml` | HOME_NET both lab segments, EXTERNAL_NET any. Must be a full copy of the generated `vars` block |

Test: `/usr/local/bin/suricata -T -c /usr/local/etc/suricata/suricata.yaml && echo CONFIG_OK`, then `configctl ids restart`. Rollback: delete the drop-in and restart. GUI settings are listed in [the install guide](../04-installation/03-opnsense-suricata.md). The full story is in [reference/opnsense-network-and-suricata.md](reference/opnsense-network-and-suricata.md).

## Zeek (victim01)

| File in repo | Goes to |
|---|---|
| `zeek/node.cfg` | `/opt/zeek/etc/node.cfg` (`${ZEEK_INTERFACE}` filled in) |
| `zeek/local.zeek.append` | appended to `/opt/zeek/share/zeek/site/local.zeek` |
| `zeek/zeek.cron` | `/etc/cron.d/zeek`, root 644 |

Test: `sudo /opt/zeek/bin/zeekctl check`, apply with `sudo /opt/zeek/bin/zeekctl deploy`.

## Services stack (services01)

| File in repo | Goes to |
|---|---|
| `docker/docker-compose.yml` | `~/soc-stack/docker-compose.yml` |
| `docker/cortex-application.conf` | `/opt/cortex/application.conf` |
| `docker/no-responders.json` | `/opt/cortex/no-responders.json` |

Test: `docker compose config --quiet && echo FILE OK`. Apply one service at a time: `docker compose up -d <service>`. A container whose definition did not change is not restarted by `up -d`; use `docker compose restart <service>` after changing a mounted config file.

## n8n

| File in repo | What |
|---|---|
| `n8n/wazuh-alert-pipeline.workflow.json` | The whole pipeline, credentials replaced by placeholders |
| `n8n/normalize.js` | The Normalize Code node (also inside the workflow) |
| `n8n/code-nodes/*.js` | Every other Code node, readable on its own |

Before changing the live workflow, export it (workflow menu > Download, or `docker exec n8n n8n export:workflow --all --output=/home/node/.n8n/backup-$(date +%Y%m%d).json`). Fetch the current version right before any API update: the owner also edits in the UI, and an update built from a stale copy overwrites their changes.

Settings worth knowing:

- Filter: `rule_level >= 5 AND (not group ossec OR (group syscheck AND file on a persistence path))`. The persistence regex is in the Filter node and in [the runbook](../06-operations/change-runbook-2026-09-30.md).
- Escalate?: `(level >= 10 AND (AI severity high/critical OR group authentication_failures)) OR Suricata alert severity 1`.
- OpenAI Chat Model: gpt-4o-mini, temperature 0.2, Responses API off.

Observable creation, the TheHive node choices and TLP/PAP are covered in [reference/n8n-thehive-observables.md](reference/n8n-thehive-observables.md).

## Read-only access to Wazuh alerts

See [readonly-indexer-user.md](readonly-indexer-user.md).
