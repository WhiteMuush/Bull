#!/usr/bin/env bash
# =============================================================================
# BULL - lib/toolkits.sh
# External toolkit installation + persistent registry
# =============================================================================

[[ -n "${_BULL_TOOLKITS_LOADED:-}" ]] && return 0
readonly _BULL_TOOLKITS_LOADED=1

readonly TOOLKITS_INSTALL_DIR="/opt/toolkits"
readonly TOOLKITS_REGISTRY="${BULL_HOME}/toolkits.json"

# ---------------------------------------------------------------------------
# Registry helpers
# ---------------------------------------------------------------------------

_toolkit_registry_init() {
    if [[ ! -f "${TOOLKITS_REGISTRY}" ]]; then
        mkdir -p "$(dirname "${TOOLKITS_REGISTRY}")"
        echo '{"toolkits":[]}' > "${TOOLKITS_REGISTRY}"
    fi
}

# Save a toolkit URL to the registry (idempotent: updates URL if name exists)
toolkit_save() {
    local name="$1"
    local url="$2"

    require_argument "${name}" "toolkit name" || return 1
    require_argument "${url}"  "toolkit URL"  || return 1

    _toolkit_registry_init

    local updated
    updated=$(jq --arg n "${name}" --arg u "${url}" '
        if any(.toolkits[]; .name == $n) then
            .toolkits = [ .toolkits[] |
                if .name == $n then .url = $u else . end ]
        else
            .toolkits += [{"name": $n, "url": $u}]
        end' "${TOOLKITS_REGISTRY}") || {
        log_error "Failed to update toolkit registry"
        return 1
    }
    local tmp
    tmp=$(mktemp "${TOOLKITS_REGISTRY}.XXXXXX")
    echo "${updated}" > "${tmp}" && mv "${tmp}" "${TOOLKITS_REGISTRY}"
    log_success "Toolkit '${name}' saved to registry"
}

toolkit_remove_from_registry() {
    local name="$1"

    require_argument "${name}" "toolkit name" || return 1
    _toolkit_registry_init

    local updated
    updated=$(jq --arg n "${name}" \
        '.toolkits = [.toolkits[] | select(.name != $n)]' \
        "${TOOLKITS_REGISTRY}") || return 1
    local tmp
    tmp=$(mktemp "${TOOLKITS_REGISTRY}.XXXXXX")
    echo "${updated}" > "${tmp}" && mv "${tmp}" "${TOOLKITS_REGISTRY}"
    log_success "Toolkit '${name}' removed from registry"
}

# Print the registry as a numbered table. Populates BULL_TOOLKIT_NAMES[].
# Returns 0 if entries exist, 1 if empty.
list_toolkit_registry() {
    _toolkit_registry_init
    BULL_TOOLKIT_NAMES=()
    BULL_TOOLKIT_URLS=()

    local count
    count=$(jq '.toolkits | length' "${TOOLKITS_REGISTRY}" 2>/dev/null || echo 0)

    echo -e "\n${BOLD}${BRIGHT_CYAN}[ Saved Toolkits ]${RESET}"

    if [[ "${count}" -eq 0 ]]; then
        echo -e "  ${DIM}No saved toolkits. Add one with option [2] below.${RESET}\n"
        return 1
    fi

    printf '\n  %-4s  %-20s  %s\n' "#" "NAME" "URL"
    echo -e "  ${DIM}────  ────────────────────  ────────────────────────────────────────────${RESET}"

    local idx=1
    while IFS=$'\t' read -r name url; do
        printf '  %-4s  %-20s  %s\n' \
            "${BRIGHT_RED}[${idx}]${RESET}" "${name}" "${DIM}${url}${RESET}"
        BULL_TOOLKIT_NAMES+=("${name}")
        BULL_TOOLKIT_URLS+=("${url}")
        (( idx++ ))
    done < <(jq -r '.toolkits[] | [.name, .url] | @tsv' "${TOOLKITS_REGISTRY}")
    echo

    return 0
}

