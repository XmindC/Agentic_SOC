> Source: `soc_lab_2_infrastructure.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

# SOC Agent Lab: Infrastructure

Build guide for the lab described in the Plan document. Build the machines in the order below. Each one works before the next depends on it. For every tool you get the purpose, the official link, the core steps, and how to check it worked.

```
Note on typing: the writing avoids hyphens so it reads easily, but commands, file names, package names and web links must be typed exactly as shown, including any hyphens they contain, or they will not work.
```

Host assumed: Intel Mac, 64 GB RAM, about 150 GB free disk, VMware Fusion installed.

---

## Preparation

Downloads you will need:

* Ubuntu Server 24.04 LTS (amd64): https://ubuntu.com/download/server
* Wazuh quickstart guide: https://documentation.wazuh.com/current/quickstart.html
* Docker Engine on Ubuntu: https://docs.docker.com/engine/install/ubuntu/
* Suricata docs: https://docs.suricata.io/
* Zeek downloads: https://zeek.org/get-zeek/
* OPNsense download: https://opnsense.org/download/
* n8n Docker guide: https://docs.n8n.io/hosting/installation/docker/
* MISP Docker: https://github.com/MISP/misp-docker
* TheHive 5 install: https://docs.strangebee.com/thehive/installation/
* Cortex download: https://docs.strangebee.com/cortex/download/
* Authentik docs: https://goauthentik.io/docs/
* VirusTotal (free API key): https://www.virustotal.com
* AlienVault OTX: https://otx.alienvault.com
* AbuseIPDB: https://www.abuseipdb.com

Network mode for every lab machine: in the machine settings under Network Adapter choose "Share with my Mac". This is Fusion NAT mode. Every machine on it can reach every other one and reach the internet, and your Mac can open their web pages directly. Keep all machines on this one network through the whole build.

Good habit from the start: after you finish installing a machine, take a Fusion snapshot named "clean base". You can then make new machines as linked clones of that snapshot, which share the base disk and save a lot of space.

## Wazuh server (the SIEM)

Purpose: the collection point that gathers logs and raises alerts.

Steps:

1. In Fusion create a new machine from the Ubuntu Server image. Set it to 4 cores, 8192 MB RAM, 60 GB disk, network "Share with my Mac".
2. Install Ubuntu Server. Tick "Install OpenSSH server" so you can connect from the Mac terminal.
3. From your Mac, connect with `ssh youruser@SERVER_IP`. Find the IP inside the machine with `ip a`.
4. Update the system:
   ```
   sudo apt update && sudo apt upgrade -y
   ```
5. Run the Wazuh all in one installer. This puts the manager, indexer and dashboard on this single host:
   ```
   curl -sO https://packages.wazuh.com/4.14/wazuh-install.sh
   sudo bash ./wazuh-install.sh -a
   ```
   If the quickstart page shows a version newer than 4.14, change the number in the link.
6. When it finishes it prints the dashboard address and the admin password. To print the passwords again:
   ```
   sudo tar -O -xvf wazuh-install-files.tar wazuh-install-files/wazuh-passwords.txt
   ```

Check it worked: from your Mac browser open `https://SERVER_IP`, accept the certificate warning, and log in as user `admin`. Take a snapshot named "wazuh installed".

Disk retention (do this now): in the dashboard open Index Management, then State management policies, and create a policy that deletes the Wazuh alert indices after 15 to 30 days, then attach it to those indices. This is what keeps you inside 150 GB over time.

## Endpoints (Wazuh agents)

Purpose: the machines the SIEM watches.

Steps:

1. In Fusion, right click your "clean base" Ubuntu snapshot and make a linked clone. Size it 2 GB RAM, 1 core. This costs very little disk.
2. Boot the clone. In the Wazuh dashboard open the "Deploy new agent" wizard.
3. Choose the endpoint operating system, enter the Wazuh server IP, and the wizard shows the exact install and enroll command.
4. Paste that command into the endpoint and start the agent.

Check it worked: the endpoint appears as an active agent in the dashboard within a minute.

Tip: start with one or two Linux endpoints. Add a Windows endpoint later only when you want to test Windows detections, because a Windows machine uses far more disk.

## Network sensor (Suricata and Zeek)

Purpose: watch network traffic for signature alerts (Suricata) and record rich connection and protocol data (Zeek).

Steps:

1. Make a machine (or linked clone) with 4 GB RAM, 2 cores, 25 GB disk, network "Share with my Mac".
2. In the machine network settings, enable promiscuous mode so the sensor can see traffic beyond its own.
3. Update the system, then install Suricata from the official stable source:
   ```
   sudo add-apt-repository ppa:oisf/suricata-stable
   sudo apt update
   sudo apt install suricata -y
   ```
4. Install Zeek by following the Ubuntu packages on the Zeek downloads page: https://zeek.org/get-zeek/
5. Point both tools at your capture interface and turn on log rotation so their logs do not grow forever.
6. Install a Wazuh agent on this machine (as in the Endpoints section) and add the Suricata and Zeek log files to its configuration so the logs reach Wazuh.

