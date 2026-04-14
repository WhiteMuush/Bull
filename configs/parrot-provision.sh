#!/usr/bin/env bash
# =============================================================================
# BULL - Parrot Security OS Provisioning Script
# Runs inside the VM as root during vagrant provision
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[BULL] Starting Parrot Security provisioning..."

# ---------------------------------------------------------------------------
# Network readiness — wait up to 30 s for DNS to come up before apt calls
# ---------------------------------------------------------------------------
_wait_for_network() {
    local retries=6
    local delay=5
    local i
    for (( i=1; i<=retries; i++ )); do
        if getent hosts parrotsec.org &>/dev/null; then
            return 0
        fi
        echo "[BULL] Waiting for network... (attempt ${i}/${retries})"
        sleep "${delay}"
    done
    return 1
}

# Helper: run apt operations only when network is available.
# If the network never comes up, skip with a warning instead of aborting.
_apt_with_net() {
    if _wait_for_network; then
        apt-get "$@"
    else
        echo "[BULL] WARNING: No network — skipping apt operation (packages may already be installed)." >&2
        return 0
    fi
}

# System Update — runs in background (non-blocking)
# Set BULL_SKIP_UPGRADE=1 to skip entirely, or leave unset to run full-upgrade.
if [[ "${BULL_SKIP_UPGRADE:-}" != "1" ]]; then
    echo "[BULL] Updating system in background..."
    nohup sudo bash -c 'apt-get update -qq; apt-get full-upgrade -y -qq' > /dev/null 2>&1 &
else
    echo "[BULL] Skipping upgrade (BULL_SKIP_UPGRADE=1)"
    _apt_with_net update -qq
fi

# ---------------------------------------------------------------------------
# Packages (installs in background for non-blocking provisioning)
# ---------------------------------------------------------------------------
echo "[BULL] Installing packages in background..."
nohup sudo bash -c 'apt-get install -y -qq \
    git curl wget vim tmux htop net-tools dnsutils jq tree unzip \
    nmap gobuster sqlmap nikto dirb enum4linux smbclient \
    openvpn wireguard iptables-persistent' > /dev/null 2>&1 &

# ---------------------------------------------------------------------------
# User Configuration (credentials injected by BULL via Vagrantfile env)
# ---------------------------------------------------------------------------
BULL_VM_USER="${BULL_VM_USER:-}"
BULL_VM_PASS="${BULL_VM_PASS:-}"
BULL_VM_KEYBOARD="${BULL_VM_KEYBOARD:-us}"

if [[ -n "${BULL_VM_USER}" ]] && [[ -n "${BULL_VM_PASS}" ]]; then
    echo "[BULL] Configuring user: ${BULL_VM_USER}..."

    # Create the user if it doesn't exist
    if ! id "${BULL_VM_USER}" &>/dev/null; then
        useradd -m -s /bin/bash "${BULL_VM_USER}"
        echo "[BULL]   Created user '${BULL_VM_USER}'"
    fi

    # Ensure the user is in the sudo group
    usermod -aG sudo "${BULL_VM_USER}" 2>/dev/null || true

    # Set password with plain-text chpasswd
    if echo "${BULL_VM_USER}:${BULL_VM_PASS}" | chpasswd; then
        echo "[BULL]   Password set for '${BULL_VM_USER}'"
    else
        echo "[BULL]   ERROR: chpasswd failed for '${BULL_VM_USER}'" >&2
        exit 1
    fi

    # Wipe password from environment immediately after use
    unset BULL_VM_PASS

    # ---------------------------------------------------------------------------
    # Encrypt /home with ecryptfs
    # ---------------------------------------------------------------------------
    echo "[BULL] Setting up /home encryption..."
    apt-get install -y -qq ecryptfs-utils > /dev/null 2>&1 || true

    user_home="/home/${BULL_VM_USER}"
    if [[ -d "${user_home}" ]] && [[ ! -d "${user_home}.ecryptfs" ]]; then
        encrypt_pass=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
        
        mkdir -p /root/.ecryptfs
        printf "%s\n" "${encrypt_pass}" > /root/.ecryptfs/passphrase
        chmod 600 /root/.ecryptfs/passphrase
        
        mkdir -p "${user_home}/.ecryptfs"
        printf "%s\n" "${encrypt_pass}" | ecryptfs-wrap-passphrase \
            "${user_home}/.ecryptfs/wrapped-passphrase" "${user_home}/.ecryptfs/Passphrase" 2>/dev/null || true
        
        echo "${encrypt_pass}" | ecryptfs-add-passphrase - 2>/dev/null || true
        echo "[BULL]   /home encryption enabled"
    fi

    # Copy Vagrant's SSH authorized key to the custom user so 'bull connect' works.
    user_home=$(getent passwd "${BULL_VM_USER}" | cut -d: -f6)
    if [[ -f /home/vagrant/.ssh/authorized_keys ]] && [[ -n "${user_home}" ]]; then
        install -d -m 700 -o "${BULL_VM_USER}" -g "${BULL_VM_USER}" "${user_home}/.ssh"
        install -m 600 -o "${BULL_VM_USER}" -g "${BULL_VM_USER}" \
            /home/vagrant/.ssh/authorized_keys "${user_home}/.ssh/authorized_keys"
        echo "[BULL]   Vagrant SSH key copied to '${BULL_VM_USER}'"
    fi

    # Always lock the default 'user' account
    if id "user" &>/dev/null; then
        passwd -l user > /dev/null 2>&1
        echo "[BULL]   Default 'user' account locked"
    fi

    # Grant passwordless sudo for the BULL user (pentest convenience)
    echo "${BULL_VM_USER} ALL=(ALL) NOPASSWD:ALL" \
        > "/etc/sudoers.d/bull-${BULL_VM_USER}"
    chmod 440 "/etc/sudoers.d/bull-${BULL_VM_USER}"
