> Source: `wazuh_disk_full_incident.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

# Wazuh Server: Disk Full Incident

**Diagnosis, root cause and permanent fix**

Lab: single node Wazuh 4.14.7 on Ubuntu Server 24.04, VMware Fusion. Date: September 2026.

---

## Summary

The Wazuh dashboard stopped working and the retention policy would not save. The cause was two problems stacking. First, a known Wazuh bug where the Vulnerability Detector downloads a large CVE feed and never cleans it up, which grew to about 20 GB and filled the disk. Second, the root volume was only 31 GB of an 80 GB disk, because it was never expanded at install, so there was very little room to absorb that growth. The permanent fix was to disable the Vulnerability Detector, delete its feed data, grow the root volume to the full disk, then restart Wazuh and clear the read only block the full disk had left behind.

## Environment

Single node deployment with the Wazuh manager, indexer and dashboard on one virtual machine at <WAZUH_IP>, 8 GB RAM and 4 cores, disk grown to 80 GB in VMware Fusion. The indexer is OpenSearch based, so its disk protection behaves like OpenSearch.

---

## How it showed up

### The retention policy would not save

Creating the index retention policy failed with a cluster create-index block. The indexer had put itself into a write blocked state.

*The indexer refused to create the policy index: FORBIDDEN cluster create-index blocked.*

### The dashboard broke and the agent view froze

The Overview health checks failed for the alerts, monitoring and statistics index patterns, all with the same reason: disk usage exceeded flood stage watermark, index has read only allow delete block. One of the blocked indices was the dashboard's own storage, which is why the agent view stopped responding.

*Dashboard health checks failing on the flood stage watermark and read only block.*

---

## Diagnosis, step by step

### Step 1: check the disk

The disk report showed the real problem. The virtual disk was 80 GB, but the root logical volume was only 31 GB and it was 100 percent full.

```bash
df -h /
lsblk
```

*An 80 GB disk (sda) but a 31 GB root volume (ubuntu-lv) at 100 percent full.*

### Step 2: growing the volume failed

The obvious fix, growing the volume into the free space, failed. A completely full disk cannot even write the small LVM metadata file that the grow operation needs first.

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
```

*lvextend failed with No space left on device, because the disk was 100 percent full.*

### Step 3: find what filled the disk

Listing the biggest directories pointed straight at the Wazuh Vulnerability Detector. Its CVE feed and updater temp folders were using about 20 GB between them.

```bash
sudo du -xh /var/ossec/queue | sort -rh | head
```

*The Vulnerability Detector feed: 11 GB under vd and 9.1 GB under vd_updater.*

### Step 4: deletes did not reclaim the space

Deleting the feed appeared to do nothing. The disk stayed at 100 percent. Two reasons: the manager kept restarting and immediately re downloading the feed, and a wildcard delete was slipping past the data. The space only came back once the manager was fully stopped and the directories themselves were removed.

*Deleting the feed left the disk still at 100 percent, because the manager kept refilling it.*

---

## Root cause

**Cause one, a Wazuh bug.** The Vulnerability Detector writes a large CVE feed to `/var/ossec/queue/vd/feed` and unpacks it under `/var/ossec/queue/vd_updater/tmp`, and it does not clean up the stale data. Over time this grows to many gigabytes and fills the disk. This is documented in the Wazuh issue tracker and is noted as especially bad on default LVM layouts with limited space.

**Cause two, an undersized volume.** The Ubuntu install left the root logical volume at 31 GB even though the disk was 80 GB, so nearly 50 GB sat unused next to a full filesystem. A small root volume had almost no headroom to absorb the feed growth.

---

## The fix

The steps below are the sequence that worked, in order. It removes both causes: it turns off the feed that fills the disk, and it grows the volume to use the whole disk.

### 1. Disable the Vulnerability Detector

It is optional and not needed for the core SIEM and agent workflow. Edit the manager config and set the module to disabled.

```bash
sudo nano /var/ossec/etc/ossec.conf
```

