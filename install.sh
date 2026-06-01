#!/usr/bin/env bash
# =============================================================================
# BULL - install.sh
# Installs Vagrant + hypervisor (libvirt/KVM or VirtualBox) fully unattended.
#
# Supported families
#   Debian/Ubuntu/Kali/Parrot   (apt)
#   Fedora/RHEL/Rocky/AlmaLinux (dnf / yum)
#   Arch / Manjaro              (pacman)
#   openSUSE Leap / Tumbleweed  (zypper)
#
# Architectures : x86_64, arm64
# Usage         : sudo ./install.sh [--provider virtualbox|libvirt] [--skip-provider]
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Logging — all to stderr so $() captures stay clean
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*" >&2; }
log_ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
log_error()   { echo -e "${RED}[ERR ]${RESET}  $*" >&2; }
log_section() {
    echo -e "\n${BOLD}──────────────────────────────────────────\n  $*\n──────────────────────────────────────────${RESET}" >&2
}

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ "${EUID:-0}" -eq 0 ]] || die "Must run as root:  sudo $0 $*"

REAL_USER="${SUDO_USER:-}"
[[ -z "$REAL_USER" ]] && REAL_USER="$(logname 2>/dev/null || echo root)"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || echo /root)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
FORCE_PROVIDER=""
SKIP_PROVIDER=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --provider)
            shift
            FORCE_PROVIDER="${1:?--provider requires: virtualbox | libvirt}"
            [[ "$FORCE_PROVIDER" =~ ^(virtualbox|libvirt)$ ]] || \
                die "Unknown provider '$FORCE_PROVIDER'. Use 'virtualbox' or 'libvirt'."
            ;;
        --skip-provider) SKIP_PROVIDER=1 ;;
        -h|--help)
            echo "Usage: sudo $0 [--provider virtualbox|libvirt] [--skip-provider]"
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# System detection
# ---------------------------------------------------------------------------
log_section "System Detection"

is_wsl()        { [[ -f /proc/version ]] && grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; }
kvm_available() { [[ -e /dev/kvm ]]; }

IS_WSL=0; is_wsl && IS_WSL=1

# Arch string normalised to HashiCorp/VirtualBox convention
case "$(uname -m)" in
    x86_64)  SYS_ARCH="amd64" ;;
    aarch64) SYS_ARCH="arm64" ;;
    *)       SYS_ARCH="amd64" ;;
esac

[[ -f /etc/os-release ]] || die "/etc/os-release not found — unsupported system."
# shellcheck disable=SC1091
source /etc/os-release
DISTRO_ID="${ID:-unknown}"
DISTRO_CODENAME="${VERSION_CODENAME:-}"
DISTRO_VERSION="${VERSION_ID:-?}"

# Detect package manager → set DISTRO_FAMILY and PKG_MANAGER
if   command -v apt-get &>/dev/null; then DISTRO_FAMILY="debian";  PKG_MANAGER="apt"
elif command -v dnf     &>/dev/null; then DISTRO_FAMILY="redhat";  PKG_MANAGER="dnf"
elif command -v yum     &>/dev/null; then DISTRO_FAMILY="redhat";  PKG_MANAGER="yum"
elif command -v pacman  &>/dev/null; then DISTRO_FAMILY="arch";    PKG_MANAGER="pacman"
elif command -v zypper  &>/dev/null; then DISTRO_FAMILY="suse";    PKG_MANAGER="zypper"
else die "No supported package manager found (apt / dnf / yum / pacman / zypper)."
fi

log_info "Distro  : ${DISTRO_ID} ${DISTRO_VERSION} (${DISTRO_CODENAME:-n/a})"
log_info "Family  : ${DISTRO_FAMILY} / ${PKG_MANAGER}"
log_info "Kernel  : $(uname -r)  arch=${SYS_ARCH}"
log_info "WSL2    : $([ $IS_WSL -eq 1 ] && echo yes || echo no)"
log_info "KVM     : $(kvm_available && echo available || echo unavailable)"
log_info "User    : ${REAL_USER} (home: ${REAL_HOME})"

