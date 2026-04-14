#!/usr/bin/env bash
# =============================================================================
# BULL - lib/vagrant.sh
# Vagrant/VirtualBox VM lifecycle management
# =============================================================================

[[ -n "${_BULL_VAGRANT_LOADED:-}" ]] && return 0
readonly _BULL_VAGRANT_LOADED=1

# ---------------------------------------------------------------------------
# libvirt helpers (bypass Vagrant SSH for lifecycle ops on WSL2)
# ---------------------------------------------------------------------------

# Detect and cache the correct libvirt connection URI.
# Tries qemu:///system (user in 'libvirt' group) then falls back to
# qemu:///session (rootless libvirt).
_LIBVIRT_URI_CACHED=""
_libvirt_uri() {
    if [[ -n "${_LIBVIRT_URI_CACHED}" ]]; then
        echo "${_LIBVIRT_URI_CACHED}"
        return 0
    fi
    if virsh -c qemu:///system list &>/dev/null; then
        _LIBVIRT_URI_CACHED="qemu:///system"
    else
        _LIBVIRT_URI_CACHED="qemu:///session"
    fi
    echo "${_LIBVIRT_URI_CACHED}"
}

# Return the libvirt domain name that vagrant-libvirt assigned to a VM.
# Format: <vm_dir_basename>_default
_libvirt_domain() {
    local vm_name="$1"
    echo "$(basename "$(get_vm_dir "${vm_name}")")_default"
}

# Stop a libvirt VM via virsh (graceful ACPI → force-off after 20 s).
_libvirt_stop() {
    local domain="$1"
    local uri
    uri="$(_libvirt_uri)"
    local timeout=20

    # Send ACPI shutdown signal; if the command itself fails, go straight to force-off
    if virsh -c "${uri}" shutdown "${domain}" &>/dev/null; then
        local elapsed=0
        while [[ $elapsed -lt $timeout ]]; do
            sleep 2
            elapsed=$(( elapsed + 2 ))
            if ! virsh -c "${uri}" list --state-running --name 2>/dev/null \
                 | grep -q "^${domain}$"; then
                log_debug "VM stopped gracefully"
                return 0
            fi
        done
        log_warn "VM did not stop within ${timeout}s, forcing off..."
    else
        log_warn "Graceful shutdown signal failed, forcing off..."
    fi

    # Force power-off
    virsh -c "${uri}" destroy "${domain}" &>/dev/null || {
        log_error "Failed to force-stop domain '${domain}'"
        return 1
    }
    return 0
}

# Start a libvirt VM via virsh.
_libvirt_start() {
    local domain="$1"
    local uri
    uri="$(_libvirt_uri)"
    virsh -c "${uri}" start "${domain}" &>/dev/null
}

# Destroy a libvirt domain and remove its storage.
# Returns 0 always — caller is responsible for directory cleanup.
_libvirt_destroy() {
    local domain="$1"
    local uri
    uri="$(_libvirt_uri)"

    # 1. Force power-off (safe to ignore: already stopped or not found)
    virsh -c "${uri}" destroy "${domain}" &>/dev/null || true
    sleep 1

    # 2. Collect storage volume paths BEFORE undefining (undefine may remove them
    #    from the domain XML, making them unreachable afterward).
    local vol_paths=()
    while IFS= read -r vol; do
        [[ -n "${vol}" ]] && vol_paths+=("${vol}")
    done < <(virsh -c "${uri}" domblklist "${domain}" --details 2>/dev/null \
        | awk '$2 == "disk" && $4 != "-" { print $4 }')

    # 3. Remove all snapshot metadata (avoids "has snapshots" undefine errors)
    virsh -c "${uri}" snapshot-list --domain "${domain}" --name 2>/dev/null \
        | while IFS= read -r snap; do
            [[ -n "${snap}" ]] && \
                virsh -c "${uri}" snapshot-delete \
                    --domain "${domain}" --snapshotname "${snap}" \
                    --metadata &>/dev/null || true
          done

    # 4. Try undefine with full storage removal (preferred path)
    if ! virsh -c "${uri}" undefine "${domain}" \
            --remove-all-storage \
            --snapshots-metadata \
            --nvram &>/dev/null 2>&1; then

        # 5. Fallback: undefine the domain definition only
        virsh -c "${uri}" undefine "${domain}" \
            --snapshots-metadata &>/dev/null 2>&1 || \
        virsh -c "${uri}" undefine "${domain}" &>/dev/null || true

        # 6. Manually delete the disk images that --remove-all-storage missed
        local vol
        for vol in "${vol_paths[@]}"; do
            if [[ -f "${vol}" ]]; then
                virsh -c "${uri}" vol-delete --pool default "${vol}" \
                    &>/dev/null 2>&1 || \
                rm -f "${vol}" 2>/dev/null || true
            fi
        done
    fi

    return 0
}

# Get the IP of a running libvirt VM via virsh domifaddr.
_libvirt_get_ip() {
    local domain="$1"
    local uri
    uri="$(_libvirt_uri)"
    virsh -c "${uri}" domifaddr "${domain}" 2>/dev/null \
        | awk '/ipv4/ { split($4, a, "/"); print a[1]; exit }'
}

# Ensure the vagrant-libvirt network is active and its route is in the kernel
# routing table. Called before SSH so "No route to host" doesn't occur.
_libvirt_ensure_network() {
    local ip="$1"
    local uri
    uri="$(_libvirt_uri)"

    # Activate vagrant-libvirt network if it exists but is not running
    local net_state
    net_state=$(virsh -c "${uri}" net-info vagrant-libvirt 2>/dev/null \
        | awk '/^Active:/ {print $2}')
    if [[ "${net_state}" == "no" ]]; then
        log_info "Starting vagrant-libvirt network..."
        virsh -c "${uri}" net-start vagrant-libvirt &>/dev/null || true
        sleep 1
    fi

    # If the IP is already routable, nothing more to do
    ip route get "${ip}" &>/dev/null && return 0

    # Find the bridge interface for this network and add the missing route
    local bridge subnet
    bridge=$(virsh -c "${uri}" net-info vagrant-libvirt 2>/dev/null \
        | awk '/^Bridge:/ {print $2}')
    if [[ -z "${bridge}" ]]; then
        # Fall back: pick any virbr interface
        bridge=$(ip -o link show type bridge 2>/dev/null \
            | grep -oE 'virbr[0-9]+' | head -1)
    fi

    if [[ -n "${bridge}" ]] && ip link show "${bridge}" &>/dev/null; then
        subnet="${ip%.*}.0/24"
        log_info "Adding missing route ${subnet} via ${bridge}..."
        sudo ip route add "${subnet}" dev "${bridge}" 2>/dev/null || true
        sleep 1
    fi
}

# SSH directly into a libvirt VM using Vagrant's generated key.
_libvirt_ssh() {
    local vm_name="$1"
    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"
    local key="${vm_dir}/.vagrant/machines/default/libvirt/private_key"

    # Resolve IP from inventory first, then live virsh lookup
    local ip
    ip=$(jq -r --arg n "${vm_name}" \
        '.vms[] | select(.name == $n) | .ip // ""' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ -z "${ip}" ]] || [[ "${ip}" == "null" ]]; then
        local domain
        domain="$(_libvirt_domain "${vm_name}")"
        ip="$(_libvirt_get_ip "${domain}")"
    fi

    if [[ -z "${ip}" ]]; then
        log_error "Cannot determine VM IP for SSH"
        return 1
    fi

    if [[ ! -f "${key}" ]]; then
        log_error "SSH private key not found: ${key}"
        log_info "The VM may still be provisioning, or try: bull sync"
        return 1
    fi

    # Resolve SSH username: prefer the one stored in .credentials, fall back to vagrant
    local ssh_user="vagrant"
    local cred_file="${vm_dir}/.credentials"
    if [[ -f "${cred_file}" ]]; then
        local stored_user
        stored_user=$(grep '^username=' "${cred_file}" | cut -d= -f2)
        [[ -n "${stored_user}" ]] && ssh_user="${stored_user}"
    fi

    # Make sure the libvirt network route is present before connecting
    _libvirt_ensure_network "${ip}"

    log_info "Connecting to ${vm_name} (${ip}) as ${ssh_user}..."

    if [[ "${ssh_user}" != "vagrant" ]]; then
        if ! command -v sshpass &>/dev/null; then
            log_error "sshpass is required for password-based SSH. Install it with:"
            echo "  sudo apt install sshpass   (Debian/Ubuntu)"
            echo "  sudo dnf install sshpass   (Fedora)"
            echo "  sudo pacman -S sshpass     (Arch)"
            return 1
        fi

        read -rs -p "Password for ${ssh_user}@${ip}: " user_pass
        echo
        sshpass -p "${user_pass}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${ssh_user}@${ip}"
    else
        ssh -i "${key}" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -o LogLevel=ERROR \
            "${ssh_user}@${ip}"
    fi
}

# ---------------------------------------------------------------------------
# OS / Vagrant box mapping
# ---------------------------------------------------------------------------
readonly BULL_OS_KALI="kali"
# shellcheck disable=SC2034
readonly BULL_OS_PARROT="parrot"
readonly BULL_DEFAULT_OS="${BULL_OS_KALI}"

# Parrot Security OS box name depends on provider:
# - libvirt: custom box built from QCOW2 (bull/parrot-security)
# - virtualbox: use cloudkats/parrotsec-os from Vagrant Cloud fallback to OVA
readonly PARROT_VERSION="7.1"

if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
    readonly PARROT_BOX_NAME="bull/parrot-security"
else
    readonly PARROT_BOX_NAME="cloudkats/parrotsec-os"
fi
readonly PARROT_OVA_URL="https://download.parrot.sh/parrot/iso/${PARROT_VERSION}/Parrot-security-${PARROT_VERSION}_amd64.ova"
readonly PARROT_OVA_URL_ALT="https://download.parrotsec.org/parrot/iso/${PARROT_VERSION}/Parrot-security-${PARROT_VERSION}_amd64.ova"
readonly PARROT_QCOW2_URL="https://download.parrot.sh/parrot/iso/${PARROT_VERSION}/Parrot-security-${PARROT_VERSION}_amd64.qcow2"
readonly PARROT_QCOW2_URL_ALT="https://download.parrotsec.org/parrot/iso/${PARROT_VERSION}/Parrot-security-${PARROT_VERSION}_amd64.qcow2"
readonly PARROT_OVA_FILENAME="Parrot-security-${PARROT_VERSION}_amd64.ova"
readonly PARROT_QCOW2_FILENAME="Parrot-security-${PARROT_VERSION}_amd64.qcow2"

# Map OS identifier → Vagrant box name
_os_to_box() {
    local os="$1"
    case "${os}" in
        kali)   echo "kalilinux/rolling" ;;
        parrot) echo "${PARROT_BOX_NAME}" ;;
        *)
            log_error "Unknown OS: ${os}"
            return 1
            ;;
    esac
}

