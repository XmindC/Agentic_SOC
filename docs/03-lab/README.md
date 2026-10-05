# Lab

The single source of truth for addresses, accounts, services and working rules is [lab-reference.md](lab-reference.md). Read it before any change. This page is the summary.

## Address placeholders

This repository contains no real lab addresses. Every address is a placeholder named after its `.env` key. Fill in `.env` once; `install.sh`, `scripts/healthcheck.sh` and the L2 agent read the values from it, and the workflow import writes the subnets into the L1 prompt. When a document shows a placeholder in a command, type your own value.

| Placeholder | Machine or network | `.env` key |
|---|---|---|
| `<LAB_LAN_CIDR>` | Protected LAN behind OPNsense (vmnet2) | `LAB_LAN_CIDR` |
| `<LAB_INFRA_CIDR>` | VMware NAT segment with the SOC tooling | `LAB_INFRA_CIDR` |
| `<LAB_LAN_NET>` | Network address of the protected LAN (used in `grep` checks) | first three octets of `LAB_LAN_CIDR` |
| `<OPNSENSE_WAN_IP>` / `<OPNSENSE_LAN_IP>` | OPNsense em0 / em1 | `OPNSENSE_WAN_IP` / `OPNSENSE_LAN_IP` |
| `<WAZUH_IP>` | Wazuh server | `WAZUH_IP` |
| `<SERVICES_IP>` | services01 (n8n, TheHive, Cortex) | `SERVICES_IP` |
| `<VICTIM_IP>` | victim01 | `VICTIM_IP` |
| `<ATTACKER_IP>` | Kali | `ATTACKER_IP` |
| `<MAC_LAN_IP>` / `<MAC_NAT_IP>` | The Mac's addresses on the two networks | not needed by the installer |
| `<NAT_GATEWAY_IP>` | VMware NAT router (the .2 host of the NAT subnet by Fusion convention) | not needed by the installer |

Use private, non-overlapping subnets that do not clash with your home network.

## Machines and sizing

| Machine | Address | OS | RAM / vCPU / disk | Role |
|---|---|---|---|---|
| OPNsense | WAN <OPNSENSE_WAN_IP>, LAN <OPNSENSE_LAN_IP> | OPNsense 26.7 (FreeBSD) | 4 GB / 2 / 20 GB | Firewall, gateway, Suricata IDS on em0 and em1 |
| Wazuh | <WAZUH_IP> | Ubuntu Server | 8 GB / 4 / 80 GB | Manager, indexer, dashboard |
| services01 | <SERVICES_IP> | Ubuntu Server | 12 GB / 4 / 60 GB | Docker: n8n, TheHive, Cortex, Elasticsearch, Cassandra, dockerproxy |
| victim01 | <VICTIM_IP> | Ubuntu Server | 2 GB / 1 / 20 GB | Monitored target, Wazuh agent 003, Zeek on ens37 |
| Kali | <ATTACKER_IP> | Kali Linux | not recorded | Authorised attacker, Wazuh agent 001 |
| Mac host | <MAC_LAN_IP> / <MAC_NAT_IP> | macOS | 64 GB | VMware Fusion, Wazuh agent 002, passive DNS logger |

Fusion disks are thin, so the disk figure is a cap. Everything running at once uses about 30 GB of RAM. Give the Wazuh VM at least 80 GB: the default 31 GB root volume filled up once (see [wazuh-disk-full](../07-troubleshooting/cases/wazuh-disk-full.md)).

## Networks

| Network | Fusion name | Subnet | Who is on it |
|---|---|---|---|
| NAT ("Share with my Mac") | vmnet8 | <LAB_INFRA_CIDR> | OPNsense WAN, Wazuh, services01, Kali |
| Lab LAN (custom, host-connected) | vmnet2 | <LAB_LAN_CIDR> | OPNsense LAN, victim01, the Mac at <MAC_LAN_IP> |

Kali reaches <LAB_LAN_CIDR> through a persistent static route via <OPNSENSE_WAN_IP>. Check it after every Kali reboot with `ip route | grep <LAB_LAN_NET>10.10`.

## Web interfaces

| Service | URL | Login |
|---|---|---|
| Wazuh dashboard | https://<WAZUH_IP> | `admin`, password from the installer |
| OPNsense | https://<OPNSENSE_WAN_IP> | `root` |
| n8n | http://<SERVICES_IP>:5678 | owner account created on first visit |
| TheHive | http://<SERVICES_IP>:9000 | `<THEHIVE_ANALYST_USER>` |
| Cortex | http://<SERVICES_IP>:9001 | superadmin, org admin and API-only `n8n` user |

Passwords are in your password manager. API keys live in each service's own credential store, and the few the command-line tools need are in `.env`.

## Wazuh agents

| ID | Name | Machine |
|---|---|---|
| 000 | wazuhserver | the manager; Suricata alerts also show this name because they arrive by syslog |
| 001 | kali | Kali |
| 002 | MacOS | the Mac host |
| 003 | sensor | victim01 |

## Custom rule IDs

| ID | Level | Meaning |
|---|---|---|
| 100200 | 0 | Any Suricata event from OPNsense |
| 100201 | 5 | Suricata alert (opens a case) |
| 100202 | 10 | Suricata reconnaissance |
| 100300 | 3 | Mac DNS query (never a case) |
| 100310 | 3 | Zeek connection record (never a case) |
| 100311 | 0 | Zeek NTP, silenced |