# ---------------------------------------------------------------------------
# Attempt to activate KVM before deciding on provider
# ---------------------------------------------------------------------------
if ! kvm_available && [[ $SKIP_PROVIDER -eq 0 && -z "$FORCE_PROVIDER" ]]; then
    log_info "Trying to load KVM kernel modules..."
    modprobe kvm       2>/dev/null || true
    modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
    if kvm_available; then
        log_ok "/dev/kvm active after module load."
    else
        log_warn "KVM unavailable — VirtualBox will be used as provider."
    fi
fi

# ---------------------------------------------------------------------------
# Provider selection
# ---------------------------------------------------------------------------
PROVIDER="virtualbox"
if [[ $SKIP_PROVIDER -eq 0 ]]; then
    if   [[ -n "$FORCE_PROVIDER" ]]; then PROVIDER="$FORCE_PROVIDER"
    elif kvm_available;               then PROVIDER="libvirt"
    fi
    log_info "Provider: ${PROVIDER}"
fi

# ---------------------------------------------------------------------------
# Package manager abstraction
# ---------------------------------------------------------------------------
pkg_update() {
    case "$PKG_MANAGER" in
        apt)    apt-get update -qq ;;
        dnf)    dnf makecache -q --refresh ;;
        yum)    yum makecache -q ;;
        pacman) pacman -Sy --noconfirm ;;
        zypper) zypper --non-interactive refresh ;;
    esac
}

pkg_install() {
    case "$PKG_MANAGER" in
        apt)
            apt-get install -y -q --no-install-recommends \
                -o Dpkg::Options::="--force-confold" \
                -o Dpkg::Options::="--force-confdef" \
                "$@"
            ;;
        dnf)    dnf install -y -q "$@" ;;
        yum)    yum install -y -q "$@" ;;
        pacman) pacman -S --noconfirm --needed "$@" ;;
        zypper) zypper --non-interactive install -y "$@" ;;
    esac
}

# Probe an APT repo for a codename; returns the fallback if absent.
probe_apt_codename() {
    local base_url="$1" codename="$2" fallback="$3"
    if wget -q --spider --timeout=10 "${base_url}/dists/${codename}/" 2>/dev/null; then
        echo "$codename"
    else
        log_warn "APT repo ${base_url}: '${codename}' not found → using '${fallback}'."
        echo "$fallback"
    fi
}

# ---------------------------------------------------------------------------
# Step 1 — Prerequisites
# ---------------------------------------------------------------------------
log_section "Prerequisites"

case "$DISTRO_FAMILY" in
    debian)
        # Remove stale repo files from any previous partial run
        rm -f /etc/apt/sources.list.d/hashicorp.list \
              /etc/apt/sources.list.d/virtualbox.list
        pkg_update
        pkg_install curl wget gnupg lsb-release software-properties-common \
                    ca-certificates apt-transport-https build-essential dkms \
                    util-linux-extra
        ;;
    redhat)
        pkg_update
        # dnf-plugins-core provides dnf config-manager
        pkg_install curl wget make gcc dkms dnf-plugins-core
        # EPEL provides DKMS and other tools on RHEL-compatible distros
        if [[ "$DISTRO_ID" != "fedora" ]]; then
            pkg_install epel-release 2>/dev/null || \
                pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${DISTRO_VERSION%%.*}.noarch.rpm" \
                2>/dev/null || true
        fi
        # Kernel headers for DKMS
        pkg_install "kernel-devel-$(uname -r)" 2>/dev/null || \
            pkg_install kernel-devel || true
        ;;
    arch)
        pkg_update
        pkg_install curl wget gnupg base-devel dkms linux-headers
        ;;
    suse)
        pkg_update
        pkg_install curl wget gpg2 make gcc dkms \
                    kernel-devel kernel-default-devel
        ;;
esac

log_ok "Prerequisites installed."

# ---------------------------------------------------------------------------
# Step 2 — Vagrant
# ---------------------------------------------------------------------------
log_section "Vagrant"

if command -v vagrant &>/dev/null; then
    log_warn "Vagrant $(vagrant --version | awk '{print $2}') already installed — skipping."