else
    echo "[BULL] No custom credentials provided — default Parrot user unchanged."
fi

# ---------------------------------------------------------------------------
# Directory Structure
# ---------------------------------------------------------------------------
echo "[BULL] Creating working directories..."
mkdir -p /opt/pentest/{scans,loot,notes,exploits}
mkdir -p /opt/toolkits
mkdir -p /root/.ssh

# If a custom user was created, grant them ownership of /opt/toolkits
if [[ -n "${BULL_VM_USER}" ]]; then
    chown -R "${BULL_VM_USER}:${BULL_VM_USER}" /opt/toolkits
fi

# ---------------------------------------------------------------------------
# SSH Configuration
# ---------------------------------------------------------------------------
echo "[BULL] Configuring SSH..."
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# ---------------------------------------------------------------------------
# LightDM Auto-login
# Skip the greeter entirely so MATE loads directly with the correct keyboard
# layout and resolution from first boot.
# ---------------------------------------------------------------------------
if [[ -n "${BULL_VM_USER}" ]]; then
    echo "[BULL] Configuring LightDM auto-login for '${BULL_VM_USER}'..."
    mkdir -p /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/10-bull-autologin.conf << AUTOLOGEOF
[Seat:*]
autologin-user=${BULL_VM_USER}
autologin-user-timeout=0
AUTOLOGEOF
fi

# ---------------------------------------------------------------------------
# System Configuration
# ---------------------------------------------------------------------------
echo "[BULL] Configuring system..."

# Set timezone to UTC
timedatectl set-timezone UTC 2>/dev/null || ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# Keyboard layout — configure at every level of the stack so the chosen
# layout survives MATE first-login defaults, dpkg upgrades, and session resets.
echo "[BULL] Configuring keyboard layout: ${BULL_VM_KEYBOARD}..."

# ---- /etc/default/keyboard (written directly — most reliable) ----
cat > /etc/default/keyboard << KBDEFEOF
XKBMODEL="pc105"
XKBLAYOUT="${BULL_VM_KEYBOARD}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBDEFEOF

# ---- debconf preseed ----
debconf-set-selections << DBEOF
keyboard-configuration keyboard-configuration/layoutcode string ${BULL_VM_KEYBOARD}
keyboard-configuration keyboard-configuration/modelcode string pc105
keyboard-configuration keyboard-configuration/variantcode string
keyboard-configuration keyboard-configuration/optionscode string
keyboard-configuration keyboard-configuration/compose select No compose key
keyboard-configuration keyboard-configuration/ctrl_alt_bksp boolean false
keyboard-configuration keyboard-configuration/toggle select No toggling
keyboard-configuration keyboard-configuration/switch select No temporary switch
keyboard-configuration keyboard-configuration/altgr select The default for the keyboard layout
keyboard-configuration keyboard-configuration/unsupported_layout boolean true
DBEOF

DEBIAN_FRONTEND=noninteractive dpkg-reconfigure keyboard-configuration 2>/dev/null || true
setupcon --force 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true

# ---- X11 xorg.conf.d ----
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf << KBEOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${BULL_VM_KEYBOARD}"
    Option "XkbModel"  "pc105"
EndSection
KBEOF

# ---- /etc/xprofile ----
# Sourced by LightDM for every X session, BEFORE the window manager starts.
grep -qF 'bull-keyboard' /etc/xprofile 2>/dev/null \
    || cat >> /etc/xprofile << XPEOF

