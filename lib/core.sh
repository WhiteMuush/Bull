#!/usr/bin/env bash
# =============================================================================
# BULL - lib/core.sh
# Core utilities: colors, logging, dependency checks, input validation
# =============================================================================

# Guard against double-sourcing
[[ -n "${_BULL_CORE_LOADED:-}" ]] && return 0
readonly _BULL_CORE_LOADED=1

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
readonly BULL_VERSION="0.1.0"
readonly BULL_MIN_BASH_VERSION=4
# shellcheck disable=SC2034
readonly DEFAULT_RAM=4096
# shellcheck disable=SC2034
readonly DEFAULT_CPU=2
# shellcheck disable=SC2034
readonly DEFAULT_RESOLUTION="1920x1080"
# shellcheck disable=SC2034
readonly MIN_RAM=1024
readonly MIN_DISK_GB=20

# ---------------------------------------------------------------------------
# WSL2 Detection
# ---------------------------------------------------------------------------
is_wsl() {
    [[ -f /proc/version ]] && grep -qi "microsoft\|wsl" /proc/version 2>/dev/null
}

BULL_WSL=0
VAGRANT_CMD="vagrant"
VBOXMANAGE_CMD="VBoxManage"

# ---------------------------------------------------------------------------
# Provider detection: libvirt/KVM (WSL2 native) vs VirtualBox (Windows)
# KVM is preferred on WSL2 — everything stays in Linux, no Windows tools needed.
# ---------------------------------------------------------------------------
_kvm_available() {
    [[ -e /dev/kvm ]]
}

# BULL_PROVIDER can be forced via environment: export BULL_PROVIDER=virtualbox
if [[ -z "${BULL_PROVIDER:-}" ]]; then
    if _kvm_available; then
        BULL_PROVIDER="libvirt"
    else
        BULL_PROVIDER="virtualbox"
    fi
fi

# Always tell Vagrant which provider to use so it never iterates over all
# registered providers (avoids Vagrant 2.4.x Hyper-V detection crash on WSL2).
export VAGRANT_DEFAULT_PROVIDER="${BULL_PROVIDER}"

if is_wsl; then
    BULL_WSL=1

    # Vagrant on WSL2 always requires VAGRANT_WSL_ENABLE_WINDOWS_ACCESS=1
    # regardless of provider. Without it, Vagrant refuses to operate.
    export VAGRANT_WSL_ENABLE_WINDOWS_ACCESS=1

    if [[ "${BULL_PROVIDER}" == "virtualbox" ]]; then
        VBOXMANAGE_CMD="VBoxManage.exe"
        if command -v vagrant.exe &>/dev/null; then
            VAGRANT_CMD="vagrant.exe"
        else
            VAGRANT_CMD="vagrant"
        fi
    else
        # libvirt on WSL2: pure Linux stack
        VAGRANT_CMD="vagrant"

        # VAGRANT_WSL_ENABLE_WINDOWS_ACCESS makes Vagrant redirect its home
        # directory to the Windows filesystem (e.g. /mnt/c/Users/.../.vagrant.d).
        # For libvirt/KVM this is wrong — boxes and VMs live on the Linux side.
        # Force VAGRANT_HOME to the Linux path so Vagrant finds the right boxes.
        export VAGRANT_HOME="${HOME}/.vagrant.d"
        mkdir -p "${VAGRANT_HOME}"

        # Shim cmd.exe/powershell so Vagrant's WSL checks pass
        # without calling real Windows binaries (which may fail or be slow)
        _shim_dir="${HOME}/.bull/bin"
        mkdir -p "${_shim_dir}"

        if [[ ! -x "${_shim_dir}/cmd.exe" ]]; then
            printf '#!/usr/bin/env bash\n# BULL: Vagrant WSL2 shim\nexit 0\n' \
                > "${_shim_dir}/cmd.exe" && chmod +x "${_shim_dir}/cmd.exe"
        fi

        for _ps in powershell powershell.exe; do
            if [[ ! -x "${_shim_dir}/${_ps}" ]]; then
                printf '#!/usr/bin/env bash\n# BULL: Vagrant WSL2 PowerShell shim\necho "7"\n' \
                    > "${_shim_dir}/${_ps}" && chmod +x "${_shim_dir}/${_ps}"
            fi
        done
        unset _ps

        [[ ":${PATH}:" != *":${_shim_dir}:"* ]] && \
            export PATH="${_shim_dir}:${PATH}"
        unset _shim_dir
    fi
fi