else
    case "$DISTRO_FAMILY" in
        debian)
            HC_BASE="https://apt.releases.hashicorp.com"
            HC_KEYRING="/usr/share/keyrings/hashicorp-archive-keyring.gpg"
            log_info "Adding HashiCorp APT repo..."
            wget -qO - "${HC_BASE}/gpg" | gpg --dearmor -o "$HC_KEYRING"
            _cn=$(probe_apt_codename "$HC_BASE" "${DISTRO_CODENAME:-}" "noble")
            echo "deb [signed-by=${HC_KEYRING}] ${HC_BASE} ${_cn} main" \
                > /etc/apt/sources.list.d/hashicorp.list
            pkg_update
            ;;
        redhat)
            log_info "Adding HashiCorp RPM repo..."
            if [[ "$DISTRO_ID" == "fedora" ]]; then
                _hc_repo="https://rpm.releases.hashicorp.com/fedora/hashicorp.repo"
            else
                _hc_repo="https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo"
            fi
            dnf config-manager --add-repo "$_hc_repo" -q 2>/dev/null || \
                wget -qO /etc/yum.repos.d/hashicorp.repo "$_hc_repo"
            pkg_update
            ;;
        arch)
            log_info "Vagrant available from Arch extra repo."
            pkg_update
            ;;
        suse)
            log_info "Adding HashiCorp SLES/openSUSE repo..."
            _hc_repo="https://rpm.releases.hashicorp.com/SLES/hashicorp.repo"
            wget -qO /etc/zypp/repos.d/hashicorp.repo "$_hc_repo" 2>/dev/null || \
                zypper addrepo "${_hc_repo}" hashicorp 2>/dev/null || true
            zypper --non-interactive refresh 2>/dev/null || true
            ;;
    esac

    pkg_install vagrant
    log_ok "Vagrant $(vagrant --version | awk '{print $2}') installed."
fi

# Make sure vagrant binary is on PATH for this session
export PATH="/opt/vagrant/bin:/usr/bin:${PATH}"

# ---------------------------------------------------------------------------
# Step 3 — Provider
# ---------------------------------------------------------------------------
if [[ $SKIP_PROVIDER -eq 1 ]]; then
    log_warn "Skipping provider installation (--skip-provider)."

