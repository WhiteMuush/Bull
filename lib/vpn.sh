#!/usr/bin/env bash
# =============================================================================
# BULL - lib/vpn.sh
# VPN configuration with kill switch support (OpenVPN & WireGuard)
# =============================================================================

[[ -n "${_BULL_VPN_LOADED:-}" ]] && return 0
readonly _BULL_VPN_LOADED=1

# ---------------------------------------------------------------------------
# VPN Type Detection
# ---------------------------------------------------------------------------

detect_vpn_type() {
    local config_file="$1"

    if [[ ! -f "${config_file}" ]]; then
        log_error "VPN config file not found: ${config_file}"
        return 1
    fi

    # Check extension first
    case "${config_file}" in
        *.ovpn|*.conf)
            if grep -q "^\[Interface\]" "${config_file}" 2>/dev/null; then
                echo "wireguard"
            else
                echo "openvpn"
            fi
            ;;
        *.wg|*.wgconf)
            echo "wireguard"
            ;;
        *)
            # Fall back to content inspection
            if grep -q "^\[Interface\]" "${config_file}" 2>/dev/null \
               && grep -q "^\[Peer\]" "${config_file}" 2>/dev/null; then
                echo "wireguard"
            elif grep -qE "^(client|remote |proto |dev )" "${config_file}" 2>/dev/null; then
                echo "openvpn"
            else
                log_error "Cannot determine VPN type from '${config_file}'"
                return 1
            fi
            ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# VPN Configuration
# ---------------------------------------------------------------------------

configure_vpn() {
    local vm_name="$1"
    local config_file="$2"

    require_argument "${vm_name}" "vm name" || return 1
    require_argument "${config_file}" "vpn config file" || return 1
    validate_vm_name "${vm_name}" || return 1

    # Verify config file exists on host
    if [[ ! -f "${config_file}" ]]; then
        log_error "VPN config file not found: ${config_file}"
        return 1
    fi

    # Verify VM exists and is running
    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    local current_status
    current_status=$(jq -r --arg name "${vm_name}" \
        '.vms[] | select(.name == $name) | .status' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ "${current_status}" != "running" ]]; then
        log_error "VM '${vm_name}' must be running to configure VPN (status: ${current_status})"
        return 1
    fi

    # Detect VPN type
    local vpn_type
    vpn_type=$(detect_vpn_type "${config_file}") || return 1

    log_info "Detected VPN type: ${vpn_type}"
    log_info "Configuring VPN on VM '${vm_name}'..."

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    # Create VPN directory in VM folder
    mkdir -p "${vm_dir}/vpn"

    # Copy config to VM directory
    local config_basename
    config_basename=$(basename "${config_file}")
    cp "${config_file}" "${vm_dir}/vpn/${config_basename}"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would configure ${vpn_type} VPN on '${vm_name}'"
        inventory_update "${vm_name}" "vpn_configured" "true"
        return 0
    fi

    # Upload config to VM
    (cd "${vm_dir}" && vagrant upload "vpn/${config_basename}" "/tmp/${config_basename}") || {
        log_error "Failed to upload VPN config to VM"
        return 1
    }

    case "${vpn_type}" in
        openvpn)
            setup_openvpn "${vm_name}" "${vm_dir}" "${config_basename}" || return 1
            ;;
        wireguard)
            setup_wireguard "${vm_name}" "${vm_dir}" "${config_basename}" || return 1
            ;;
    esac

    # Set up kill switch
    setup_kill_switch "${vm_name}" "${vpn_type}" || {
        log_warn "Kill switch setup failed. VPN configured without kill switch."
    }

    # Update inventory
    inventory_update "${vm_name}" "vpn_configured" "true"

    log_success "VPN configured on VM '${vm_name}'"
    log_info "Verify with: bull connect ${vm_name}, then 'curl ifconfig.me'"
    return 0
}

# ---------------------------------------------------------------------------
# OpenVPN Setup
# ---------------------------------------------------------------------------

setup_openvpn() {
    local vm_name="$1"
    local vm_dir="$2"
    local config_name="$3"

    log_info "Installing and configuring OpenVPN..."

    local setup_script
    read -r -d '' setup_script << 'PROVISION_EOF' || true
#!/usr/bin/env bash
set -euo pipefail

CONFIG_NAME="__CONFIG_NAME__"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openvpn > /dev/null 2>&1

mkdir -p /etc/openvpn/client
cp "/tmp/${CONFIG_NAME}" "/etc/openvpn/client/client.conf"

systemctl enable openvpn-client@client
systemctl start openvpn-client@client

echo "OpenVPN configured successfully"
PROVISION_EOF

    setup_script="${setup_script//__CONFIG_NAME__/${config_name}}"

    # Write to temp file, upload, execute as root, clean up
    local tmp_script
    tmp_script=$(mktemp /tmp/bull_ovpn_XXXXXX.sh)
    chmod 600 "${tmp_script}"
    echo "${setup_script}" > "${tmp_script}"
    (cd "${vm_dir}" && vagrant upload "${tmp_script}" "/tmp/bull_ovpn_setup.sh") || {
        rm -f "${tmp_script}"
        log_error "Failed to upload OpenVPN setup script to VM"
        return 1
    }
    rm -f "${tmp_script}"
    (cd "${vm_dir}" && vagrant ssh -c "sudo bash /tmp/bull_ovpn_setup.sh && rm -f /tmp/bull_ovpn_setup.sh" 2>&1) || {
        log_error "Failed to configure OpenVPN inside VM"
        return 1
    }

    log_debug "OpenVPN installed and started"
    return 0
}

