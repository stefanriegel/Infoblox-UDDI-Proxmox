#!/bin/bash
set -e

# Resolve script directory for relative source paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Constants ────────────────────────────────────────────────────────────────

IPAM_LOADER="/usr/share/perl5/PVE/Network/SDN/Ipams.pm"
DNS_LOADER="/usr/share/perl5/PVE/Network/SDN/Dns.pm"

IPAM_PLUGIN_SRC="$SCRIPT_DIR/src/PVE/Network/SDN/Ipams/InfobloxPlugin.pm"
DNS_PLUGIN_SRC="$SCRIPT_DIR/src/PVE/Network/SDN/Dns/InfobloxPlugin.pm"

IPAM_PLUGIN_DST="/usr/share/perl5/PVE/Network/SDN/Ipams/InfobloxPlugin.pm"
DNS_PLUGIN_DST="/usr/share/perl5/PVE/Network/SDN/Dns/InfobloxPlugin.pm"

IPAM_USE="use PVE::Network::SDN::Ipams::InfobloxPlugin;"
IPAM_REG="PVE::Network::SDN::Ipams::InfobloxPlugin->register();"
DNS_USE="use PVE::Network::SDN::Dns::InfobloxPlugin;"
DNS_REG="PVE::Network::SDN::Dns::InfobloxPlugin->register();"

JS_SRC="$SCRIPT_DIR/src/js/infobloxuddi-sdn.js"
JS_DST="/usr/share/javascript/pve-sdn-infoblox-uddi/infobloxuddi-sdn.js"
JS_LINK="/usr/share/pve-manager/js/infobloxuddi-sdn.js"
INDEX_TPL="/usr/share/pve-manager/index.html.tpl"
JS_SCRIPT_TAG='<script type="text/javascript" src="/pve2/js/infobloxuddi-sdn.js"></script>'

# ── Helper Functions ─────────────────────────────────────────────────────────

check_prereqs() {
    local missing=()
    for pkg in libnet-ip-perl libnetaddr-ip-perl libjson-perl liblwp-protocol-https-perl; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "WARNING: Missing recommended packages: ${missing[*]}"
        echo "  Install with: apt install ${missing[*]}"
    fi
}

patch_loader() {
    local file="$1"
    local use_line="$2"
    local reg_line="$3"
    local init_pattern="$4"

    if ! grep -qF "$use_line" "$file"; then
        sed -i "/${init_pattern}/i ${use_line}" "$file"
    fi
    if ! grep -qF "$reg_line" "$file"; then
        sed -i "/${init_pattern}/i ${reg_line}" "$file"
    fi
}

unpatch_loader() {
    local file="$1"
    local use_line="$2"
    local reg_line="$3"

    if grep -qF "$use_line" "$file"; then
        grep -vF "$use_line" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
    if grep -qF "$reg_line" "$file"; then
        grep -vF "$reg_line" "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
    fi
}

# ── Main Logic ───────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

if [ "$1" = "--remove" ]; then
    # ── Remove flow ──────────────────────────────────────────────────────
    echo "Removing Infoblox UDDI plugins..."

    unpatch_loader "$IPAM_LOADER" "$IPAM_USE" "$IPAM_REG"
    unpatch_loader "$DNS_LOADER" "$DNS_USE" "$DNS_REG"

    [ -f "$IPAM_PLUGIN_DST" ] && rm -f "$IPAM_PLUGIN_DST"
    [ -f "$DNS_PLUGIN_DST" ] && rm -f "$DNS_PLUGIN_DST"

    # Remove JS symlink and file
    [ -L "$JS_LINK" ] && rm -f "$JS_LINK"
    [ -f "$JS_DST" ] && rm -f "$JS_DST"

    # Remove script tag from index.html.tpl
    if [ -f "$INDEX_TPL" ] && grep -qF "infobloxuddi-sdn.js" "$INDEX_TPL"; then
        grep -vF "infobloxuddi-sdn.js" "$INDEX_TPL" > "${INDEX_TPL}.tmp" && mv "${INDEX_TPL}.tmp" "$INDEX_TPL"
    fi

    echo "Infoblox UDDI plugins removed successfully."
else
    # ── Install flow ─────────────────────────────────────────────────────
    echo "Installing Infoblox UDDI plugins..."

    check_prereqs

    # Create destination directories if needed
    mkdir -p "$(dirname "$IPAM_PLUGIN_DST")"
    mkdir -p "$(dirname "$DNS_PLUGIN_DST")"

    # Copy plugin files
    cp "$IPAM_PLUGIN_SRC" "$IPAM_PLUGIN_DST"
    cp "$DNS_PLUGIN_SRC" "$DNS_PLUGIN_DST"

    # Copy JS file and create symlink
    mkdir -p "$(dirname "$JS_DST")"
    cp "$JS_SRC" "$JS_DST"
    ln -sf "$JS_DST" "$JS_LINK"

    # Patch index.html.tpl to load our JS
    if [ -f "$INDEX_TPL" ] && ! grep -qF "infobloxuddi-sdn.js" "$INDEX_TPL"; then
        sed -i '/pvemanagerlib\.js/a\    '"$JS_SCRIPT_TAG" "$INDEX_TPL"
    fi

    # Back up loader files before patching (only if backup does not exist)
    [ ! -f "${IPAM_LOADER}.bak" ] && cp "$IPAM_LOADER" "${IPAM_LOADER}.bak"
    [ ! -f "${DNS_LOADER}.bak" ] && cp "$DNS_LOADER" "${DNS_LOADER}.bak"

    # Patch loader files (idempotent)
    patch_loader "$IPAM_LOADER" "$IPAM_USE" "$IPAM_REG" "Ipams::Plugin->init"
    patch_loader "$DNS_LOADER" "$DNS_USE" "$DNS_REG" "Dns::Plugin->init"

    echo "Infoblox UDDI plugins installed successfully."
fi

# Prompt for service restart
read -r -p "Restart pveproxy and pvedaemon now? [y/N] " response
if [[ "$response" =~ ^[Yy]$ ]]; then
    systemctl restart pveproxy
    systemctl restart pvedaemon
    echo "Services restarted."
else
    echo "Skipping service restart. Run manually when ready:"
    echo "  systemctl restart pveproxy pvedaemon"
fi
