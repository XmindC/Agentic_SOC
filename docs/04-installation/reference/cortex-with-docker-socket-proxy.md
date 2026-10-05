> Source: `soc_lab_8_cortex.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

**SOC Agent Lab 8: Cortex**

*Adding the analyzer engine, the Docker socket problem, and the socket proxy that solved it*

------------------------------------------------------------------------

Session date 13 September 2026. Companion to continuation brief 4. *Prose in this document avoids hyphens so it reads easily. Commands and web links must be typed exactly as shown, including any hyphens they contain.*

1\. What Cortex does and why it is here

Cortex is the analyzer engine. TheHive holds cases and observables but cannot look anything up by itself. Cortex takes an observable, such as an address, runs it against a reputation service, and hands back a report.

Each analyzer is its own Docker container. Cortex does not contain the analyzers. It downloads a catalogue describing several hundred of them, and when a job runs it asks Docker to start the matching container, passes the observable in through a shared folder, and reads the answer back out. That design is the source of every difficulty in this document.

In the lab, Cortex sits between TheHive and the outside world. It is the component that turns a bare address on a case into a judgement about that address.

2\. Choosing a version

Cortex versions are tied to Elasticsearch versions and cannot span two major releases at once.

| **Cortex version** | **Elasticsearch** | **Consequence for this lab** |
|----|----|----|
| 3.1.x | 7.x only | Would need a second Elasticsearch container |
| 4.x | 8.x only | Shares the existing instance |

The stack already ran elasticsearch:8.14.3 for TheHive, so Cortex 4.1.0 was the only choice that avoided a second database. The two share the instance under different index names: TheHive under thehive, Cortex under cortex_6.

The vendor warns that sharing requires TheHive 5.2.16 or later. TheHive 5.2 here had already built its schema against Elasticsearch 8 and was working, so the question was answered by observation rather than by the version string.

3\. The Docker socket problem

This consumed most of the session and is the single most important thing in this document.

3.1 What the documentation says to do

Cortex needs to start containers, so the published instructions mount the host Docker socket into it, at /var/run/docker.sock. Doing that on services01 breaks the host.

3.2 The symptom

Cortex started, then reported that it could not reach Docker. Moments later every Docker command typed in an ordinary shell failed as well.

```
permission denied while trying to connect to the docker API at unix:///var/run/docker.sock
```

The socket had changed owner:

```
srw-rw---- 1 1001 1001 0 Sep 11 20:31 /var/run/docker.sock
```

User 1001 and group 1001 do not exist on services01. The numbers appear raw because there is nothing to resolve them to. The account socadmin belongs to group 983, which is the docker group, so it no longer matched and was refused.

3.3 The cause

The Cortex image runs a change of ownership on its files at startup, and the user it runs as inside the container is uid 1001. Because the real socket was handed to it, that ownership change landed on the real socket, on the host.

Two details made this harder to diagnose than it should have been.

- The modification time on the socket was from the previous day, which suggested an old fault. It was misleading. Changing ownership does not update the modification time. The change time, visible through stat, showed the true moment.

- Restarting the docker service did not repair it. The socket is created by a separate systemd unit called docker.socket, and only restarting that unit recreates the file.

Recovery, should it ever recur:

```
sudo systemctl restart docker.socket docker
```

3.4 An approach that does not work

Running Cortex as root, by setting user: "0:0" in the compose file, seems like it should help. It does not. The ownership change still runs, and running as root simply gives it more authority to complete. This was tested and the socket was taken a second time.

3.5 The approach that works

Put a small proxy container between Cortex and Docker. The proxy holds the real socket read only, so it is physically incapable of changing its ownership. Cortex talks to the proxy over the network instead of touching a socket file at all.

A second benefit follows from the first. The proxy exposes only the parts of the Docker interface that are switched on, so Cortex receives the ability to start analyzers without receiving the ability to do everything else.

4\. The working arrangement

Six containers on services01, defined in a single compose file.

| **Container** | **Image** | **Port** | **Purpose** |
|----|----|----|----|
| n8n | n8nio/n8n:latest | 5678 | Workflow automation |
| cassandra | cassandra:4.1 | internal | TheHive database |
| elasticsearch | elasticsearch:8.14.3 | internal | Index for TheHive and Cortex |
| thehive | strangebee/thehive:5.2 | 9000 | Case management |
| cortex | thehiveproject/cortex:4.1.0-1 | 9001 | Analyzer engine |
| dockerproxy | tecnativa/docker-socket-proxy:0.3.0 | internal | Limited Docker access for Cortex |

The path a job takes:

1.  An analyst or n8n asks Cortex to analyse an observable.

2.  Cortex creates a folder for that job inside the shared jobs directory and writes the observable into it.

3.  Cortex asks the proxy to start the analyzer container, with the job folder attached.

4.  The proxy passes the request to Docker on the host.

5.  The analyzer runs, calls the reputation service over the internet, writes its report into the job folder, and exits.

6.  Cortex reads the report and stores it in Elasticsearch.

Because the host Docker daemon performs the mount, the job folder path must be identical inside and outside the container. That is why both directory settings point at the same location.

5\. Build procedure

Written as it would be done knowing what is known now, rather than in the order it actually happened.

Step 1. Prepare the folders and a secret

```
sudo mkdir -p /opt/cortex/jobs
sudo chown -R 1001:1001 /opt/cortex/jobs
echo '[]' > /opt/cortex/no-responders.json
openssl rand -hex 32
```

The jobs folder must be owned by 1001, the user Cortex runs as inside its container. Owned by socadmin it fails with AccessDeniedException when Cortex tries to create the folder for an individual job.

The file no-responders.json contains an empty list. Section 7 explains why.

Keep the random string from the last command. It becomes the Cortex session secret.

Step 2. Write the Docker host configuration

The setting that points Cortex at the proxy is not a command line option. Passing --docker-host causes Cortex to print its help text and exit. It belongs in a configuration file instead.

```
cat > /opt/cortex/application.conf << 'EOF'
docker {
host = "tcp://dockerproxy:2375"
}
EOF
```

Step 3. Add both services to the compose file

The Cortex service:

```
cortex:
image: thehiveproject/cortex:4.1.0-1
container_name: cortex
restart: unless-stopped
depends_on:
- elasticsearch
ports:
- "9001:9001"
volumes:
- /opt/cortex/jobs:/opt/cortex/jobs
- /opt/cortex/no-responders.json:/opt/cortex/no-responders.json:ro
- /opt/cortex/application.conf:/etc/cortex/application.conf:ro
command:
- --secret
- <CORTEX_SECRET>
- --es-uri
- http://elasticsearch:9200
- --job-directory
- /opt/cortex/jobs
- --docker-job-directory
- /opt/cortex/jobs
- --responder-url
- /opt/cortex/no-responders.json
```

The proxy service:

```
dockerproxy:
image: tecnativa/docker-socket-proxy:0.3.0
container_name: dockerproxy
restart: unless-stopped
environment:
- CONTAINERS=1
- IMAGES=1
- POST=1
- INFO=1
- EXEC=1
volumes:
- /var/run/docker.sock:/var/run/docker.sock:ro
```

All five permissions are required. The first three are the obvious ones. The other two are easy to miss and neither failure is clearly reported.

| **Permission** | **What breaks without it** |
|----|----|
| CONTAINERS | Cortex cannot create or inspect the analyzer container |
| IMAGES | Cortex cannot check whether the analyzer image is present |
| POST | Every write request is refused, so nothing starts |
| INFO | The availability check fails and the log says Docker is not available |
| EXEC | Cortex cannot read the analyzer output back |

Step 4. Start the proxy first, alone

```
cd ~/soc-stack
docker compose config --quiet && echo "FILE OK"
docker compose up -d dockerproxy
sleep 15
ls -l /var/run/docker.sock
docker ps
```

The socket must still show root and docker as its owners, and the container listing must still work. This is the check that the proxy has not repeated the original fault.

Then confirm the proxy answers:

```
docker run --rm --network soc-stack_default curlimages/curl:latest -s http://dockerproxy:2375/_ping
```

The reply should be OK.

Step 5. Start Cortex

```
docker compose up -d cortex
sleep 40
docker compose logs --tail 100 cortex | grep -i "docker is"
```

The wanted line is Docker is available. If it says Docker is not available with a 403, a proxy permission is missing.

Step 6. First run in the browser

Open http://<SERVICES_IP>:9001 and press the button that updates the database. Cortex creates its index at that point. Until then the log fills with complaints that the index does not exist, which is normal and not a fault.

Then create the administrator account when offered.

6\. Users, organisations and analyzers

6.1 The organisation model

Cortex separates administration from work. The built in cortex organisation manages organisations and users and cannot run analyzers at all. A second organisation is required to do anything useful, and it needs its own administrator.

| **Organisation** | **User** | **Roles** | **Purpose** |
|----|----|----|----|
| cortex | kali | superadmin | Manages organisations and users only |
| soclab | soclabadmin | read, analyze, orgadmin | Enables and configures analyzers |
| soclab | n8n | read, analyze | API account for automation |

The n8n account deliberately lacks orgadmin. It can run lookups and read results and cannot change any setting. Its API key is what TheHive and the workflow will use.

The analyzer catalogue is only visible to a user holding orgadmin, which is why the third account exists. Neither the superadmin nor the automation account can reach it.

6.2 Analyzers enabled

Two of the 283 available. The rest are left alone, since each one enabled is another container image to download and another key to manage.

| **Analyzer** | **Version** | **Notes** |
|----|----|----|
| AbuseIPDB_2_0 | 2.0 | Address reputation. Applies to ip only |
| VirusTotal_GetReport_3_1 | 3.1 | Reads existing reports. Applies to several types |

Both are configured with Max TLP set to AMBER and Max PAP set to AMBER. This matters more than it looks. Cortex refuses to run an analyzer whose permitted level sits below the level of the observable, and the observables the workflow creates are tagged Amber. Set either one lower and the analyzer quietly never runs.

6.3 Settings chosen against the defaults

| **Setting** | **Chosen** | **Reason** |
|----|----|----|
| download_sample | False | True downloads the actual malware file onto services01 |
| download_sample_if_highlighted | False | Same, conditionally |
| Extract observables | False | True adds new observables to cases automatically |
| Rate limiting | empty | The free tiers throttle at their own end |

7\. What was deliberately switched off

7.1 Responders

Cortex ships responders alongside analyzers. An analyzer looks something up. A responder acts, by blocking an address or disabling an account.

The lab design states that no state changing action happens without the analyst approving it, and that only n8n calls response tools. A Cortex responder would fire from inside Cortex, outside that path entirely.

Responders are inert until enabled, so leaving them alone would have been adequate. Instead the responder catalogue points at an empty local file, which makes the rule part of the build rather than a matter of memory. The file /opt/cortex/no-responders.json contains an empty list and is mounted read only. Reversing this is three lines if a responder is ever wanted.

7.2 VirusTotal Scan

Only VirusTotal_GetReport is enabled. VirusTotal_Scan was left disabled on purpose. Scan submits the sample or address for fresh analysis, which is an act visible to whoever owns it. GetReport only reads what already exists. PAP Amber permits the second and not the first.

8\. Verification

A single successful job proves the entire chain, so it is worth running deliberately rather than waiting for real traffic.

1.  Log in as the organisation administrator.

2.  Choose New Analysis.

3.  Data type ip, data 1.1.1.1, TLP Amber, PAP Amber.

4.  Select AbuseIPDB and run it.

The address belongs to a public resolver. It is known clean and there is nothing sensitive about looking it up.

The first run takes up to a minute because the analyzer image has to download. A result of Success confirms four separate things at once: Cortex reached the proxy, the proxy started a container, the job folder was writable from both sides, and the API key is valid.

9\. Things that will catch you out

- Never mount the real Docker socket into Cortex. It takes ownership of it and locks you out of Docker on the host.

- Running Cortex as root does not avoid that. Only the proxy does.

- Restarting the docker service does not repair a taken socket. Restart docker.socket as well.

- The modification time on a socket does not change when its ownership does. Read the change time from stat instead, or the fault looks older than it is.

- A compose command will not restart a container whose own definition has not changed. After editing the proxy, Cortex reported Running rather than Started and kept its old failed connection. Cortex checks for Docker once, at startup, so it must be restarted explicitly.

- The password field in the Cortex user list has no save button. Type the password and press Enter. Fewer than eight characters fails without saying so.

- The Analyzers page in the top bar lists only what is enabled. The catalogue of everything available lives under Organization.

- An index not found error for cortex_6 before the database button is pressed is expected, not a fault.

- Listing an empty directory shows nothing at all. Add the d flag to see the directory itself and its ownership.

- Cortex logs are extremely noisy. Authentication failures and long stack traces are ordinary background chatter. Filter before reading.

10\. Command reference

Reading the log without the noise

```
cd ~/soc-stack
docker compose logs --tail 100 cortex | grep -v -E "AccessLogFilter|Authentication failure|session:|key:|init:"
```

Checking Docker availability

```
docker compose logs --tail 100 cortex | grep -i "docker is"
```

Repairing a taken socket

```
sudo systemctl restart docker.socket docker
ls -l /var/run/docker.sock
docker ps
```

Reading the true change time of a file

```
stat /var/run/docker.sock
```

Testing the proxy from outside

```
docker run --rm --network soc-stack_default curlimages/curl:latest -s http://dockerproxy:2375/_ping
```

Testing the proxy from inside Cortex

```
docker exec cortex curl -s -o /dev/null -w "%{http_code}\n" http://dockerproxy:2375/info
```

Confirming Cortex can reach the analyzer catalogue

```
docker exec cortex curl -s -o /dev/null -w "%{http_code}\n" https://catalogs.download.strangebee.com/latest/json/analyzers.json
```

Checking job folder ownership

```
ls -lnd /opt/cortex/jobs
```

Restarting Cortex properly after a configuration change

```
docker compose restart cortex
```

11\. Open items arising from this work

- The Cortex session secret and the TheHive session secret are both in plain text in the compose file, and both have appeared in chat transcripts. Add them to the rotation list alongside the API keys.

- The soclabadmin password has also appeared in a transcript.

- The proxy reduces what Cortex can do but does not eliminate it. Anything able to start containers on services01 can still reach a great deal of that machine. services01 also holds the case data and the workflow credentials, and sits on the same flat network as the attacking machine. That combination belongs on a management segment in any build that is not a lab.

- Image tags should be pinned. The n8n image has already drifted to an untagged identifier, which means a future pull could move it without warning.
