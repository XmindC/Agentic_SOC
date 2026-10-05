#!/usr/bin/env bash
# Agentic SOC health check, run from the admin host (the Mac) after a cold start.
# Read-only: it only pings and opens web ports. Usage: scripts/healthcheck.sh [--env FILE]
# Mirrors docs/06-operations/cold-start-checklist.md. Wait ~5 minutes after starting the VMs.
set -uo pipefail

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[[ "${1:-}" == "--env" ]] && ENV_FILE="$2"
[[ -f "$ENV_FILE" ]] || { echo "No $ENV_FILE (copy .env.example)"; exit 1; }

get() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | sed 's/#.*//; s/[[:space:]]*$//'; }
OPN="$(get OPNSENSE_WAN_IP)"; WAZ="$(get WAZUH_IP)"; SVC="$(get SERVICES_IP)"; VIC="$(get VICTIM_IP)"

fail=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }

ping_host() { ping -c1 -W2 "$1" >/dev/null 2>&1 || ping -c1 -t2 "$1" >/dev/null 2>&1; }
http_code() { curl -sk -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null; }

echo "Hosts"
for pair in "OPNsense:$OPN" "Wazuh:$WAZ" "services01:$SVC" "victim01:$VIC"; do
  if ping_host "${pair#*:}"; then ok "${pair%%:*} ${pair#*:}"; else bad "${pair%%:*} ${pair#*:} (no ping)"; fi
done

echo "Web interfaces"
check_web() {  # name url
  local code; code="$(http_code "$2")"
  if [[ "$code" =~ ^(200|301|302|401|403)$ ]]; then ok "$1 $2 (HTTP $code)"; else bad "$1 $2 (HTTP ${code:-none})"; fi
}
check_web "Wazuh dashboard" "https://$WAZ"
check_web "OPNsense GUI"    "https://$OPN"
check_web "n8n"             "http://$SVC:5678/healthz"
check_web "TheHive"         "http://$SVC:9000/api/status"
check_web "Cortex"          "http://$SVC:9001/api/status"

cat <<EOF

Then by hand (needs shell access, see the checklist):
  services01  docker exec cassandra nodetool status        -> UN
  Wazuh       sudo /var/ossec/bin/agent_control -l         -> agents Active
  OPNsense    tail -1 /var/log/suricata/eve.json           -> a recent timestamp
  Kali        sudo nmap -sS -p<NEW_PORT> $VIC              -> new case in TheHive (vary the port)
EOF
exit "$fail"
