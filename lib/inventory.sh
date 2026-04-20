#!/usr/bin/env bash
# =============================================================================
# BULL - lib/inventory.sh
# VM inventory management (JSON-based via jq)
# =============================================================================

[[ -n "${_BULL_INVENTORY_LOADED:-}" ]] && return 0
readonly _BULL_INVENTORY_LOADED=1

INVENTORY_FILE="${SCRIPT_DIR}/data/inventory.json"

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

inventory_init() {
    local data_dir
    data_dir="$(dirname "${INVENTORY_FILE}")"

    if [[ ! -d "${data_dir}" ]]; then
        mkdir -p "${data_dir}" || {
            log_error "Cannot create inventory data directory: ${data_dir}"
            return 1
        }
        log_debug "Created data directory: ${data_dir}"
    fi

    if [[ ! -f "${INVENTORY_FILE}" ]]; then
        echo '{"version":"1.0","vms":[]}' | jq '.' > "${INVENTORY_FILE}" || {
            log_error "Cannot create inventory file: ${INVENTORY_FILE}"
            return 1
        }
        log_debug "Initialized empty inventory: ${INVENTORY_FILE}"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# CRUD operations
# ---------------------------------------------------------------------------

inventory_add() {
    local name="$1"
    local ram="$2"
    local cpu="$3"
    local resolution="${4:-${DEFAULT_RESOLUTION}}"
    local os="${5:-kali}"

    inventory_init || return 1

    if inventory_vm_exists "${name}"; then
        log_error "VM '${name}' already exists in inventory"
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${name}")"
    local now
    now="$(timestamp_iso)"

    local tmp_file
    tmp_file=$(mktemp "${INVENTORY_FILE}.XXXXXX")

    jq --arg name "${name}" \
       --arg ram "${ram}" \
       --arg cpu "${cpu}" \
       --arg resolution "${resolution}" \
       --arg os "${os}" \
       --arg created "${now}" \
       --arg vm_dir "${vm_dir}" \
       '.vms += [{
           name: $name,
           os: $os,
           status: "not_created",
           ip: null,
           created: $created,
           ram: $ram,
           cpu: $cpu,
           resolution: $resolution,
           snapshots: [],
           vpn_configured: false,
           vm_dir: $vm_dir
       }]' "${INVENTORY_FILE}" > "${tmp_file}" || {
        rm -f "${tmp_file}"
        log_error "Failed to update inventory JSON for VM '${name}'"
        return 1
    }

    mv "${tmp_file}" "${INVENTORY_FILE}" || {
        rm -f "${tmp_file}"
        log_error "Failed to write inventory file: ${INVENTORY_FILE}"
        return 1
    }

    log_debug "Added VM '${name}' to inventory"
    return 0
}

inventory_remove() {
    local name="$1"

    if ! inventory_vm_exists "${name}"; then
        log_error "VM '${name}' not found in inventory"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${INVENTORY_FILE}.XXXXXX")

    jq --arg name "${name}" \
       '.vms = [.vms[] | select(.name != $name)]' \
       "${INVENTORY_FILE}" > "${tmp_file}" || {
        rm -f "${tmp_file}"
        log_error "Failed to update inventory JSON"
        return 1
    }

    mv "${tmp_file}" "${INVENTORY_FILE}" || {
        rm -f "${tmp_file}"
        log_error "Failed to write inventory file: ${INVENTORY_FILE}"
        return 1
    }

    log_debug "Removed VM '${name}' from inventory"
    return 0
}

inventory_update() {
    local name="$1"
    local field="$2"
    local value="$3"

    if ! inventory_vm_exists "${name}"; then
        log_error "VM '${name}' not found in inventory"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${INVENTORY_FILE}.XXXXXX")

    # Handle boolean and null values correctly
    case "${value}" in
        true|false|null)
            jq --arg name "${name}" \
               --arg field "${field}" \
               --argjson value "${value}" \
               '(.vms[] | select(.name == $name))[$field] = $value' \
               "${INVENTORY_FILE}" > "${tmp_file}" || {
                rm -f "${tmp_file}"
                log_error "Failed to update inventory JSON"
                return 1
            }
            ;;
        *)
            jq --arg name "${name}" \
               --arg field "${field}" \
               --arg value "${value}" \
               '(.vms[] | select(.name == $name))[$field] = $value' \
               "${INVENTORY_FILE}" > "${tmp_file}" || {
                rm -f "${tmp_file}"
                log_error "Failed to update inventory JSON"
                return 1
            }
            ;;
    esac

    mv "${tmp_file}" "${INVENTORY_FILE}" || {
        rm -f "${tmp_file}"
        log_error "Failed to write inventory file: ${INVENTORY_FILE}"
        return 1
    }

    log_debug "Updated VM '${name}': ${field}=${value}"
    return 0
}

inventory_get() {
    local name="$1"

    inventory_init || return 1

    local result
    result=$(jq --arg name "${name}" \
        '.vms[] | select(.name == $name)' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ -z "${result}" ]]; then
        return 1
    fi

    echo "${result}"
    return 0
}

