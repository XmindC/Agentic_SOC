# Zeek sensor

Machine: victim01. Installer role: `sensor`. Run it after the `agent` role.

Zeek records every connection on the protected segment. Wazuh indexes the records at level 3 (rule 100310), so they are searchable next to the alerts but never open a case or call the model.

## 1. Pick the interface

```bash
ip -br a
```

Use the interface that holds <VICTIM_IP> (`ens37` in the reference lab) and set `ZEEK_INTERFACE` in `.env`. The Zeek default `eth0` does not exist on these VMs; that mistake left Zeek installed but never running.

## 2. Install

```bash
sudo ./install.sh sensor
```

The script installs Zeek from the openSUSE Build Service repository for your Ubuntu version (packages install to `/opt/zeek`) and then:

| File | Change |
|---|---|
| `/opt/zeek/etc/node.cfg` | standalone, `interface=ZEEK_INTERFACE` |
| `/opt/zeek/share/zeek/site/local.zeek` | JSON logs, and `redef Log::default_scope_sep = "_";` |
| `/opt/zeek/etc/zeekctl.cfg` | `LogExpireInterval = 7day` (it was 0: logs grew forever) |
| `/etc/cron.d/zeek` | start at boot, `zeekctl cron` every 5 minutes |
| `/var/ossec/etc/ossec.conf` | a `<localfile>` reading `/opt/zeek/logs/current/conn.log` as JSON |

The `_` separator matters. With Zeek's default dotted names, `id.orig_h` becomes `data.id.orig_h` in Wazuh, which collides with `data.id` (mapped as keyword). The indexer then silently rejects every Zeek alert, while `wazuh-logtest` and the agent both look fine.

If the script reports no packages for your Ubuntu version, build from source following the [Zeek install guide](https://docs.zeek.org/en/master/install.html) with `--prefix=/opt/zeek`, then rerun the role: it skips the install and does the configuration.

## 3. Check

```bash
sudo /opt/zeek/bin/zeekctl status         # zeek standalone running
sudo tail -1 /opt/zeek/logs/current/conn.log   # one JSON record
```

On the manager, generate traffic from Kali (`curl http://<VICTIM_IP>`) and search the dashboard for `rule.id:100310`. NTP records are silenced by rule 100311 (level 0) but stay in Zeek's own log.