# ---------------------------------------------------------------------------
# Directories
# KVM/libvirt: BULL_HOME anywhere in WSL2 filesystem
# VirtualBox:  BULL_HOME must be on Windows filesystem (/mnt/X/)
# ---------------------------------------------------------------------------
if [[ "${BULL_PROVIDER}" == "virtualbox" ]] && \
   [[ "${BULL_WSL}" -eq 1 ]] && \
   [[ -z "${BULL_HOME:-}" ]]; then
    _wsl_win_home=""

    # Method 1: PowerShell
    _ps="$(command -v powershell.exe 2>/dev/null \
        || echo "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe")"
    # shellcheck disable=SC2016
    if [[ -f "${_ps}" ]]; then
        _wsl_win_home="$(wslpath \
            "$("${_ps}" -NoProfile -NonInteractive \
               -Command '$env:USERPROFILE' 2>/dev/null | tr -d '\r\n')" \
            2>/dev/null)" || _wsl_win_home=""
    fi

    # Method 2: cmd.exe
    if [[ -z "${_wsl_win_home}" ]]; then
        _wsl_win_home="$(wslpath \
            "$(cmd.exe /C 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r\n')" \
            2>/dev/null)" || _wsl_win_home=""
    fi

    # Method 3: heuristic /mnt/X/Users/<user>
    if [[ -z "${_wsl_win_home}" ]]; then
        for _drive in c d e f; do
            _candidate="/mnt/${_drive}/Users/${USER}"
            if [[ -d "${_candidate}" ]]; then
                _wsl_win_home="${_candidate}"
                break
            fi
        done
        unset _drive _candidate
    fi

    if [[ -n "${_wsl_win_home}" && -d "${_wsl_win_home}" ]]; then
        BULL_HOME="${_wsl_win_home}/.bull"
    else
        # Cannot reach Windows filesystem — hard error, VMs would be inaccessible
        echo "[ERROR] Cannot determine Windows home directory from WSL2." >&2
        echo "[ERROR] Set BULL_HOME to a Windows path before running bull:" >&2
        echo "[ERROR]   export BULL_HOME=/mnt/c/Users/<yourname>/.bull" >&2
        exit 1
    fi

    unset _wsl_win_home _ps
else
    BULL_HOME="${BULL_HOME:-${HOME}/.bull}"
fi

readonly BULL_VM_DIR="${BULL_HOME}/vms"
readonly BULL_ERROR_LOG="${BULL_HOME}/bull-error.log"

# Debug / dry-run modes
BULL_DEBUG="${BULL_DEBUG:-0}"
BULL_DRY_RUN="${BULL_DRY_RUN:-0}"

# ---------------------------------------------------------------------------
# Colors (respect NO_COLOR - https://no-color.org/)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
setup_colors() {
    if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
        RED=""
        GREEN=""
        BLUE=""
        YELLOW=""
        GRAY=""
        CYAN=""
        MAGENTA=""
        BOLD=""
        DIM=""
        RESET=""
        BRIGHT_RED=""
        BRIGHT_GREEN=""
        BRIGHT_BLUE=""
        BRIGHT_CYAN=""
        BRIGHT_MAGENTA=""
    else
        RESET="$(tput sgr0)"
        BOLD="$(tput bold)"
        DIM="$(tput dim)"
        RED="$(tput setaf 1)"
        GREEN="$(tput setaf 2)"
        YELLOW="$(tput setaf 3)"
        BLUE="$(tput setaf 4)"
        MAGENTA="$(tput setaf 5)"
        CYAN="$(tput setaf 6)"
        GRAY="$(tput setaf 8)"
        BRIGHT_RED="$(tput setaf 9)"
        BRIGHT_GREEN="$(tput setaf 10)"
        BRIGHT_BLUE="$(tput setaf 12)"
        BRIGHT_CYAN="$(tput setaf 14)"
        BRIGHT_MAGENTA="$(tput setaf 13)"
    fi
}

setup_colors

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info() {
    echo -e "${BLUE}[INFO]${RESET} $*" >&2
    _log_to_file "[INFO] $*"
}

log_success() {
    echo -e "${GREEN}[OK]${RESET} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*" >&2
    _log_to_file "[WARN] $*"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
    _log_to_file "[ERROR] $*"
}

_log_to_file() {
    [[ -n "${BULL_HOME:-}" ]] || return 0
    mkdir -p "${BULL_HOME}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${BULL_ERROR_LOG}" 2>/dev/null || true
}

log_debug() {
    if [[ "${BULL_DEBUG}" == "1" ]]; then
        echo -e "${GRAY}[DEBUG]${RESET} $*" >&2
    fi
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------
error_handler() {
    local line_no="$1"
    log_error "Script failed at line ${line_no}"
    _log_to_file "[ERROR] Script failed at line ${line_no}"
    exit 1
}

cleanup() {
    log_debug "Cleanup: nothing to do"
}

# Restore terminal to clean state when leaving the TUI
_tui_restore() {
    printf '\033[?25h'    # show cursor
    printf '\033[?1049l'  # exit alternate screen buffer (restores previous content)
    printf '\033[0m'      # reset all color/attribute escapes
    stty sane 2>/dev/null || true  # restore echo, icanon, etc. (broken by password prompts)
}

setup_traps() {
    trap cleanup EXIT
    trap 'error_handler ${LINENO}' ERR
}

# ---------------------------------------------------------------------------
# GPG-based credential encryption
# Credentials are encrypted with a per-user GPG key and stored in
# .credentials.gpg inside each VM directory. The password is never stored
# in plaintext anywhere on disk.
# ---------------------------------------------------------------------------

_BULL_GPG_KEY_ID=""
readonly _BULL_GPG_UID="bull-credentials@local"

_bull_gpg_key_id() {
    if [[ -n "${_BULL_GPG_KEY_ID}" ]]; then
        echo "${_BULL_GPG_KEY_ID}"
        return 0
    fi

    local gpg_home="${BULL_HOME}/.gnupg"
    mkdir -p "${gpg_home}"
    chmod 700 "${gpg_home}"

    if ! "gpg" --homedir "${gpg_home}" --list-keys "${_BULL_GPG_UID}" &>/dev/null; then
        log_info "Generating GPG key for credential encryption..."
        if ! "gpg" --homedir "${gpg_home}" --batch --passphrase "" \
            --quick-generate-key "${_BULL_GPG_UID}" default default 0 2>&1; then
            log_error "Failed to generate GPG key for credential encryption"
            return 1
        fi
    fi

    _BULL_GPG_KEY_ID="${_BULL_GPG_UID}"
    echo "${_BULL_GPG_KEY_ID}"
}

# Encrypt a string with the BULL GPG key. Outputs armored ciphertext.
# Uses AES256 + high iteration count to slow brute-force attacks.
_bull_encrypt() {
    local plaintext="$1"
    local gpg_home="${BULL_HOME}/.gnupg"
    local key_id
    key_id="$(_bull_gpg_key_id)" || return 1

    echo "${plaintext}" | "gpg" --homedir "${gpg_home}" \
        --encrypt --armor --recipient "${key_id}" \
        --cipher-algo AES256 --s2k-digest SHA512 --s2k-count 65000000 \
        --trust-model always --batch --no-tty 2>/dev/null
}

# Decrypt a GPG-encrypted string. Outputs plaintext.
_bull_decrypt() {
    local ciphertext="$1"
    local gpg_home="${BULL_HOME}/.gnupg"

    echo "${ciphertext}" | "gpg" --homedir "${gpg_home}" \
        --decrypt --armor --batch --no-tty \
        --passphrase "" 2>/dev/null
}

# Encrypt password and save to .credentials.gpg in the VM directory.
# The .credentials file stores only the username (no password).
# The .credentials.gpg file stores the password encrypted with GPG.
_credentials_save() {
    local vm_name="$1"
    local username="$2"
    local password="$3"
    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"

    local cred_file="${vm_dir}/.credentials"
    {
        echo "# BULL VM Credentials"
        echo "# Password is encrypted in .credentials.gpg"
        echo "# To decrypt: bull show-pass ${vm_name}"
        echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "vm_name=${vm_name}"
        echo "username=${username}"
    } > "${cred_file}"
    chmod 600 "${cred_file}"

    if [[ -n "${password}" ]]; then
        local encrypted
        encrypted=$(_bull_encrypt "${password}") || {
            log_warn "GPG encryption failed — password NOT stored. Use 'bull passwd ${vm_name}' to reset."
            return 0
        }
        echo "${encrypted}" > "${vm_dir}/.credentials.gpg"
        chmod 600 "${vm_dir}/.credentials.gpg"
    fi
}

# Decrypt and display the password for a VM.
_credentials_show() {
    local vm_name="$1"
    local vm_dir
    vm_dir="$(get_vm_dir "${vm_name}")"
    local gpg_file="${vm_dir}/.credentials.gpg"
    local cred_file="${vm_dir}/.credentials"

    if [[ ! -f "${gpg_file}" ]]; then
        log_error "No encrypted credentials found for '${vm_name}'"
        if [[ -f "${cred_file}" ]]; then
            log_warn "Legacy .credentials file found (password was stored in plaintext)"
            log_warn "Recreate the VM to use encrypted credentials."
        fi
        return 1
    fi

    local username=""
    if [[ -f "${cred_file}" ]]; then
        username=$(grep '^username=' "${cred_file}" | cut -d= -f2)
    fi

    local password
    password=$(_bull_decrypt "$(cat "${gpg_file}")") || {
        log_error "Failed to decrypt credentials for '${vm_name}'"
        return 1
    }

    echo ""
    echo -e "  ╔══════════════════════════════════════════════════════╗"
    echo -e "  ║  !! CREDENTIALS — KEEP CONFIDENTIAL !!              ║"
    echo -e "  ╠══════════════════════════════════════════════════════╣"
    printf "  ║  Username : %-39s  ║\n" "${username}"
    printf "  ║  Password : %-39s  ║\n" "${password}"
    echo -e "  ╚══════════════════════════════════════════════════════╝"
    echo ""
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

# Validate VM name: starts with letter, alphanumeric + hyphens, max 11 chars
validate_vm_name() {
    local name="$1"

    if [[ -z "${name}" ]]; then
        log_error "VM name is required"
        return 1
    fi

    if [[ ! "${name}" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,10}$ ]]; then
        log_error "Invalid VM name '${name}'"
        log_error "Rules: start with letter, alphanumeric + hyphens, max 11 chars"
        return 1
    fi

    return 0
}

# Validate a positive integer
validate_positive_int() {
    local value="$1"
    local label="$2"

    if [[ ! "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -eq 0 ]]; then
        log_error "${label} must be a positive integer, got '${value}'"
        return 1
    fi

    return 0
}

# Ensure a required argument is non-empty
require_argument() {
    local value="$1"
    local name="$2"

    if [[ -z "${value}" ]]; then
        log_error "Missing required argument: ${name}"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# User confirmation (destructive actions)
# ---------------------------------------------------------------------------
confirm_action() {
    local message="$1"

    # Non-interactive mode -> abort
    if [[ ! -t 0 ]]; then
        log_error "Cannot confirm in non-interactive mode. Aborting."
        return 1
    fi

    echo -en "${YELLOW}[WARN]${RESET} ${message} [y/N]: "
    local confirm
    read -r confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        return 0
    fi

    log_info "Aborted."
    return 1
}

# ---------------------------------------------------------------------------
# Package manager detection & auto-install
# ---------------------------------------------------------------------------

# Detect the system package manager
detect_pkg_manager() {
    if [[ "$(uname)" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
            echo "brew"
        else
            echo "none"
        fi
        return
    fi

    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    elif command -v apk &>/dev/null; then
        echo "apk"
    else
        echo "none"
    fi
}

# Try to install a package interactively
# Usage: try_install_package "jq" "jq"
#        try_install_package "vagrant" "vagrant" "https://www.vagrantup.com/downloads"
try_install_package() {
    local cmd_name="$1"
    local pkg_name="${2:-${cmd_name}}"
    local manual_url="${3:-}"

    local pkg_mgr
    pkg_mgr="$(detect_pkg_manager)"

    if [[ "${pkg_mgr}" == "none" ]]; then
        log_error "No supported package manager found."
        if [[ -n "${manual_url}" ]]; then
            log_error "Install '${cmd_name}' manually: ${manual_url}"
        fi
        return 1
    fi

    echo -en "${YELLOW}[WARN]${RESET} '${cmd_name}' is not installed. Install it now? [Y/n]: "

    # Non-interactive -> skip
    if [[ ! -t 0 ]]; then
        echo "n"
        log_error "Non-interactive mode. Cannot install '${cmd_name}'."
        return 1
    fi

    local answer
    read -r answer
    answer="${answer:-y}"

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        log_info "Skipped installation of '${cmd_name}'."
        return 1
    fi

    log_info "Installing '${pkg_name}' via ${pkg_mgr}..."

    local install_ok=0
    case "${pkg_mgr}" in
        brew)
            brew install "${pkg_name}" || install_ok=1
            ;;
        apt)
            sudo apt-get update -qq && sudo apt-get install -y "${pkg_name}" || install_ok=1
            ;;
        dnf)
            sudo dnf install -y "${pkg_name}" || install_ok=1
            ;;
        yum)
            sudo yum install -y "${pkg_name}" || install_ok=1
            ;;
        pacman)
            sudo pacman -Sy --noconfirm "${pkg_name}" || install_ok=1
            ;;
        zypper)
            sudo zypper --non-interactive install "${pkg_name}" || install_ok=1
            ;;
        apk)
            sudo apk add "${pkg_name}" || install_ok=1
            ;;
    esac

    if [[ "${install_ok}" -ne 0 ]]; then
        log_error "Failed to install '${pkg_name}' via ${pkg_mgr}."
        if [[ -n "${manual_url}" ]]; then
            log_error "Try installing manually: ${manual_url}"
        fi
        return 1
    fi

    # Verify it's now available
    if ! command -v "${cmd_name}" &>/dev/null; then
        log_error "'${cmd_name}' still not found after install."
        return 1
    fi

    log_success "'${cmd_name}' installed successfully."
    return 0
}

