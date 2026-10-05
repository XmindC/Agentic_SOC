> Source: `opnsense_install_notes.md` (lab session notes). Screenshots and personal details were removed for publication; commands are unchanged except where marked.

# OPNsense Firewall: Installation Notes

**Steps covered so far, commands, and plain explanations**

Lab: OPNsense 26.7 on VMware Fusion, Intel Mac. Date: September 2026.

---

## Why we are building this

The network sensor (Suricata and Zeek) can only watch traffic that passes in front of it. On a normal Fusion network, each machine's traffic is kept separate, so the sensor sees almost nothing. OPNsense fixes this by becoming a single gate that all lab traffic passes through. Once the lab machines sit behind it, the sensor can be given a copy of everything.

## The design, in simple words

OPNsense has two network connections, and the whole design rests on what each one does:

- **WAN**, the outside facing side. This is the adapter set to Share with my Mac. It sits on the same NAT network as your Mac and the Wazuh server (<LAB_INFRA_CIDR>) and reaches the internet.
- **LAN**, the inside lab side. This is the adapter set to Private to my Mac. It is an isolated network at <OLD_LAB_LAN_IP> where OPNsense will hand out addresses and act as the gateway for Kali and the sensor.

Decision made: the Wazuh server stays exactly where it is on the NAT network at <WAZUH_IP>. Only the endpoints and the sensor move behind OPNsense. Their traffic flows out through OPNsense to reach the server, so nothing about Wazuh needs to change.

---

## Steps covered

### Step 1: Download the correct image

Go to https://opnsense.org/download/, choose architecture **amd64** and image type **DVD**. The file arrives compressed, so decompress it in the Mac Terminal:

```bash
cd ~/Downloads
bunzip2 OPNsense-26.7-dvd-amd64.iso.bz2
```

This leaves `OPNsense-26.7-dvd-amd64.iso`, which is what Fusion needs.

**Mistake we hit:** the first download was the VGA image, `OPNsense-26.7-vga-amd64.img`. That image is made for writing to a USB stick, not for booting as a CD in a VM, so it would not install. For a Fusion VM, always use the DVD `.iso`.

*Wrong image. The drive was pointed at the VGA img instead of the DVD iso.*

### Step 2: Create the VM

Create a new VM from the DVD iso. When Fusion asks for the operating system, do not pick Linux. OPNsense is built on FreeBSD, so the correct choice is under **Other**, then **FreeBSD 14 64-bit**. Picking the wrong OS type gives the VM the wrong disk and network defaults.

*Wrong category. OPNsense is not Linux.*

*Correct choice. Other, then FreeBSD 14 64-bit.*

Before finishing, customize the settings:

- Processors and memory: 2 cores, 2048 MB
- Hard disk: 20 GB
- Network: two adapters. The first set to **Share with my Mac** (this becomes WAN). Add a second and set it to **Private to my Mac** (this becomes LAN).

Give the VM a clear name such as OPNsense so it does not sit in the list as "FreeBSD 14 64-bit".

### Step 3: First boot problems and how we fixed them

The first boot failed with "No operating system was found". The VM tried the empty disk, then tried to boot from the network, and gave up. The cause was simply that no bootable install image was attached to the CD/DVD drive.

*The disk is empty and nothing is attached to boot from. Both network adapters are present, which is a good sign.*

The fix is to attach the DVD iso: shut the VM down, open Settings, CD/DVD, tick Connect CD/DVD Drive, and choose the `OPNsense-26.7-dvd-amd64.iso`.

A second problem appeared: the VM showed "Could not get vm files" and its disk read 0 bytes. The VM was broken and half created. Since nothing had been installed, the clean fix was to delete that VM entirely and create a fresh one from the correct iso with the two adapters set from the start.

*A broken VM. Deleting it and recreating from the correct iso was faster than repairing it.*

**Lesson:** if a VM has nothing installed on it yet, throwing it away and recreating it is often quicker and safer than fixing it.

### Step 4: Answer the network prompts

On the fresh boot, OPNsense asks a few questions about the network before it installs.

*The first network prompt.*

The answers, in order:

| Prompt | Answer | Why |
|---|---|---|
| Configure LAGGs now? | `n` | LAGG bonds several network cards into one. We do not need it. |
| Configure VLANs now? | `n` | We are not using VLANs. |
| WAN interface | `em0` | The outside facing card. |
| LAN interface | `em1` | The inside lab card. |
| Optional interfaces | press Enter | Only WAN and LAN are needed. |
| Proceed? | `y` | Confirm. |

### Step 5: Log in and start the installer

After the network prompts, OPNsense boots into a live environment and shows a login prompt.