```xml
<vulnerability-detection>
  <enabled>no</enabled>
</vulnerability-detection>
```

### 2. Stop the refill, then delete the feed

Mask the manager so it cannot restart and refill, stop the indexer, confirm the filesystem is writable, then delete the two directories themselves rather than their contents.

```bash
sudo systemctl stop wazuh-manager
sudo systemctl mask wazuh-manager
sudo systemctl stop wazuh-indexer
findmnt /
sudo rm -rf /var/ossec/queue/vd /var/ossec/queue/vd_updater
df -h /
```

After this the disk dropped from 100 percent to about 35 percent used.

### 3. Grow the volume into the full disk

With free space present, the grow finally completes and the filesystem is resized live.

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /
```

Result: the root volume went from 31 GB to about 61 GB, dropping to roughly 18 percent used. This is the structural fix that stops the problem returning.

### 4. Bring Wazuh back

```bash
sudo systemctl unmask wazuh-manager
sudo systemctl start wazuh-indexer
sudo systemctl start wazuh-manager
sudo /var/ossec/bin/wazuh-control status
```

The manager comes up clean, and with the detector disabled it does not pull the feed again.

### 5. Reinitialize the indexer security

The rough restart on a full disk left the indexer security in a bad state, where even the admin user got a security_exception with no permissions. Reloading the security config from the files on disk restores it.

```bash
sudo JAVA_HOME=/usr/share/wazuh-indexer/jdk \
  /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh \
  -cd /etc/wazuh-indexer/opensearch-security/ -icl -nhnv \
  -cacert /etc/wazuh-indexer/certs/root-ca.pem \
  -cert /etc/wazuh-indexer/certs/admin.pem \
  -key /etc/wazuh-indexer/certs/admin-key.pem \
  -h 127.0.0.1
```

### 6. Clear the write block

With the disk healthy, remove the read only block the full disk had set.

```bash
curl -k -u admin -X PUT "https://localhost:9200/_all/_settings" \
  -H 'Content-Type: application/json' \
  -d '{"index.blocks.read_only_allow_delete": null}'
```

Expected response: `{"acknowledged":true}`.

### 7. Verify

The dashboard loads fully, the health checks clear, and it reports alerts again. The disk sits low and stable.

*Resolved: the dashboard loads and reports alerts, and the disk is healthy at 18 percent used.*

---

## Prevention

Four habits keep this from recurring on this machine and on every VM still to be built:

1. Give each virtual machine its full disk at install time by pushing the root volume to use the whole disk on the storage screen. The half sized volume was half the pain here.
2. Keep the Vulnerability Detector disabled in a small lab. It is heavy and, per the Wazuh bug tracker, it does not clean up after itself.
3. Keep an index retention policy in place so alert data is deleted after a set number of days rather than growing without limit.
4. Snapshot the machine at each healthy milestone, so recovery is a rollback rather than a rebuild.

---

## In plain words

The Wazuh server ran out of disk. One Wazuh feature, the Vulnerability Detector, kept downloading a big list of known vulnerabilities and never deleted the old copies, so it quietly ate about 20 GB. The disk was also smaller than it looked, only 31 GB was actually usable out of 80 GB, so it filled fast. When a disk fills, the database locks itself to avoid corruption, which is why the dashboard broke and the policy would not save. The fix was to turn off that feature, delete the junk it left behind, give the disk its full size, restart, and unlock the database. With the feature off and the disk at its full size, there is nothing left to fill it.

---

## References

- Wazuh Vulnerability Detector disk growth bug: https://github.com/wazuh/wazuh/issues/32854
- Related disk growth report: https://github.com/wazuh/wazuh/issues/31848
- Wazuh vulnerability detection configuration: https://documentation.wazuh.com/current/user-manual/capabilities/vulnerability-detection/configuring-scans.html
- lvextend manual: https://man7.org/linux/man-pages/man8/lvextend.8.html
- resize2fs manual: https://man7.org/linux/man-pages/man8/resize2fs.8.html
