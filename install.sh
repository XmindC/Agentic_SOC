#!/usr/bin/env bash
# Agentic SOC installer: one script, run once per machine with that machine's role.
#
#   ./install.sh preflight            any host: check .env and reach every lab machine
#   sudo ./install.sh wazuh           Wazuh server VM: all-in-one install + SOC decoders, rules, n8n integration
#   sudo ./install.sh services        services01: Docker + n8n, TheHive, Cortex, Elasticsearch, Cassandra
#   sudo ./install.sh workflow        services01: import the n8n alert pipeline (after "services")
#   sudo ./install.sh agent [NAME]    any Ubuntu/Debian endpoint (victim01, Kali): Wazuh agent + SSH persistence FIM
#   sudo ./install.sh sensor          victim01: Zeek on ZEEK_INTERFACE, conn.log shipped to Wazuh (after "agent")
#   sudo ./install.sh mac-dns         the macOS host: passive DNS logger feeding the Mac Wazuh agent
#        ./install.sh opnsense        prints the OPNsense + Suricata steps (GUI install, not scriptable)
#
# Options: --dry-run (print every command, change nothing), --env FILE (default: ./.env)
# Order for a new lab: opnsense -> wazuh -> services -> workflow -> agent (each endpoint) -> sensor -> mac-dns
# Full guide: docs/04-installation/README.md
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
DRY_RUN=0
STAMP="$(date +%Y%m%dT%H%M%S)"
ROLE=""
EXTRA=()

# ---------------------------------------------------------------- helpers
c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s!!%s  %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%sxx%s  %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# run CMD...: execute, or only print it with --dry-run
run() {
  if (( DRY_RUN )); then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}