# BULL: force keyboard layout before any WM/DE starts
if command -v setxkbmap >/dev/null 2>&1; then
    setxkbmap -layout ${BULL_VM_KEYBOARD} -model pc105 2>/dev/null || true
fi
XPEOF

# ---- MATE dconf keyboard settings ----
# Parrot uses MATE desktop — configure keyboard via dconf/gsettings.
_write_mate_kb() {
    local target_user="$1"
    local home_dir
    home_dir=$(getent passwd "${target_user}" | cut -d: -f6 2>/dev/null) || return 0
    [[ -d "${home_dir}" ]] || return 0

    local dconf_dir="${home_dir}/.config/dconf"
    mkdir -p "${dconf_dir}"

    sudo -u "${target_user}" dbus-launch gsettings set org.mate.peripherals-keyboard-xkb.kbd layouts "['${BULL_VM_KEYBOARD}']" 2>/dev/null || true
    sudo -u "${target_user}" dbus-launch gsettings set org.mate.peripherals-keyboard-xkb.kbd model "'pc105'" 2>/dev/null || true

    chown -R "${target_user}:${target_user}" "${dconf_dir}" 2>/dev/null || true
}

if [[ -n "${BULL_VM_USER}" ]]; then
    _write_mate_kb "${BULL_VM_USER}"
fi

# ---- System-wide XDG autostart with setxkbmap ----
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/bull-keyboard.desktop << KBDESKTOP
[Desktop Entry]
Type=Application
Name=BULL Keyboard Layout
Comment=Force keyboard layout after desktop loads
Exec=bash -c 'sleep 5 && DISPLAY=:0 setxkbmap -layout ${BULL_VM_KEYBOARD} -model pc105'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-MATE-Autostart-enabled=true
KBDESKTOP

# ---- localectl ----
localectl set-x11-keymap "${BULL_VM_KEYBOARD}" pc105 "" "" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Display: Guest Additions (VirtualBox) or spice-vdagent (libvirt/KVM)
# ---------------------------------------------------------------------------
BULL_VM_RESOLUTION="${BULL_VM_RESOLUTION:-1920x1080}"
echo "[BULL] Configuring display (target resolution: ${BULL_VM_RESOLUTION})..."

_is_virtualbox() { lsmod 2>/dev/null | grep -q vboxguest || \
                   grep -qi virtualbox /sys/devices/virtual/dmi/id/product_name 2>/dev/null; }
_is_kvm()        { grep -qi kvm /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || \
                   grep -q 'QEMU' /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null; }

if _is_virtualbox; then
    echo "[BULL]   Hypervisor: VirtualBox — installing Guest Additions..."
    nohup sudo bash -c 'apt-get install -y -qq virtualbox-guest-x11 virtualbox-guest-utils' > /dev/null 2>&1 &

    mkdir -p /etc/xdg/autostart
    cat > /etc/xdg/autostart/vboxclient.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=VirtualBox Guest Additions
Exec=/usr/bin/VBoxClient-all
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-MATE-Autostart-enabled=true
EOF

elif _is_kvm; then
    echo "[BULL]   Hypervisor: KVM/libvirt — installing spice-vdagent..."
    nohup sudo bash -c 'apt-get install -y -qq spice-vdagent xserver-xorg-video-qxl xdotool' > /dev/null 2>&1 &
    systemctl enable spice-vdagentd 2>/dev/null || true
    systemctl start spice-vdagentd 2>/dev/null || true

    mkdir -p /etc/xdg/autostart
    cat > /etc/xdg/autostart/bull-spice-cursor.desktop << 'SPICEEOF'
[Desktop Entry]
Type=Application
Name=BULL SPICE Cursor Fix
Comment=Start spice-vdagent and sync cursor to eliminate double-cursor offset
Exec=bash -c 'spice-vdagent 2>/dev/null; sleep 2; xdotool mousemove_relative -- 1 0; xdotool mousemove_relative -- -1 0'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-MATE-Autostart-enabled=true
X-GNOME-Autostart-Phase=Initialization
SPICEEOF
fi

XRES_W="${BULL_VM_RESOLUTION%%x*}"
XRES_H="${BULL_VM_RESOLUTION##*x}"

# ---------------------------------------------------------------------------
# Xorg startup resolution
# ---------------------------------------------------------------------------
mkdir -p /etc/X11/xorg.conf.d

MODE_MODELINE=$(cvt "${XRES_W}" "${XRES_H}" 60 2>/dev/null | grep "^Modeline" | head -1)