# ── VirtualBox ───────────────────────────────────────────────────────────────
elif [[ "$PROVIDER" == "virtualbox" ]]; then

    log_section "VirtualBox"

    if command -v VBoxManage &>/dev/null; then
        log_warn "VirtualBox $(VBoxManage --version) already installed — skipping."
    else
        case "$DISTRO_FAMILY" in
            debian)
                VBX_BASE="https://download.virtualbox.org/virtualbox/debian"
                VBX_KEYRING="/usr/share/keyrings/oracle-vbox-keyring.gpg"
                log_info "Adding VirtualBox APT repo..."
                wget -qO - https://www.virtualbox.org/download/oracle_vbox_2016.asc \
                    | gpg --dearmor -o "$VBX_KEYRING"
                case "$DISTRO_ID" in
                    kali|parrot) _vbx_cn="bookworm" ;;
                    *)           _vbx_cn="${DISTRO_CODENAME:-noble}" ;;
                esac
                _vbx_cn=$(probe_apt_codename "$VBX_BASE" "$_vbx_cn" "noble")
                echo "deb [arch=amd64 signed-by=${VBX_KEYRING}] ${VBX_BASE} ${_vbx_cn} contrib" \
                    > /etc/apt/sources.list.d/virtualbox.list
                pkg_update
                _vbx_pkg=$(apt-cache search "^virtualbox-[0-9]" 2>/dev/null \
                    | awk '{print $1}' | sort -Vr | head -1)
                [[ -n "$_vbx_pkg" ]] || _vbx_pkg="virtualbox-7.0"
                pkg_install "$_vbx_pkg" "linux-headers-$(uname -r)"
                ;;
            redhat)
                log_info "Adding VirtualBox RPM repo..."
                if [[ "$DISTRO_ID" == "fedora" ]]; then
                    _vbx_repo="https://download.virtualbox.org/virtualbox/rpm/fedora/virtualbox.repo"
                else
                    _vbx_repo="https://download.virtualbox.org/virtualbox/rpm/el/virtualbox.repo"
                fi
                wget -qO /etc/yum.repos.d/virtualbox.repo "$_vbx_repo"
                pkg_update
                _vbx_pkg=$(${PKG_MANAGER} search VirtualBox 2>/dev/null \
                    | grep -oP 'VirtualBox-[0-9]+\.[0-9]+' | sort -Vr | head -1)
                [[ -n "$_vbx_pkg" ]] || _vbx_pkg="VirtualBox-7.0"
                pkg_install "$_vbx_pkg" "kernel-devel-$(uname -r)" 2>/dev/null || \
                    pkg_install "$_vbx_pkg" kernel-devel
                ;;
            arch)
                log_info "Installing VirtualBox from Arch repos..."
                # virtualbox-host-dkms works with any kernel (requires matching *-headers)
                _kernel_pkg=$(pacman -Qq linux linux-lts linux-zen linux-hardened 2>/dev/null \
                    | head -1 || echo linux)
                pkg_install virtualbox virtualbox-host-dkms "${_kernel_pkg}-headers"
                # Load VirtualBox modules for the current session
                modprobe vboxdrv     2>/dev/null || true
                modprobe vboxnetadp  2>/dev/null || true
                modprobe vboxnetflt  2>/dev/null || true
                ;;
            suse)
                log_info "Adding VirtualBox openSUSE repo..."
                zypper addrepo \
                    "https://download.virtualbox.org/virtualbox/rpm/opensuse/virtualbox.repo" \
                    virtualbox 2>/dev/null || true
                zypper --non-interactive refresh virtualbox 2>/dev/null || true
                _vbx_pkg=$(zypper search -s VirtualBox 2>/dev/null \
                    | grep -oP 'VirtualBox-[0-9]+\.[0-9]+' | sort -Vr | head -1)
                [[ -n "$_vbx_pkg" ]] || _vbx_pkg="VirtualBox-7.0"
                pkg_install "$_vbx_pkg"
                ;;
        esac

        # Rebuild DKMS modules
        if command -v dkms &>/dev/null; then
            log_info "Building VirtualBox kernel modules (DKMS)..."
            dkms autoinstall 2>/dev/null || true
        fi

        # Add user to vboxusers group
        if [[ "$REAL_USER" != "root" ]]; then
            usermod -aG vboxusers "$REAL_USER"
            log_info "Added '${REAL_USER}' to group vboxusers."
        fi

        log_ok "VirtualBox $(VBoxManage --version 2>/dev/null || echo '?') installed."

        [[ $IS_WSL -eq 1 ]] && \
            log_warn "WSL2: hypervisor also requires VirtualBox installed on the Windows host."
    fi