*The live environment login.*

Log in with username `installer` and the vendor default password from the OPNsense docs. This starts the installer. The password does not show as you type, which is normal.

Two other default logins exist. `root` with the vendor default password opens the live shell instead of the installer. After installation, the web interface login is `root` with the password you set during install.

### Step 6: Install with ZFS

The installer menu appears with Install (ZFS) already highlighted.

*Choose Install (ZFS), the modern default.*

Next it asks for the ZFS layout. Choose **stripe**. The other options (mirror, raidz) need two or more disks for redundancy. You have one disk, so stripe is the only sensible choice.

*Stripe. One disk, no redundancy needed in a lab.*

Then select the disk. The single 20 GB disk shows as `da0` and is already marked with an X.

*The disk is already selected. Press Enter.*

Confirm the warning that the disk will be erased (it is empty, so this is safe). The install runs for a couple of minutes. At the end, set a strong root password and write it down, then choose Complete Install and reboot.

**At reboot, remove the iso** so it does not boot the installer again: shut the VM down, untick Connect CD/DVD Drive in Fusion settings, then start it.

### Step 7: First boot success and the mapping check

After reboot, OPNsense shows its console menu with the interface addresses. This is the screen that proves the install worked.

*Success. LAN on em1 at <OLD_LAB_LAN_IP>, WAN on em0 at <OPNSENSE_WAN_IP>.*

Read the two key lines:

- **LAN (em1) <OLD_LAB_LAN_IP>/24**, the private lab side, correct.
- **WAN (em0) <OPNSENSE_WAN_IP>/24 via DHCP**, an address from the Mac's NAT network, correct.

The mapping came out right the first time, so no swapping was needed. OPNsense is installed and running as the firewall.

---

## Where we are and what is next

Installed and working: OPNsense 26.7, WAN and LAN assigned correctly, root password set.

Not yet done: reaching the web interface. The GUI lives on the LAN side at <OLD_LAB_LAN_IP>, but the Mac is on the WAN side and cannot reach <OLD_LAB_LAN_IP> directly. OPNsense also blocks its GUI on the WAN side by default for security.

The planned next step is to temporarily allow GUI access from the WAN so the Mac can log in, then do the real configuration from the web interface. At the console, choose option `8` (Shell) and run:

```bash
pfctl -d
```

Then from the Mac browser open `https://<OPNSENSE_WAN_IP>`, accept the certificate warning, and log in as `root`. This is pending and will be confirmed in the next session. After that comes configuring the LAN, DHCP, and moving Kali and the sensor behind the firewall.

Take a Fusion snapshot named `opnsense installed` before going further, so this clean state can be restored.

---

## Quick reference

**Decompress the image**
```bash
bunzip2 OPNsense-26.7-dvd-amd64.iso.bz2
```

**Logins**

| Where | Username | Password |
|---|---|---|
| Live environment, to install | `installer` | `<OPNSENSE_DEFAULT_PASSWORD>` |
| Live environment, shell | `root` | `<OPNSENSE_DEFAULT_PASSWORD>` |
| Installed system and web GUI | `root` | the password you set |

**Console network answers:** LAGGs `n`, VLANs `n`, WAN `em0`, LAN `em1`, then `y`.

**Addresses**

| Interface | Address | Meaning |
|---|---|---|
| WAN (em0) | <OPNSENSE_WAN_IP> | Outside side, on the Mac's NAT network |
| LAN (em1) | <OLD_LAB_LAN_IP> | Inside lab side, OPNsense is the gateway |
| Wazuh server | <WAZUH_IP> | Stays on the NAT network, unchanged |

---

## Simple notes on the terms

**WAN and LAN.** WAN is the side facing the outside world. LAN is the protected inside side. A firewall sits between the two and decides what passes.

**NAT (Share with my Mac).** Fusion's shared network. Machines on it can reach the internet through the Mac. Both the Wazuh server and OPNsense's WAN live here.

**Private to my Mac.** An isolated Fusion network with no internet on its own. OPNsense's LAN lives here and will become the gateway for the lab machines.

**DHCP.** The service that hands out addresses automatically. OPNsense runs one on its LAN, and it also tells machines to use OPNsense as their gateway, which is what routes their traffic through the firewall.

**ZFS and stripe.** ZFS is the filesystem OPNsense installs onto. Stripe means a single disk with no redundancy, correct for one virtual disk.

**LAGG and VLAN.** LAGG bonds network cards together. VLANs split one network into several. Neither is needed here, so both are answered no.

**em0 and em1.** FreeBSD's names for the two network cards. em0 became WAN, em1 became LAN.
