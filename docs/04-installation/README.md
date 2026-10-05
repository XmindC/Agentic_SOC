# Installation

Build the machines in this order. Each guide ends with a check; do not start the next machine until the check passes.

| Step | Guide | Machine | Installer role | Time |
|---|---|---|---|---|
| 1 | [Host and networks](01-host-and-network.md) | Mac | manual | 30 min |
| 2 | [Wazuh server](02-wazuh-server.md) | Wazuh VM | `sudo ./install.sh wazuh` | 30 min |
| 3 | [OPNsense and Suricata](03-opnsense-suricata.md) | OPNsense VM | `./install.sh opnsense` (prints steps) | 60 min |
| 4 | [Services stack](04-services-stack.md) | services01 | `sudo ./install.sh services` | 40 min |
| 5 | [n8n pipeline](05-n8n-pipeline.md) | services01 | `sudo ./install.sh workflow` | 30 min |
| 6 | [Endpoints](06-endpoints.md) | victim01, Kali | `sudo ./install.sh agent <name>` | 10 min each |
| 7 | [Zeek sensor](07-zeek-sensor.md) | victim01 | `sudo ./install.sh sensor` | 15 min |
| 8 | [Mac DNS logger](08-mac-dns-logger.md) | Mac | `sudo ./install.sh mac-dns` | 10 min |
| 9 | [Validation](../06-operations/validation-tests.md) | Kali | manual | 15 min |

## The installer

`install.sh` is one script for the whole lab. Copy the repository to each machine (or clone it there), put the same `.env` next to it, and run the role for that machine.

```bash
cp .env.example .env && chmod 600 .env   # fill in every <PLACEHOLDER> that your role needs
./install.sh preflight                   # validates .env and pings every machine
sudo ./install.sh <role> --dry-run       # shows every command without changing anything
sudo ./install.sh <role>
```

What it does for you, and what it leaves alone:

| Role | Automates | Still manual |
|---|---|---|
| `wazuh` | All-in-one install, Suricata/Mac/Zeek decoders and rules, syslog listener for OPNsense, n8n integration and script, config test, rollback on failure, restart | Storing the admin password, the index retention policy |
| `services` | Docker, Cortex folders and config, compose file, generated secrets, staged start (proxy, databases, TheHive and Cortex, n8n) | First-run screens of n8n, TheHive and Cortex, the TheHive licence, Cortex users and analyzer keys |
| `workflow` | Imports the pipeline with your services address and alert email filled in | Creating the five n8n credentials, activating the workflow |
| `agent` | Wazuh apt repo, agent pinned to the manager's version, SSH persistence FIM | nothing |
| `sensor` | Zeek packages, interface, JSON logs, "_" field names, 7-day expiry, cron, Wazuh agent reads conn.log | nothing (Ubuntu versions without Zeek packages need a source build) |
| `mac-dns` | launchd DNS logger, log rotation, Mac agent reads the log | Installing the Mac Wazuh agent from the dashboard first |
| `opnsense` | prints the steps | the whole OPNsense install (FreeBSD console and GUI) |

Every role is safe to rerun: it skips what is already there, backs up each file it edits as `<file>.bak-<timestamp>`, and for Wazuh tests the configuration before restarting and restores the backups if the test fails.

## Before you start

- Intel Mac with 64 GB RAM (32 GB works with fewer VMs running), about 150 GB free disk, VMware Fusion.
- ISOs: [Ubuntu Server](https://ubuntu.com/download/server) (amd64), [OPNsense](https://opnsense.org/download/) (amd64 DVD image), [Kali](https://www.kali.org/get-kali/).
- Free accounts and API keys: [OpenAI](https://platform.openai.com), [AbuseIPDB](https://www.abuseipdb.com), [VirusTotal](https://www.virustotal.com). A Gmail account with 2-Step Verification for the escalation email (it needs an App Password).
- A password manager. Every password the installers print goes there, not into the repository.

## Background reading

The original build notes, with every command and the reasoning behind it:

- [reference/infrastructure-build-guide.md](reference/infrastructure-build-guide.md) the first per-machine build guide
- [reference/opnsense-vm-install.md](reference/opnsense-vm-install.md) the OPNsense console install, step by step
- [reference/cortex-with-docker-socket-proxy.md](reference/cortex-with-docker-socket-proxy.md) Cortex, its organisations and users, and the Docker socket problem
