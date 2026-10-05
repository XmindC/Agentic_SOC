# Wazuh server

Machine: Wazuh VM, <WAZUH_IP>. Installer role: `wazuh`.

## 1. Create the VM

Linked clone of `clean base` (or a fresh Ubuntu Server), 4 vCPU, 8 GB RAM, **80 GB disk**, network "Share with my Mac", static address <WAZUH_IP>.

During the Ubuntu install, give the root logical volume the whole disk. The Ubuntu default made a 31 GB root volume on an 80 GB disk, and the Vulnerability Detector feed (about 20 GB) filled it. If you already have a small root volume:

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv && sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /
```

## 2. Install

```bash
cd ~/Agentic_SOC
sudo ./install.sh wazuh --dry-run     # read what it will do
sudo ./install.sh wazuh
```

The script:

1. Downloads and runs `wazuh-install.sh -a` for `WAZUH_VERSION` (manager, indexer and dashboard on this host). It prints the admin password once: put it in your password manager.
2. Backs up `ossec.conf`, `local_decoder.xml` and `local_rules.xml`.
3. Appends the Suricata, Mac DNS and Zeek decoders and rules 100200 to 100311 from [configs/wazuh](../../configs/wazuh/).
4. Adds a syslog listener on UDP 514 that accepts only the OPNsense address, and the `custom-n8n` integration (level 5 and above, all agents) pointing at `http://SERVICES_IP:5678/webhook/wazuh-alert`.
5. Installs `/var/ossec/integrations/custom-n8n` (root:wazuh, 750).
6. Runs `wazuh-analysisd -t`. On failure it restores all three backups and stops. On success it restarts the manager.

Doing it by hand instead: the same files with the same comments are in `configs/wazuh/`, and [05-configuration](../05-configuration/README.md) explains each one.

## 3. Disk retention (do this now)

Dashboard > Index Management > State management policies > create a policy that deletes `wazuh-alerts-*` indices after 15 to 30 days, and apply it to those indices. Without it the indexer grows until the disk is full.

If you do not need vulnerability detection, turn it off in `ossec.conf` (`<vulnerability-detection><enabled>no</enabled>`). Its feed is the largest single consumer of disk.

## 4. Check

```bash
sudo systemctl is-active wazuh-manager wazuh-indexer wazuh-dashboard
sudo grep -i "Enabling integration for: 'custom-n8n'" /var/ossec/logs/ossec.log | tail -1
sudo ss -ulnp | grep ':514'          # syslog listener is open
```

Open https://<WAZUH_IP>, accept the certificate warning, log in as `admin`. Take a Fusion snapshot named `wazuh installed`.

The n8n webhook does not exist yet, so the integration logs delivery errors until step 5 is done. That is expected.
