# Services stack (n8n, TheHive, Cortex)

Machine: services01, <SERVICES_IP>. Installer role: `services`.

## 1. Create the VM

Ubuntu Server, 4 vCPU, 12 GB RAM, 60 GB disk, "Share with my Mac", static address <SERVICES_IP>.

## 2. Install

```bash
cd ~/Agentic_SOC
sudo ./install.sh services --dry-run
sudo ./install.sh services
```

The script:

1. Installs Docker Engine if missing and adds your user to the `docker` group (log out and back in afterwards).
2. Creates `/opt/cortex/jobs` owned by `1001:1001` (Cortex's user inside its container), an empty responders list, and `application.conf` pointing Cortex at `tcp://dockerproxy:2375`.
3. Writes `~/soc-stack/docker-compose.yml` from [configs/docker/docker-compose.yml](../../configs/docker/docker-compose.yml) and `~/soc-stack/.env` (mode 600) with your image tags and two generated 64-character session secrets. A rerun reuses the existing secrets.
4. Starts the services one group at a time: dockerproxy, then Cassandra and Elasticsearch (waiting for Cassandra to report `UN`), then TheHive and Cortex, then n8n.

If you already run the lab, an existing compose file is backed up first. Compare the two before restarting anything: the repository version was rebuilt from notes, not copied from the live host.

## 3. First run in the browser

### n8n, http://<SERVICES_IP>:5678

Create the owner account. Store the password in your password manager.

### TheHive, http://<SERVICES_IP>:9000

1. Log in with the default administrator from the [StrangeBee documentation](https://docs.strangebee.com/thehive/installation/) and change its password at once.
2. Request the free Community licence when prompted.
3. Create an organisation and two users: your analyst account, and an `n8n` service account with an API key (Organisation > Users > the account > API key > Create). n8n uses that key.

### Cortex, http://<SERVICES_IP>:9001

1. Press **Update database**. Until you do, the log complains that the `cortex_6` index does not exist. That is normal.
2. Create the superadmin. It can only manage organisations and users; it cannot run analyzers.
3. Create an organisation `soclab` with two users:

| User | Roles | Purpose |
|---|---|---|
| `<CORTEX_ORGADMIN_USER>` | read, analyze, orgadmin | Enables and configures analyzers (only orgadmin sees the catalogue) |
| `n8n` | read, analyze | API-only account for automation. Create its API key; n8n uses it |

Passwords need at least 8 characters. There is no save button: press Enter in the field. A shorter password fails without an error.

4. Log in as the org admin, Organization > Analyzers, enable two of the 283:
   - **AbuseIPDB**: paste your AbuseIPDB key.
   - **VirusTotal_GetReport**: paste your VirusTotal key (free tier, about 4 lookups a minute).
   - For both, set **Max TLP** and **Max PAP** to AMBER. The workflow tags observables Amber; a lower maximum means the analyzer silently never runs.

Leave every responder disabled. Responders take actions, and actions belong to a person.

## 4. Check

```bash
cd ~/soc-stack
docker compose ps                                   # six services Up
docker exec cassandra nodetool status | grep ^UN    # Cassandra ready
docker compose logs --tail 100 cortex | grep -i "docker is"   # "Docker is available"
docker run --rm --network soc-stack_default curlimages/curl:latest -s http://dockerproxy:2375/_ping   # OK
ls -l /var/run/docker.sock                          # still root:docker (Cortex must not own it)
```

In Cortex, New Analysis on IP `8.8.8.8` with AbuseIPDB returns a report.

If Docker on the host stops working after Cortex starts, Cortex has taken over the socket. See [the Cortex notes](reference/cortex-with-docker-socket-proxy.md), section 3, and `sudo systemctl restart docker.socket docker`.