Check it worked: generate some traffic and confirm Suricata alerts and Zeek connection logs appear in the Wazuh dashboard.

## Firewall (OPNsense)

Purpose: a real firewall you can log from and later push block rules into.

Steps:

1. Download the OPNsense image from https://opnsense.org/download/ (choose the dvd or vga image, amd64).
2. Make a machine with 2 GB RAM, 2 cores, 20 GB disk. Give it two network adapters, one for WAN and one for LAN. For a first pass both can be "Share with my Mac".
3. Boot the image and run the installer, then set the interfaces.
4. Open the OPNsense web page from your Mac browser and finish setup.
5. Send its logs to Wazuh: point OPNsense system logging at the Wazuh server.

Check it worked: OPNsense firewall events appear in the Wazuh dashboard.

## Services host (Docker with n8n, TheHive, Cortex, MISP, Authentik)

Purpose: one machine that runs the automation, the case system, the analyzer engine, the threat intelligence store and the login system, all in containers to save disk.

First, prepare the machine:

1. Make a machine with 12 GB RAM, 4 cores, 60 GB disk, network "Share with my Mac".
2. Update the system, then install Docker. The simple lab method:
   ```
   curl -fsSL https://get.docker.com | sh
   sudo usermod -aG docker $USER
   ```
   Log out and back in so your user can run Docker without sudo. Full guide: https://docs.docker.com/engine/install/ubuntu/

Then install each service:

**n8n (orchestration).** Follow https://docs.n8n.io/hosting/installation/docker/. Quick start:
```
docker volume create n8n_data
docker run -d --name n8n --restart unless-stopped -p 5678:5678 -v n8n_data:/home/node/.n8n docker.n8n.io/n8nio/n8n
```
Check it worked: open `http://SERVICES_IP:5678` and create the owner account.

**MISP (threat intelligence).** Use the official Docker project:
```
git clone https://github.com/MISP/misp-docker
cd misp-docker
cp template.env .env
```
Edit `.env` to set the base URL to your services host address, then start it with `docker compose up -d`. Follow the readme in that repository for the current variable names.
Check it worked: open the MISP web page, log in with the default admin account shown in the readme, then change the password.

**Cortex (analyzer engine).** Cortex runs with Elasticsearch using Docker Compose. Follow https://docs.strangebee.com/cortex/download/ and the "Run Cortex with Docker" guide.
Check it worked: open `http://SERVICES_IP:9001` and complete the first start, which sets up the database and the admin user.

**TheHive (case management and approval surface).** Follow https://docs.strangebee.com/thehive/installation/, using the Docker option. TheHive 5 has a free community edition, which asks for a free license key that you request from StrangeBee inside the app on first start.
Check it worked: open TheHive in the browser, log in, and connect it to Cortex under organization settings so cases can run analyzers.

**Authentik (identity and auth), optional at this stage.** Follow the Docker Compose install on https://goauthentik.io/docs/. This gives you real login events to collect and an account you can disable as a response action later. Keycloak is an alternative. You can skip this until you want auth use cases.

Send the useful container logs (at least MISP, TheHive and Authentik) into Wazuh by installing a Wazuh agent on this services host and pointing it at the container log files.

## Enrichment API keys (free)

Purpose: give the analyzers reputation data without hosting anything.

Steps:

1. VirusTotal: make a free account at https://www.virustotal.com and copy your API key from your account settings.
2. AlienVault OTX: make a free account at https://otx.alienvault.com and copy your key.
3. AbuseIPDB: make a free account at https://www.abuseipdb.com and copy your key.
4. In Cortex, enable the matching analyzers and paste each key into the analyzer settings. In MISP, add OTX as a feed.

Check it worked: in Cortex, run an analyzer against a known bad test indicator and confirm you get a result. Mind the free rate limits, which are fine for a lab.

## Wire it together

Purpose: connect the pieces so an alert flows to the agent and stops at you.

Steps:

1. In n8n, build a workflow that watches Wazuh for new alerts (poll the Wazuh API or receive them by webhook) and, for each alert, creates a case in TheHive.
2. In the same workflow, send the alert facts to the Copilot free tier model using the Level 1 triage prompt. Save the returned verdict and summary into the TheHive case.
3. When the verdict says escalate, run the Level 2 investigation prompt with related events, then the containment proposal prompt. Write the proposal into TheHive as a task.
4. Pause the workflow on a wait step. Post the proposal to you inside TheHive, or as a message with approve and reject buttons.
5. Only after you approve does n8n run the response action: a Wazuh active response to isolate a host, an OPNsense rule to block an address, or an Authentik call to disable an account.

Guardrails to keep in place: the Copilot model never holds any tool credentials and never calls a response tool. Only n8n calls response tools, and only after reading your approval. If you do not approve within a set time, the workflow holds or escalates and never acts. Log who approved what and when.

## Suggested first milestone

Get everything up to and including the enrichment keys working, and run the agent in read only mode: it writes verdicts and summaries into cases but cannot act. Live with that for a couple of weeks to judge the quality of the cheap model on real alerts. Only then turn on the approval wiring and let it start proposing actions for your yes. This order protects your environment while you learn how far the free tier model can be trusted.
