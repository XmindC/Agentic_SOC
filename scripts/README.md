# Scripts

| Script | Run from | What |
|---|---|---|
| `healthcheck.sh` | the Mac | Pings every lab machine and opens every web interface. Read-only |
| `query-kali-40101.sh` | piped to the Wazuh manager over SSH | Counts Kali rule 40101/5301 alerts per day with the read-only indexer user; credentials on stdin |
