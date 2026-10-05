# Read-only indexer user

Lets a person or an assistant query Wazuh alerts without root on the manager and without the dashboard admin account.

The indexer listens on `127.0.0.1:9200` on the manager only. Keep it that way: query it over SSH as the normal lab user.

## Create the role and user

Wazuh dashboard > Indexer management > Security (or Dev Tools):

```
PUT _plugins/_security/api/roles/alerts_readonly
{
  "index_permissions": [
    { "index_patterns": ["wazuh-alerts-*"], "allowed_actions": ["read"] }
  ]
}

PUT _plugins/_security/api/internalusers/<WAZUH_INDEXER_RO_USER>
{ "password": "<WAZUH_INDEXER_RO_PASSWORD>" }

PUT _plugins/_security/api/rolesmapping/alerts_readonly
{ "users": ["<WAZUH_INDEXER_RO_USER>"] }
```

No cluster permissions, no tenant permissions. Type the password into the dashboard yourself; never put it in a file in this repository.

Check the saved pattern with `GET _plugins/_security/api/roles/alerts_readonly`. The dashboard form once saved it as `" wazuh-alerts-*"` with a leading space, which matched nothing.

## Use it without exposing the password

Put the credentials in `.env` (`WAZUH_INDEXER_USER`, `WAZUH_INDEXER_PASS`, mode 600) and pass them to curl on stdin, never on the command line:

```bash
printf '%s:%s\n' "$WAZUH_INDEXER_USER" "$WAZUH_INDEXER_PASS" \
  | ssh <LAB_USER>@<WAZUH_IP> bash -s < scripts/query-kali-40101.sh
```

Inside a script: `curl -sk -K <(printf 'user = "%s"\n' "$CRED") https://127.0.0.1:9200/wazuh-alerts-*/_search ...`

## Verify it is read-only

Expected: reads on `wazuh-alerts-*` succeed. Writes, `wazuh-states-*`, `.opendistro_security`, `_cluster/settings` and `_cat/indices` all return 403.

Query tips: `data.dns_query` is a keyword field (exact match); `full_log` is text.