# ---------------------------------------------------------------------------
# Dependency checking (with auto-install offer)
# ---------------------------------------------------------------------------

# Check if a command exists; if not, offer to install it
check_command() {
    local cmd="$1"
    local install_hint="${2:-}"

    if command -v "${cmd}" &>/dev/null; then
        return 0
    else
        if [[ -n "${install_hint}" ]]; then
            log_error "'${cmd}' not found. Install: ${install_hint}"
        else
            log_error "'${cmd}' not found"
        fi
        return 1
    fi
}

# Require a command: check, and if missing offer interactive install
# Returns 0 if command is available (possibly after install), 1 if not
require_command() {
    local cmd="$1"
    local pkg_name="${2:-${cmd}}"
    local manual_url="${3:-}"

    if command -v "${cmd}" &>/dev/null; then
        return 0
    fi

    log_warn "'${cmd}' is not installed."
    try_install_package "${cmd}" "${pkg_name}" "${manual_url}"
    return $?
}

# ---------------------------------------------------------------------------
# Windows package installation (WSL2)
# ---------------------------------------------------------------------------

# Repair VirtualBox Windows services via UAC-elevated cmd.
# Tries VBoxSDS first (COM server), then VBoxDrv (kernel driver).
_repair_vbox_services() {
    local ps
    ps="$(_get_powershell)" || { log_error "PowerShell not found."; return 1; }

    log_info "Requesting elevation to repair VirtualBox services..."
    log_info "(A Windows UAC prompt will appear — click Yes to continue)"

    "${ps}" -NoProfile -NonInteractive -Command "
        Start-Process cmd -ArgumentList @('/c',
            'sc config VBoxSDS start=demand & sc start VBoxSDS & sc config VBoxDrv start=system & sc start VBoxDrv'
        ) -Verb RunAs -Wait
    " 2>/dev/null

    # Give services a moment to start
    sleep 2

    if "${VBOXMANAGE_CMD}" list vms > /dev/null 2>&1; then
        log_success "VirtualBox services repaired."
        return 0
    fi

    # Still broken — offer winget reinstall as last resort
    log_warn "Services still not responding. Try reinstalling VirtualBox via winget?"
    echo -en "${YELLOW}[WARN]${RESET} Reinstall VirtualBox? [Y/n]: "
    local answer
    read -r answer
    answer="${answer:-y}"

    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        log_info "Reinstalling VirtualBox..."
        _run_winget uninstall --id Oracle.VirtualBox 2>&1 || true
        _run_winget install --id Oracle.VirtualBox \
            --accept-source-agreements --accept-package-agreements 2>&1
        sleep 3
        if "${VBOXMANAGE_CMD}" list vms > /dev/null 2>&1; then
            log_success "VirtualBox working after reinstall."
            return 0
        fi
    fi

    log_error "Could not repair VirtualBox automatically."
    log_error "Open VirtualBox on Windows manually once — this triggers driver initialization."
    return 1
}