cat > /etc/X11/xorg.conf.d/10-bull-display.conf << XORGEOF
Section "Monitor"
    Identifier  "Virtual-1"
    ModelName   "BULL Preferred"
    ${MODE_MODELINE}
    Option      "PreferredMode" "${XRES_W}x${XRES_H}"
EndSection

Section "Screen"
    Identifier "Screen0"
    DefaultDepth 24
    SubSection "Display"
        Depth    24
        Modes    "${XRES_W}x${XRES_H}"
    EndSubSection
EndSection
XORGEOF

# ---------------------------------------------------------------------------
# LightDM resolution — force at the login screen
# ---------------------------------------------------------------------------
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /usr/local/bin/bull-lightdm-xrandr.sh << 'SCRIPTEOF'
#!/bin/bash
export DISPLAY=:0
xrandr --output Virtual-1 --mode "${1}x${2}" 2>/dev/null || true
SCRIPTEOF
chmod +x /usr/local/bin/bull-lightdm-xrandr.sh
cat > /etc/lightdm/lightdm.conf.d/20-bull-display.conf << LIGHTDMEOF
[Seat:*]
display-setup-script=/usr/local/bin/bull-lightdm-xrandr.sh ${XRES_W} ${XRES_H}
session-setup-script=/usr/local/bin/bull-lightdm-xrandr.sh ${XRES_W} ${XRES_H}
LIGHTDMEOF

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/bull-display.desktop << AUTOSTARTEOF
[Desktop Entry]
Type=Application
Name=BULL Display Resolution
Exec=/usr/local/bin/bull-display.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-MATE-Autostart-enabled=true
AUTOSTARTEOF

echo "[BULL] Xorg resolution set to ${BULL_VM_RESOLUTION}"

# ---------------------------------------------------------------------------
# GRUB: force video resolution at boot
# ---------------------------------------------------------------------------
if [ -f /etc/default/grub ]; then
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 video=Virtual-1:'"${XRES_W}"'x'"${XRES_H}"'e"/' /etc/default/grub 2>/dev/null || true
    sed -i 's/video=[^ "]*//g' /etc/default/grub
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="video=Virtual-1:'"${XRES_W}"'x'"${XRES_H}"'e /' /etc/default/grub 2>/dev/null || true
    update-grub 2>/dev/null || true
    echo "[BULL] GRUB video resolution set to ${BULL_VM_RESOLUTION}"
fi

# ---------------------------------------------------------------------------
# bull-set-resolution.sh — called from the HOST via: vagrant ssh -c "sudo ..."
# Parrot uses MATE — detect mate-session owner for XAUTHORITY.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/bull-set-resolution.sh << 'SETRESEOF'
#!/bin/bash
W="${1:-1920}"
H="${2:-1080}"
# Find the user owning the MATE session (the LightDM autologin user)
XUSER=$(ps -eo user,comm --no-headers | awk '/mate-session/{print $1; exit}')
# Fallback: try any X session owner
[ -z "${XUSER}" ] && XUSER=$(ps -eo user,comm --no-headers | awk '/xfce4-session|gnome-session/{print $1; exit}')
[ -z "${XUSER}" ] && exit 0
export DISPLAY=:0
export XAUTHORITY="/home/${XUSER}/.Xauthority"
[ -f "${XAUTHORITY}" ] || exit 0
OUT=$(xrandr 2>/dev/null | awk '/\bconnected\b/{print $1; exit}')
[ -z "${OUT}" ] && exit 0
xrandr --output "${OUT}" --mode "${W}x${H}" 2>/dev/null && exit 0
# Mode not listed: create via cvt
if command -v cvt >/dev/null 2>&1; then
    MODELINE=$(cvt "${W}" "${H}" 60 2>/dev/null | grep Modeline)
    MODENAME=$(echo "${MODELINE}" | awk '{gsub(/"/, "", $2); print $2}')
    MODEPARAMS=$(echo "${MODELINE}" | awk '{for(i=3;i<=NF;i++) printf "%s ",$i}')
    if [ -n "${MODENAME}" ]; then
        xrandr --newmode "${MODENAME}" ${MODEPARAMS} 2>/dev/null || true
        xrandr --addmode "${OUT}" "${MODENAME}" 2>/dev/null || true
        xrandr --output "${OUT}" --mode "${MODENAME}" 2>/dev/null && exit 0
    fi
fi
xrandr --fb "${W}x${H}" 2>/dev/null || true
SETRESEOF
chmod +x /usr/local/bin/bull-set-resolution.sh

cat > /usr/local/bin/bull-display.sh << DISPEOF
#!/bin/bash
# BULL: apply and persist target resolution at session start (Parrot/MATE).
#
# Resolution baked in at provision time:
XRES_W="${XRES_W}"
XRES_H="${XRES_H}"