# Map OS identifier → human-readable label
_os_label() {
    local os="$1"
    case "${os}" in
        kali)   echo "Kali Linux" ;;
        parrot) echo "Parrot Security" ;;
        *)      echo "${os}" ;;
    esac
}

# Map OS identifier → default username
_os_default_user() {
    local os="$1"
    case "${os}" in
        kali)   echo "admin" ;;
        parrot) echo "admin" ;;
        *)      echo "user" ;;
    esac
}

# ---------------------------------------------------------------------------
# Vagrant box management
# ---------------------------------------------------------------------------

# Check if a Vagrant box is locally cached, download from Vagrant Cloud if not.
ensure_vagrant_box() {
    local os="${1:-${BULL_DEFAULT_OS}}"
    local box label

    box="$(_os_to_box "${os}")" || return 1
    label="$(_os_label "${os}")"

    # Check if box is registered AND if the actual image file exists
    local box_registered=0
    local image_exists=0
    
    if "${VAGRANT_CMD}" box list 2>/dev/null | grep -q "${box}"; then
        box_registered=1
    fi
    
    # Check if the actual image file exists in vagrant.d
    local vagrant_home="${VAGRANT_HOME:-${HOME}/.vagrant.d}"
    local encoded_name="${box//\//-VAGRANTSLASH-}"
    local image_path="${vagrant_home}/boxes/${encoded_name}/0/amd64/libvirt/box.img"
    if [[ -f "${image_path}" ]]; then
        image_exists=1
    fi
    
    # For Parrot, check the specific qcow2 filename
    if [[ "${os}" == "parrot" ]]; then
        image_path="${vagrant_home}/boxes/${encoded_name}/0/amd64/libvirt/Parrot-security-${PARROT_VERSION}-amd64.qcow2"
        if [[ -f "${image_path}" ]]; then
            image_exists=1
        fi
    fi
    
    # Already registered AND image exists - we're good
    if [[ "${box_registered}" -eq 1 ]] && [[ "${image_exists}" -eq 1 ]]; then
        log_debug "${label} box already cached"
        return 0
    fi
    
    # Box registered but image missing - clean up and re-register
    if [[ "${box_registered}" -eq 1 ]] && [[ "${image_exists}" -eq 0 ]]; then
        log_warn "Box '${box}' registered but image file missing - cleaning up"
        vagrant box remove "${box}" --force 2>/dev/null || true
        rm -rf "${vagrant_home}/boxes/${encoded_name}" 2>/dev/null || true
    fi

    # Dry-run: skip the actual download
    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would download ${label} box '${box}' for ${BULL_PROVIDER}"
        return 0
    fi

    log_warn "Vagrant box '${box}' is not available locally."
    echo -en "${YELLOW}[WARN]${RESET} Download and install it now? [Y/n]: "

    # Auto-accept in non-interactive mode
    if [[ ! -t 0 ]]; then
        echo "y"
    fi

    local answer
    read -r answer
    answer="${answer:-y}"

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        log_info "Skipped. Re-run when ready."
        return 1
    fi

    # For Parrot: use dedicated pipeline (OVA for VirtualBox, QCOW2 for libvirt)
    if [[ "${os}" == "parrot" ]]; then
        _ensure_parrot_box
        return $?
    fi

    # Kali (and any future OS with a Vagrant Cloud box): direct download
    log_info "Downloading ${label} box for ${BULL_PROVIDER} (this may take a while)..."
    if "${VAGRANT_CMD}" box add "${box}" --provider "${BULL_PROVIDER}" 2>&1; then
        log_success "${label} box downloaded and ready."
        return 0
    else
        log_error "Failed to download ${label} box."
        log_info "Try manually: ${VAGRANT_CMD} box add ${box} --provider ${BULL_PROVIDER}"
        return 1
    fi
}

# Backward-compatible alias
ensure_kali_box() {
    ensure_vagrant_box "kali"
}

# ---------------------------------------------------------------------------
# Parrot OS — OVA download → VirtualBox import → Vagrant box packaging
#
# Parrot Security has no official Vagrant box on Vagrant Cloud. The project
# distributes pre-built OVA images for VirtualBox. This pipeline:
#   1. Downloads the official OVA (~9 GB)
#   2. Imports it into VirtualBox as a temporary VM ("bull-parrot-base")
#   3. Boots it to inject a "vagrant" user with the Vagrant insecure SSH key
#   4. Packages it as a .box file
#   5. Registers it in Vagrant as "bull/parrot-security"
#   6. Cleans up the temporary VM
# ---------------------------------------------------------------------------

# Download the official Parrot Security OVA to $BULL_HOME/boxes/.
# Supports resume on interruption. Prints the local file path on success.
_parrot_download_ova() {
    local ova_path="${BULL_HOME}/boxes/${PARROT_OVA_FILENAME}"
    mkdir -p "${BULL_HOME}/boxes"

    if [[ -f "${ova_path}" ]]; then
        log_info "Parrot OVA already downloaded: ${ova_path}"
        echo "${ova_path}"
        return 0
    fi

    log_info "Downloading Parrot Security OVA (~9 GB, this may take a while)..."
    log_info "URL: ${PARROT_OVA_URL}"
    log_info "If interrupted, re-run to resume the download."
    echo ""

    # Check for a partial download to resume
    local partial_path="${ova_path}.part"
    local resume_flag=""
    if [[ -f "${partial_path}" ]]; then
        local partial_size
        partial_size=$(stat -c%s "${partial_path}" 2>/dev/null || stat -f%z "${partial_path}" 2>/dev/null || echo 0)
        if [[ "${partial_size}" -gt 0 ]]; then
            log_info "Resuming from partial download (${partial_size} bytes already downloaded)..."
            resume_flag="-C -"
        fi
    fi

    local dl_ok=0
    if command -v curl &>/dev/null; then
        # shellcheck disable=SC2086
        curl -fL ${resume_flag} --progress-bar -o "${partial_path}" "${PARROT_OVA_URL}" && dl_ok=1
        if [[ "${dl_ok}" -eq 0 ]]; then
            log_warn "Primary URL failed, trying alternate mirror..."
            curl -fL -C - --progress-bar -o "${partial_path}" "${PARROT_OVA_URL_ALT}" && dl_ok=1
        fi
    elif command -v wget &>/dev/null; then
        wget -c --show-progress -O "${partial_path}" "${PARROT_OVA_URL}" && dl_ok=1
        if [[ "${dl_ok}" -eq 0 ]]; then
            log_warn "Primary URL failed, trying alternate mirror..."
            wget -c --show-progress -O "${partial_path}" "${PARROT_OVA_URL_ALT}" && dl_ok=1
        fi
    else
        log_error "Neither curl nor wget is available — cannot download."
        return 1
    fi

    if [[ "${dl_ok}" -eq 0 ]]; then
        log_error "Failed to download Parrot OVA from both mirrors."
        log_info "Partial download kept at: ${partial_path}"
        log_info "Re-run to resume the download."
        return 1
    fi

    # Move completed download to final location
    mv "${partial_path}" "${ova_path}"

    log_success "OVA downloaded: ${ova_path}"
    echo "${ova_path}"
    return 0
}

# Download Parrot QCOW2 for libvirt.
# Supports resume on interruption. Prints the local file path on success.
_parrot_download_qcow2() {
    local qcow2_path="${BULL_HOME}/boxes/${PARROT_QCOW2_FILENAME}"
    mkdir -p "${BULL_HOME}/boxes"

    if [[ -f "${qcow2_path}" ]]; then
        log_info "Parrot QCOW2 already downloaded: ${qcow2_path}"
        printf "%s" "${qcow2_path}"
        return 0
    fi

    log_info "Downloading Parrot Security QCOW2 (~12 GB, this may take a while)..."
    log_info "URL: ${PARROT_QCOW2_URL}"
    log_info "If interrupted, re-run to resume the download."
    echo ""

    # Check for a partial download to resume
    local partial_path="${qcow2_path}.part"
    local resume_flag=""
    if [[ -f "${partial_path}" ]]; then
        local partial_size
        partial_size=$(stat -c%s "${partial_path}" 2>/dev/null || stat -f%z "${partial_path}" 2>/dev/null || echo 0)
        if [[ "${partial_size}" -gt 0 ]]; then
            log_info "Resuming from partial download (${partial_size} bytes already downloaded)..."
            resume_flag="-C -"
        fi
    fi

    local dl_ok=0
    if command -v curl &>/dev/null; then
        # shellcheck disable=SC2086
        curl -fL ${resume_flag} --progress-bar -o "${partial_path}" "${PARROT_QCOW2_URL}" && dl_ok=1
        if [[ "${dl_ok}" -eq 0 ]]; then
            log_warn "Primary URL failed, trying alternate mirror..."
            curl -fL -C - --progress-bar -o "${partial_path}" "${PARROT_QCOW2_URL_ALT}" && dl_ok=1
        fi
    elif command -v wget &>/dev/null; then
        wget -c --show-progress -O "${partial_path}" "${PARROT_QCOW2_URL}" && dl_ok=1
        if [[ "${dl_ok}" -eq 0 ]]; then
            log_warn "Primary URL failed, trying alternate mirror..."
            wget -c --show-progress -O "${partial_path}" "${PARROT_QCOW2_URL_ALT}" && dl_ok=1
        fi
    else
        log_error "Neither curl nor wget is available — cannot download."
        return 1
    fi

    if [[ "${dl_ok}" -eq 0 ]]; then
        log_error "Failed to download Parrot QCOW2 from both mirrors."
        log_info "Partial download kept at: ${partial_path}"
        log_info "Re-run to resume the download."
        return 1
    fi

    # Move completed download to final location
    mv "${partial_path}" "${qcow2_path}"

    log_success "QCOW2 downloaded: ${qcow2_path}"
    printf "%s" "${qcow2_path}"
    return 0
}

