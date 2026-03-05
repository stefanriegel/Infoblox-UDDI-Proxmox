# Proxmox SDN Plugin for Infoblox Universal DDI

Automates IP address management (IPAM) and DNS record lifecycle for Proxmox VE virtual machines and containers through the Infoblox Universal DDI (BloxOne DDI) API.

Works with Proxmox VE 8.x and 9.x using **Simple Zones only**.

## Prerequisites

- Proxmox VE 8.x or 9.x
- Infoblox Universal DDI account with API token
- An IP Space configured in Infoblox (for IPAM)
- A DNS View configured in Infoblox (for DNS)
- **Important:** This plugin works with **Simple Zones only**. VLAN and EVPN zones do not trigger IPAM/DNS hooks in PVE 8.x/9.x.
- Required Perl packages: `libnet-ip-perl`, `libnetaddr-ip-perl`, `libjson-perl`, `liblwp-protocol-https-perl` (the install script warns if missing)

## Quick Start

### Option A: Install Script

```bash
git clone https://github.com/stefanriegel/Infoblox-UDDI-Proxmox.git
cd Infoblox-UDDI-Proxmox
sudo bash install.sh
```

The script checks prerequisites, copies plugin files, patches Proxmox SDN loader files, and prompts to restart services.

### Option B: Debian Package

```bash
# Download the latest release for your PVE version
wget https://github.com/stefanriegel/Infoblox-UDDI-Proxmox/releases/latest/download/pve-sdn-infoblox-uddi_VERSION-1+pveX_all.deb
sudo dpkg -i pve-sdn-infoblox-uddi_*.deb
sudo systemctl restart pveproxy pvedaemon
```

Then configure the IPAM and DNS providers in the Proxmox SDN configuration (Datacenter > SDN > IPAM / DNS).

## Configuration Options

### IPAM Plugin (type: `infobloxuddi`)

| Property    | Description                          | Example                      |
|-------------|--------------------------------------|------------------------------|
| `url`       | Infoblox Universal DDI API base URL  | `https://csp.infoblox.com`   |
| `token`     | API authentication token             | (from Infoblox portal)       |
| `ip_space`  | IP Space name for address allocation | `Default`                    |

### DNS Plugin (type: `infobloxuddi`)

| Property    | Description                          | Example                      |
|-------------|--------------------------------------|------------------------------|
| `url`       | Infoblox Universal DDI API base URL  | `https://csp.infoblox.com`   |
| `token`     | API authentication token             | (from Infoblox portal)       |
| `dns_view`  | DNS View name for record management  | `default`                    |

Configuration is managed through the Proxmox web UI under Datacenter > SDN, or via `/etc/pve/sdn/ipams.cfg` and `/etc/pve/sdn/dns.cfg`.

## Verification

After installation, verify the plugins are registered:

```bash
# Check IPAM plugin
pvesh get /cluster/sdn/ipams --type list 2>/dev/null | grep -q infobloxuddi && echo "IPAM plugin registered" || echo "IPAM plugin NOT found"

# Check DNS plugin
pvesh get /cluster/sdn/dns --type list 2>/dev/null | grep -q infobloxuddi && echo "DNS plugin registered" || echo "DNS plugin NOT found"
```

Both plugins should also appear in the Proxmox web UI dropdown when adding a new IPAM or DNS provider under Datacenter > SDN.

## Upgrade Path

When Proxmox updates the `libpve-network-perl` package (via `apt upgrade`), the SDN loader files are overwritten, removing the plugin registration.

**If installed via .deb package:** The package declares a dpkg trigger that automatically re-patches the loader files after any upgrade to `libpve-network-perl`. No manual action needed.

**If installed via script:** Re-run `sudo bash install.sh` after any `apt upgrade` that updates `libpve-network-perl`. The script is idempotent and safe to re-run.

## Known Limitations

1. **Simple Zones only** -- VLAN and EVPN zone types do not trigger IPAM/DNS hooks in Proxmox VE 8.x and 9.x. This is a Proxmox limitation, not a plugin limitation. Ensure your SDN configuration uses Simple Zones for subnets that should be managed by Infoblox.
2. **Infoblox Universal DDI only** -- This plugin targets the cloud-based Universal DDI (BloxOne DDI) API. The on-premises NIOS API is not supported.
3. **IPv4 only (v1)** -- IPv6 support (AAAA records, ip6.arpa PTR records) is planned for a future release.

## Troubleshooting

**Plugin not appearing in dropdown**
Check registration: `grep InfobloxPlugin /usr/share/perl5/PVE/Network/SDN/Ipams.pm`. If missing, re-run `install.sh` or reinstall the .deb package.

**Plugin disappeared after apt upgrade**
If using .deb, check the trigger fired: `journalctl -t pve-sdn-infoblox-uddi`. If using the script, re-run `sudo bash install.sh`.

**Authentication error**
Verify `token` is correct. The plugin uses `Authorization: Token <key>` header format. Ensure the token has appropriate permissions in the Infoblox portal.

**Missing Perl module errors**
Install missing packages:
```bash
sudo apt install libnet-ip-perl libnetaddr-ip-perl libjson-perl liblwp-protocol-https-perl
```

## Uninstall

**Script:** `sudo bash install.sh --remove`

**Package:** `sudo dpkg -r pve-sdn-infoblox-uddi`

## License

See [LICENSE](LICENSE) file.

## Development

```bash
# Run tests
prove -It/lib -Isrc -It t/
```