command -v xrandr >/dev/null 2>&1 || exit 0
[ -n "\${DISPLAY:-}" ] || export DISPLAY=:0
xrandr --version >/dev/null 2>&1 || exit 0

# ---------- helper: create and apply a mode for one output ----------
_apply_mode() {
    local out="\$1" w="\$2" h="\$3"

    xrandr --output "\${out}" --mode "\${w}x\${h}" 2>/dev/null && return 0

    command -v cvt >/dev/null 2>&1 || return 1
    local cvt_out modename modeparams
    cvt_out=\$(cvt "\${w}" "\${h}" 60 2>/dev/null)
    modename=\$(  printf '%s' "\${cvt_out}" | awk '/Modeline/{ gsub(/"/, "", \$2); print \$2 }')
    modeparams=\$(printf '%s' "\${cvt_out}" | awk '/Modeline/{ for(i=3;i<=NF;i++) printf "%s ",\$i }')
    [ -n "\${modename}" ] && [ -n "\${modeparams}" ] || return 1

    # shellcheck disable=SC2086
    xrandr --newmode "\${modename}" \${modeparams} 2>/dev/null || true
    xrandr --addmode "\${out}" "\${modename}"       2>/dev/null || true
    xrandr --output  "\${out}" --mode "\${modename}" 2>/dev/null && return 0
    return 1
}

# ---------- main ----------
_applied=0
while IFS= read -r OUTPUT; do
    [ -n "\${OUTPUT}" ] || continue
    if _apply_mode "\${OUTPUT}" "\${XRES_W}" "\${XRES_H}"; then
        _applied=1
    else
        xrandr --output "\${OUTPUT}" --auto 2>/dev/null || true
    fi
done < <(xrandr 2>/dev/null | awk '/\bconnected\b/{ print \$1 }')

if [ "\${_applied}" -eq 0 ]; then
    xrandr --fb "\${XRES_W}x\${XRES_H}" 2>/dev/null || true
fi
DISPEOF
chmod +x /usr/local/bin/bull-display.sh
ln -sf /usr/local/bin/bull-display.sh /etc/profile.d/bull-display.sh

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/bull-display.desktop << 'DSKEOF'
[Desktop Entry]
Type=Application
Name=BULL Display Setup
Exec=bash -c 'export DISPLAY=:0; sleep 3; /usr/local/bin/bull-display.sh; sleep 5; /usr/local/bin/bull-display.sh'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
X-MATE-Autostart-enabled=true
DSKEOF

# Increase file descriptor limits
cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 65536
* hard nofile 65536
EOF

# Optimize network for scanning
cat >> /etc/sysctl.conf << 'EOF'
# BULL: Optimized for pentest
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
EOF
sysctl -p > /dev/null 2>&1

# ---------------------------------------------------------------------------
# Custom Toolkits (if TOOLKIT_URLS is set)
# ---------------------------------------------------------------------------
if [[ -n "${TOOLKIT_URLS:-}" ]]; then
    echo "[BULL] Installing custom toolkits..."
    for url in ${TOOLKIT_URLS}; do
        repo_name=$(basename "${url}" .git)
        echo "[BULL]   Cloning ${repo_name}..."
        if [[ -n "${BULL_VM_USER}" ]]; then
            sudo -u "${BULL_VM_USER}" git clone "${url}" "/opt/toolkits/${repo_name}" 2>/dev/null || {
                echo "[BULL]   WARNING: Failed to clone ${url}"
            }
        else
            git clone "${url}" "/opt/toolkits/${repo_name}" 2>/dev/null || {
                echo "[BULL]   WARNING: Failed to clone ${url}"
            }
        fi
    done
fi

# ---------------------------------------------------------------------------
# Extra Packages (if EXTRA_PACKAGES is set)
# ---------------------------------------------------------------------------
if [[ -n "${EXTRA_PACKAGES:-}" ]]; then
    echo "[BULL] Installing extra packages: ${EXTRA_PACKAGES}"
    # shellcheck disable=SC2086
    apt-get install -y -qq ${EXTRA_PACKAGES} > /dev/null 2>&1
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
echo "[BULL] Cleaning up..."
# Wait for background apt processes to finish
sleep 5
apt-get autoremove -y -qq > /dev/null 2>&1 || true
apt-get clean -qq > /dev/null 2>&1 || true

echo "[BULL] Parrot Security provisioning complete!"
echo "[BULL] Working directory: /opt/pentest"
echo "[BULL] Toolkits directory: /opt/toolkits"