# Patch the Parrot QCOW2 image to enable DHCP on all NICs and enable SSH.
# Without this, the VM boots but never gets an IP (no DHCP client configured)
# and SSH is disabled at boot, so Vagrant hangs forever waiting for SSH.
_patch_parrot_qcow2() {
    local qcow2_path="$1"
    local patched_marker="${qcow2_path%.qcow2}.bull-patched"

    if [[ -f "${patched_marker}" ]]; then
        log_debug "Parrot QCOW2 already patched"
        return 0
    fi

    if ! command -v qemu-nbd &>/dev/null; then
        log_error "qemu-nbd not found — cannot patch Parrot image for DHCP+SSH."
        log_error "The VM will hang at IP assignment. Install qemu-utils and re-run."
        return 1
    fi

    log_info "Patching Parrot QCOW2: enabling DHCP + SSH on boot..."

    local nbd_dev=""
    local nbd_idx
    for nbd_idx in 0 1 2 3; do
        if [[ ! -e "/dev/nbd${nbd_idx}" ]]; then
            sudo modprobe nbd max_part=8 2>/dev/null || true
        fi
        if ! sudo qemu-nbd -c "/dev/nbd${nbd_idx}" "${qcow2_path}" &>/dev/null; then
            continue
        fi
        nbd_dev="/dev/nbd${nbd_idx}"
        break
    done

    if [[ -z "${nbd_dev}" ]]; then
        log_error "Could not connect QCOW2 via NBD — skipping DHCP+SSH patch."
        return 1
    fi

    # Give the kernel a moment to create partition devices
    sleep 2

    local mount_point
    mount_point=$(mktemp -d)

    local patched=0
    local partition=""

    # Parrot's QCOW2 uses GPT with:
    #   p1 = EFI System Partition (vfat)
    #   p2 = Root filesystem (btrfs with @ and @home subvolumes)
    if sudo mount -o rw "${nbd_dev}p2" "${mount_point}" &>/dev/null; then
        partition="p2"
    elif sudo mount -o rw "${nbd_dev}p1" "${mount_point}" &>/dev/null; then
        partition="p1"
    elif sudo mount -o rw "${nbd_dev}" "${mount_point}" &>/dev/null; then
        partition="whole"
    fi

    if [[ -z "${partition}" ]]; then
        sudo qemu-nbd -d "${nbd_dev}" &>/dev/null
        rmdir "${mount_point}" 2>/dev/null
        log_error "Could not mount Parrot root partition — skipping DHCP+SSH patch."
        {
            echo "=== _patch_parrot_qcow2: mount failed ==="
            lsblk "${nbd_dev}" 2>/dev/null || true
            blkid "${nbd_dev}"* 2>/dev/null || true
        } >> "${BULL_HOME}/bull-error.log" 2>/dev/null || true
        return 1
    fi

    local root_dir="${mount_point}"

    # If btrfs with @ subvolume, we must mount the @ subvolume specifically
    # (the root of a btrfs filesystem is the top-level subvolume, not @)
    if [[ -d "${mount_point}/@" ]] && [[ -d "${mount_point}/@/etc" ]]; then
        sudo umount "${mount_point}" 2>/dev/null || true
        sleep 0.5
        if sudo mount -o rw,subvol=@ "${nbd_dev}${partition}" "${mount_point}" &>/dev/null; then
            root_dir="${mount_point}"
            log_debug "Mounted btrfs @ subvolume successfully"
        else
            # Fallback: try remounting without subvol and use @ path directly
            if sudo mount -o rw "${nbd_dev}${partition}" "${mount_point}" &>/dev/null; then
                root_dir="${mount_point}/@"
                log_debug "Mounted btrfs top-level, using @ subdirectory"
            else
                sudo qemu-nbd -d "${nbd_dev}" &>/dev/null
                rmdir "${mount_point}" 2>/dev/null
                log_error "Could not mount Parrot btrfs @ subvolume — skipping DHCP+SSH patch."
                return 1
            fi
        fi
    fi

    if [[ ! -d "${root_dir}/etc" ]]; then
        sudo umount "${mount_point}" 2>/dev/null
        sudo qemu-nbd -d "${nbd_dev}" &>/dev/null
        rmdir "${mount_point}" 2>/dev/null
        log_error "Could not find /etc in Parrot image — skipping DHCP+SSH patch."
        return 1
    fi

    sudo mount -o remount,rw "${nbd_dev}${partition}" "${mount_point}" &>/dev/null || true

    sudo mkdir -p "${root_dir}/etc/network/interfaces.d"
    sudo bash -c "cat > '${root_dir}/etc/network/interfaces.d/99-dhcp-all.cfg'" <<'DHCP_EOF'
# BULL: Auto-configure all ethernet interfaces via DHCP
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp

allow-hotplug ens3
iface ens3 inet dhcp

allow-hotplug enp1s0
iface enp1s0 inet dhcp

allow-hotplug enp0s3
iface enp0s3 inet dhcp
DHCP_EOF

    if [[ -f "${root_dir}/etc/NetworkManager/NetworkManager.conf" ]]; then
        sudo sed -i 's/managed=false/managed=true/' "${root_dir}/etc/NetworkManager/NetworkManager.conf"
    fi

    local ssh_rc_dir
    for rc_dir in rc2.d rc3.d rc4.d rc5.d; do
        ssh_rc_dir="${root_dir}/etc/${rc_dir}"
        if [[ -d "${ssh_rc_dir}" ]]; then
            if [[ -L "${ssh_rc_dir}/K01ssh" ]]; then
                sudo mv "${ssh_rc_dir}/K01ssh" "${ssh_rc_dir}/S01ssh" 2>/dev/null || true
            fi
        fi
    done

    if [[ -d "${root_dir}/etc/systemd/system/multi-user.target.wants" ]]; then
        sudo ln -sf /lib/systemd/system/ssh.service \
            "${root_dir}/etc/systemd/system/multi-user.target.wants/ssh.service" 2>/dev/null || true
    fi

    # Enable PasswordAuthentication in sshd_config so Vagrant can connect
    # with username/password before the insecure key is set up.
    if [[ -f "${root_dir}/etc/ssh/sshd_config" ]]; then
        sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "${root_dir}/etc/ssh/sshd_config"
    fi

    # Set the default "user" password to "user" so Vagrant can SSH in
    # with config.ssh.username='user' / config.ssh.password='user'.
    # The BULL provision script later creates a custom user and locks this one.
    sudo bash -c "echo 'user:user' | chroot '${root_dir}' chpasswd"

    # Inject the Vagrant insecure public key into the default user's
    # authorized_keys so Vagrant can SSH in immediately after boot.
    # Parrot's default user is "user" (uid 1000).
    local vagrant_key_dir="${root_dir}/home/user/.ssh"
    sudo mkdir -p "${vagrant_key_dir}"
    sudo chmod 700 "${vagrant_key_dir}"

    # The Vagrant insecure public key (standard across all Vagrant installations).
    # Extracted from ~/.vagrant.d/insecure_private_key at build time.
    sudo bash -c "cat > '${vagrant_key_dir}/authorized_keys'" <<'VAGRANTKEY_EOF'
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant
VAGRANTKEY_EOF
    sudo chmod 600 "${vagrant_key_dir}/authorized_keys"
    sudo chown -R "$(id -u user 2>/dev/null || echo 1000):$(id -g user 2>/dev/null || echo 1000)" "${vagrant_key_dir}" 2>/dev/null || true

    sudo touch "${patched_marker}"
    patched=1

    sudo umount "${mount_point}" 2>/dev/null || true
    sudo qemu-nbd -d "${nbd_dev}" &>/dev/null
    rmdir "${mount_point}" 2>/dev/null

    if [[ "${patched}" -eq 1 ]]; then
        log_success "Parrot QCOW2 patched: DHCP + SSH + Vagrant key"
    fi
    return 0
}

# Ensure Parrot box for libvirt (QCOW2)
_ensure_parrot_qcow2() {
    local box_name="${PARROT_BOX_NAME}"
    local box_dir="${BULL_HOME}/boxes"
    local vagrant_home="${VAGRANT_HOME:-${HOME}/.vagrant.d}"
    # Vagrant encodes "/" in box names as "-VAGRANTSLASH-"
    local encoded_name
    encoded_name="${box_name//\//-VAGRANTSLASH-}"
    local version="0"

    # Check if box is registered AND if the actual qcow2 file exists
    local box_registered=0
    local qcow2_exists=0
    
    if "${VAGRANT_CMD}" box list 2>/dev/null | grep -q "${box_name}"; then
        box_registered=1
    fi
    
    # Check if the qcow2 file actually exists
    local qcow2_path="${vagrant_home}/boxes/${encoded_name}/${version}/amd64/libvirt/Parrot-security-${PARROT_VERSION}-amd64.qcow2"
    if [[ -f "${qcow2_path}" ]]; then
        qcow2_exists=1
    fi
    
    # Already registered AND file exists - we're good
    if [[ "${box_registered}" -eq 1 ]] && [[ "${qcow2_exists}" -eq 1 ]]; then
        log_debug "Parrot box '${box_name}' already registered with valid qcow2"
        return 0
    fi
    
    # Box registered but qcow2 missing - clean up and re-register
    if [[ "${box_registered}" -eq 1 ]] && [[ "${qcow2_exists}" -eq 0 ]]; then
        log_warn "Parrot box registered but qcow2 file missing - cleaning up"
        vagrant box remove "${box_name}" --force 2>/dev/null || true
        rm -rf "${vagrant_home}/boxes/${encoded_name}" 2>/dev/null || true
    fi

    # Dry-run: skip the actual download and registration
    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would download Parrot QCOW2 and register as '${box_name}'"
        return 0
    fi

    # Download QCOW2
    local qcow2_path
    qcow2_path="$(_parrot_download_qcow2)" || return 1

    # ---------------------------------------------------------------
    # Strategy: install the box directly into Vagrant's internal
    # directory. This bypasses the slow tar → gzip → vagrant box add
    # → untar cycle (12 GB read+write twice). Instead, we hard-link
    # the QCOW2 file — instant regardless of file size.
    #
    # Vagrant-libvirt expects this layout:
    #   ~/.vagrant.d/boxes/<encoded_name>/<version>/amd64/libvirt/
    #       metadata.json    (provider, format, architecture, disks)
    #       <diskfile>.qcow2 (referenced by "path" in metadata.json)
    #       Vagrantfile      (optional, libvirt settings)
    #   ~/.vagrant.d/boxes/<encoded_name>/metadata_url
    # ---------------------------------------------------------------
    local version="0"
    local disk_name="Parrot-security-${PARROT_VERSION}-amd64.qcow2"
    local vagrant_box_dir="${vagrant_home}/boxes/${encoded_name}/${version}/amd64/libvirt"

    log_info "Installing Parrot box as '${box_name}'..."

    # Remove any previous incomplete attempt
    rm -rf "${vagrant_home}/boxes/${encoded_name}"

    mkdir -p "${vagrant_box_dir}"

    # metadata.json — must match the format Vagrant expects for libvirt boxes
    cat > "${vagrant_box_dir}/metadata.json" <<METADATA_EOF
{
    "provider": "libvirt",
    "format": "qcow2",
    "architecture": "amd64",
    "disks": [
        {
            "format": "qcow2",
            "path": "${disk_name}"
        }
    ]
}
METADATA_EOF

    # Hard-link or copy. If the image was previously patched (BULL marker),
    # hard-link the patched copy in BULL_HOME instead of the original download.
    local src_qcow2="${qcow2_path}"
    if [[ -f "${BULL_HOME}/boxes/Parrot-security-${PARROT_VERSION}-amd64-patched.qcow2" ]]; then
        src_qcow2="${BULL_HOME}/boxes/Parrot-security-${PARROT_VERSION}-amd64-patched.qcow2"
    fi

    ln -f "${src_qcow2}" "${vagrant_box_dir}/${disk_name}" 2>/dev/null \
        || cp "${src_qcow2}" "${vagrant_box_dir}/${disk_name}"

    if ! _patch_parrot_qcow2 "${vagrant_box_dir}/${disk_name}"; then
        log_error "Failed to patch Parrot QCOW2 — VM will not have network/SSH."
        rm -rf "${vagrant_home}/boxes/${encoded_name}"
        return 1
    fi

    # Vagrantfile for the box (minimal libvirt settings)
    cat > "${vagrant_box_dir}/Vagrantfile" <<'VAGRANTFILE_EOF'
# -*- mode: ruby -*-
# vi: set ft=ruby :
ENV['VAGRANT_DEFAULT_PROVIDER'] = 'libvirt'
Vagrant.configure("2") do |config|
  config.vm.provider :libvirt do |libvirt|
    libvirt.disk_bus = "virtio"
    libvirt.driver = "kvm"
  end
end
VAGRANTFILE_EOF

    # metadata_url — Vagrant only recognises boxes with a non-empty metadata_url.
    # A URL is required (even a fake one); an empty file or "0" won't work.
    mkdir -p "${vagrant_home}/boxes/${encoded_name}"
    echo "https://vagrantcloud.com/api/v2/vagrant/${box_name}" \
        > "${vagrant_home}/boxes/${encoded_name}/metadata_url"

    # Verify that Vagrant recognises the box
    if "${VAGRANT_CMD}" box list 2>/dev/null | grep -q "${box_name}"; then
        log_success "Parrot Security box ready: ${box_name} (instant install via hard-link)"
        # Clean up the old .box archive — no longer needed and wastes ~10 GB
        rm -f "${box_dir}/parrot-security-libvirt.box"
        return 0
    fi

    # Direct install didn't work — fall back to vagrant box add.
    # This is slower (reads+writes 12 GB) but guaranteed to work.
    log_warn "Direct install not recognised by Vagrant. Falling back to 'vagrant box add'..."
    log_warn "This will take several minutes as Vagrant copies the 12 GB disk image."
    rm -rf "${vagrant_home}/boxes/${encoded_name}"

    local box_file="${box_dir}/parrot-security-libvirt.box"

    # Reuse an existing .box file if available, otherwise build one from QCOW2
    if [[ ! -f "${box_file}" ]]; then
        log_info "Building Parrot box archive for Vagrant (this may take a few minutes)..."

        mkdir -p "${box_dir}/parrot-libvirt"

        cat > "${box_dir}/parrot-libvirt/metadata.json" <<'METADATA2'
{
    "provider": "libvirt",
    "format": "qcow2",
    "virtual_size": 64
}
METADATA2

        ln -f "${qcow2_path}" "${box_dir}/parrot-libvirt/box.img" 2>/dev/null \
            || cp "${qcow2_path}" "${box_dir}/parrot-libvirt/box.img"

        # gzip -0: no compression (QCOW2 is already compressed internally).
        # Wraps the tar in a valid gzip stream accepted by 'vagrant box add'
        # while avoiding minutes of useless recompression on a ~12 GB file.
        rm -f "${box_file}"
        (cd "${box_dir}/parrot-libvirt" && tar cSf - ./metadata.json ./box.img | gzip -0 > "${box_file}") || {
            log_error "Failed to create Parrot box archive"
            rm -f "${box_file}"
            rm -rf "${box_dir}/parrot-libvirt"
            return 1
        }

        rm -rf "${box_dir}/parrot-libvirt"
    fi

    log_info "Registering Parrot box via 'vagrant box add' (this copies ~12 GB)..."
    if "${VAGRANT_CMD}" box add "${box_file}" --name "${box_name}" --force --provider libvirt 2>&1; then
        log_success "Parrot Security box ready: ${box_name}"
        return 0
    else
        log_error "Failed to register Parrot box"
        return 1
    fi
}