# ── libvirt / KVM ────────────────────────────────────────────────────────────
elif [[ "$PROVIDER" == "libvirt" ]]; then

    log_section "libvirt / KVM"

    if ! command -v virsh &>/dev/null || ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        log_info "Installing QEMU/KVM + libvirt stack..."
        case "$DISTRO_FAMILY" in
            debian)
                pkg_install qemu-kvm qemu-utils libvirt-daemon-system \
                            libvirt-clients bridge-utils virtinst
                ;;
            redhat)
                # "virtualization" group covers everything; fall back to explicit list
                dnf group install -y "virtualization" -q 2>/dev/null || \
                    pkg_install qemu-kvm libvirt libvirt-daemon-config-network \
                                virt-install bridge-utils
                ;;
            arch)
                pkg_install qemu-full libvirt virt-install dnsmasq \
                            bridge-utils edk2-ovmf openbsd-netcat
                ;;
            suse)
                pkg_install qemu-kvm libvirt libvirt-daemon virt-install \
                            bridge-utils
                ;;
        esac

        log_info "Enabling and starting libvirtd..."
        systemctl enable --now libvirtd
        log_ok "libvirt/KVM running."
    else
        log_warn "libvirt already active — skipping daemon install."
    fi

    # Add user to libvirt + kvm groups (only if not already a member)
    if [[ "$REAL_USER" != "root" ]]; then
        _to_add=()
        id -nG "$REAL_USER" | grep -qw libvirt || _to_add+=(libvirt)
        id -nG "$REAL_USER" | grep -qw kvm     || _to_add+=(kvm)
        if [[ ${#_to_add[@]} -gt 0 ]]; then
            usermod -aG "$(IFS=,; echo "${_to_add[*]}")" "$REAL_USER"
            log_info "Added '${REAL_USER}' to group(s): ${_to_add[*]}."
        fi
    fi

    log_section "vagrant-libvirt Plugin"

    _plugin_installed() {
        sudo -u "$REAL_USER" \
            env HOME="$REAL_HOME" PATH="/opt/vagrant/bin:/usr/bin:${PATH}" \
            vagrant plugin list 2>/dev/null | grep -q "vagrant-libvirt"
    }

    if _plugin_installed; then
        log_warn "vagrant-libvirt plugin already installed — skipping."
    else
        log_info "Installing native build dependencies..."
        case "$DISTRO_FAMILY" in
            debian)
                pkg_install libvirt-dev ruby-dev pkg-config \
                            libxml2-dev libxslt-dev zlib1g-dev
                ;;
            redhat)
                pkg_install libvirt-devel ruby-devel gcc make pkg-config \
                            libxml2-devel libxslt-devel zlib-devel
                ;;
            arch)
                pkg_install libvirt ruby pkgconf libxml2 libxslt
                ;;
            suse)
                pkg_install libvirt-devel ruby-devel gcc make pkg-config \
                            libxml2-devel libxslt-devel zlib-devel
                ;;
        esac

        log_info "Installing vagrant-libvirt plugin as '${REAL_USER}'..."
        if [[ "$REAL_USER" != "root" ]]; then
            sudo -u "$REAL_USER" \
                env HOME="$REAL_HOME" \
                    PATH="/opt/vagrant/bin:/usr/bin:${PATH}" \
                    VAGRANT_HOME="${REAL_HOME}/.vagrant.d" \
                vagrant plugin install vagrant-libvirt
        else
            vagrant plugin install vagrant-libvirt
        fi
        log_ok "vagrant-libvirt plugin installed."
    fi
fi

# ---------------------------------------------------------------------------
# Step 4 — Verification
# ---------------------------------------------------------------------------
log_section "Verification"
FAIL=0

_check() {
    local label="$1" ok="$2" detail="${3:-}"
    if [[ "$ok" == "1" ]]; then
        log_ok  "${label}${detail:+  (${detail})}"
    else
        log_error "${label}  ← NOT FOUND / NOT RUNNING"
        FAIL=1
    fi
}

_check "vagrant" \
    "$(vagrant --version &>/dev/null && echo 1 || echo 0)" \
    "$(vagrant --version 2>/dev/null | awk '{print $2}')"

if [[ $SKIP_PROVIDER -eq 0 ]]; then
    case "$PROVIDER" in
        virtualbox)
            _check "VBoxManage" \
                "$(command -v VBoxManage &>/dev/null && echo 1 || echo 0)" \
                "$(VBoxManage --version 2>/dev/null || true)"
            ;;
        libvirt)
            _check "libvirtd" \
                "$(systemctl is-active --quiet libvirtd 2>/dev/null && echo 1 || echo 0)" \
                "running"
            _check "virsh" \
                "$(command -v virsh &>/dev/null && echo 1 || echo 0)"
            if [[ "$REAL_USER" != "root" ]]; then
                _pok=0
                sudo -u "$REAL_USER" \
                    env HOME="$REAL_HOME" PATH="/opt/vagrant/bin:/usr/bin:${PATH}" \
                    vagrant plugin list 2>/dev/null \
                    | grep -q "vagrant-libvirt" && _pok=1
                _check "vagrant-libvirt plugin" "$_pok"
            fi
            ;;
    esac
fi

echo "" >&2
if [[ $FAIL -eq 0 ]]; then
    log_ok "All components installed and verified."
    if [[ "${PROVIDER:-}" == "libvirt" && "$REAL_USER" != "root" ]]; then
        echo "" >&2
        log_info "Activate group membership without re-login:  newgrp libvirt"
    fi
else
    die "One or more components failed — check the output above."
fi