# ---------------------------------------------------------------------------
# WireGuard Setup
# ---------------------------------------------------------------------------

setup_wireguard() {
    local vm_name="$1"
    local vm_dir="$2"
    local config_name="$3"

    log_info "Installing and configuring WireGuard..."

    local setup_script
    read -r -d '' setup_script << 'PROVISION_EOF' || true
#!/usr/bin/env bash
set -euo pipefail

CONFIG_NAME="__CONFIG_NAME__"

# Install WireGuard
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard > /dev/null 2>&1

# Move config into place
cp "/tmp/${CONFIG_NAME}" "/etc/wireguard/wg0.conf"
chmod 600 /etc/wireguard/wg0.conf

# Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

echo "WireGuard configured successfully"
PROVISION_EOF

    setup_script="${setup_script//__CONFIG_NAME__/${config_name}}"

    local tmp_script
    tmp_script=$(mktemp /tmp/bull_wg_XXXXXX.sh)
    chmod 600 "${tmp_script}"
    echo "${setup_script}" > "${tmp_script}"
    (cd "${vm_dir}" && vagrant upload "${tmp_script}" "/tmp/bull_wg_setup.sh") || {
        rm -f "${tmp_script}"
        log_error "Failed to upload WireGuard setup script to VM"
        return 1
    }
    rm -f "${tmp_script}"
    (cd "${vm_dir}" && vagrant ssh -c "sudo bash /tmp/bull_wg_setup.sh && rm -f /tmp/bull_wg_setup.sh" 2>&1) || {
        log_error "Failed to configure WireGuard inside VM"
        return 1
    }

    log_debug "WireGuard installed and started"
    return 0
}

# ---------------------------------------------------------------------------
# Kill Switch (iptables)
# ---------------------------------------------------------------------------

# Block all traffic except through VPN interface
setup_kill_switch() {
    local vm_name="$1"
    local vpn_type="$2"
    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    local vpn_iface
    case "${vpn_type}" in
        openvpn)   vpn_iface="tun0" ;;
        wireguard) vpn_iface="wg0" ;;
    esac

    log_info "Configuring kill switch (blocking non-VPN traffic)..."

    local killswitch_script
    read -r -d '' killswitch_script << PROVISION_EOF || true
#!/usr/bin/env bash
set -euo pipefail

VPN_IFACE="${vpn_iface}"

# Install iptables-persistent so rules survive reboots
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq iptables-persistent netfilter-persistent > /dev/null 2>&1

# Flush existing rules
iptables -F
iptables -X

# Default policies: allow input, drop output and forward
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Allow VPN interface
iptables -A OUTPUT -o "\${VPN_IFACE}" -j ACCEPT
iptables -A INPUT -i "\${VPN_IFACE}" -j ACCEPT

# Allow LAN traffic (for Vagrant SSH and management)
iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
iptables -A INPUT -s 10.0.0.0/8 -j ACCEPT
iptables -A INPUT -s 172.16.0.0/12 -j ACCEPT
iptables -A INPUT -s 192.168.0.0/16 -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Persist rules across reboots
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
netfilter-persistent save > /dev/null 2>&1 || true

echo "Kill switch configured on \${VPN_IFACE}"
PROVISION_EOF

    local tmp_script
    tmp_script=$(mktemp /tmp/bull_ks_XXXXXX.sh)
    chmod 600 "${tmp_script}"
    echo "${killswitch_script}" > "${tmp_script}"
    (cd "${vm_dir}" && vagrant upload "${tmp_script}" "/tmp/bull_ks_setup.sh") || {
        rm -f "${tmp_script}"
        log_error "Failed to upload kill switch script to VM"
        return 1
    }
    rm -f "${tmp_script}"
    (cd "${vm_dir}" && vagrant ssh -c "sudo bash /tmp/bull_ks_setup.sh && rm -f /tmp/bull_ks_setup.sh" 2>&1) || {
        log_error "Failed to configure kill switch"
        return 1
    }

    # Save kill switch script locally for reference
    echo "${killswitch_script}" > "${vm_dir}/vpn/killswitch.sh"

    log_success "Kill switch active (interface: ${vpn_iface})"
    return 0
}

# ---------------------------------------------------------------------------
# VPN Verification
# ---------------------------------------------------------------------------

verify_vpn() {
    local vm_name="$1"

    require_argument "${vm_name}" "vm name" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found"
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    log_info "Verifying VPN status on '${vm_name}'..."

    local check_script
    read -r -d '' check_script << 'PROVISION_EOF' || true
#!/usr/bin/env bash
echo "=== VPN Interface Check ==="
if ip a show tun0 &>/dev/null; then
    echo "FOUND: tun0 (OpenVPN)"
    ip a show tun0 | grep inet
elif ip a show wg0 &>/dev/null; then
    echo "FOUND: wg0 (WireGuard)"
    ip a show wg0 | grep inet
else
    echo "NOT FOUND: No VPN interface detected"
    exit 1
fi

echo ""
echo "=== External IP ==="
EXTERNAL_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "UNREACHABLE")
echo "External IP: ${EXTERNAL_IP}"

echo ""
echo "=== DNS Leak Check ==="
DNS_SERVER=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')
echo "DNS Server: ${DNS_SERVER}"
PROVISION_EOF

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would verify VPN on '${vm_name}'"
        return 0
    fi

    (cd "${vm_dir}" && vagrant ssh -c "${check_script}" 2>&1) || {
        log_error "VPN verification failed"
        return 1
    }

    return 0
}