# Verify VirtualBox is fully functional (not just installed).
# Vagrant validates with --version; if that output contains errors, it reports
# "incomplete installation". We check both --version and list vms.
_verify_vbox_functional() {
    # Vagrant's own check: VBoxManage --version must produce clean output (version only)
    local version_out
    version_out="$("${VBOXMANAGE_CMD}" --version 2>&1 | tr -d '\r')"

    # Check list vms — actually contacts VBoxSVC/VBoxSDS
    local listvm_out listvm_rc
    listvm_out="$("${VBOXMANAGE_CMD}" list vms 2>&1)"
    listvm_rc=$?

    # All good: version is clean and list vms works
    if [[ ${listvm_rc} -eq 0 ]] && ! echo "${version_out}" | grep -qi "error\|warning\|failed"; then
        return 0
    fi

    # Combine errors for pattern matching
    local all_errors="${version_out}
${listvm_out}"

    log_warn "VirtualBox is not working correctly. Attempting auto-repair..."
    echo

    # Show what VBoxManage says
    while IFS= read -r line; do
        [[ -n "${line}" ]] && log_error "  ${line}"
    done <<< "${all_errors}"
    echo

    echo -en "${YELLOW}[WARN]${RESET} Attempt automatic repair? (Windows UAC elevation required) [Y/n]: "
    local answer
    if [[ -t 0 ]]; then read -r answer; fi
    answer="${answer:-y}"

    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        _repair_vbox_services && return 0
    fi

    log_error "VirtualBox must be functional before creating VMs."
    return 1
}

