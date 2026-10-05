# Operations

| Document | Use it when |
|---|---|
| [cold-start-checklist.md](cold-start-checklist.md) | The Mac restarted or woke from sleep |
| [validation-tests.md](validation-tests.md) | You changed something and need to prove the pipeline still works end to end |
| [known-behaviours.md](known-behaviours.md) | Something looks wrong but may be normal |
| [suricata-housekeeping.md](suricata-housekeeping.md) | Rule 2009582 self-repair cron, eve.json watchdog, packet-drop tuning, sensor tags |
| [change-runbook-2026-09-30.md](change-runbook-2026-09-30.md) | The full record of the 30 Sep to 2 Oct 2026 change set: full-fleet ingestion, DNS visibility, email escalation, FIM, Zeek, with every backup and rollback |

## How changes are made in this lab

1. Back up the file or export the workflow before touching it.
2. Change one thing.
3. Test the configuration before restarting (`wazuh-analysisd -t`, `suricata -T`, `zeekctl check`, `docker compose config`).
4. Restart and validate with a real event.
5. Write down the diff, the backup path and the rollback command.

When root is needed for an assistant or a script, use a temporary sudoers rule limited to the exact commands (`/etc/sudoers.d/<name>`, mode 440), and delete it when the work is done.

## Housekeeping jobs that run on their own

| Where | Job | Schedule |
|---|---|---|
| OPNsense | Re-enable sid 2009582 after rule updates (`/root/fix_suricata_rules.sh`) | every 6 hours and at boot |
| OPNsense | Restart Suricata if `eve.json` is stale for over 6 hours (`/root/check_eve.sh`) | every 2 hours and at boot |
| victim01 | `zeekctl cron` (restart if down, rotate logs) | every 5 minutes |
| Wazuh agents | File-integrity scan | every 12 hours |
| Wazuh manager | rootcheck, SCA and wazuh-db backup | daily about 03:27 UTC |

After an OPNsense firmware update, check that `crontab -l` still has both jobs.
