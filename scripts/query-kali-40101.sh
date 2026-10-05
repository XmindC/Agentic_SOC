#!/usr/bin/env bash
# Read-only query: Kali rule 40101/5301 alerts per day for the last 10 days (wazuh-alerts-* index).
# Run ON the Wazuh manager (the indexer listens on 127.0.0.1:9200 only), as the read-only user.
# The "user:password" pair is read from stdin so it never appears on a command line or in history:
#   printf "%s:%s\n" "$WAZUH_INDEXER_USER" "$WAZUH_INDEXER_PASS" | ssh <LAB_USER>@<WAZUH_IP> bash -s < scripts/query-kali-40101.sh
IFS= read -r CRED
B=https://127.0.0.1:9200
q(){ curl -sk -m 15 -K <(printf 'user = "%s"\n' "$CRED") "$@"; }
q -H 'Content-Type: application/json' "$B/wazuh-alerts-*/_search" -d '{"size":0,"query":{"bool":{"must":[{"term":{"agent.name":"kali"}},{"terms":{"rule.id":["40101","5301"]}},{"range":{"timestamp":{"gte":"now-10d"}}}]}},"aggs":{"per_day":{"date_histogram":{"field":"timestamp","calendar_interval":"day"},"aggs":{"rules":{"terms":{"field":"rule.id"}}}}}}' | python3 -c 'import sys,json; j=json.load(sys.stdin)
if "error" in j: print(j["error"]); sys.exit()
for b in j["aggregations"]["per_day"]["buckets"]:
    if b["doc_count"]: print(" ", b["key_as_string"][:10], b["doc_count"], {r["key"]:r["doc_count"] for r in b["rules"]["buckets"]})'