# Ensure VirtualBox is in the Windows User PATH so Vagrant (which reads Windows
# PATH directly via VAGRANT_WSL_ENABLE_WINDOWS_ACCESS) can find the provider.
_ensure_vbox_in_windows_path() {
    local ps current_path

    ps="$(_get_powershell 2>/dev/null)" || return 0  # no PowerShell, skip silently

    # Check known VirtualBox install locations on Windows
    local -a vbox_win_candidates=(
        'C:\Program Files\Oracle\VirtualBox'
        'C:\Program Files (x86)\Oracle\VirtualBox'
    )

    local found_win_path=""
    local candidate
    for candidate in "${vbox_win_candidates[@]}"; do
        local unix_candidate
        unix_candidate="$(wslpath -u "${candidate}" 2>/dev/null)" || continue
        if [[ -f "${unix_candidate}/VBoxManage.exe" ]]; then
            found_win_path="${candidate}"
            # Also add to WSL PATH for this session
            if [[ ":${PATH}:" != *":${unix_candidate}:"* ]]; then
                export PATH="${PATH}:${unix_candidate}"
            fi
            break
        fi
    done

    [[ -z "${found_win_path}" ]] && return 0  # VBox not found, nothing to do

    # Check if already in Windows User PATH
    current_path="$("${ps}" -NoProfile -NonInteractive \
        -Command '[Environment]::GetEnvironmentVariable("PATH","User")' \
        2>/dev/null | tr -d '\r')"

    if [[ "${current_path}" == *"${found_win_path}"* ]]; then
        log_debug "VirtualBox already in Windows User PATH"
        return 0
    fi

    log_info "Adding VirtualBox to Windows User PATH for Vagrant..."
    if "${ps}" -NoProfile -NonInteractive -Command \
        "[Environment]::SetEnvironmentVariable('PATH', \
        [Environment]::GetEnvironmentVariable('PATH','User') + ';${found_win_path}', \
        'User')" 2>/dev/null; then
        log_success "VirtualBox added to Windows User PATH."
    else
        log_warn "Could not update Windows PATH (non-critical)."
    fi
}

# Resolve PowerShell executable — tries PATH first, then the fixed Windows location.
# Windows PATH is not always forwarded to WSL2 (appendWindowsPath may be false).
_get_powershell() {
    if command -v powershell.exe &>/dev/null; then
        echo "powershell.exe"
    elif [[ -f "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" ]]; then
        echo "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    else
        return 1
    fi
}

# Refresh PATH to pick up newly installed Windows programs
_win_refresh_path() {
    local ps
    ps="$(_get_powershell)" || return 1

    local win_path
    win_path="$("${ps}" -NoProfile -NonInteractive \
        -Command '[Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [Environment]::GetEnvironmentVariable("PATH","User")' \
        2>/dev/null | tr -d '\r')" || return 1

    local IFS=';'
    local p
    for p in ${win_path}; do
        local unix_p
        unix_p="$(wslpath -u "${p}" 2>/dev/null)" || continue
        if [[ -d "${unix_p}" ]] && [[ ":${PATH}:" != *":${unix_p}:"* ]]; then
            export PATH="${PATH}:${unix_p}"
        fi
    done
}

# Check if winget (App Installer) is available via Windows package registry.
# Winget is a UWP app — its execution alias cannot be exec'd from WSL2 interop.
# Get-AppxPackage queries the registry without invoking the alias.
_has_winget() {
    local ps ver
    ps="$(_get_powershell)" || return 1

    ver="$("${ps}" -NoProfile -NonInteractive \
        -Command "Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' \
            -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Version" \
        2>/dev/null | tr -d '\r\n')"
    [[ -n "${ver}" ]]
}

# Run winget via PowerShell's call operator (&).
# Each argument is wrapped in single quotes so that --flags are treated as string
# literals by PowerShell, not parsed as unary operators (-- is a PS operator).
_run_winget() {
    local ps ps_args arg
    ps="$(_get_powershell)" || { log_error "PowerShell not found."; return 1; }

    ps_args=""
    for arg in "$@"; do
        ps_args="${ps_args} '${arg}'"
    done

    "${ps}" -NoProfile -NonInteractive -Command "& winget${ps_args}" 2>&1
}

# Try to install a Windows package via winget
# Usage: try_install_winget "VBoxManage.exe" "Oracle.VirtualBox" "https://..."
try_install_winget() {
    local cmd_name="$1"
    local winget_id="$2"
    local manual_url="${3:-}"

    if ! _has_winget; then
        log_error "winget not found. Cannot auto-install Windows packages."
        if [[ -n "${manual_url}" ]]; then
            log_info "Install '${cmd_name}' manually: ${manual_url}"
        fi
        return 1
    fi

    echo -en "${YELLOW}[WARN]${RESET} '${cmd_name}' is not installed. Install via winget? [Y/n]: "

    # Non-interactive -> skip
    if [[ ! -t 0 ]]; then
        echo "n"
        log_error "Non-interactive mode. Cannot install '${cmd_name}'."
        return 1
    fi

    local answer
    read -r answer
    answer="${answer:-y}"

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        log_info "Skipped installation of '${cmd_name}'."
        return 1
    fi

    log_info "Installing '${winget_id}' via winget (interactive installer)..."
    log_info "Follow the installation wizard — this properly initializes drivers."

    # --interactive opens the GUI installer which correctly sets up kernel drivers.
    # Silent install (--silent) leaves drivers uninitialized and requires a reboot.
    _run_winget install --id "${winget_id}" \
        --accept-source-agreements --accept-package-agreements --interactive || true

    # Refresh WSL2 PATH from the Windows registry so newly added dirs are visible
    _win_refresh_path

    if command -v "${cmd_name}" &>/dev/null; then
        log_success "'${cmd_name}' is now available."
        return 0
    fi

    # PATH refresh didn't expose the binary — check known Windows install directories.
    local -a fallback_dirs=(
        "/mnt/c/Program Files/Oracle/VirtualBox"
        "/mnt/c/Program Files (x86)/Oracle/VirtualBox"
        "/mnt/c/Windows/System32"
    )
    local d
    for d in "${fallback_dirs[@]}"; do
        if [[ -f "${d}/${cmd_name}" ]]; then
            if [[ ":${PATH}:" != *":${d}:"* ]]; then
                export PATH="${PATH}:${d}"
            fi
            log_success "'${cmd_name}' is now available."
            return 0
        fi
    done

    log_warn "'${cmd_name}' installed but not yet in PATH."
    log_warn "Restart your terminal, then re-run bull."
    return 1
}

