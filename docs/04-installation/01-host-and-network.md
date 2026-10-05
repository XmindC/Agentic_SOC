# Host and networks

Machine: the Mac running VMware Fusion. Manual.

## 1. Create the two virtual networks

1. Fusion > Settings > Network. Keep the built-in **Share with my Mac** (NAT). Note its subnet; the lab uses <LAB_INFRA_CIDR>. Every address in `.env` assumes this.
2. Add a custom network, `vmnet2`: subnet <LAB_LAN_CIDR>, "Connect the host Mac to this network" on. Leave Fusion's DHCP on (this Fusion build will not let you set a subnet with DHCP off); the lab uses static addresses anyway, with OPNsense as gateway.
3. Make sure <LAB_LAN_CIDR> and <LAB_INFRA_CIDR> do not overlap your home network. If your home LAN uses one of them, pick other subnets and change `.env` to match.

## 2. Make a base VM

1. New VM from the Ubuntu Server ISO. Tick "Install OpenSSH server" during setup.
2. `sudo apt update && sudo apt upgrade -y`
3. Shut it down and take a snapshot named `clean base`. Later Ubuntu machines are linked clones of this snapshot, which share the base disk and save space.

## 3. Copy the repository to the lab

From the Mac:

```bash
cd Agentic_SOC
cp .env.example .env && chmod 600 .env
# edit .env: addresses, versions, then keys as you get them
for h in <WAZUH_IP> <SERVICES_IP> <VICTIM_IP>; do
  scp -r ../Agentic_SOC <LAB_USER>@$h:~/   # .env travels with it; it is mode 600
done
```

## 4. Keep the Mac awake during lab hours

A sleeping Mac freezes every VM, so detection stops and scheduled jobs miss their window. While the lab is in use:

```bash
caffeinate -s &      # prevents idle sleep while on AC power
```

## Check

`ifconfig | grep -A2 bridge` shows interfaces with <MAC_NAT_IP> and <MAC_LAN_IP>. Newer Fusion versions name them `bridgeN`/`vmenetN` rather than `vmnet2`; that is normal.