# ---------------------------------------------------------------------------
# Toolkit Installation
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Input validation for toolkit URLs
# Only allow valid Git URLs (https://, git://, git@, ssh://) with safe
# characters. Reject anything containing shell metacharacters to prevent
# injection via vagrant ssh -c.
# ---------------------------------------------------------------------------
_validate_toolkit_url() {
    local url="$1"

    if [[ ! "${url}" =~ ^(https?://|git://|git@|ssh://) ]]; then
        log_error "Invalid toolkit URL: must start with https://, http://, git://, git@, or ssh://"
        return 1
    fi

    # Reject shell metacharacters to prevent injection via vagrant ssh -c
    # shellcheck disable=SC2046
    if printf '%s' "${url}" | grep -qE "'"'"`'$'();|&<>'; then
        log_error "Invalid toolkit URL: contains forbidden characters"
        return 1
    fi

    return 0
}

# Validate toolkit name: alphanumeric, hyphens, underscores only
_validate_toolkit_name() {
    local name="$1"

    if [[ ! "${name}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid toolkit name: '${name}' (alphanumeric, hyphens, underscores only)"
        return 1
    fi

    return 0
}

# Install a single toolkit from a Git URL into a running VM.
# Runs as sudo inside the VM to ensure /opt/toolkits is writable.
install_toolkit() {
    local vm_name="$1"
    local toolkit_url="$2"

    require_argument "${vm_name}"    "vm name"    || return 1
    require_argument "${toolkit_url}" "toolkit URL" || return 1

    _validate_toolkit_url "${toolkit_url}" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found"
        return 1
    fi

    local current_status
    current_status=$(jq -r --arg name "${vm_name}" \
        '.vms[] | select(.name == $name) | .status' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ "${current_status}" != "running" ]]; then
        log_error "VM '${vm_name}' must be running to install toolkits"
        return 1
    fi

    local repo_name
    repo_name=$(basename "${toolkit_url}" .git)

    _validate_toolkit_name "${repo_name}" || return 1

    log_info "Installing toolkit '${repo_name}' on VM '${vm_name}'..."

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would install ${toolkit_url} into ${TOOLKITS_INSTALL_DIR}/${repo_name}"
        return 0
    fi

    # Build a self-contained install script executed inside the VM via SSH.
    # Uses sudo throughout to avoid permission issues on /opt/toolkits
    # (created as root during provisioning). The BULL user has NOPASSWD sudo.
    local install_script
    install_script=$(cat << PROVISION_EOF
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${TOOLKITS_INSTALL_DIR}"
REPO_URL="${toolkit_url}"
REPO_NAME="${repo_name}"

sudo mkdir -p "\${INSTALL_DIR}"
sudo chmod 775 "\${INSTALL_DIR}"

if [[ -d "\${INSTALL_DIR}/\${REPO_NAME}" ]]; then
    echo "[BULL] Toolkit '\${REPO_NAME}' already exists — updating..."
    cd "\${INSTALL_DIR}/\${REPO_NAME}"
    sudo git pull --ff-only 2>&1 || {
        echo "[BULL] Pull failed, re-cloning..."
        cd /
        sudo rm -rf "\${INSTALL_DIR}/\${REPO_NAME}"
        sudo git clone "\${REPO_URL}" "\${INSTALL_DIR}/\${REPO_NAME}"
    }
else
    echo "[BULL] Cloning '\${REPO_NAME}'..."
    sudo git clone "\${REPO_URL}" "\${INSTALL_DIR}/\${REPO_NAME}"
fi

sudo chown -R "\$(id -u):\$(id -g)" "\${INSTALL_DIR}/\${REPO_NAME}"

if [[ -f "\${INSTALL_DIR}/\${REPO_NAME}/install.sh" ]]; then
    echo "[BULL] Running install.sh..."
    chmod +x "\${INSTALL_DIR}/\${REPO_NAME}/install.sh"
    bash "\${INSTALL_DIR}/\${REPO_NAME}/install.sh"
elif [[ -f "\${INSTALL_DIR}/\${REPO_NAME}/setup.py" ]]; then
    echo "[BULL] Installing Python package..."
    cd "\${INSTALL_DIR}/\${REPO_NAME}"
    pip3 install -r requirements.txt 2>/dev/null || true
fi

echo "[BULL] Toolkit '\${REPO_NAME}' ready at \${INSTALL_DIR}/\${REPO_NAME}"
PROVISION_EOF
)

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    # Pass validated values via environment variables — no string interpolation
    # in the script body, eliminating shell injection risk.
    if (cd "${vm_dir}" && vagrant ssh -c "${install_script}" 2>&1); then
        log_success "Toolkit '${repo_name}' installed on '${vm_name}'"
        return 0
    else
        log_error "Failed to install toolkit '${repo_name}'"
        return 1
    fi
}

# Install all toolkits from the registry onto a VM (used during creation)
install_registry_toolkits() {
    local vm_name="$1"

    require_argument "${vm_name}" "vm name" || return 1
    _toolkit_registry_init

    local count
    count=$(jq '.toolkits | length' "${TOOLKITS_REGISTRY}" 2>/dev/null || echo 0)

    if [[ "${count}" -eq 0 ]]; then
        log_info "No saved toolkits in registry."
        return 0
    fi

    local success=0 failed=0
    while IFS=$'\t' read -r name url; do
        log_info "Installing: ${name}"
        if install_toolkit "${vm_name}" "${url}"; then
            (( success++ ))
        else
            (( failed++ ))
        fi
    done < <(jq -r '.toolkits[] | [.name, .url] | @tsv' "${TOOLKITS_REGISTRY}")

    log_info "Done: ${success} installed, ${failed} failed"
    [[ "${failed}" -eq 0 ]]
}

# Rename a toolkit in the registry (keeps its URL)
toolkit_rename() {
    local old_name="$1"
    local new_name="$2"

    require_argument "${old_name}" "old name" || return 1
    require_argument "${new_name}" "new name" || return 1
    _toolkit_registry_init

    local updated
    updated=$(jq --arg old "${old_name}" --arg new "${new_name}" \
        '.toolkits = [.toolkits[] |
         if .name == $old then .name = $new else . end]' \
        "${TOOLKITS_REGISTRY}") || {
        log_error "Failed to rename toolkit"
        return 1
    }
    local tmp
    tmp=$(mktemp "${TOOLKITS_REGISTRY}.XXXXXX")
    echo "${updated}" > "${tmp}" && mv "${tmp}" "${TOOLKITS_REGISTRY}"
    log_success "Toolkit renamed: '${old_name}' → '${new_name}'"
}

toolkit_pull() {
    local vm_name="$1"
    local toolkit_name="$2"

    require_argument "${vm_name}" "vm name" || return 1
    require_argument "${toolkit_name}" "toolkit name" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found"
        return 1
    fi

    local current_status
    current_status=$(jq -r --arg name "${vm_name}" \
        '.vms[] | select(.name == $name) | .status' \
        "${INVENTORY_FILE}" 2>/dev/null)

    if [[ "${current_status}" != "running" ]]; then
        log_error "VM '${vm_name}' must be running to pull toolkits"
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    log_info "Pulling '${toolkit_name}' on VM '${vm_name}'..."

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would pull ${TOOLKITS_INSTALL_DIR}/${toolkit_name}"
        return 0
    fi

    local pull_cmd="cd '${TOOLKITS_INSTALL_DIR}/${toolkit_name}' && sudo git pull --ff-only 2>&1"
    if (cd "${vm_dir}" && "${VAGRANT_CMD}" ssh -c "${pull_cmd}" 2>&1); then
        log_success "Toolkit '${toolkit_name}' updated on '${vm_name}'"
        return 0
    else
        log_error "Failed to pull toolkit '${toolkit_name}'"
        return 1
    fi
}

list_toolkits() {
    local vm_name="$1"

    require_argument "${vm_name}" "vm name" || return 1

    if ! inventory_vm_exists "${vm_name}"; then
        log_error "VM '${vm_name}' not found"
        return 1
    fi

    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    log_info "Installed toolkits on '${vm_name}':"

    if [[ "${BULL_DRY_RUN}" == "1" ]]; then
        log_info "[DRY RUN] Would list toolkits"
        return 0
    fi

    (cd "${vm_dir}" && vagrant ssh -c \
        "ls -1 '${TOOLKITS_INSTALL_DIR}/' 2>/dev/null || echo '(none)'" 2>&1) || {
        log_error "Failed to list toolkits"
        return 1
    }
}