# Require a Windows command on WSL2: check, offer winget install if missing
require_windows_command() {
    local cmd="$1"
    local winget_id="$2"
    local manual_url="${3:-}"

    if command -v "${cmd}" &>/dev/null; then
        return 0
    fi

    try_install_winget "${cmd}" "${winget_id}" "${manual_url}"
    return $?
}

# ---------------------------------------------------------------------------
# libvirt / KVM system dependency installer
# ---------------------------------------------------------------------------

# Ask user to install a list of apt packages, then install them.
_apt_install_ask() {
    local packages=("$@")
    local pkg_list="${packages[*]}"

    echo -en "${YELLOW}[WARN]${RESET} Missing system packages: ${pkg_list}\n"
    echo -en "${YELLOW}[WARN]${RESET} Install via apt? [Y/n]: "

    if [[ ! -t 0 ]]; then
        echo "n"
        log_error "Non-interactive mode. Run manually: sudo apt install -y ${pkg_list}"
        return 1
    fi

    local answer
    read -r answer
    answer="${answer:-y}"

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        log_info "Skipped. Install manually: sudo apt install -y ${pkg_list}"
        return 1
    fi

    log_info "Installing: ${pkg_list}..."
    if sudo apt-get install -y "${packages[@]}" 2>&1; then
        log_success "Packages installed: ${pkg_list}"
        return 0
    else
        log_error "apt install failed for: ${pkg_list}"
        return 1
    fi
}

# Ensure all system packages required by vagrant-libvirt are present,
# then install the Vagrant plugin. Asks before each apt install.
_ensure_libvirt_deps() {
    local missing_pkgs=()

    # If /dev/kvm exists, KVM is already operational — skip qemu-kvm package check
    local need_qemu=true
    [[ -e /dev/kvm ]] && need_qemu=false

    local -a required_pkgs=(
        "libvirt-daemon-system"
        "libvirt-clients"
        "libvirt-dev"
        "build-essential"
        "ruby-dev"
        "pkg-config"
        "ovmf"
    )
    [[ "${need_qemu}" == "true" ]] && required_pkgs+=("qemu-kvm")

    local pkg
    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg -s "${pkg}" &>/dev/null 2>&1; then
            missing_pkgs+=("${pkg}")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        if ! _apt_install_ask "${missing_pkgs[@]}"; then
            log_warn "Some packages may be missing (sudo may require password)"
        fi
    fi

    # Ensure libvirtd is running
    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        log_info "Starting libvirtd service..."
        sudo systemctl enable --now libvirtd 2>&1 || \
            log_warn "Could not start libvirtd — you may need to run: sudo systemctl start libvirtd"
    fi

    # Add current user to libvirt + kvm groups if needed
    if ! groups | grep -q "libvirt"; then
        log_info "Adding ${USER} to libvirt group..."
        sudo usermod -aG libvirt,kvm "${USER}" 2>/dev/null || true
        log_warn "Group change requires a new shell session to take effect."
    fi

    # Ensure the 'default' storage pool exists — vagrant-libvirt requires it
    # Skip for VirtualBox provider
    if [[ "${BULL_PROVIDER}" != "virtualbox" ]]; then
        if virsh pool-info default &>/dev/null; then
            # Pool exists and is accessible — just make sure it's active
            if ! virsh pool-list 2>/dev/null | grep -q "default[[:space:]]*active"; then
                log_info "Starting existing libvirt 'default' storage pool..."
                sudo virsh pool-start default 2>&1 || log_warn "Could not start pool"
            fi
        elif sudo virsh pool-info default &>/dev/null; then
            # Pool exists but current user can't see it without sudo
            log_info "Storage pool 'default' exists (requires sudo to manage)."
            if ! sudo virsh pool-list 2>/dev/null | grep -q "default[[:space:]]*active"; then
                sudo virsh pool-start default 2>&1 || log_warn "Could not start pool"
            fi
            sudo virsh pool-autostart default 2>&1 || true
        else
            # Pool doesn't exist — create it
            log_info "Creating libvirt 'default' storage pool..."
            if sudo virsh pool-define-as default dir --target /var/lib/libvirt/images 2>&1; then
                sudo virsh pool-build default 2>&1 || true
                sudo virsh pool-start default 2>&1 || true
                sudo virsh pool-autostart default 2>&1 || true
                log_success "Storage pool 'default' created and started."
            else
                log_warn "Could not create storage pool."
                log_warn "Try: sudo virsh pool-define-as default dir --target /var/lib/libvirt/images"
            fi
        fi

        # Create OVMF_VARS_4M.fd symlink if missing.
        # Ubuntu's ovmf package ships OVMF_VARS_4M.ms.fd and .snakeoil.fd
        # but NOT OVMF_VARS_4M.fd (plain). vagrant-libvirt and libvirt need
        # this file for UEFI boot — create a symlink to .ms.fd as fallback.
        local ovmf_vars="/usr/share/OVMF/OVMF_VARS_4M.fd"
        if [[ ! -f "${ovmf_vars}" ]]; then
            local ovmf_dir
            ovmf_dir="$(dirname "${ovmf_vars}")"
            if [[ -f "${ovmf_dir}/OVMF_VARS_4M.ms.fd" ]]; then
                sudo ln -sf "${ovmf_dir}/OVMF_VARS_4M.ms.fd" "${ovmf_vars}" 2>/dev/null \
                    || log_warn "Could not create OVMF_VARS_4M.fd symlink"
            elif [[ -f "${ovmf_dir}/OVMF_VARS_4M.snakeoil.fd" ]]; then
                sudo ln -sf "${ovmf_dir}/OVMF_VARS_4M.snakeoil.fd" "${ovmf_vars}" 2>/dev/null \
                    || log_warn "Could not create OVMF_VARS_4M.fd symlink"
            else
                log_warn "OVMF VARS template not found — UEFI boot may fail"
            fi
        fi

        # Install vagrant-libvirt plugin
        if ! vagrant plugin list 2>/dev/null | grep -q "vagrant-libvirt"; then
            log_info "Installing vagrant-libvirt plugin..."
            if vagrant plugin install vagrant-libvirt 2>&1; then
                log_success "vagrant-libvirt plugin installed."
            else
                log_error "Failed to install vagrant-libvirt plugin."
                return 1
            fi
        else
            log_debug "vagrant-libvirt plugin already installed."
        fi

        # Ensure the 'default' NAT network exists and is active.
        # Without it, VMs cannot get an IP via DHCP and vagrant up will fail
        # with "The specified wait_for timeout (2 seconds) was exceeded".
        if virsh net-info default &>/dev/null; then
            # Network exists and is accessible — just make sure it's active
            if ! virsh net-list 2>/dev/null | grep -q "default[[:space:]]*active"; then
                log_info "Starting libvirt 'default' NAT network..."
                sudo virsh net-start default 2>&1 || log_warn "Could not start network"
            fi
        elif sudo virsh net-info default &>/dev/null; then
            # Network exists but current user can't see it without sudo
            log_info "NAT network 'default' exists (requires sudo to manage)."
            if ! sudo virsh net-list 2>/dev/null | grep -q "default[[:space:]]*active"; then
                sudo virsh net-start default 2>&1 || log_warn "Could not start network"
            fi
            sudo virsh net-autostart default 2>&1 || true
        else
            # Network doesn't exist — create it with standard NAT + DHCP
            log_info "Creating libvirt 'default' NAT network..."
            local net_xml
            net_xml='<network>
  <name>default</name>
  <forward mode="nat"/>
  <bridge name="virbr0" stp="on" delay="0"/>
  <ip address="192.168.122.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.122.2" end="192.168.122.254"/>
    </dhcp>
  </ip>
</network>'
            if echo "${net_xml}" | sudo virsh net-define /dev/stdin 2>&1; then
                sudo virsh net-start default 2>&1 || true
                sudo virsh net-autostart default 2>&1 || true
                log_success "NAT network 'default' created and started."
            else
                log_warn "Could not create NAT network."
                log_warn "Try: sudo virsh net-define default from XML"
            fi
        fi
    fi

    return 0
}