# Ensure Parrot box for VirtualBox (OVA)
_ensure_parrot_ova() {
    local box_name="${PARROT_BOX_NAME}"
    local base_vm="bull-parrot-base"
    local box_dir="${BULL_HOME}/boxes"
    local box_file="${box_dir}/parrot-security.box"

    # Dry-run: skip the actual download and registration
    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would download Parrot OVA and register as '${box_name}'"
        return 0
    fi

    # sshpass is optional - try to install if missing
    if ! command -v sshpass &>/dev/null; then
        log_warn "'sshpass' not found. Will attempt to inject vagrant user automatically."
    fi

    # Already have .box file?
    if [[ -f "${box_file}" ]]; then
        log_info "Found existing box file, registering..."
        if "${VAGRANT_CMD}" box add "${box_file}" --name "${box_name}" --force 2>&1; then
            log_success "Parrot box registered: ${box_name}"
            return 0
        fi
        log_warn "Re-add failed — rebuilding from OVA."
        rm -f "${box_file}"
    fi

    # Download OVA
    local ova_path
    ova_path="$(_parrot_download_ova)" || return 1

    # Clean up any leftover base VM
    if "${VBOXMANAGE_CMD}" list vms 2>/dev/null | grep -q "\"${base_vm}\""; then
        log_info "Cleaning up previous '${base_vm}'..."
        "${VBOXMANAGE_CMD}" unregistervm "${base_vm}" --delete 2>/dev/null || true
    fi

    # For WSL2 + VirtualBox, OVA must be on Windows filesystem
    local ova_path_import=""
    if [[ "${BULL_WSL:-0}" -eq 1 ]] && [[ "${BULL_PROVIDER}" == "virtualbox" ]]; then
        local win_bull_home="${BULL_HOME}"
        if [[ "${BULL_HOME}" == /mnt/* ]]; then
            local drive_letter="${BULL_HOME#/mnt/}"
            drive_letter="${drive_letter%%/*}"
            drive_letter="${drive_letter^^}"
            win_bull_home="${drive_letter}:$(echo "${BULL_HOME}" | sed "s|/mnt/${drive_letter,,}||;s|/|\\\\|g")"
        fi
        local ova_filename
        ova_filename=$(basename "${ova_path}")
        ova_path_import="${win_bull_home}\\boxes\\${ova_filename}"
        log_info "Using Windows path for VirtualBox: ${ova_path_import}"
    else
        ova_path_import="${ova_path}"
    fi

    log_info "Importing Parrot OVA into VirtualBox (this takes a few minutes)..."
    if ! "${VBOXMANAGE_CMD}" import "${ova_path_import}" \
            --vsys 0 --vmname "${base_vm}" \
            --vsys 0 --eula accept 2>&1; then
        log_error "Failed to import Parrot OVA into VirtualBox."
        return 1
    fi

    log_success "OVA imported as '${base_vm}'"

    # Package as .box
    log_info "Packaging VM as Vagrant box (this takes a few minutes)..."
    mkdir -p "${box_dir}"
    rm -f "${box_file}"

    if ! "${VAGRANT_CMD}" package --base "${base_vm}" --output "${box_file}" 2>&1; then
        log_error "Failed to package '${base_vm}' as a Vagrant box."
        "${VBOXMANAGE_CMD}" unregistervm "${base_vm}" --delete 2>/dev/null || true
        return 1
    fi

    log_success "Box file created: ${box_file}"

    # Register in Vagrant
    log_info "Registering box as '${box_name}'..."
    if ! "${VAGRANT_CMD}" box add "${box_file}" --name "${box_name}" --force 2>&1; then
        log_error "Failed to register '${box_name}' in Vagrant."
        "${VBOXMANAGE_CMD}" unregistervm "${base_vm}" --delete 2>/dev/null || true
        return 1
    fi

    log_success "Parrot Security box ready: ${box_name}"

    # Cleanup
    "${VBOXMANAGE_CMD}" unregistervm "${base_vm}" --delete 2>/dev/null || true
    log_debug "Cleaned up temporary VM '${base_vm}'"

    return 0
}

# Full pipeline: OVA (VirtualBox) or QCOW2 (libvirt)
_ensure_parrot_box() {
    local box_name="${PARROT_BOX_NAME}"
    local box_dir="${BULL_HOME}/boxes"
    local vagrant_home="${VAGRANT_HOME:-${HOME}/.vagrant.d}"
    local encoded_name="${box_name//\//-VAGRANTSLASH-}"
    
    # Check if box is registered AND if actual image file exists
    local box_registered=0
    local image_exists=0
    
    if "${VAGRANT_CMD}" box list 2>/dev/null | grep -q "${box_name}"; then
        box_registered=1
    fi
    
    # Verify the actual image file exists for the provider
    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        if [[ -f "${vagrant_home}/boxes/${encoded_name}/0/amd64/libvirt/Parrot-security-${PARROT_VERSION}-amd64.qcow2" ]]; then
            image_exists=1
        fi
    else
        # VirtualBox - check for .box file
        if [[ -f "${box_dir}/parrot-security.box" ]]; then
            image_exists=1
        fi
    fi
    
    # Already registered AND image exists - we're good
    if [[ "${box_registered}" -eq 1 ]] && [[ "${image_exists}" -eq 1 ]]; then
        log_debug "Parrot box '${box_name}' already registered with valid image"
        return 0
    fi
    
    # Box registered but image missing - clean up and re-download
    if [[ "${box_registered}" -eq 1 ]] && [[ "${image_exists}" -eq 0 ]]; then
        log_warn "Parrot box registered but image file missing - cleaning up"
        vagrant box remove "${box_name}" --force 2>/dev/null || true
        rm -rf "${vagrant_home}/boxes/${encoded_name}" 2>/dev/null || true
    fi

    # Use QCOW2 for libvirt, OVA for VirtualBox
    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        log_info "Using Parrot QCOW2 for libvirt..."
        _ensure_parrot_qcow2
        return $?
    else
        log_info "Using Parrot OVA for VirtualBox..."
        _ensure_parrot_ova
        return $?
    fi
}

# ---------------------------------------------------------------------------
# VM Creation
# ---------------------------------------------------------------------------
# VM Creation
# ---------------------------------------------------------------------------

# Detect the primary screen resolution on the host machine.
# Returns WIDTHxHEIGHT (e.g. "1920x1080"). Falls back to 1920x1080.
_detect_host_resolution() {
    local res=""

    # WSL2 / Windows host — query via PowerShell using WMI (no assembly load needed)
    if grep -qi microsoft /proc/version 2>/dev/null; then
        res=$(powershell.exe -NoProfile -NonInteractive -Command \
            "\$v = Get-CimInstance Win32_VideoController | Where-Object { \$_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1; if (\$v) { '{0}x{1}' -f \$v.CurrentHorizontalResolution, \$v.CurrentVerticalResolution }" \
            2>/dev/null | tr -d '\r\n' || true)
    fi

    # Linux host with X11
    if [[ -z "${res}" ]] && command -v xrandr &>/dev/null; then
        res=$(xrandr 2>/dev/null \
            | grep ' connected primary' \
            | grep -o '[0-9]\+x[0-9]\+' | head -1 || true)
        # Fallback: any connected output
        [[ -z "${res}" ]] && \
            res=$(xrandr 2>/dev/null | grep '\*' | awk '{print $1}' | head -1 || true)
    fi

    # macOS host
    if [[ -z "${res}" ]] && command -v system_profiler &>/dev/null; then
        res=$(system_profiler SPDisplaysDataType 2>/dev/null \
            | grep -i 'Resolution' | head -1 \
            | grep -o '[0-9]\+ x [0-9]\+' \
            | tr ' ' 'x' | tr -d ' ' || true)
    fi

    # Fallback
    [[ -z "${res}" ]] && res="1920x1080"
    echo "${res}"
}

# Generate a Vagrantfile from template for a specific VM
generate_vagrantfile() {
    local vm_name="$1"
    local ram="$2"
    local cpu="$3"
    local vm_dir="$4"
    local username="${5:-}"
    local plain_password="${6:-}"   # plain text, only present during initial provision
    local keyboard="${7:-us}"
    local resolution="${8:-1920x1080}"
    local os="${9:-${BULL_DEFAULT_OS}}"
    
    # Get default username based on OS if not provided
    [[ -z "${username}" ]] && username="$(_os_default_user "${os}")"

    local template="${SCRIPT_DIR}/configs/Vagrantfile.template"

    if [[ ! -f "${template}" ]]; then
        log_error "Vagrantfile template not found: ${template}"
        return 1
    fi

    local box
    box="$(_os_to_box "${os}")" || return 1

    # Default: run full-upgrade for fully updated system. Set BULL_SKIP_UPGRADE=1
    # in the environment to skip upgrade (faster provisioning).
    local skip_upgrade="${BULL_SKIP_UPGRADE:-0}"

    local uefi="false"
    local ovmf_loader=""
    local ovmf_vars=""
    if [[ "${os}" == "parrot" ]]; then
        # Parrot Security OS uses UEFI boot (GPT + EFI System Partition).
        # Without the OVMF firmware loader, vagrant-libvirt defaults to SeaBIOS
        # and the VM won't boot. Try UEFI first, but fall back to SeaBIOS
        # if OVMF files are not accessible (e.g. Ubuntu Server with AppArmor restrictions).
        # Set BULL_FORCE_UEFI=1 to force UEFI even if files are not accessible.
        local ovmf_accessible=0
        if [[ -r "/usr/share/OVMF/OVMF_CODE_4M.fd" ]] 2>/dev/null && \
           [[ -r "/usr/share/OVMF/OVMF_VARS_4M.fd" ]] 2>/dev/null; then
            ovmf_accessible=1
        fi
        
        if [[ "${ovmf_accessible}" -eq 1 ]] || [[ "${BULL_FORCE_UEFI:-0}" == "1" ]]; then
            uefi="true"
            ovmf_loader="/usr/share/OVMF/OVMF_CODE_4M.fd"
            if [[ -f "/usr/share/OVMF/OVMF_VARS_4M.fd" ]]; then
                ovmf_vars="/usr/share/OVMF/OVMF_VARS_4M.fd"
            elif [[ -f "/usr/share/OVMF/OVMF_VARS_4M.ms.fd" ]]; then
                ovmf_vars="/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
            elif [[ -f "/usr/share/OVMF/OVMF_VARS_4M.snakeoil.fd" ]]; then
                ovmf_vars="/usr/share/OVMF/OVMF_VARS_4M.snakeoil.fd"
            else
                log_warn "OVMF VARS template not found"
                ovmf_vars="/usr/share/OVMF/OVMF_VARS_4M.fd"
            fi
            log_info "Using UEFI for Parrot"
        else
            log_info "Using SeaBIOS (BIOS legacy) for Parrot - OVMF not accessible"
            log_info "Set BULL_FORCE_UEFI=1 to force UEFI anyway"
        fi
    fi

    sed -e "s|%%VM_NAME%%|${vm_name}|g" \
        -e "s|%%RAM%%|${ram}|g" \
        -e "s|%%CPU%%|${cpu}|g" \
        -e "s|%%PROVIDER%%|${BULL_PROVIDER}|g" \
        -e "s|%%BOX%%|${box}|g" \
        -e "s|%%USERNAME%%|${username}|g" \
        -e "s|%%PLAIN_PASSWORD%%|${plain_password}|g" \
        -e "s|%%KEYBOARD%%|${keyboard}|g" \
        -e "s|%%RESOLUTION%%|${resolution}|g" \
        -e "s|%%SKIP_UPGRADE%%|${skip_upgrade}|g" \
        -e "s|%%TOOLKIT_URLS%%|${TOOLKIT_URLS:-}|g" \
        -e "s|%%EXTRA_PACKAGES%%|${EXTRA_PACKAGES:-}|g" \
        -e "s|%%UEFI%%|${uefi}|g" \
        -e "s|%%OVMF_LOADER%%|${ovmf_loader}|g" \
        -e "s|%%OVMF_VARS%%|${ovmf_vars}|g" \
        "${template}" > "${vm_dir}/Vagrantfile" || {
        log_error "Failed to generate Vagrantfile from template"
        return 1
    }

    log_debug "Generated Vagrantfile for '${vm_name}'"
    return 0
}

# Copy provisioning script to VM directory
copy_provision_script() {
    local vm_dir="$1"
    local os="${2:-${BULL_DEFAULT_OS}}"

    local provision_src="${SCRIPT_DIR}/configs/${os}-provision.sh"

    if [[ ! -f "${provision_src}" ]]; then
        log_error "Provisioning script not found: ${provision_src}"
        return 1
    fi

    cp "${provision_src}" "${vm_dir}/provision.sh"
    chmod +x "${vm_dir}/provision.sh"

    log_debug "Copied ${os} provisioning script to ${vm_dir}/provision.sh"
    return 0
}

# Create a new VM (Kali or Parrot)
create_vm() {
    local vm_name="$1"
    local ram="${2:-${DEFAULT_RAM}}"
    local cpu="${3:-${DEFAULT_CPU}}"
    local username="${4:-}"
    local plain_password="${5:-}"
    local keyboard="${6:-us}"
    local resolution_override="${7:-}"  # optional: e.g. "2560x1440"
    local os="${8:-${BULL_DEFAULT_OS}}"
    local resolution="${resolution_override:-${DEFAULT_RESOLUTION}}"
    
    # Get default username based on OS if not provided
    [[ -z "${username}" ]] && username="$(_os_default_user "${os}")"

    # Ensure all required tools are available (offer install if missing)
    ensure_dependencies || return 1

    # Validate inputs
    validate_vm_name "${vm_name}" || return 1
    validate_positive_int "${ram}" "RAM" || return 1
    validate_positive_int "${cpu}" "CPU" || return 1

    if [[ "${ram}" -lt "${MIN_RAM}" ]]; then
        log_warn "RAM ${ram}MB is below recommended minimum (${MIN_RAM}MB)"
    fi

    # Check for duplicates
    if inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' already exists. Use 'bull destroy ${vm_name}' first."
        return 1
    fi

    # Check disk space
    check_disk_space || return 1

    # Ensure Vagrant box is cached locally (offers download if missing)
    ensure_vagrant_box "${os}" || return 1

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    # Create VM directory
    mkdir -p "${vm_dir}"
    log_debug "Created VM directory: ${vm_dir}"

    # Generate Vagrantfile and copy provisioning script
    log_debug "Detected host resolution: ${resolution}"
    generate_vagrantfile "${vm_name}" "${ram}" "${cpu}" "${vm_dir}" "${username}" "${plain_password}" "${keyboard}" "${resolution}" "${os}" || {
        rm -rf "${vm_dir}"
        return 1
    }

    copy_provision_script "${vm_dir}" "${os}" || {
        rm -rf "${vm_dir}"
        return 1
    }

    # Add to inventory before vagrant up (status: not_created)
    inventory_add "${vm_name}" "${ram}" "${cpu}" "${resolution}" "${os}" || {
        rm -rf "${vm_dir}"
        return 1
    }

    # Convert RAM to human-readable for display
    local ram_display
    if [[ "${ram}" -ge 1024 ]]; then
        ram_display="$((ram / 1024))GB"
    else
        ram_display="${ram}MB"
    fi

    local os_label
    os_label="$(_os_label "${os}")"
    log_info "Creating VM: ${vm_name} [${os_label}] (${ram_display} RAM, ${cpu} CPU)"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would run 'vagrant up' in ${vm_dir}"
        inventory_update "${vm_name}" "status" "running"
        log_success "VM '${vm_name}' created (dry run)"
        return 0
    fi

    if [[ "${BULL_PROVIDER}" == "virtualbox" ]]; then
        if [[ "${BULL_WSL}" -eq 1 ]]; then
            _ensure_vbox_in_windows_path
        fi
        _verify_vbox_functional || return 1
    fi

    local vagrant_log
    vagrant_log="$(mktemp /tmp/bull-vagrant-XXXX.log)"
    chmod 600 "${vagrant_log}"

    # Also save a persistent log in the VM directory for post-mortem debugging
    local vagrant_persist_log="${vm_dir}/vagrant-up.log"

    echo
    log_info "Running: vagrant up --provider=${BULL_PROVIDER}"
    log_info "Full log: ${vagrant_persist_log}"
    echo "─────────────────────────────────────────"

    # Export provider so the Vagrantfile can conditionally configure network
    export VAGRANT_DEFAULT_PROVIDER="${BULL_PROVIDER}"

    # Tee: show output in real time AND capture it for error reporting
    if (cd "${vm_dir}" && "${VAGRANT_CMD}" up --provider="${BULL_PROVIDER}" 2>&1 \
            | tee "${vagrant_log}"); then
        # Save log for reference
        cp "${vagrant_log}" "${vagrant_persist_log}"
        echo "─────────────────────────────────────────"
        inventory_update "${vm_name}" "status" "running"

        local ip
        ip=$(get_vm_ip "${vm_name}")
        if [[ -n "${ip}" ]]; then
            inventory_update "${vm_name}" "ip" "${ip}"
        fi

        rm -f "${vagrant_log}"

        # libvirt: inject <mouse mode='client'/> into the SPICE graphics element
        # right after creation so the double cursor is eliminated from the start.
        # This stops the VM, redefines the domain XML, and restarts it.
        if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
            local domain_name uri_str
            domain_name="$(_libvirt_domain "${vm_name}")"
            uri_str="$(_libvirt_uri)"
            _fix_spice_cursor "${domain_name}" "${uri_str}"
            # Re-fetch IP after restart
            ip=$(get_vm_ip "${vm_name}")
            if [[ -n "${ip}" ]]; then
                inventory_update "${vm_name}" "ip" "${ip}"
            fi
        fi

        # Apply the target resolution: two-pass approach because Guest Additions
        # kernel modules are often missing (apt version mismatch with host VBox).
        #  1. setvideomodehint  → host-side: syncs VirtualBox cursor coordinate mapping
        #  2. xrandr via SSH    → guest-side: sets the actual X11 display resolution
        # Both are needed: setvideomodehint alone is ignored without GA modules,
        # and xrandr alone leaves the cursor coordinates desynchronized.
        if [[ "${BULL_PROVIDER}" == "virtualbox" ]]; then
            local res_w res_h
            res_w="${resolution%%x*}"
            res_h="${resolution##*x}"

            log_info "Applying display resolution ${resolution}..."

            # Host side: cursor coordinate mapping
            "${VBOXMANAGE_CMD}" controlvm "bull-${vm_name}" \
                setvideomodehint "${res_w}" "${res_h}" 32 2>/dev/null || true

            # Guest side: wait for X11/XFCE to be ready then force xrandr.
            # bull-set-resolution.sh detects the X session owner and their
            # XAUTHORITY cookie, so it works from any SSH user (vagrant/root).
            sleep 5
            if (cd "${vm_dir}" && \
                "${VAGRANT_CMD}" ssh -c \
                "sudo /usr/local/bin/bull-set-resolution.sh ${res_w} ${res_h}" \
                2>/dev/null); then
                log_success "Display resolution set to ${resolution}"
            else
                log_warn "Could not apply resolution — run 'bull view ${vm_name}' to retry"
            fi
        fi

        # Wipe the plain-text password from the Vagrantfile now that provisioning
        # is done — replace %%PLAIN_PASSWORD%% slot with an empty string so
        # re-running 'vagrant provision' doesn't re-apply any credentials.
        generate_vagrantfile "${vm_name}" "${ram}" "${cpu}" "${vm_dir}" "${username}" "" "${keyboard}" "${resolution}" "${os}" \
            || log_warn "Could not sanitize Vagrantfile after provisioning"

# Store username for 'bull connect' and future reference,
        # encrypt password with GPG — never stored in plaintext on disk.
        if [[ -n "${username}" ]]; then
            _credentials_save "${vm_name}" "${username}" "${plain_password}"
        fi

        # Display password once on screen — after this it is gone forever
        if [[ -n "${plain_password}" ]]; then
            local _pass_display="${plain_password}"
            plain_password=""   # wipe immediately — display copy only below

            clear
            _display_step "Show Credentials" "Your VM login"
            echo ""
            echo -e "\n  ${YELLOW}Credentials are ready to be displayed.${RESET}"
            echo -e "  ${DIM}Make sure no one is looking at your screen.${RESET}"
            echo ""
            echo -ne "  ${BOLD}${BRIGHT_CYAN}Show credentials? [y/N] > ${RESET}"
            local _confirm_show
            read -r _confirm_show
            if [[ ! "${_confirm_show}" =~ ^[yY]$ ]]; then
                _pass_display=""
                log_warn "Credentials not displayed. Use 'bull show-pass ${vm_name}' to decrypt them later."
                echo ""
                echo -ne "  ${DIM}Press Enter to continue...${RESET}"
                read -r _
                echo ""
            else
                echo ""
                echo -e "  ╔══════════════════════════════════════════════════════╗"
                echo -e "  ║  !! CREDENTIALS — SHOWN ONCE, NEVER STORED !!        ║"
                echo -e "  ╠══════════════════════════════════════════════════════╣"
                printf "    Username : %-39s  \n" "${username}"
                printf "    Password : %-39s  \n" "${_pass_display}"
                echo -e "  ╠══════════════════════════════════════════════════════╣"
                echo -e "  ║  Password is encrypted in .credentials.gpg           ║"
                echo -e "  ║  Decrypt later with: bull show-pass ${vm_name}       ║"
                echo -e "  ╚══════════════════════════════════════════════════════╝"
                echo ""
                echo -ne "  ${BOLD}${BRIGHT_CYAN}Press Enter once saved...${RESET}"
                read -r _
                _pass_display=""    # wipe display copy
                echo ""
            fi
        fi

        log_success "VM '${vm_name}' created successfully"
        return 0
    else
        echo "─────────────────────────────────────────"
        # Save persistent log for post-mortem debugging
        cp "${vagrant_log}" "${vagrant_persist_log}" 2>/dev/null || true
        log_error "vagrant up failed. Full log saved to: ${vagrant_persist_log}"
        log_error "Last lines of output:"
        tail -30 "${vagrant_log}" | while IFS= read -r line; do
            log_error "  ${line}"
        done
        {
            echo "=== vagrant up failure: $(date) ==="
            echo "VM: ${vm_name}"
            echo "OS: ${os}"
            echo "Provider: ${BULL_PROVIDER}"
            echo "Directory: ${vm_dir}"
            echo "--- full log ---"
            cat "${vagrant_log}"
            echo "--- end of log ---"
        } >> "${BULL_HOME}/bull-error.log" 2>/dev/null || true
        rm -f "${vagrant_log}"
        log_error "To retry: cd ${vm_dir} && vagrant up --provider=${BULL_PROVIDER}"
        inventory_update "${vm_name}" "status" "not_created"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# VM Lifecycle
# ---------------------------------------------------------------------------

# Start a stopped or suspended VM
start_vm() {
    local vm_name="$1"

    ensure_dependencies || return 1
    require_argument "${vm_name}" "vm name" || return 1
    validate_vm_name "${vm_name}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    if [[ ! -d "${vm_dir}" ]]; then
        log_error "VM directory not found: ${vm_dir}"
        return 1
    fi

    # Check current status
    local current_status
    current_status=$(jq -r --arg name "${vm_name}" \
        '.vms[] | select(.name == $name) | .status' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ "${current_status}" == "running" ]]; then
        log_warn "VM '${vm_name}' is already running"
        return 0
    fi

    log_info "Starting VM: ${vm_name}"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would run 'vagrant up' in ${vm_dir}"
        inventory_update "${vm_name}" "status" "running"
        return 0
    fi

    if [[ "${BULL_PROVIDER}" == "virtualbox" ]] && [[ "${BULL_WSL}" -eq 1 ]]; then
        _ensure_vbox_in_windows_path
    fi

    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        local domain
        domain="$(_libvirt_domain "${vm_name}")"
        if _libvirt_start "${domain}"; then
            sleep 5  # give the VM a moment to get an IP
            local ip
            ip="$(_libvirt_get_ip "${domain}")"
            inventory_update "${vm_name}" "status" "running"
            if [[ -n "${ip}" ]]; then
                inventory_update "${vm_name}" "ip" "${ip}"
                log_success "VM '${vm_name}' started (IP: ${ip})"
            else
                log_success "VM '${vm_name}' started"
            fi
            log_info "Connect with: bull connect ${vm_name}"
            return 0
        else
            log_error "Failed to start VM '${vm_name}'"
            return 1
        fi
    fi

    if (cd "${vm_dir}" && "${VAGRANT_CMD}" up --provider="${BULL_PROVIDER}" 2>&1); then
        inventory_update "${vm_name}" "status" "running"

        local ip
        ip=$(get_vm_ip "${vm_name}")
        if [[ -n "${ip}" ]]; then
            inventory_update "${vm_name}" "ip" "${ip}"
            log_success "VM '${vm_name}' started (IP: ${ip})"
        else
            log_success "VM '${vm_name}' started"
        fi

        log_info "Connect with: bull connect ${vm_name}"
        return 0
    else
        log_error "Failed to start VM '${vm_name}'"
        return 1
    fi
}

# Stop a running VM
stop_vm() {
    local vm_name="$1"

    ensure_dependencies || return 1
    require_argument "${vm_name}" "vm name" || return 1
    validate_vm_name "${vm_name}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    local current_status
    current_status=$(jq -r --arg name "${vm_name}" \
        '.vms[] | select(.name == $name) | .status' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ "${current_status}" == "stopped" ]] || [[ "${current_status}" == "poweroff" ]]; then
        log_warn "VM '${vm_name}' is already stopped"
        return 0
    fi

    log_info "Stopping VM: ${vm_name}"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would run 'vagrant halt' in ${vm_dir}"
        inventory_update "${vm_name}" "status" "stopped"
        return 0
    fi

    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        local domain
        domain="$(_libvirt_domain "${vm_name}")"
        if _libvirt_stop "${domain}"; then
            inventory_update "${vm_name}" "status" "stopped"
            inventory_update "${vm_name}" "ip" "null"
            log_success "VM '${vm_name}' stopped"
            return 0
        else
            log_error "Failed to stop VM '${vm_name}'"
            return 1
        fi
    fi

    if (cd "${vm_dir}" && "${VAGRANT_CMD}" halt 2>&1); then
        inventory_update "${vm_name}" "status" "stopped"
        inventory_update "${vm_name}" "ip" "null"
        log_success "VM '${vm_name}' stopped"
        return 0
    else
        log_error "Failed to stop VM '${vm_name}'"
        return 1
    fi
}

# Destroy a VM permanently
destroy_vm() {
    local vm_name="$1"

    ensure_dependencies || return 1
    require_argument "${vm_name}" "vm name" || return 1
    validate_vm_name "${vm_name}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    # Require confirmation
    confirm_action "Destroy VM '${vm_name}'? This is irreversible." || return 1

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    log_info "Destroying VM: ${vm_name}"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would destroy VM and remove ${vm_dir}"
        inventory_remove "${vm_name}"
        return 0
    fi

    # Destroy VM
    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        local domain
        domain="$(_libvirt_domain "${vm_name}")"
        log_info "Removing libvirt domain and disk images..."
        _libvirt_destroy "${domain}"

        # Belt-and-suspenders: also scrub any residual volumes in the
        # default pool whose name starts with the VM name (vagrant-libvirt
        # names volumes as "<domain>_vagrant_box_image_0.img" etc.)
        local uri pool_path
        uri="$(_libvirt_uri)"
        pool_path=$(virsh -c "${uri}" pool-dumpxml default 2>/dev/null \
            | grep -oP '(?<=<path>)[^<]+' | head -1)
        if [[ -n "${pool_path}" ]] && [[ -d "${pool_path}" ]]; then
            find "${pool_path}" -maxdepth 1 \
                \( -name "${domain}*" -o -name "${vm_name}*" \) \
                2>/dev/null | while IFS= read -r leftover; do
                    log_debug "Removing residual volume: ${leftover}"
                    rm -f "${leftover}" 2>/dev/null || true
                done
        fi
    elif [[ -d "${vm_dir}" ]]; then
        (cd "${vm_dir}" && "${VAGRANT_CMD}" destroy -f 2>&1) || {
            log_warn "Vagrant destroy returned errors (VM may already be gone)"
        }
    fi

    # Remove the VM working directory unconditionally (includes Vagrantfile,
    # provision.sh, .vagrant state). Use || true so a missing directory
    # (already manually deleted) never blocks the cleanup.
    if [[ -d "${vm_dir}" ]]; then
        rm -rf "${vm_dir}" || log_warn "Could not remove VM directory: ${vm_dir}"
        log_debug "Removed VM directory: ${vm_dir}"
    fi

    # Remove from inventory
    inventory_remove "${vm_name}"

    log_success "VM '${vm_name}' destroyed"
    return 0
}

# ---------------------------------------------------------------------------
# SSH Connection
# ---------------------------------------------------------------------------

# SSH into a running VM
connect_vm() {
    local vm_name="$1"

    ensure_dependencies || return 1
    require_argument "${vm_name}" "vm name" || return 1
    validate_vm_name "${vm_name}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    local current_status
    current_status=$(jq -r --arg name "${vm_name}" \
        '.vms[] | select(.name == $name) | .status' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ "${current_status}" != "running" ]]; then
        log_error "VM '${vm_name}' is not running (status: ${current_status})"
        log_info "Start it with: bull start ${vm_name}"
        return 1
    fi

    log_info "Connecting to VM: ${vm_name}"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would SSH into ${vm_name}"
        return 0
    fi

    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        _libvirt_ssh "${vm_name}"
        return $?
    fi

    # For VirtualBox: if a custom username was set, pass it to vagrant ssh
    local cred_file="${vm_dir}/.credentials"
    local stored_user=""
    if [[ -f "${cred_file}" ]]; then
        stored_user=$(grep '^username=' "${cred_file}" | cut -d= -f2)
    fi

    local vm_ip
    vm_ip=$(get_vm_ip "${vm_name}")

    if [[ -n "${stored_user}" ]] && [[ "${stored_user}" != "vagrant" ]]; then
        if ! command -v sshpass &>/dev/null; then
            log_error "sshpass is required for password-based SSH. Install it with:"
            echo "  sudo apt install sshpass   (Debian/Ubuntu)"
            echo "  sudo dnf install sshpass   (Fedora)"
            echo "  sudo pacman -S sshpass     (Arch)"
            return 1
        fi

        read -rs -p "Password for ${stored_user}@${vm_ip}: " user_pass
        echo
        sshpass -p "${user_pass}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${stored_user}@${vm_ip}"
    else
        (cd "${vm_dir}" && "${VAGRANT_CMD}" ssh)
    fi
}

# ---------------------------------------------------------------------------
# Graphical console
# ---------------------------------------------------------------------------

# Fix the double-cursor problem on a libvirt/SPICE VM.
#
# SPICE renders two cursors: the "client cursor" (drawn by virt-viewer on the
# host) and the "server cursor" (drawn by the VM inside the framebuffer).
# When both are visible you see a double cursor with an offset.
#
# Two fixes applied here:
#   1. USB tablet — sends absolute coordinates so SPICE knows where the cursor
#      is without relative-delta guessing. Added live + persisted.
#   2. <mouse mode='client'/> in the SPICE graphics element — tells QEMU to
#      hide the server-rendered cursor entirely and let virt-viewer draw the
#      only cursor the user sees. Requires a VM restart to take effect (the
#      graphics element cannot be changed live), so we stop→define→start.
_fix_spice_cursor() {
    local domain="$1"
    local uri="$2"
    local needs_restart=0

    # --- USB tablet (can be added live) ---
    if ! virsh -c "${uri}" dumpxml "${domain}" 2>/dev/null \
            | grep -q "type='tablet'"; then
        log_info "Adding USB tablet device for absolute pointer..."
        local tablet_xml
        tablet_xml=$(mktemp /tmp/bull-tablet-XXXXXX.xml)
        chmod 600 "${tablet_xml}"
        printf '<input type="tablet" bus="usb"/>\n' > "${tablet_xml}"
        virsh -c "${uri}" attach-device "${domain}" "${tablet_xml}" \
            --live --config 2>/dev/null \
            || log_warn "Could not hot-add USB tablet"
        rm -f "${tablet_xml}"
    fi

    # --- SPICE client-cursor mode (requires domain XML edit + restart) ---
    if virsh -c "${uri}" dumpxml "${domain}" 2>/dev/null \
            | grep -q '<mouse mode'; then
        # Already configured
        return 0
    fi

    log_info "Setting SPICE to client-cursor mode (eliminates double cursor)..."
    local tmp_xml
    tmp_xml=$(mktemp /tmp/bull-domain-XXXXXX.xml)
    chmod 600 "${tmp_xml}"
    virsh -c "${uri}" dumpxml "${domain}" > "${tmp_xml}" 2>/dev/null || {
        rm -f "${tmp_xml}"
        log_warn "Could not dump domain XML — skipping cursor fix"
        return 0
    }

    # Insert <mouse mode='client'/> inside the <graphics type='spice'...> element.
    # sed matches the opening tag and appends the child element on the next line.
    if grep -q "graphics type='spice'" "${tmp_xml}"; then
        sed -i "/<graphics type='spice'/a\\      <mouse mode='client'/>" "${tmp_xml}"
        needs_restart=1
    fi

    if [[ "${needs_restart}" -eq 1 ]]; then
        log_info "Restarting VM to apply SPICE cursor fix..."
        virsh -c "${uri}" destroy "${domain}" 2>/dev/null || true
        sleep 1
        virsh -c "${uri}" define "${tmp_xml}" 2>/dev/null || {
            log_warn "Could not redefine domain with cursor fix"
            rm -f "${tmp_xml}"
            # Try to restart anyway
            virsh -c "${uri}" start "${domain}" 2>/dev/null || true
            return 0
        }
        virsh -c "${uri}" start "${domain}" 2>/dev/null || {
            log_error "Failed to restart VM after cursor fix"
            rm -f "${tmp_xml}"
            return 1
        }
        # Wait for VM to be fully up before opening the viewer
        sleep 5
        log_success "SPICE client-cursor mode active — double cursor eliminated"
    fi

    rm -f "${tmp_xml}"
    return 0
}

# Open a graphical console for a running libvirt VM.
# Tries virt-viewer → remote-viewer → plain VNC viewer in that order.
view_vm() {
    local vm_name="$1"

    ensure_dependencies || return 1
    require_argument "${vm_name}" "vm name" || return 1
    validate_vm_name "${vm_name}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    local current_status
    current_status=$(jq -r --arg name "${vm_name}" \
        '.vms[] | select(.name == $name) | .status' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ "${current_status}" != "running" ]]; then
        log_error "VM '${vm_name}' is not running (status: ${current_status})"
        log_info "Start it first with: bull start ${vm_name}"
        return 1
    fi

    log_info "Opening graphical console for: ${vm_name}"

    # -------------------------------------------------------------------------
    # VirtualBox — attach a GUI window to the already-running headless VM
    # -------------------------------------------------------------------------
    if [[ "${BULL_PROVIDER}" == "virtualbox" ]]; then
        local vbox_name="bull-${vm_name}"

        # Read resolution stored in inventory (falls back to DEFAULT_RESOLUTION).
        local vm_resolution res_w res_h
        vm_resolution=$(jq -r --arg name "${vm_name}" \
            '.vms[] | select(.name == $name) | .resolution // "'"${DEFAULT_RESOLUTION}"'"' \
            "${INVENTORY_FILE}" 2>/dev/null)
        vm_resolution="${vm_resolution:-${DEFAULT_RESOLUTION}}"
        res_w="${vm_resolution%%x*}"
        res_h="${vm_resolution##*x}"

        # --type separate: attach a GUI window without stopping the headless VM
        if "${VBOXMANAGE_CMD}" startvm "${vbox_name}" --type separate &>/dev/null; then
            # Wait for the VirtualBox GUI window and the guest X session to stabilise
            # before attempting any resize. The guest was headless so VBoxClient-all
            # had no window dimensions to query; we cannot rely on its auto-resize here.
            sleep 4

            # Pass 1 — setvideomodehint: tells VBoxClient's --display service (if running)
            # to resize the framebuffer. Works when Guest Additions are healthy.
            "${VBOXMANAGE_CMD}" controlvm "${vbox_name}" \
                setvideomodehint "${res_w}" "${res_h}" 32 2>/dev/null || true

            # Pass 2 — SSH xrandr: force the resolution directly inside the guest.
            # bull-set-resolution.sh detects the X session owner and their
            # XAUTHORITY cookie, so it works from any SSH user (vagrant/root).
            local vm_dir
            vm_dir="$(get_vm_dir "${vm_name}")"
            (cd "${vm_dir}" && \
                "${VAGRANT_CMD}" ssh -c \
                "sudo /usr/local/bin/bull-set-resolution.sh ${res_w} ${res_h}" \
                2>/dev/null || true) &

            log_success "Graphical console opened at ${vm_resolution} for '${vbox_name}'"
            log_info "If white borders remain: Host+F (full-screen) then resize the window."
            return 0
        fi

        # If the GUI window is already open VBoxManage returns a non-zero code;
        # try to bring the existing window to the foreground instead.
        log_warn "Could not attach GUI window (may already be open)."
        log_info "Open VirtualBox Manager and double-click '${vbox_name}' to show the console."
        return 1
    fi

    # -------------------------------------------------------------------------
    # libvirt/KVM — SPICE (primary) then VNC (fallback)
    # -------------------------------------------------------------------------
    local domain uri
    domain="$(_libvirt_domain "${vm_name}")"
    uri="$(_libvirt_uri)"

    # Fix double cursor: add USB tablet + force SPICE client-cursor mode.
    # May restart the VM if the graphics XML needs updating (first time only).
    _fix_spice_cursor "${domain}" "${uri}"

    # virt-viewer handles both SPICE and VNC automatically — always try it first.
    # --attach: connect via libvirt's attach API instead of a direct TCP socket.
    # Required when SPICE has no listen address (the default on modern libvirt).
    # 2>/dev/null: suppresses harmless GLib/GStreamer audio warnings that appear
    # with some GStreamer versions but do not affect display or input.
    if command -v virt-viewer &>/dev/null; then
        # --full-screen: fills the host screen so SPICE/spice-vdagent immediately
        # negotiates the correct resolution (e.g. 1920x1080) instead of starting
        # at the VM's current framebuffer size (often 800x600 before vdagent kicks in).
        # Press F11 inside the window to toggle full-screen off.
        virt-viewer --connect "${uri}" --attach --full-screen "${domain}" 2>/dev/null &
        log_success "Graphical console opened via virt-viewer (full-screen, F11 to toggle)"
        return 0
    fi

    # remote-viewer (part of virt-manager) — same --attach requirement
    if command -v remote-viewer &>/dev/null; then
        remote-viewer --connect "${uri}" --attach --full-screen "${domain}" 2>/dev/null &
        log_success "Graphical console opened via remote-viewer"
        return 0
    fi

    # Last resort: plain VNC (only works if the VM was configured with VNC, not SPICE)
    local vnc_display
    vnc_display=$(virsh -c "${uri}" vncdisplay "${domain}" 2>/dev/null | tr -d '\r\n')
    if [[ -n "${vnc_display}" ]]; then
        local port=$(( 5900 + ${vnc_display##*:} ))
        local vnc_viewer=""
        for _v in vncviewer xtightvncviewer tigervnc-viewer; do
            command -v "${_v}" &>/dev/null && { vnc_viewer="${_v}"; break; }
        done
        unset _v
        if [[ -n "${vnc_viewer}" ]]; then
            "${vnc_viewer}" "127.0.0.1:${port}" &
            log_success "Graphical console opened via ${vnc_viewer}"
            return 0
        fi
        log_info "Manual VNC: connect a VNC client to 127.0.0.1:${port}"
    fi

    log_error "No graphical viewer found."
    if command -v apt-get &>/dev/null; then
        echo -en "${YELLOW}[WARN]${RESET} Install virt-viewer now? [Y/n]: "
        local answer
        read -r answer
        answer="${answer:-y}"
        if [[ "${answer}" =~ ^[Yy]$ ]]; then
            log_info "Installing virt-viewer..."
            if sudo apt-get install -y virt-viewer 2>&1; then
                log_success "virt-viewer installed."
                virt-viewer --connect "${uri}" --attach "${domain}" 2>/dev/null &
                log_success "Graphical console opened."
                return 0
            else
                log_error "Installation failed. Try manually: sudo apt install virt-viewer"
                return 1
            fi
        fi
    else
        log_info "Install a viewer manually: sudo apt install virt-viewer"
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------

# List snapshots for a VM. Prints a formatted table and populates the global
# array BULL_SNAPSHOT_NAMES with snapshot names (index 1-based) for selection.
# Returns 0 if snapshots found, 1 if none or VM not found.
list_snapshots() {
    local vm_name="$1"

    require_argument "${vm_name}" "vm name" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    BULL_SNAPSHOT_NAMES=()

    echo -e "\n${BOLD}${BRIGHT_CYAN}[ Snapshots: ${vm_name} ]${RESET}"

    # Read snapshots from inventory (name + creation date recorded at creation).
    local -a snap_names=()
    local -a snap_dates=()
    while IFS=$'\t' read -r sname sdate; do
        [[ -z "${sname}" ]] && continue
        snap_names+=("${sname}")
        snap_dates+=("${sdate}")
    done < <(inventory_list_snapshots "${vm_name}")

    if [[ "${#snap_names[@]}" -eq 0 ]]; then
        echo -e "  ${DIM}No snapshots found.${RESET}\n"
        return 1
    fi

    printf '\n  %-4s  %-30s  %s\n' "#" "NAME" "CREATED"
    echo -e "  ${DIM}────  ──────────────────────────────  ────────────────────${RESET}"

    local idx=1
    for (( i=0; i<${#snap_names[@]}; i++ )); do
        printf '  %-4s  %-30s  %s\n' \
            "${BRIGHT_RED}[$((i+1))]${RESET}" \
            "${snap_names[${i}]}" \
            "${DIM}${snap_dates[${i}]}${RESET}"
        BULL_SNAPSHOT_NAMES+=("${snap_names[${i}]}")
        (( idx++ ))
    done
    echo

    return 0
}

# Interactively prompt user to pick a snapshot from the list.
# Prints the chosen snapshot name to stdout. Returns 1 on Exit/error.
select_snapshot() {
    local vm_name="$1"

    # Called inside $() — all display must go to /dev/tty, only the chosen
    # snapshot name is echoed to stdout for the caller to capture.
    BULL_SNAPSHOT_NAMES=()
    list_snapshots "${vm_name}" > /dev/tty || return 1

    local count="${#BULL_SNAPSHOT_NAMES[@]}"
    if [[ "${count}" -eq 0 ]]; then
        return 1
    fi

    local choice
    echo -ne "  ${BRIGHT_CYAN}Select snapshot [1-${count}] > ${RESET}" > /dev/tty
    read -r choice < /dev/tty

    if [[ ! "${choice}" =~ ^[0-9]+$ ]] || \
       [[ "${choice}" -lt 1 ]] || \
       [[ "${choice}" -gt "${count}" ]]; then
        log_error "Invalid selection." > /dev/tty
        return 1
    fi

    echo "${BULL_SNAPSHOT_NAMES[$((choice - 1))]}"
    return 0
}

# Create a snapshot of a VM
snapshot_vm() {
    local vm_name="$1"
    local snapshot_name="${2:-snapshot-$(date +%Y%m%d-%H%M%S)}"

    require_argument "${vm_name}" "vm name" || return 1
    validate_vm_name "${vm_name}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    log_info "Creating snapshot '${snapshot_name}' for VM '${vm_name}'"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would create snapshot '${snapshot_name}'"
        inventory_add_snapshot "${vm_name}" "${snapshot_name}"
        return 0
    fi

    if (cd "${vm_dir}" && "${VAGRANT_CMD}" snapshot save "${snapshot_name}" 2>&1); then
        inventory_add_snapshot "${vm_name}" "${snapshot_name}"
        log_success "Snapshot '${snapshot_name}' created for VM '${vm_name}'"
        return 0
    else
        log_error "Failed to create snapshot"
        return 1
    fi
}

# Restore a VM to a snapshot
restore_snapshot() {
    local vm_name="$1"
    local snapshot_name="$2"

    require_argument "${vm_name}" "vm name" || return 1
    require_argument "${snapshot_name}" "snapshot name" || return 1
    validate_vm_name "${vm_name}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    log_info "Restoring VM '${vm_name}' to snapshot '${snapshot_name}'"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would restore snapshot '${snapshot_name}'"
        return 0
    fi

    if (cd "${vm_dir}" && "${VAGRANT_CMD}" snapshot restore "${snapshot_name}" 2>&1); then
        log_success "VM '${vm_name}' restored to snapshot '${snapshot_name}'"

        # Update status after restore
        local actual_status
        actual_status=$(cd "${vm_dir}" && "${VAGRANT_CMD}" status --machine-readable 2>/dev/null \
            | grep -E ',state,' | tail -1 | cut -d',' -f4)
        if [[ -n "${actual_status}" ]]; then
            inventory_update "${vm_name}" "status" "${actual_status}"
        fi

        return 0
    else
        log_error "Failed to restore snapshot '${snapshot_name}'"
        return 1
    fi
}

# Delete a snapshot from a VM
delete_snapshot() {
    local vm_name="$1"
    local snapshot_name="$2"

    require_argument "${vm_name}" "vm name" || return 1
    require_argument "${snapshot_name}" "snapshot name" || return 1
    validate_vm_name "${vm_name}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found. See 'bull list'."
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    log_info "Deleting snapshot '${snapshot_name}' from VM '${vm_name}'"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would delete snapshot '${snapshot_name}'"
        inventory_remove_snapshot "${vm_name}" "${snapshot_name}"
        return 0
    fi

    if (cd "${vm_dir}" && "${VAGRANT_CMD}" snapshot delete "${snapshot_name}" 2>&1); then
        inventory_remove_snapshot "${vm_name}" "${snapshot_name}"
        log_success "Snapshot '${snapshot_name}' deleted from VM '${vm_name}'"
        return 0
    else
        log_error "Failed to delete snapshot '${snapshot_name}'"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Status / Info
# ---------------------------------------------------------------------------

# Get IP address of a running VM
get_vm_ip() {
    local vm_name="$1"
    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    if [[ ! -d "${vm_dir}" ]]; then
        return 1
    fi

    local ip

    # libvirt: use virsh domifaddr — no SSH required, no password prompt
    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        local domain
        domain="$(_libvirt_domain "${vm_name}")"
        ip="$(_libvirt_get_ip "${domain}")"
        if [[ -n "${ip}" ]]; then
            echo "${ip}"
            return 0
        fi
        return 1
    fi

    # VirtualBox: vagrant ssh (uses key auth, no interactive prompt)
    ip=$(cd "${vm_dir}" && "${VAGRANT_CMD}" ssh -c "hostname -I" 2>/dev/null \
        | awk '{print $1}' | tr -d '\r\n')

    if [[ -n "${ip}" ]]; then
        echo "${ip}"
        return 0
    fi

    return 1
}

# Get Vagrant status of a VM
get_vm_status() {
    local vm_name="$1"
    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    if [[ ! -d "${vm_dir}" ]]; then
        echo "not_created"
        return 0
    fi

    local status
    status=$(cd "${vm_dir}" && "${VAGRANT_CMD}" status --machine-readable 2>/dev/null \
        | grep -E ',state,' | tail -1 | cut -d',' -f4)

    echo "${status:-unknown}"
    return 0
}

# Global status overview
show_status() {
    inventory_init

    local vm_count
    vm_count=$(jq '.vms | length' "${INVENTORY_FILE}" 2>/dev/null)

    local running_count
    running_count=$(jq '[.vms[] | select(.status == "running")] | length' \
        "${INVENTORY_FILE}" 2>/dev/null)

    local stopped_count
    stopped_count=$(jq '[.vms[] | select(.status != "running")] | length' \
        "${INVENTORY_FILE}" 2>/dev/null)

    echo -e "\n${BOLD}BULL Status${RESET}"
    printf '%.0s─' {1..40}
    echo

    echo -e "  Version:     ${BULL_VERSION}"
    echo -e "  VMs:         ${vm_count} total (${running_count} running, ${stopped_count} stopped)"

    # Disk usage
    local disk_info
    if df --version &>/dev/null 2>&1; then
        disk_info=$(df -BG "${BULL_HOME}" 2>/dev/null | tail -1 \
            | awk '{printf "%s used / %s available", $3, $4}')
    else
        disk_info=$(df -h "${BULL_HOME}" 2>/dev/null | tail -1 \
            | awk '{printf "%s used / %s available", $3, $4}')
    fi
    echo -e "  Disk:        ${disk_info}"

    # Tool versions
    if command -v "${VBOXMANAGE_CMD}" &>/dev/null; then
        local vbox_ver
        vbox_ver=$("${VBOXMANAGE_CMD}" --version 2>/dev/null | cut -d'r' -f1)
        echo -e "  VirtualBox:  v${vbox_ver}"
    fi

    if [[ "${BULL_WSL}" -eq 1 ]]; then
        echo -e "  Platform:    WSL2"
    fi

    if command -v vagrant &>/dev/null; then
        local vag_ver
        vag_ver=$(vagrant --version 2>/dev/null | awk '{print $2}')
        echo -e "  Vagrant:     v${vag_ver}"
    fi

    echo -e "  Home:        ${BULL_HOME}"
    echo

    # Show VM list if any
    if [[ "${vm_count}" -gt 0 ]]; then
        inventory_list
    fi

    return 0
}