usage() { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# Read KEY=VALUE lines from the env file without executing it (values may contain < or spaces).
load_env() {
  [[ -f "$ENV_FILE" ]] || die "No $ENV_FILE. Run: cp .env.example .env && chmod 600 .env, then fill it in."
  local perms
  if [[ "$(uname -s)" == "Darwin" ]]; then perms="$(stat -f '%Lp' "$ENV_FILE")"; else perms="$(stat -c '%a' "$ENV_FILE")"; fi
  [[ "$perms" == "600" || "$perms" == "400" ]] || warn "$ENV_FILE is mode $perms; run: chmod 600 $ENV_FILE"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                                   # strip comments
    [[ "$line" =~ ^[[:space:]]*([A-Z0-9_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"   # trim
    val="${val%\"}"; val="${val#\"}"
    export "$key=$val"
  done < "$ENV_FILE"
}

# require VAR...: each must be set and contain no unfilled <PLACEHOLDER>.
require() {
  local v missing=()
  for v in "$@"; do
    if [[ -z "${!v:-}" || "${!v}" == *"<"* ]]; then missing+=("$v"); fi
  done
  (( ${#missing[@]} == 0 )) || die "Fill these in $ENV_FILE first: ${missing[*]}"
}

need_root()   { (( DRY_RUN )) || [[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0 $ROLE"; }
need_linux()  { [[ "$(uname -s)" == "Linux" ]] || die "Role '$ROLE' runs on Ubuntu/Debian."; command -v apt-get >/dev/null || die "apt-get not found."; }
need_macos()  { [[ "$(uname -s)" == "Darwin" ]] || die "Role '$ROLE' runs on the macOS host."; }

# render FILE: substitute ${VARS} from the environment (only the variables named in the file)
render() {
  local vars
  vars="$(grep -o '\${[A-Z0-9_]*}' "$1" | sort -u | tr -d '\n')"
  envsubst "$vars" < "$1"
}

backup() {  # backup FILE -> FILE.bak-STAMP (preserving owner and mode)
  [[ -e "$1" ]] && run cp -p "$1" "$1.bak-$STAMP" && info "Backup: $1.bak-$STAMP"
  return 0
}

# insert_before_close FILE SNIPPET_TEXT: insert text before the FIRST </ossec_config>
insert_before_close() {
  local file="$1" snippet="$2" tmp
  if (( DRY_RUN )); then printf '    [dry-run] insert into %s:\n%s\n' "$file" "$snippet"; return; fi
  tmp="$(mktemp)"
  SNIP="$snippet" awk 'BEGIN{s=ENVIRON["SNIP"]} !done && /<\/ossec_config>/ {print s; done=1} {print}' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
}

append_once() {  # append_once FILE MARKER SOURCE: append SOURCE unless MARKER already present
  if grep -q -- "$2" "$1" 2>/dev/null; then info "Already present in $1: $2"; return; fi
  if (( DRY_RUN )); then printf '    [dry-run] append %s to %s\n' "$3" "$1"; return; fi
  { echo; cat "$3"; } >> "$1"
  info "Appended $(basename "$3") to $1"
}

# ---------------------------------------------------------------- roles
role_preflight() {
  load_env
  require LAB_LAN_CIDR LAB_INFRA_CIDR OPNSENSE_WAN_IP WAZUH_IP SERVICES_IP VICTIM_IP
  info "Env file: $ENV_FILE"
  local name ip
  for pair in "OPNsense:$OPNSENSE_WAN_IP" "Wazuh:$WAZUH_IP" "services01:$SERVICES_IP" "victim01:$VICTIM_IP"; do
    name="${pair%%:*}"; ip="${pair#*:}"
    if ping -c1 -W2 "$ip" >/dev/null 2>&1 || ping -c1 -t2 "$ip" >/dev/null 2>&1; then
      info "$name ($ip) answers ping"
    else
      warn "$name ($ip) does not answer. After a host restart, wait ~5 minutes before diagnosing."
    fi
  done
  local placeholders
  placeholders="$(grep -E '^[A-Z0-9_]+=.*<' "$ENV_FILE" | cut -d= -f1 | tr '\n' ' ' || true)"
  [[ -z "$placeholders" ]] && info "No unfilled placeholders" || warn "Still placeholders (fine if that role is not used here): $placeholders"
  info "Next: ./install.sh opnsense, then sudo ./install.sh wazuh on the Wazuh VM."
}

role_wazuh() {
  need_linux; need_root; load_env
  require WAZUH_VERSION SERVICES_IP OPNSENSE_WAN_IP
  command -v envsubst >/dev/null || run apt-get install -y gettext-base
  local OSSEC=/var/ossec

  if [[ -x "$OSSEC/bin/wazuh-control" ]]; then
    info "Wazuh already installed; skipping the all-in-one installer."
  else
    info "Installing Wazuh $WAZUH_VERSION all-in-one (manager, indexer, dashboard). Takes 10-20 minutes."
    run curl -fsSLo /tmp/wazuh-install.sh "https://packages.wazuh.com/${WAZUH_VERSION}/wazuh-install.sh"
    run bash /tmp/wazuh-install.sh -a
    warn "The admin password was printed above. Store it in your password manager, not in this repo."
    warn "Reprint it later with: sudo tar -O -xvf wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt"
  fi

  info "Applying Agentic SOC detection content."
  backup "$OSSEC/etc/ossec.conf"; backup "$OSSEC/etc/decoders/local_decoder.xml"; backup "$OSSEC/etc/rules/local_rules.xml"

  append_once "$OSSEC/etc/decoders/local_decoder.xml" 'name="suricata-opnsense"' "$REPO_DIR/configs/wazuh/decoders/suricata-opnsense.xml"
  append_once "$OSSEC/etc/decoders/local_decoder.xml" 'name="soc-mac-dns"'       "$REPO_DIR/configs/wazuh/decoders/mac-dns.xml"
  append_once "$OSSEC/etc/rules/local_rules.xml"      'id="100200"'              "$REPO_DIR/configs/wazuh/rules/100200-suricata-opnsense.xml"
  append_once "$OSSEC/etc/rules/local_rules.xml"      'id="100300"'              "$REPO_DIR/configs/wazuh/rules/100300-mac-dns.xml"
  append_once "$OSSEC/etc/rules/local_rules.xml"      'id="100310"'              "$REPO_DIR/configs/wazuh/rules/100310-zeek-conn.xml"
  append_once "$OSSEC/etc/rules/local_rules.xml"      'id="100311"'              "$REPO_DIR/configs/wazuh/rules/100311-zeek-ntp-silence.xml"

  if grep -q '<connection>syslog</connection>' "$OSSEC/etc/ossec.conf"; then
    info "Syslog listener already configured."
  else
    insert_before_close "$OSSEC/etc/ossec.conf" "$(render "$REPO_DIR/configs/wazuh/ossec-remote-syslog.xml")"
  fi
  if grep -q '<name>custom-n8n</name>' "$OSSEC/etc/ossec.conf"; then
    info "n8n integration already configured."
  else
    insert_before_close "$OSSEC/etc/ossec.conf" "$(render "$REPO_DIR/configs/wazuh/ossec-integration-n8n.xml")"
  fi
  run install -o root -g wazuh -m 750 "$REPO_DIR/configs/wazuh/integrations/custom-n8n" "$OSSEC/integrations/custom-n8n"

  info "Testing the configuration before restart."
  if (( ! DRY_RUN )) && ! "$OSSEC/bin/wazuh-analysisd" -t; then
    warn "wazuh-analysisd -t failed. Rolling back."
    for f in etc/ossec.conf etc/decoders/local_decoder.xml etc/rules/local_rules.xml; do
      [[ -e "$OSSEC/$f.bak-$STAMP" ]] && cp -p "$OSSEC/$f.bak-$STAMP" "$OSSEC/$f"
    done
    die "Restored the backups. Check the XML with: sudo $OSSEC/bin/wazuh-logtest"
  fi
  run systemctl restart wazuh-manager
  info "Done. Check: sudo $OSSEC/bin/agent_control -l ; sudo grep -i integrat $OSSEC/logs/ossec.log | tail"
  info "Dashboard: https://$WAZUH_IP (user admin). Set an index retention policy now: docs/04-installation/02-wazuh-server.md"
}

role_services() {
  need_linux; need_root; load_env
  require SERVICES_IP THEHIVE_IMAGE CORTEX_IMAGE CASSANDRA_IMAGE ELASTICSEARCH_IMAGE N8N_IMAGE DOCKERPROXY_IMAGE ELASTICSEARCH_HEAP CASSANDRA_HEAP
  local user="${SUDO_USER:-root}" home stack
  home="$(getent passwd "$user" | cut -d: -f6)"; stack="$home/soc-stack"

  if ! command -v docker >/dev/null; then
    info "Installing Docker Engine (official convenience script, downloaded then run)."
    run curl -fsSLo /tmp/get-docker.sh https://get.docker.com
    run sh /tmp/get-docker.sh
    run usermod -aG docker "$user"
    warn "$user was added to the docker group; log out and back in to use docker without sudo."
  fi
  command -v openssl >/dev/null || run apt-get install -y openssl

  info "Preparing Cortex folders (jobs owned by uid 1001, Cortex's user inside the container)."
  run mkdir -p /opt/cortex/jobs
  run chown -R 1001:1001 /opt/cortex/jobs
  run install -m 644 "$REPO_DIR/configs/docker/no-responders.json" /opt/cortex/no-responders.json
  run install -m 644 "$REPO_DIR/configs/docker/cortex-application.conf" /opt/cortex/application.conf

  info "Writing $stack (compose file + generated .env, mode 600)."
  run install -d -o "$user" -g "$user" "$stack"
  if [[ -f "$stack/docker-compose.yml" ]] && ! cmp -s "$stack/docker-compose.yml" "$REPO_DIR/configs/docker/docker-compose.yml"; then
    backup "$stack/docker-compose.yml"
    warn "An existing compose file was backed up. Compare it with the repo version before starting."
  fi
  run install -o "$user" -g "$user" -m 644 "$REPO_DIR/configs/docker/docker-compose.yml" "$stack/docker-compose.yml"

  # Reuse secrets from an earlier run so restarts don't invalidate sessions; generate when asked to.
  local th_secret="$THEHIVE_SECRET" cx_secret="$CORTEX_SECRET"
  if [[ -f "$stack/.env" ]]; then
    [[ "$th_secret" == "GENERATE" ]] && th_secret="$(grep -E '^THEHIVE_SECRET=' "$stack/.env" | cut -d= -f2- || true)"
    [[ "$cx_secret" == "GENERATE" ]] && cx_secret="$(grep -E '^CORTEX_SECRET=' "$stack/.env" | cut -d= -f2- || true)"
  fi
  [[ -z "$th_secret" || "$th_secret" == "GENERATE" ]] && th_secret="$(openssl rand -hex 32)"
  [[ -z "$cx_secret" || "$cx_secret" == "GENERATE" ]] && cx_secret="$(openssl rand -hex 32)"
  if (( DRY_RUN )); then
    printf '    [dry-run] write %s/.env (image tags, heap sizes, generated secrets)\n' "$stack"
  else
    umask 077
    cat > "$stack/.env" <<EOF
SERVICES_IP=$SERVICES_IP
THEHIVE_IMAGE=$THEHIVE_IMAGE
CORTEX_IMAGE=$CORTEX_IMAGE
CASSANDRA_IMAGE=$CASSANDRA_IMAGE
ELASTICSEARCH_IMAGE=$ELASTICSEARCH_IMAGE
N8N_IMAGE=$N8N_IMAGE
DOCKERPROXY_IMAGE=$DOCKERPROXY_IMAGE
ELASTICSEARCH_HEAP=$ELASTICSEARCH_HEAP
CASSANDRA_HEAP=$CASSANDRA_HEAP
THEHIVE_SECRET=$th_secret
CORTEX_SECRET=$cx_secret
EOF
    chown "$user:$user" "$stack/.env"; chmod 600 "$stack/.env"; umask 022
  fi

  # One service at a time: stacked faults with identical symptoms are what made this lab hard to debug.
  local dc=(docker compose --project-directory "$stack")
  run "${dc[@]}" config --quiet
  info "1/4 dockerproxy"; run "${dc[@]}" up -d dockerproxy
  info "2/4 cassandra + elasticsearch (Cassandra needs a minute or two)"; run "${dc[@]}" up -d cassandra elasticsearch
  if (( ! DRY_RUN )); then
    local _
    for _ in $(seq 1 30); do
      docker exec cassandra nodetool status 2>/dev/null | grep -q '^UN' && break
      sleep 10
    done
    docker exec cassandra nodetool status 2>/dev/null | grep -q '^UN' || warn "Cassandra not UN yet; TheHive may restart a few times until it is."
  fi
  info "3/4 thehive + cortex"; run "${dc[@]}" up -d thehive cortex
  info "4/4 n8n"; run "${dc[@]}" up -d n8n
  run "${dc[@]}" ps
  cat <<EOF

Next, in a browser (manual first-run steps, see docs/04-installation/04-services-stack.md):
  n8n      http://$SERVICES_IP:5678  create the owner account
  TheHive  http://$SERVICES_IP:9000  default admin login from StrangeBee docs; change it; request the free licence; create the analyst user
  Cortex   http://$SERVICES_IP:9001  press "Update database", create superadmin, org "soclab", orgadmin + API-only "n8n" user
Then: sudo ./install.sh workflow
EOF
}

role_workflow() {
  need_linux; need_root; load_env
  require SERVICES_IP ALERT_EMAIL LAB_LAN_CIDR LAB_INFRA_CIDR
  command -v docker >/dev/null || die "Docker not found; run the services role first."
  local tmp; tmp="$(mktemp)"
  # Fill the placeholders: the services address, the alert email, and the lab subnets in the L1 prompt.
  sed -e "s#<SERVICES_IP>#$SERVICES_IP#g" -e "s#<ALERT_EMAIL>#$ALERT_EMAIL#g" \
    -e "s#<LAB_LAN_CIDR>#$LAB_LAN_CIDR#g" -e "s#<LAB_INFRA_CIDR>#$LAB_INFRA_CIDR#g" \
    "$REPO_DIR/configs/n8n/wazuh-alert-pipeline.workflow.json" > "$tmp"
  run docker cp "$tmp" n8n:/tmp/agentic-soc-workflow.json
  run docker exec n8n n8n import:workflow --input=/tmp/agentic-soc-workflow.json
  run docker exec n8n rm -f /tmp/agentic-soc-workflow.json
  rm -f "$tmp"
  cat <<EOF

Imported (inactive). In n8n, create these credentials, attach them to the matching nodes, then activate:
  "The Hive 5 account"            TheHive API key of the n8n service account     (Create observable, Unassign Case, HTTP Request1)
  "TheHive Authorization header"  Header Auth: Authorization = Bearer <key>     (HTTP Request: create case)
  "Cortex account"                API key of the Cortex "n8n" user               (Execute an analyzer, Get Cortex Report)
  "OpenAI account"                OpenAI API key; model gpt-4o-mini, Responses API off
  "SMTP account"                  smtp.gmail.com:465 SSL + Gmail App Password    (Send Email)
Type every key into the n8n form yourself. Never into a file, a node field or chat.
Test: docs/06-operations/validation-tests.md
EOF
}

role_agent() {
  need_linux; need_root; load_env
  require WAZUH_IP WAZUH_VERSION
  local name="${EXTRA[0]:-$(hostname -s)}"
  if [[ -x /var/ossec/bin/wazuh-control ]]; then
    info "Wazuh agent already installed."
  else
    info "Installing the Wazuh agent ($name -> manager $WAZUH_IP)."
    run apt-get install -y curl gnupg apt-transport-https
    if (( DRY_RUN )); then
      printf '    [dry-run] add Wazuh apt key and repo\n'
    else
      curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
      chmod 644 /usr/share/keyrings/wazuh.gpg
      echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
    fi
    run apt-get update
    # The agent must not be newer than the manager.
    run env WAZUH_MANAGER="$WAZUH_IP" WAZUH_AGENT_NAME="$name" apt-get install -y "wazuh-agent=${WAZUH_VERSION}.*"
    run systemctl daemon-reload
    run systemctl enable --now wazuh-agent
  fi

  # Persistence FIM: every login account's .ssh folder, known_hosts ignored.
  local conf=/var/ossec/etc/ossec.conf dirs="/root/.ssh" h
  for h in /home/*; do [[ -d "$h" ]] && dirs+=",$h/.ssh"; done
  if grep -q '/root/.ssh' "$conf" 2>/dev/null; then
    info "SSH persistence FIM already configured."
  else
    backup "$conf"
    local snippet="  <syscheck>
    <directories>$dirs</directories>
    <ignore type=\"sregex\">/.ssh/known_hosts</ignore>
  </syscheck>"
    insert_before_close "$conf" "$snippet"
    run systemctl restart wazuh-agent
    info "FIM added for: $dirs (alerts start after the next scheduled scan; the first scan is a silent baseline)."
  fi
  info "Check on the manager: sudo /var/ossec/bin/agent_control -l   ($name should be Active)"
}

role_sensor() {
  need_linux; need_root; load_env
  require ZEEK_INTERFACE
  [[ -x /var/ossec/bin/wazuh-control ]] || die "Install the Wazuh agent first: sudo ./install.sh agent"
  ip link show "$ZEEK_INTERFACE" >/dev/null 2>&1 || die "Interface $ZEEK_INTERFACE does not exist here. Check 'ip -br a' and set ZEEK_INTERFACE in .env."
  command -v envsubst >/dev/null || run apt-get install -y gettext-base

  if [[ -x /opt/zeek/bin/zeekctl ]]; then
    info "Zeek already installed: $(/opt/zeek/bin/zeek --version 2>/dev/null || echo unknown)"
  else
    # shellcheck disable=SC1091
    . /etc/os-release
    local obs="https://download.opensuse.org/repositories/security:/zeek/xUbuntu_${VERSION_ID}"
    info "Installing Zeek from the openSUSE Build Service repo for Ubuntu $VERSION_ID."
    curl -fsI "$obs/Release.key" >/dev/null || die "No Zeek packages for Ubuntu $VERSION_ID at $obs. See docs/04-installation/06-zeek-sensor.md for a source build."
    if (( DRY_RUN )); then
      printf '    [dry-run] add Zeek apt key and repo %s\n' "$obs"
    else
      curl -fsSL "$obs/Release.key" | gpg --dearmor -o /usr/share/keyrings/zeek.gpg
      echo "deb [signed-by=/usr/share/keyrings/zeek.gpg] $obs/ /" > /etc/apt/sources.list.d/zeek.list
    fi
    run apt-get update
    run apt-get install -y zeek
  fi

  info "Configuring Zeek (interface $ZEEK_INTERFACE, JSON logs, '_' field names, 7-day log expiry)."
  backup /opt/zeek/etc/node.cfg
  if (( DRY_RUN )); then printf '    [dry-run] write /opt/zeek/etc/node.cfg\n'; else render "$REPO_DIR/configs/zeek/node.cfg" > /opt/zeek/etc/node.cfg; fi
  append_once /opt/zeek/share/zeek/site/local.zeek 'default_scope_sep' "$REPO_DIR/configs/zeek/local.zeek.append"
  backup /opt/zeek/etc/zeekctl.cfg
  run sed -i -E 's/^LogExpireInterval *=.*/LogExpireInterval = 7day/' /opt/zeek/etc/zeekctl.cfg
  run install -o root -g root -m 644 "$REPO_DIR/configs/zeek/zeek.cron" /etc/cron.d/zeek
  run /opt/zeek/bin/zeekctl check
  run /opt/zeek/bin/zeekctl deploy

  local conf=/var/ossec/etc/ossec.conf
  if grep -q '/opt/zeek/logs/current/conn.log' "$conf"; then
    info "Wazuh agent already reads conn.log."
  else
    backup "$conf"
    insert_before_close "$conf" "$(cat "$REPO_DIR/configs/wazuh/agent-localfile-zeek.xml")"
    run systemctl restart wazuh-agent
  fi
  info "Check: ls /opt/zeek/logs/current/conn.log ; on the manager search rule.id:100310 (level 3, never reaches n8n)."
}

role_mac_dns() {
  need_macos; need_root; load_env
  local plist=/Library/LaunchDaemons/com.soc.dnslog.plist
  info "Installing the passive DNS logger (tcpdump reads port 53 only; it never blocks or changes anything)."
  run install -o root -g wheel -m 644 "$REPO_DIR/configs/macos/com.soc.dnslog.plist" "$plist"
  run plutil -lint "$plist"
  run install -o root -g wheel -m 644 "$REPO_DIR/configs/macos/soc-dnslog.newsyslog.conf" /etc/newsyslog.d/soc-dnslog.conf
  run launchctl bootout system "$plist" 2>/dev/null || true
  run launchctl bootstrap system "$plist"

  local conf=/Library/Ossec/etc/ossec.conf
  if [[ ! -f "$conf" ]]; then
    warn "No Wazuh agent at /Library/Ossec. Install it from the dashboard's 'Deploy new agent' wizard, then rerun."
    return
  fi
  if grep -q '/var/log/dns-queries.log' "$conf"; then
    info "Mac agent already reads the DNS log."
  else
    backup "$conf"
    insert_before_close "$conf" "$(cat "$REPO_DIR/configs/macos/ossec-localfile-dns.xml")"
    if (( ! DRY_RUN )) && ! /Library/Ossec/bin/wazuh-logcollector -t; then
      cp -p "$conf.bak-$STAMP" "$conf"; die "logcollector test failed; restored the backup."
    fi
    run /Library/Ossec/bin/wazuh-control restart
  fi
  info "Check: nslookup soc-dnstest.example.com ; sudo tail -2 /var/log/dns-queries.log"
  info "Then on the manager: rule 100300 (level 3) with agent MacOS. It never reaches n8n or OpenAI."
}

role_opnsense() {
  cat <<'EOF'
OPNsense is installed from its DVD ISO through the console and web GUI; it cannot be scripted from here.
Follow, in order:
  1. docs/04-installation/03-opnsense-suricata.md      VM, interfaces, LAN <OPNSENSE_LAN_IP>/24, GUI access
  2. docs/04-installation/reference/opnsense-vm-install.md  the full console walkthrough
  3. Suricata: IDS mode only (IPS OFF), interfaces LAN (em1) + WAN (em0), promiscuous on,
     Detect Profile High, ET Open rules, syslog eve output (alerts) to the Wazuh manager UDP 514.
  4. Optional: configs/suricata/soc-lab-netvars.yaml.example (HOME_NET both segments, EXTERNAL_NET any)
  5. Verify: from Kali  sudo nmap -sS -p<ANY_PORT> <VICTIM_IP>  then  tail -1 /var/log/suricata/eve.json
EOF
}

# ---------------------------------------------------------------- main
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --env) shift; ENV_FILE="$1" ;;
    -h|--help) usage 0 ;;
    -*) die "Unknown option $1" ;;
    *) if [[ -z "$ROLE" ]]; then ROLE="$1"; else EXTRA+=("$1"); fi ;;
  esac
  shift
done
[[ -n "$ROLE" ]] || usage 1
(( DRY_RUN )) && warn "Dry run: nothing will be changed."

case "$ROLE" in
  preflight) role_preflight ;;
  wazuh)     role_wazuh ;;
  services)  role_services ;;
  workflow)  role_workflow ;;
  agent)     role_agent ;;
  sensor)    role_sensor ;;
  mac-dns)   role_mac_dns ;;
  opnsense)  role_opnsense ;;
  *) die "Unknown role '$ROLE'. Run ./install.sh --help" ;;
esac