check_dependencies() {
    local all_ok=0

    log_info "Checking dependencies..."

    if [[ "${BULL_WSL}" -eq 1 ]]; then
        log_success "WSL2 environment detected"
        log_info "  BULL_HOME: ${BULL_HOME}"
    fi

    if command -v "${VAGRANT_CMD}" &>/dev/null; then
        local vagrant_ver
        vagrant_ver="$("${VAGRANT_CMD}" --version 2>/dev/null | awk '{print $2}')"
        log_success "Vagrant detected (v${vagrant_ver}) [${VAGRANT_CMD}]"
    else
        if [[ "${BULL_WSL}" -eq 1 ]]; then
            log_warn "vagrant.exe not found. Install Vagrant for Windows:"
            log_info "  https://developer.hashicorp.com/vagrant/install"
            log_info "  (Install on Windows, not inside WSL2)"
            all_ok=1
        else
            if require_command "vagrant" "vagrant" "https://developer.hashicorp.com/vagrant/install"; then
                local vagrant_ver
                vagrant_ver="$("${VAGRANT_CMD}" --version 2>/dev/null | awk '{print $2}')"
                log_success "Vagrant installed (v${vagrant_ver})"
            else
                all_ok=1
            fi
        fi
    fi

    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        if [[ -e /dev/kvm ]]; then
            log_success "KVM available (/dev/kvm)"
        else
            log_error "KVM not available. Enable nestedVirtualization in ~/.wslconfig"
            all_ok=1
        fi
        if command -v virsh &>/dev/null; then
            log_success "libvirt detected ($(virsh --version 2>/dev/null))"
        else
            log_warn "libvirt-clients not installed"
            all_ok=1
        fi
        if vagrant plugin list 2>/dev/null | grep -q "vagrant-libvirt"; then
            log_success "vagrant-libvirt plugin ready"
        else
            log_warn "vagrant-libvirt plugin not installed (run: bull init to install)"
            all_ok=1
        fi
    else
        # VirtualBox provider checks
        if command -v "${VBOXMANAGE_CMD}" &>/dev/null; then
            local vbox_ver
            vbox_ver="$("${VBOXMANAGE_CMD}" --version 2>/dev/null | cut -d'r' -f1)"
            log_success "VirtualBox detected (v${vbox_ver})"
        else
            if [[ "${BULL_WSL}" -eq 1 ]]; then
                if require_windows_command "VBoxManage.exe" "Oracle.VirtualBox" \
                    "https://www.virtualbox.org/wiki/Downloads"; then
                    local vbox_ver
                    vbox_ver=$("${VBOXMANAGE_CMD}" --version 2>/dev/null | cut -d'r' -f1)
                    log_success "VirtualBox installed (v${vbox_ver})"
                else
                    all_ok=1
                fi
            else
                if require_command "VBoxManage" "virtualbox" "https://www.virtualbox.org/wiki/Downloads"; then
                    local vbox_ver
                    vbox_ver="$(VBoxManage --version 2>/dev/null | cut -d'r' -f1)"
                    log_success "VirtualBox installed (v${vbox_ver})"
                else
                    all_ok=1
                fi
            fi
        fi
    fi

    if command -v jq &>/dev/null; then
        log_success "jq detected"
    else
        if require_command "jq" "jq" "https://stedolan.github.io/jq/download/"; then
            log_success "jq installed"
        else
            all_ok=1
        fi
    fi

    if command -v ssh &>/dev/null; then
        log_success "SSH client detected"
    else
        if require_command "ssh" "openssh-client"; then
            log_success "SSH client installed"
        else
            all_ok=1
        fi
    fi

    if command -v gpg &>/dev/null; then
        log_success "GPG detected (credential encryption)"
    else
        if require_command "gpg" "gnupg"; then
            log_success "GPG installed (credential encryption)"
        else
            all_ok=1
        fi
    fi

    # VirtualBox on WSL2: files must be on Windows filesystem
    if [[ "${BULL_PROVIDER}" == "virtualbox" ]] && \
       [[ "${BULL_WSL}" -eq 1 ]] && \
       [[ ! "${BULL_HOME}" =~ ^/mnt/[a-zA-Z]/ ]]; then
        log_warn "BULL_HOME is not on the Windows filesystem: ${BULL_HOME}"
        log_warn "VirtualBox requires VM files on /mnt/c/ (or another Windows drive)."
        log_warn "Set: export BULL_HOME=/mnt/c/Users/<user>/.bull"
    fi

    log_info "Provider: ${BULL_PROVIDER}"

    if [[ "${all_ok}" -eq 0 ]]; then
        log_success "All dependencies satisfied"
    else
        log_error "Some dependencies are still missing."
    fi

    return "${all_ok}"
}