inventory_vm_exists() {
    local name="$1"

    inventory_init || return 1

    local count
    count=$(jq --arg name "${name}" \
        '[.vms[] | select(.name == $name)] | length' \
        "${INVENTORY_FILE}" 2>/dev/null)

    [[ "${count}" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

inventory_list() {
    inventory_init || return 1

    local vm_count
    vm_count=$(jq '.vms | length' "${INVENTORY_FILE}" 2>/dev/null)

    if [[ "${vm_count}" -eq 0 ]]; then
        log_info "No VMs found. Create one with: bull create <name>"
        return 0
    fi

    # Table header
    printf "${BOLD}%-20s %-10s %-12s %-18s %-8s %-6s %-6s${RESET}\n" \
        "NAME" "OS" "STATUS" "IP" "RAM" "CPU" "VPN"
    printf '%.0s─' {1..82}
    echo

    # Table rows
    jq -r '.vms[] | [.name, (.os // "kali"), .status, (.ip // "-"), .ram, .cpu, (if .vpn_configured then "yes" else "no" end)] | @tsv' \
        "${INVENTORY_FILE}" 2>/dev/null | while IFS=$'\t' read -r name os status ip ram cpu vpn; do

        # Color the status
        local status_colored
        case "${status}" in
            running)     status_colored="${GREEN}${status}${RESET}" ;;
            stopped)     status_colored="${RED}${status}${RESET}" ;;
            suspended)   status_colored="${YELLOW}${status}${RESET}" ;;
            *)           status_colored="${GRAY}${status}${RESET}" ;;
        esac

        # Convert RAM to human-readable
        local ram_display
        if [[ "${ram}" -ge 1024 ]]; then
            ram_display="$((ram / 1024))GB"
        else
            ram_display="${ram}MB"
        fi

        printf "%-20s %-10s %-22b %-18s %-8s %-6s %-6s\n" \
            "${name}" "${os}" "${status_colored}" "${ip}" "${ram_display}" "${cpu}" "${vpn}"
    done

    return 0
}

# ---------------------------------------------------------------------------
# Snapshot management
# ---------------------------------------------------------------------------

inventory_add_snapshot() {
    local name="$1"
    local snapshot_name="$2"
    local created="${3:-$(date -u +"%Y-%m-%d %H:%M")}"

    if ! inventory_vm_exists "${name}"; then
        log_error "VM '${name}' not found in inventory"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${INVENTORY_FILE}.XXXXXX")

    jq --arg name "${name}" \
       --arg snap "${snapshot_name}" \
       --arg created "${created}" \
       '(.vms[] | select(.name == $name)).snapshots += [{"name": $snap, "created": $created}]' \
       "${INVENTORY_FILE}" > "${tmp_file}" || {
        rm -f "${tmp_file}"
        log_error "Failed to update inventory JSON"
        return 1
    }

    mv "${tmp_file}" "${INVENTORY_FILE}" || {
        rm -f "${tmp_file}"
        log_error "Failed to write inventory file: ${INVENTORY_FILE}"
        return 1
    }

    log_debug "Added snapshot '${snapshot_name}' to VM '${name}'"
    return 0
}

inventory_remove_snapshot() {
    local name="$1"
    local snapshot_name="$2"

    if ! inventory_vm_exists "${name}"; then
        log_error "VM '${name}' not found in inventory"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp "${INVENTORY_FILE}.XXXXXX")

    jq --arg name "${name}" \
       --arg snap "${snapshot_name}" \
       '(.vms[] | select(.name == $name)).snapshots =
        [(.vms[] | select(.name == $name)).snapshots[] |
         if type == "object" then select(.name != $snap)
         else select(. != $snap) end]' \
       "${INVENTORY_FILE}" > "${tmp_file}" || {
        rm -f "${tmp_file}"
        log_error "Failed to update inventory JSON"
        return 1
    }

    mv "${tmp_file}" "${INVENTORY_FILE}" || {
        rm -f "${tmp_file}"
        log_error "Failed to write inventory file: ${INVENTORY_FILE}"
        return 1
    }

    log_debug "Removed snapshot '${snapshot_name}' from VM '${name}'"
    return 0
}

inventory_list_snapshots() {
    local name="$1"

    if ! inventory_vm_exists "${name}"; then
        log_error "VM '${name}' not found in inventory"
        return 1
    fi

    # Each snapshot is stored as {"name":..., "created":...}.
    # Backward-compat: if entry is a plain string, emit it with "-" as date.
    jq -r --arg name "${name}" \
        '.vms[] | select(.name == $name) | .snapshots[] |
         if type == "object" then [.name, .created] else [., "-"] end | @tsv' \
        "${INVENTORY_FILE}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------

inventory_sync() {
    inventory_init || return 1

    local vm_names
    vm_names=$(jq -r '.vms[].name' "${INVENTORY_FILE}" 2>/dev/null)

    if [[ -z "${vm_names}" ]]; then
        log_info "No VMs in inventory to sync"
        return 0
    fi

    log_info "Syncing inventory with actual VM state..."

    local synced=0
    while IFS= read -r vm_name; do
        local vm_dir
        vm_dir="$(get_vm_dir "${vm_name}")"

        if [[ ! -d "${vm_dir}" ]]; then
            log_warn "VM directory missing for '${vm_name}', marking as not_created"
            inventory_update "${vm_name}" "status" "not_created"
            inventory_update "${vm_name}" "ip" "null"
            ((synced++))
            continue
        fi

        # Get actual status from Vagrant
        local actual_status
        actual_status=$(cd "${vm_dir}" && vagrant status --machine-readable 2>/dev/null \
            | grep -E ',state,' | tail -1 | cut -d',' -f4)

        if [[ -n "${actual_status}" ]]; then
            inventory_update "${vm_name}" "status" "${actual_status}"

            # Update IP if running
            if [[ "${actual_status}" == "running" ]]; then
                local ip
                ip=$(cd "${vm_dir}" && vagrant ssh -c "hostname -I" 2>/dev/null \
                    | awk '{print $1}' | tr -d '\r')
                if [[ -n "${ip}" ]]; then
                    inventory_update "${vm_name}" "ip" "${ip}"
                fi
            else
                inventory_update "${vm_name}" "ip" "null"
            fi
        fi

        ((synced++))
    done <<< "${vm_names}"

    log_success "Synced ${synced} VM(s)"
    return 0
}