# Ensure critical dependencies are available before a VM operation.
# Offers to install missing ones. Returns 1 if any are still missing.
ensure_dependencies() {
    local missing=0

    if ! command -v jq &>/dev/null; then
        require_command "jq" "jq" "https://stedolan.github.io/jq/download/" || missing=1
    fi

    if ! command -v "${VAGRANT_CMD}" &>/dev/null; then
        if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
            require_command "vagrant" "vagrant" "https://developer.hashicorp.com/vagrant/install" || missing=1
        elif [[ "${BULL_WSL}" -eq 1 ]]; then
            log_error "vagrant.exe not found. Install Vagrant for Windows:"
            log_error "  https://developer.hashicorp.com/vagrant/install"
            missing=1
        else
            require_command "vagrant" "vagrant" "https://developer.hashicorp.com/vagrant/install" || missing=1
        fi
    fi

    if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
        if ! [[ -e /dev/kvm ]]; then
            log_error "KVM not available. Add nestedVirtualization=true to ~/.wslconfig"
            missing=1
        else
            _ensure_libvirt_deps || missing=1
        fi
    elif ! command -v "${VBOXMANAGE_CMD}" &>/dev/null; then
        if [[ "${BULL_WSL}" -eq 1 ]]; then
            require_windows_command "VBoxManage.exe" "Oracle.VirtualBox" \
                "https://www.virtualbox.org/wiki/Downloads" || missing=1
        else
            require_command "VBoxManage" "virtualbox" "https://www.virtualbox.org/wiki/Downloads" || missing=1
        fi
    fi

    if [[ "${missing}" -ne 0 ]]; then
        # For libvirt, check if we have at least basic access
        if [[ "${BULL_PROVIDER}" == "libvirt" ]]; then
            if [[ -e /dev/kvm ]] && command -v virsh &>/dev/null; then
                log_warn "Some dependencies may be missing but KVM is available"
                return 0  # Continue anyway
            fi
        fi
        log_error "Cannot proceed: missing required dependencies."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Bash version check
# ---------------------------------------------------------------------------
check_bash_version() {
    if [[ "${BASH_VERSINFO[0]}" -lt "${BULL_MIN_BASH_VERSION}" ]]; then
        log_error "Bash ${BULL_MIN_BASH_VERSION}.0+ required (found ${BASH_VERSION})"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Utility functions
# ---------------------------------------------------------------------------

# Get the BULL home directory, creating it if needed
get_bull_dir() {
    if [[ ! -d "${BULL_HOME}" ]]; then
        mkdir -p "${BULL_HOME}"
        log_debug "Created BULL_HOME: ${BULL_HOME}"
    fi
    echo "${BULL_HOME}"
}

# Get VM directory path
get_vm_dir() {
    local vm_name="$1"
    echo "${BULL_VM_DIR}/${vm_name}"
}

# Check available disk space (in GB)
check_disk_space() {
    local required_gb="${1:-${MIN_DISK_GB}}"
    local available_gb

    # df -BG for Linux, df -g for macOS
    if df --version &>/dev/null 2>&1; then
        # GNU df (Linux)
        available_gb=$(df -BG "${BULL_HOME}" 2>/dev/null \
            | tail -1 | awk '{print $4}' | tr -d 'G')
    else
        # BSD df (macOS) - output in 512-byte blocks, convert to GB
        available_gb=$(df -g "${BULL_HOME}" 2>/dev/null \
            | tail -1 | awk '{print $4}')
    fi

    if [[ -z "${available_gb}" ]]; then
        log_warn "Could not determine available disk space"
        return 0
    fi

    if [[ "${available_gb}" -lt "${required_gb}" ]]; then
        log_error "Insufficient disk space: ${available_gb}GB available, ${required_gb}GB required"
        return 1
    fi

    log_debug "Disk space OK: ${available_gb}GB available"
    return 0
}

# ISO 8601 timestamp
timestamp_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Detect OS
detect_os() {
    local uname_out
    uname_out="$(uname -s)"
    case "${uname_out}" in
        Linux*)
            if is_wsl; then
                echo "wsl2"
            else
                echo "linux"
            fi
            ;;
        Darwin*) echo "macos" ;;
        *)       echo "unknown" ;;
    esac
}

check_bash_version
