#!/usr/bin/env bash
# =============================================================================
# BULL - Automated Pentest Environment Provisioning Toolkit
# Version: 0.1.0
#
# Creates, manages, and configures pentest VMs (Kali/Parrot) via Vagrant
# with VPN kill switch, snapshot management, and inventory tracking.
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# Require root
if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Error: BULL must be run as root (sudo)."
    echo "Usage: sudo ./bull.sh <command>"
    exit 1
fi

# Resolve script directory (works with symlinks)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Source libraries (order matters: core first)
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/inventory.sh"
source "${SCRIPT_DIR}/lib/vagrant.sh"
source "${SCRIPT_DIR}/lib/vpn.sh"
source "${SCRIPT_DIR}/lib/toolkits.sh"

# =============================================================================
# ASCII ART BANNER (left side)
# =============================================================================
ASCII_ART=$(cat <<'ASCII'
⠀⠀⠀⠀⠀⠀⠀⢀⣠⣤⣴⣶⣶⡦⠤⠤⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢰⣿⣛⣉⣉⣉⣩⣭⣥⣤⣤⣤⡤⢀⡀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠈⠀⠉⠉⠁⠀⠀⠀⠀⠀⠀⠈⠉⢢⠆⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⠤⠤⠤⠄⢀⣀⣀⣀⡘⡄⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⡠⠐⠁⠀⠀⠀⠀⡀⠀⠀⢴⣶⣧⡀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⡠⠊⠀⠀⠀⠀⠀⠀⠀⠹⡄⠀⠨⣿⣿⣷⡄⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⡸⠁⠀⠀⠀⠀⠀⠀⢰⠀⠀⠙⣤⣶⣿⣿⣿⣿⡄⠀⠀⠀⠀
⠀⠀⠀⠀⠀⡐⠁⠀⠀⠀⠀⠀⡠⣴⠾⣷⡆⠀⢿⣿⣿⣿⣿⣿⣧⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠇⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣧⣴⡄⢻⣿⣿⣿⣿⣿⠀⠀⠀⠀
⠀⠀⠀⠀⢸⠀⠀⢠⠀⠀⠀⠀⠀⠀⠈⠉⢉⠿⢿⣆⢿⣿⣿⣿⣿⡀⠀⠀⠀
⠀⠀⠀⠀⠎⠀⠀⣿⡄⠀⠀⠀⠀⠀⠀⠘⠋⢛⣟⠛⠃⠙⠻⠿⣿⡇⠀⠀⠀
⠀⠀⠀⢸⡄⠀⠀⡘⠋⠉⡀⢠⣾⡰⢶⣶⡖⠁⣤⣳⣿⣶⢶⣶⡌⠳⠤⣀⣀
⠀⠀⠀⢸⢠⠀⢀⣿⣿⣶⣿⣿⣿⠇⠀⠁⣷⣄⣈⣙⣛⣿⣿⣿⡲⡒⠒⠒⠊
⠀⠀⠀⠀⣿⣾⣿⣿⣿⣿⣿⣿⡟⠀⠀⣰⣿⣿⣿⣿⣿⣿⣿⣟⣿⣶⡄⠀⠀
⠀⠀⠀⢠⣿⣿⣿⣿⣿⣿⣿⣿⣇⠀⠐⣿⠿⣿⣿⣿⣿⡿⠋⠀⠙⣿⡇⠀⠀
⠀⠀⠀⣿⣿⡿⠁⠸⣿⣿⣿⣿⣿⣦⠸⠋⢸⣿⣿⣿⡿⠁⠀⠀⠀⢸⣷⡀⠀
⠀⠀⠀⣻⣿⡇⠀⠀⠀⣹⣿⡿⢻⣿⢠⡀⠸⣿⣿⣿⣧⠀⠀⠀⠀⠘⣿⣧⠀
⠀⠀⢠⠉⣿⠇⠀⠀⢰⠋⣿⣰⣁⡟⠀⠁⢼⣿⡿⠿⠏⠀⠀⠀⠀⠀⠋⠟⠀
⠀⠀⢰⣿⠋⠀⠀⠀⢀⣿⡏⠛⠐⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⣾⡇⠀⠀⠀⢀⠎⢹⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠜⢹⡇⠀⠀⠀⠾⣶⡾⠃⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠮⣿⠿⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
ASCII
)
readonly ASCII_ART

# OSC 8 hyperlink for creator
readonly CREATOR_LINK=$'\e]8;;https://github.com/WhiteMuush\aMelvin PETIT\e]8;;\a'

# =============================================================================
# MENU GENERATION
# Builds the right-hand column displayed next to the ASCII art.
# Each line MUST be a separate array element for side-by-side alignment.
# =============================================================================
generate_menu() {
    local -a menu_lines=(
        ""
        "${BRIGHT_RED}${BOLD}__________  ____ ___ .____     .____      ${RESET}"
        "${BRIGHT_RED}${BOLD}\\______   \\|    |   \\|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |  _/|    |   /|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |   \\|    |  / |    |___ |    |___  ${RESET}"
        "${BRIGHT_RED}${BOLD} |______  /|______/  |_______ \\|_______ \\ ${RESET}"
        "${BRIGHT_RED}${BOLD}        \\/                   \\/        \\/ ${RESET}"
        ""
        "${BRIGHT_MAGENTA}  Creator: ${CREATOR_LINK}            ${RESET}${RED}v${BULL_VERSION}${RESET}"
        "${RESET}"
        "  ${CYAN}Manage your Pentest VMs like you always wanted${RESET} 🔥"
        "${BRIGHT_CYAN}  ┌───────────────────────────────────────────────┐${RESET}"
        "${BRIGHT_CYAN}  │                                               │"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[1]${RESET}  Create VM      ${BRIGHT_RED}[8]${RESET}  Snapshot            ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[2]${RESET}  List VMs       ${BRIGHT_RED}[9]${RESET}  Restore             ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[3]${RESET}  Start VM       ${BRIGHT_RED}[10]${RESET} VPN Config          ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[4]${RESET}  Stop VM        ${BRIGHT_RED}[11]${RESET} Tools Manager       ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[5]${RESET}  Destroy VM     ${BRIGHT_RED}[12]${RESET} Status              ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[6]${RESET}  View VM (GUI)  ${BRIGHT_RED}[13]${RESET} Sync Inventory      ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[7]${RESET}  Connect (SSH)  ${BRIGHT_RED}[14]${RESET} Init / Check Deps   ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  │                                               │"
        "${BRIGHT_CYAN}  ├───────────────────────────────────────────────┘${RESET}"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[0]${RESET}  Exit         ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  └────────────────────┘${RESET}"
        ""
    )

    printf '%s\n' "${menu_lines[@]}"
}

# =============================================================================
# TITLE SCREEN (centered splash)
# =============================================================================
display_title_middle_screen() {
    local cols rows
    cols=$(tput cols 2>/dev/null || echo 80)
    rows=$(tput lines 2>/dev/null || echo 24)

    local -a lines=(
        "${BOLD}${BRIGHT_RED}__________  ____ ___ .____     .____      ${RESET}"
        "${BOLD}${BRIGHT_RED}\\______   \\|    |   \\|    |    |    |     ${RESET}"
        "${BOLD}${BRIGHT_RED} |    |  _/|    |   /|    |    |    |     ${RESET}"
        "${BOLD}${BRIGHT_RED} |    |   \\|    |  / |    |___ |    |___  ${RESET}"
        "${BOLD}${BRIGHT_RED} |______  /|______/  |_______ \\|_______ \\ ${RESET}"
        "${BOLD}${BRIGHT_RED}        \\/                   \\/        \\/ ${RESET}"
        ""
        "${CYAN}Automated Pentest Environment Provisioning${RESET}"
        ""
        "${CYAN}BY MELVIN PETIT${RESET}"
    )
    local h=${#lines[@]}

    # Strip ANSI escapes to measure visible width
    strip_esc() {
        sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g; s/\x1B\][^\a]*\a//g'
    }

    local max_w=0 raw visible_len line
    for line in "${lines[@]}"; do
        raw=$(printf "%s" "$line" | strip_esc)
        visible_len=${#raw}
        (( visible_len > max_w )) && max_w=$visible_len
    done

    local top=$(( (rows - h) / 2 ))
    (( top < 0 )) && top=0
    local left=$(( (cols - max_w) / 2 ))
    (( left < 0 )) && left=0

    printf "\033c"
    for ((i=0; i<top; i++)); do printf "\n"; done
    for line in "${lines[@]}"; do
        printf "%*s%s\n" "$left" "" "$line"
    done
}

# =============================================================================
# DISPLAY ASCII ART + MENU SIDE-BY-SIDE
# Renders to stdout. Callers capture it to measure height before printing.
# =============================================================================
display_banner_with_menu() {
    local -a ascii_lines menu_lines

    IFS=$'\n' read -r -d '' -a ascii_lines <<< "${ASCII_ART}" || true
    IFS=$'\n' read -r -d '' -a menu_lines <<< "$(generate_menu)" || true

    local ascii_count=${#ascii_lines[@]}
    local menu_count=${#menu_lines[@]}
    local max_lines=$(( ascii_count > menu_count ? ascii_count : menu_count ))

    local max_ascii_width=0
    local _raw _w
    for _raw in "${ascii_lines[@]}"; do
        _raw=$(printf "%s" "${_raw}" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        _w=${#_raw}
        (( _w > max_ascii_width )) && max_ascii_width=${_w}
    done

    local spacing="  "
    local i
    for (( i=0; i<max_lines; i++ )); do
        local ascii_line="${ascii_lines[i]:-}"
        local menu_line="${menu_lines[i]:-}"
        local raw_line
        raw_line=$(printf "%s" "${ascii_line}" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local pad=$(( max_ascii_width - ${#raw_line} ))
        (( pad < 0 )) && pad=0
        printf "  %s%s%*s%s%s\n" \
            "${BRIGHT_CYAN}" "${ascii_line}${RESET}" \
            "${pad}" "" \
            "${spacing}" \
            "${menu_line}"
    done
}

# =============================================================================
# DISPLAY STEP — ASCII art + step info side-by-side
# Usage: _display_step "Step Title" "Step description"
# =============================================================================
_display_step() {
    local title="$1"
    local description="${2:-}"

    local -a ascii_lines step_lines
    IFS=$'\n' read -r -d '' -a ascii_lines <<< "${ASCII_ART}" || true

    local -a step_lines=(
        ""
        ""
        ""
        ""
        ""
        "${BRIGHT_RED}${BOLD}__________  ____ ___ .____     .____      ${RESET}"
        "${BRIGHT_RED}${BOLD}\\______   \\|    |   \\|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |  _/|    |   /|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |   \\|    |  / |    |___ |    |___  ${RESET}"
        "${BRIGHT_RED}${BOLD} |______  /|______/  |_______ \\|_______ \\ ${RESET}"
        "${BRIGHT_RED}${BOLD}        \\/                   \\/        \\/ ${RESET}"
        ""
        "${BRIGHT_MAGENTA}  Creator: ${CREATOR_LINK}            ${RESET}${RED}v${BULL_VERSION}${RESET}"
        ""
        "  ${CYAN}${title}${RESET}"
    )

    if [[ -n "${description}" ]]; then
        step_lines+=("  ${DIM}${description}${RESET}")
    fi

    step_lines+=("")
    step_lines+=("")

    local ascii_count=${#ascii_lines[@]}
    local step_count=${#step_lines[@]}
    local max_lines=$(( ascii_count > step_count ? ascii_count : step_count ))

    local max_ascii_width=0
    for line in "${ascii_lines[@]}"; do
        local raw
        raw=$(printf "%s" "${line}" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local w=${#raw}
        (( w > max_ascii_width )) && max_ascii_width=$w
    done

    local spacing="  "
    for (( i=0; i<max_lines; i++ )); do
        local ascii_line="${ascii_lines[i]:-}"
        local step_line="${step_lines[i]:-}"
        local raw_line
        raw_line=$(printf "%s" "${ascii_line}" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local pad=$(( max_ascii_width - ${#raw_line} ))
        (( pad < 0 )) && pad=0
        printf "  %s%s%*s%s%s\n" \
            "${BRIGHT_CYAN}" "${ascii_line}${RESET}" \
            "${pad}" "" \
            "${spacing}" \
            "${step_line}"
    done
}

# =============================================================================
# VM SELECTOR — renders in the same ASCII art + box layout as the main menu
# =============================================================================

# Build menu-box lines listing VMs (mirrors generate_menu style).
# Inner box width: 54 visible chars.
_generate_vm_select_lines() {
    local title="$1"
    shift
    local -a names=("$@")

    # Box inner width = 54 chars (matches main menu)
    local BOX_W=54

    local -a lines=(
        ""
        "${BRIGHT_RED}${BOLD}__________  ____ ___ .____     .____      ${RESET}"
        "${BRIGHT_RED}${BOLD}\\______   \\|    |   \\|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |  _/|    |   /|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |   \\|    |  / |    |___ |    |___  ${RESET}"
        "${BRIGHT_RED}${BOLD} |______  /|______/  |_______ \\|_______ \\ ${RESET}"
        "${BRIGHT_RED}${BOLD}        \\/                   \\/        \\/ ${RESET}"
        ""
        "${BRIGHT_MAGENTA}  Creator: ${CREATOR_LINK}            ${RESET}${RED}v${BULL_VERSION}${RESET}"
        "${RESET}"
        "  ${CYAN}${title}${RESET}"
        "${BRIGHT_CYAN}  ┌──────────────────────────────────────────────────────┐${RESET}"
        "${BRIGHT_CYAN}  │                                                      │"
    )

    local count="${#names[@]}"
    # names array is interleaved: name0 status0 name1 status1 ...
    local vm_count=$(( count / 2 ))

    local i
    for ((i = 0; i < vm_count; i++)); do
        local vm_name="${names[$((i * 2))]}"
        local vm_status="${names[$((i * 2 + 1))]}"
        local idx=$(( i + 1 ))
        local idx_str="[${idx}]"

        # Colored status
        local sc
        case "${vm_status}" in
            running)            sc="${GREEN}${vm_status}${RESET}" ;;
            stopped|poweroff)   sc="${RED}${vm_status}${RESET}" ;;
            suspended)          sc="${YELLOW}${vm_status}${RESET}" ;;
            *)                  sc="${GRAY}${vm_status}${RESET}" ;;
        esac

        # Compute visible widths to pad correctly inside the 54-char box:
        # "  " + idx_str(pad5) + "  " + name(pad20) + "  (" + status + ")" + trailing
        local v_idx=${#idx_str}
        local idx_pad=$(( 5 - v_idx ))   # pad [N] to 5 chars ([1]  or [10] )
        local v_name=${#vm_name}
        local name_pad=$(( 20 - v_name < 0 ? 0 : 20 - v_name ))
        local status_field="(${vm_status})"
        local v_status=${#status_field}
        # fixed visible: 2 + 5 + 2 + 20 + 2 = 31
        local trailing=$(( BOX_W - 31 - v_status ))
        (( trailing < 1 )) && trailing=1
        local trailing_str
        printf -v trailing_str "%${trailing}s" ""
        local idx_pad_str
        printf -v idx_pad_str "%${idx_pad}s" ""
        local name_pad_str
        printf -v name_pad_str "%${name_pad}s" ""

        lines+=("${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}${idx_str}${idx_pad_str}${RESET}  ${vm_name}${name_pad_str}  ${DIM}(${sc}${DIM})${trailing_str}${RESET}${BRIGHT_CYAN}│${RESET}")
    done

    lines+=(
        "${BRIGHT_CYAN}  │                                                      │"
        "${BRIGHT_CYAN}  ├──────────────────────────────────────────────────────┘${RESET}"
        "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[0]${RESET}  Exit         ${BRIGHT_CYAN}│${RESET}"
        "${BRIGHT_CYAN}  └────────────────────┘${RESET}"
        ""
    )

    printf '%s\n' "${lines[@]}"
}

# Generate the right-hand column for the Toolkit Manager full-screen view.
# Shows the saved toolkit list + action sub-menu at the bottom.
# Right-side column: only the saved toolkit list (no actions).
_generate_toolkit_manager_lines() {
    local BOX_W=54

    local -a lines=(
        ""
        "${BRIGHT_RED}${BOLD}__________  ____ ___ .____     .____      ${RESET}"
        "${BRIGHT_RED}${BOLD}\\______   \\|    |   \\|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |  _/|    |   /|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |   \\|    |  / |    |___ |    |___  ${RESET}"
        "${BRIGHT_RED}${BOLD} |______  /|______/  |_______ \\|_______ \\ ${RESET}"
        "${BRIGHT_RED}${BOLD}        \\/                   \\/        \\/ ${RESET}"
        ""
        "${BRIGHT_MAGENTA}  Creator: ${CREATOR_LINK}            ${RESET}${RED}v${BULL_VERSION}${RESET}"
        "${RESET}"
        "  ${CYAN}Toolkit Manager${RESET}"
        "${BRIGHT_CYAN}  ┌──────────────────────────────────────────────────────┐${RESET}"
        "${BRIGHT_CYAN}  │                                                      │${RESET}"
    )

    _toolkit_registry_init
    local tk_count
    tk_count=$(jq '.toolkits | length' "${TOOLKITS_REGISTRY}" 2>/dev/null || echo 0)

    if [[ "${tk_count}" -eq 0 ]]; then
        lines+=("${BRIGHT_CYAN}  │${RESET}  ${DIM}No tools registered.                              ${RESET}${BRIGHT_CYAN}│${RESET}")
    else
        while IFS=$'\t' read -r tk_name tk_url; do
            # No numbering — name (24 chars) + URL hint (remaining)
            local short_url="${tk_url#https://}"
            short_url="${short_url#http://}"
            short_url="${short_url%.git}"

            local v_name=${#tk_name}
            local name_pad=$(( 24 - v_name < 0 ? 0 : 24 - v_name ))
            # visible fixed: 2 + 24 + 2 = 28 ; remaining for url = BOX_W - 28 - 2 = 24
            [[ ${#short_url} -gt 24 ]] && short_url="${short_url:0:21}..."

            local v_url=${#short_url}
            local trailing=$(( BOX_W - 28 - v_url ))
            (( trailing < 1 )) && trailing=1

            local name_pad_str trailing_str
            printf -v name_pad_str "%${name_pad}s" ""
            printf -v trailing_str "%${trailing}s" ""

            lines+=("${BRIGHT_CYAN}  │${RESET}  ${BOLD}${tk_name}${RESET}${name_pad_str}  ${DIM}${short_url}${trailing_str}${RESET}${BRIGHT_CYAN}│${RESET}")
        done < <(jq -r '.toolkits[] | [.name, .url] | @tsv' "${TOOLKITS_REGISTRY}")
    fi

    lines+=(
        "${BRIGHT_CYAN}  │                                                      │${RESET}"
        "${BRIGHT_CYAN}  └──────────────────────────────────────────────────────┘${RESET}"
        ""
    )

    printf '%s\n' "${lines[@]}"
}

# Generate a NUMBERED toolkit list for the right-hand panel (used in Delete/Modify).
# Same box style as _generate_toolkit_manager_lines but with [N] prefixes.
_generate_numbered_toolkit_lines() {
    local title="${1:-Select tool}"
    local BOX_W=54

    local title_pad=$(( BOX_W - 4 - ${#title} ))
    (( title_pad < 1 )) && title_pad=1
    local title_pad_str
    # shellcheck disable=SC2034
    printf -v title_pad_str "%${title_pad}s" ""

    local -a lines=(
        ""
        "${BRIGHT_RED}${BOLD}__________  ____ ___ .____     .____      ${RESET}"
        "${BRIGHT_RED}${BOLD}\\______   \\|    |   \\|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |  _/|    |   /|    |    |    |     ${RESET}"
        "${BRIGHT_RED}${BOLD} |    |   \\|    |  / |    |___ |    |___  ${RESET}"
        "${BRIGHT_RED}${BOLD} |______  /|______/  |_______ \\|_______ \\ ${RESET}"
        "${BRIGHT_RED}${BOLD}        \\/                   \\/        \\/ ${RESET}"
        ""
        "${BRIGHT_MAGENTA}  Creator: ${CREATOR_LINK}            ${RESET}${RED}v${BULL_VERSION}${RESET}"
        "${RESET}"
        "  ${CYAN}${title}${RESET}"
        "${BRIGHT_CYAN}  ┌──────────────────────────────────────────────────────┐${RESET}"
        "${BRIGHT_CYAN}  │                                                      │${RESET}"
    )

    _toolkit_registry_init
    local tk_count
    tk_count=$(jq '.toolkits | length' "${TOOLKITS_REGISTRY}" 2>/dev/null || echo 0)

    if [[ "${tk_count}" -eq 0 ]]; then
        lines+=("${BRIGHT_CYAN}  │${RESET}  ${DIM}No tools registered.                              ${RESET}${BRIGHT_CYAN}│${RESET}")
    else
        local idx=1
        while IFS=$'\t' read -r tk_name tk_url; do
            local short_url="${tk_url#https://}"
            short_url="${short_url#http://}"
            short_url="${short_url%.git}"

            local v_name=${#tk_name}
            local name_pad=$(( 20 - v_name < 0 ? 0 : 20 - v_name ))
            # visible fixed: [N]·· + 20 name + ·· = 26 ; remaining for url = BOX_W - 26 - 2 = 26
            [[ ${#short_url} -gt 20 ]] && short_url="${short_url:0:17}..."

            local v_url=${#short_url}
            local trailing=$(( BOX_W - 28 - v_url ))
            (( trailing < 1 )) && trailing=1

            local name_pad_str trailing_str
            printf -v name_pad_str "%${name_pad}s" ""
            printf -v trailing_str "%${trailing}s" ""

            lines+=("${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[${idx}]${RESET}  ${BOLD}${tk_name}${RESET}${name_pad_str}${DIM}${short_url}${trailing_str} ${RESET}${BRIGHT_CYAN}│${RESET}")
            (( idx++ ))
        done < <(jq -r '.toolkits[] | [.name, .url] | @tsv' "${TOOLKITS_REGISTRY}")
    fi

    lines+=(
        "${BRIGHT_CYAN}  │                                                      │${RESET}"
        "${BRIGHT_CYAN}  └──────────────────────────────────────────────────────┘${RESET}"
        ""
    )

    printf '%s\n' "${lines[@]}"
}

# Render: ASCII art + NUMBERED toolkit list side-by-side (selection interface).
# Used for Delete and Modify so the panel IS the selector — no separate box below.
_display_toolkit_select() {
    local title="${1:-Select tool}"
    local -a ascii_lines menu_lines
    IFS=$'\n' read -r -d '' -a ascii_lines <<< "${ASCII_ART}" || true
    IFS=$'\n' read -r -d '' -a menu_lines <<< "$(_generate_numbered_toolkit_lines "${title}")" || true

    local ascii_count=${#ascii_lines[@]}
    local menu_count=${#menu_lines[@]}
    local max_lines=$(( ascii_count > menu_count ? ascii_count : menu_count ))

    local max_ascii_width=0
    for line in "${ascii_lines[@]}"; do
        local raw
        raw=$(printf "%s" "$line" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local w=${#raw}
        (( w > max_ascii_width )) && max_ascii_width=$w
    done

    local spacing="  "
    for ((i = 0; i < max_lines; i++)); do
        local ascii_line="${ascii_lines[i]:-}"
        local menu_line="${menu_lines[i]:-}"
        local raw_line
        raw_line=$(printf "%s" "$ascii_line" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local pad=$(( max_ascii_width - ${#raw_line} ))
        (( pad < 0 )) && pad=0
        printf "  %s%s%*s%s%s\n" \
            "${BRIGHT_CYAN}" "${ascii_line}${RESET}" \
            "$pad" "" \
            "$spacing" \
            "$menu_line"
    done
    echo ""
}

# Render: ASCII art + toolkit list side-by-side (no actions box).
# Used when there is no other numbered list below (e.g. Install, modify detail).
_display_toolkit_context() {
    local -a ascii_lines menu_lines
    IFS=$'\n' read -r -d '' -a ascii_lines <<< "${ASCII_ART}" || true
    IFS=$'\n' read -r -d '' -a menu_lines <<< "$(_generate_toolkit_manager_lines)" || true

    local ascii_count=${#ascii_lines[@]}
    local menu_count=${#menu_lines[@]}
    local max_lines=$(( ascii_count > menu_count ? ascii_count : menu_count ))

    local max_ascii_width=0
    for line in "${ascii_lines[@]}"; do
        local raw
        raw=$(printf "%s" "$line" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local w=${#raw}
        (( w > max_ascii_width )) && max_ascii_width=$w
    done

    local spacing="  "
    for ((i = 0; i < max_lines; i++)); do
        local ascii_line="${ascii_lines[i]:-}"
        local menu_line="${menu_lines[i]:-}"
        local raw_line
        raw_line=$(printf "%s" "$ascii_line" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local pad=$(( max_ascii_width - ${#raw_line} ))
        (( pad < 0 )) && pad=0
        printf "  %s%s%*s%s%s\n" \
            "${BRIGHT_CYAN}" "${ascii_line}${RESET}" \
            "$pad" "" \
            "$spacing" \
            "$menu_line"
    done
    echo ""
}

# Render: ASCII art + toolkit list side-by-side, then actions sub-menu below.
_display_toolkit_manager() {
    _display_toolkit_context

    echo -e "${BRIGHT_CYAN}  ┌───────────────────────────────┐${RESET}"
    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[1]${RESET}  Quick Install           ${BRIGHT_CYAN}│${RESET}"
    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[2]${RESET}  Library Install         ${BRIGHT_CYAN}│${RESET}"
    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[3]${RESET}  Save to Library         ${BRIGHT_CYAN}│${RESET}"
    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[4]${RESET}  Delete from Lib         ${BRIGHT_CYAN}│${RESET}"
    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[5]${RESET}  Update / Modify         ${BRIGHT_CYAN}│${RESET}"
    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[6]${RESET}  Update Tools on all VMs ${BRIGHT_CYAN}│${RESET}"
    echo -e "${BRIGHT_CYAN}  ├───────────────────────────────┘${RESET}"
    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[0]${RESET}  Exit         ${BRIGHT_CYAN}│${RESET}"
    echo -e "${BRIGHT_CYAN}  └────────────────────┘${RESET}"
    echo ""
}

# Clear screen and render ASCII art + VM selection box side-by-side.
_display_banner_with_vm_select() {
    local title="$1"
    shift
    local -a pairs=("$@")

    local -a ascii_lines menu_lines
    IFS=$'\n' read -r -d '' -a ascii_lines <<< "${ASCII_ART}" || true
    IFS=$'\n' read -r -d '' -a menu_lines <<< "$(_generate_vm_select_lines "${title}" "${pairs[@]}")" || true

    local ascii_count=${#ascii_lines[@]}
    local menu_count=${#menu_lines[@]}
    local max_lines=$(( ascii_count > menu_count ? ascii_count : menu_count ))

    local max_ascii_width=0
    for line in "${ascii_lines[@]}"; do
        local raw
        raw=$(printf "%s" "$line" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local w=${#raw}
        (( w > max_ascii_width )) && max_ascii_width=$w
    done

    local spacing="  "
    for ((i = 0; i < max_lines; i++)); do
        local ascii_line="${ascii_lines[i]:-}"
        local menu_line="${menu_lines[i]:-}"
        local raw_line
        raw_line=$(printf "%s" "$ascii_line" | sed -E 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')
        local pad=$(( max_ascii_width - ${#raw_line} ))
        (( pad < 0 )) && pad=0
        printf "  %s%s%*s%s%s\n" \
            "${BRIGHT_CYAN}" "${ascii_line}${RESET}" \
            "$pad" "" \
            "$spacing" \
            "$menu_line"
    done
    echo ""
}

# Display a numbered list of VMs (full-screen, same style as main menu) and
# prompt the user to pick one. Prints the selected VM name to stdout.
# Returns 1 if inventory is empty, user Exits ([0]), or selection is invalid.
select_vm_from_list() {
    local prompt="${1:-Select VM}"

    inventory_init

    local vm_data
    vm_data=$(jq -r '.vms[] | [.name, .status] | @tsv' "${INVENTORY_FILE}" 2>/dev/null)

    if [[ -z "${vm_data}" ]]; then
        {
            echo ""
            echo -e "  ${BRIGHT_RED}No VMs in inventory.${RESET}"
            echo -e "  ${DIM}Create one first with option [1].${RESET}"
            echo ""
            echo -ne "  ${DIM}Press Enter to return to the menu...${RESET}"
            read -r
        } > /dev/tty
        return 1
    fi

    # Build a flat interleaved array: name0 status0 name1 status1 …
    local -a pairs
    while IFS=$'\t' read -r _name _status; do
        pairs+=("${_name}" "${_status}")
    done <<< "${vm_data}"

    local vm_count=$(( ${#pairs[@]} / 2 ))

    # All display + input MUST go through /dev/tty: this function is called
    # inside $() which captures stdout, so normal echo/read would be invisible.
    { clear; _display_banner_with_vm_select "${prompt}" "${pairs[@]}"; } > /dev/tty
    echo -ne "  ${BOLD}${BRIGHT_CYAN}BULL > ${RESET}" > /dev/tty

    local choice
    read -r choice < /dev/tty

    if [[ "${choice}" == "0" ]]; then
        return 1
    fi

    if [[ "${choice}" =~ ^[0-9]+$ ]] && \
       [[ "${choice}" -ge 1 ]] && \
       [[ "${choice}" -le "${vm_count}" ]]; then
        # Only the selected name goes to stdout (captured by the caller's $())
        echo "${pairs[$((( choice - 1 ) * 2))]}"
        return 0
    fi

    echo -e "${BRIGHT_RED}Invalid selection.${RESET}" > /dev/tty
    return 1
}

# =============================================================================
# OS SELECTION PROMPT
# Prompts for the guest OS (Kali Linux or Parrot Security).
# Sets global: BULL_OS
# =============================================================================
_prompt_os() {
    BULL_OS=""

    clear
    _display_step "Operating System" "Select the OS for the VM"
    echo ""

    echo -e "  ${BRIGHT_RED}[1]${RESET}  Kali Linux        ${DIM}(kalilinux/rolling)${RESET}"
    echo -e "  ${BRIGHT_RED}[2]${RESET}  Parrot Security   ${DIM}(parrotsec/rolling-security)${RESET}"
    echo ""
    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice [1-2] (default: 1) > ${RESET}")" _os_choice

    case "${_os_choice:-1}" in
        1) BULL_OS="kali" ;;
        2) BULL_OS="parrot" ;;
        *) BULL_OS="kali" ;;
    esac

    echo -e "\n  ${DIM}OS set to:${RESET} ${BOLD}${BULL_OS}${RESET}"
    unset _os_choice
    return 0
}

# =============================================================================
# CREDENTIALS PROMPT
# Prompts for VM username + password (masked input).
# Sets globals: BULL_CRED_USER  BULL_CRED_PASS
# =============================================================================
_prompt_credentials() {
    BULL_CRED_USER=""
    BULL_CRED_PASS=""

    clear
    _display_step "VM Credentials" "Set the login user for the VM"
    echo ""

    local _default_user
    _default_user="$(_os_default_user "${BULL_OS:-kali}")"
    read -rp "$(echo -e "  ${BRIGHT_CYAN}Username (${_default_user}) > ${RESET}")" BULL_CRED_USER
    BULL_CRED_USER="${BULL_CRED_USER:-${_default_user}}"
    echo ""

    echo -e "  ${BRIGHT_RED}[G]${RESET} Generate a random strong password ${DIM}(recommended)${RESET}"
    echo -e "  ${BRIGHT_RED}[M]${RESET} Enter your own password"
    echo ""
    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice [G/m] > ${RESET}")" _pw_mode

    if [[ "${_pw_mode:-g}" =~ ^[Mm]$ ]]; then
        while true; do
            echo -ne "  ${BRIGHT_CYAN}Password > ${RESET}"
            read -rs BULL_CRED_PASS
            echo
            if [[ ${#BULL_CRED_PASS} -lt 12 ]]; then
                echo -e "  ${BRIGHT_RED}Password must be at least 12 characters.${RESET}"
                continue
            fi
            echo -ne "  ${BRIGHT_CYAN}Confirm  > ${RESET}"
            local _confirm
            read -rs _confirm
            echo
            if [[ "${BULL_CRED_PASS}" == "${_confirm}" ]]; then
                _confirm=""
                break
            fi
            echo -e "  ${BRIGHT_RED}Passwords do not match.${RESET}"
        done
    else
        BULL_CRED_PASS=$(openssl rand -base64 48 \
            | tr -dc 'A-Za-z0-9!@#%^*_-' \
            | head -c 24)
        echo ""
        echo -e "  ${DIM}Generated password:${RESET} ${BOLD}${BRIGHT_GREEN}${BULL_CRED_PASS}${RESET}"
        echo -e "  ${DIM}(encrypted in .credentials.gpg — use 'bull show-pass <vm>' to reveal)${RESET}"
    fi

    unset _pw_mode
    return 0
}

# =============================================================================
# POST-CREATION: OFFER SAVED TOOLKITS
# After a VM is created, offer to install saved toolkits if the registry is
# non-empty. Silently skips if no toolkits are saved.
# =============================================================================
_offer_registry_toolkits() {
    local vm_name="$1"
    local count
    count=$(jq '.toolkits | length' "${TOOLKITS_REGISTRY}" 2>/dev/null || echo 0)
    [[ "${count}" -eq 0 ]] && return 0

    clear
    _display_step "Toolkits" "You have ${count} toolkit(s) in your registry"
    echo ""
    echo -e "  ${BRIGHT_RED}[1]${RESET}  Install ALL saved toolkits now"
    echo -e "  ${BRIGHT_RED}[2]${RESET}  Pick individual toolkits"
    echo -e "  ${BRIGHT_RED}[0]${RESET}  Skip"
    echo ""
    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice > ${RESET}")" tk_offer

    case "${tk_offer:-0}" in
        1)
            install_registry_toolkits "${vm_name}" || true
            ;;
        2)
            list_toolkit_registry || return 0
            local tk_idx
            read -rp "$(echo -e "  ${BRIGHT_CYAN}Select [1-${#BULL_TOOLKIT_URLS[@]}] > ${RESET}")" tk_idx
            if [[ "${tk_idx}" =~ ^[0-9]+$ ]] && \
               [[ "${tk_idx}" -ge 1 ]] && \
               [[ "${tk_idx}" -le "${#BULL_TOOLKIT_URLS[@]}" ]]; then
                install_toolkit "${vm_name}" "${BULL_TOOLKIT_URLS[$((tk_idx-1))]}" || true
            fi
            ;;
        0|"")
            log_info "Skipping toolkit installation."
            ;;
        *)
            echo -e "\n  ${BRIGHT_RED}Invalid choice.${RESET}"
            ;;
    esac
    unset tk_offer
}

# =============================================================================
# KEYBOARD LAYOUT PROMPT
# Prompts the user to pick a keyboard layout for the VM.
# Sets global: BULL_KB_LAYOUT
# =============================================================================
_prompt_keyboard() {
    BULL_KB_LAYOUT=""

    clear
    _display_step "Keyboard Layout" "Select the keyboard layout for the VM"
    echo ""

    echo -e "  ${BRIGHT_RED}[1]${RESET}  us  — English US  ${DIM}(QWERTY)${RESET}"
    echo -e "  ${BRIGHT_RED}[2]${RESET}  fr  — French      ${DIM}(AZERTY)${RESET}"
    echo -e "  ${BRIGHT_RED}[3]${RESET}  de  — German      ${DIM}(QWERTZ)${RESET}"
    echo -e "  ${BRIGHT_RED}[4]${RESET}  gb  — English UK  ${DIM}(QWERTY)${RESET}"
    echo -e "  ${BRIGHT_RED}[5]${RESET}  es  — Spanish     ${DIM}(QWERTY)${RESET}"
    echo -e "  ${BRIGHT_RED}[6]${RESET}  it  — Italian     ${DIM}(QWERTY)${RESET}"
    echo -e "  ${BRIGHT_RED}[7]${RESET}  be  — Belgian     ${DIM}(AZERTY)${RESET}"
    echo -e "  ${BRIGHT_RED}[8]${RESET}  ch  — Swiss       ${DIM}(QWERTZ)${RESET}"
    echo -e "  ${BRIGHT_RED}[9]${RESET}  pt  — Portuguese  ${DIM}(QWERTY)${RESET}"
    echo ""
    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice [1-9] (default: 1 = us) > ${RESET}")" _kb_choice

    case "${_kb_choice:-1}" in
        1) BULL_KB_LAYOUT="us" ;;
        2) BULL_KB_LAYOUT="fr" ;;
        3) BULL_KB_LAYOUT="de" ;;
        4) BULL_KB_LAYOUT="gb" ;;
        5) BULL_KB_LAYOUT="es" ;;
        6) BULL_KB_LAYOUT="it" ;;
        7) BULL_KB_LAYOUT="be" ;;
        8) BULL_KB_LAYOUT="ch" ;;
        9) BULL_KB_LAYOUT="pt" ;;
        *) BULL_KB_LAYOUT="us" ;;
    esac

    echo -e "\n  ${DIM}Keyboard set to:${RESET} ${BOLD}${BULL_KB_LAYOUT}${RESET}"
    unset _kb_choice
    return 0
}

# =============================================================================
# RESOLUTION PROMPT
# Prompts the user to pick a display resolution for the VM.
# Sets global: BULL_RESOLUTION
# =============================================================================
_prompt_resolution() {
    BULL_RESOLUTION=""

    clear
    _display_step "Display Resolution" "Select the screen resolution"
    echo ""

    echo -e "  ${BRIGHT_RED}[1]${RESET}  1920x1080  ${DIM}(Full HD — recommended)${RESET}"
    echo -e "  ${BRIGHT_RED}[2]${RESET}  2560x1440  ${DIM}(2K/QHD)${RESET}"
    echo -e "  ${BRIGHT_RED}[3]${RESET}  3840x2160  ${DIM}(4K/UHD)${RESET}"
    echo -e "  ${BRIGHT_RED}[4]${RESET}  1280x720   ${DIM}(HD)${RESET}"
    echo -e "  ${BRIGHT_RED}[5]${RESET}  1366x768   ${DIM}(Standard laptop)${RESET}"
    echo -e "  ${BRIGHT_RED}[6]${RESET}  1600x900   ${DIM}(HD+)${RESET}"
    echo -e "  ${BRIGHT_RED}[7]${RESET}  Custom      ${DIM}(enter manually)${RESET}"
    echo ""
    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice [1-7] (default: 1) > ${RESET}")" _res_choice

    case "${_res_choice:-1}" in
        1) BULL_RESOLUTION="1920x1080" ;;
        2) BULL_RESOLUTION="2560x1440" ;;
        3) BULL_RESOLUTION="3840x2160" ;;
        4) BULL_RESOLUTION="1280x720" ;;
        5) BULL_RESOLUTION="1366x768" ;;
        6) BULL_RESOLUTION="1600x900" ;;
        7)
            echo ""
            read -rp "$(echo -e "  ${BRIGHT_CYAN}Width (e.g. 1920) > ${RESET}")" _custom_w
            read -rp "$(echo -e "  ${BRIGHT_CYAN}Height (e.g. 1080) > ${RESET}")" _custom_h
            if [[ -n "${_custom_w}" && -n "${_custom_h}" ]]; then
                BULL_RESOLUTION="${_custom_w}x${_custom_h}"
            else
                BULL_RESOLUTION="1920x1080"
            fi
            ;;
        *) BULL_RESOLUTION="1920x1080" ;;
    esac

    echo -e "\n  ${DIM}Resolution set to:${RESET} ${BOLD}${BULL_RESOLUTION}${RESET}"
    unset _res_choice _custom_w _custom_h
    return 0
}

# =============================================================================
# INTERACTIVE MENU HANDLER
# =============================================================================
handle_menu_choice() {
    local choice="$1"

    case "$choice" in
        1)
            clear
            _display_step "Create VM" "Choose between quick or custom setup"
            echo ""
            echo -e "  ${BRIGHT_RED}[1]${RESET} Quick create       ${DIM}(${DEFAULT_RAM}MB RAM, ${DEFAULT_CPU} CPUs, auto name)${RESET}"
            echo -e "  ${BRIGHT_RED}[2]${RESET} Custom create      ${DIM}(name, RAM, CPU, resolution)${RESET}"
            echo -e "  ${BRIGHT_RED}[0]${RESET} Back to menu"
            echo ""
            read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice > ${RESET}")" create_choice

            case "$create_choice" in
                1)
                    _prompt_os
                    local auto_name
                    auto_name="${BULL_OS}-$(date +%s | tail -c 5)"
                    _prompt_credentials || return
                    _prompt_keyboard
                    _prompt_resolution
                    clear
                    _display_step "VM Creation" "Setting up your VM"
                    echo ""
                    echo -e "\n${BRIGHT_MAGENTA}Creating VM '${auto_name}' [${BULL_OS}]...${RESET}"
                    echo -e "  ${DIM}RAM: ${DEFAULT_RAM}MB | CPU: ${DEFAULT_CPU} | Resolution: ${BULL_RESOLUTION}${RESET}"
                    echo ""
                    if ! create_vm "${auto_name}" "${DEFAULT_RAM}" "${DEFAULT_CPU}" \
                        "${BULL_CRED_USER}" "${BULL_CRED_PASS}" "${BULL_KB_LAYOUT}" "${BULL_RESOLUTION}" "${BULL_OS}"; then
                        log_error "VM creation failed. Check ${BULL_HOME}/bull-error.log for details."
                        echo -ne "\n  ${DIM}Press Enter to continue...${RESET}"
                        read -r _
                    fi
                    BULL_CRED_PASS=""
                    _offer_registry_toolkits "${auto_name}"
                    ;;
                2)
                    _prompt_os
                    clear
                    _display_step "Custom Create" "VM name"
                    echo ""
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}VM name > ${RESET}")" vm_name
                    if [[ -z "${vm_name}" ]]; then
                        echo -e "\n  ${BRIGHT_RED}No name provided.${RESET}"
                        return
                    fi
                    validate_vm_name "${vm_name}" || return

                    clear
                    _display_step "Custom Create" "Hardware resources"
                    echo ""
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}RAM in MB (${DEFAULT_RAM}) > ${RESET}")" ram
                    ram="${ram:-${DEFAULT_RAM}}"
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}CPU cores (${DEFAULT_CPU}) > ${RESET}")" cpu
                    cpu="${cpu:-${DEFAULT_CPU}}"

                    _prompt_credentials || return
                    _prompt_keyboard
                    _prompt_resolution
                    clear
                    _display_step "VM Creation" "Setting up your VM"
                    echo ""
                    echo -e "\n${BRIGHT_MAGENTA}Creating VM '${vm_name}' [${BULL_OS}]...${RESET}"
                    echo -e "  ${DIM}RAM: ${ram}MB | CPU: ${cpu} | Resolution: ${BULL_RESOLUTION}${RESET}"
                    echo ""
                    if ! create_vm "${vm_name}" "${ram}" "${cpu}" \
                        "${BULL_CRED_USER}" "${BULL_CRED_PASS}" "${BULL_KB_LAYOUT}" "${BULL_RESOLUTION}" "${BULL_OS}"; then
                        log_error "VM creation failed. Check ${BULL_HOME}/bull-error.log for details."
                        echo -ne "\n  ${DIM}Press Enter to continue...${RESET}"
                        read -r _
                    fi
                    BULL_CRED_PASS=""
                    _offer_registry_toolkits "${vm_name}"
                    ;;
                0|"")
                    return
                    ;;
                *)
                    echo -e "\n  ${BRIGHT_RED}Invalid choice.${RESET}"
                    return
                    ;;
            esac
            ;;
        2)
            echo -e "\n${BOLD}${BRIGHT_CYAN}[ VM Inventory ]${RESET}\n"
            inventory_list
            echo -e "\n  ${BRIGHT_CYAN}Press Enter to continue...${RESET}"
            read -r _
            ;;
        3)
            local vm_name
            vm_name=$(select_vm_from_list "Select VM to start") || return
            start_vm "${vm_name}" || true
            ;;
        4)
            local vm_name
            vm_name=$(select_vm_from_list "Select VM to stop") || return
            stop_vm "${vm_name}" || true
            ;;
        5)
            local vm_name
            vm_name=$(select_vm_from_list "Select VM to destroy") || return
            destroy_vm "${vm_name}" || true
            ;;
        6)
            local vm_name
            vm_name=$(select_vm_from_list "Select VM to view (GUI)") || return
            view_vm "${vm_name}" || true
            ;;
        7)
            local vm_name
            vm_name=$(select_vm_from_list "Select VM to connect") || return
            connect_vm "${vm_name}" || true
            ;;
        8)
            local vm_name
            vm_name=$(select_vm_from_list "Select VM (snapshot)") || return

            # Sub-menu: create or delete
            echo -e ""
            echo -e "${BRIGHT_CYAN}  ┌──────────────────────────────────────────────────────┐${RESET}"
            echo -e "${BRIGHT_CYAN}  │                                                      │${RESET}"
            echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[1]${RESET}  Create snapshot                                ${BRIGHT_CYAN}│${RESET}"
            echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[2]${RESET}  Delete snapshot                                ${BRIGHT_CYAN}│${RESET}"
            echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[0]${RESET}  Back                                           ${BRIGHT_CYAN}│${RESET}"
            echo -e "${BRIGHT_CYAN}  │                                                      │${RESET}"
            echo -e "${BRIGHT_CYAN}  └──────────────────────────────────────────────────────┘${RESET}"
            local snap_action
            read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice > ${RESET}")" snap_action

            case "${snap_action}" in
                1)
                    local snap_label
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}Snapshot label (optional) > ${RESET}")" snap_label
                    snapshot_vm "${vm_name}" "${snap_label}" || true
                    ;;
                2)
                    local snap_to_delete
                    snap_to_delete=$(select_snapshot "${vm_name}") || {
                        echo -e "  ${BRIGHT_RED}No snapshot selected.${RESET}"
                        return
                    }
                    delete_snapshot "${vm_name}" "${snap_to_delete}" && \
                        echo -e "\n  ${BRIGHT_CYAN}Snapshot '${snap_to_delete}' deleted.${RESET}" || \
                        echo -e "\n  ${BRIGHT_RED}Failed to delete.${RESET}"
                    ;;
                0|"")
                    return
                    ;;
                *)
                    echo -e "  ${BRIGHT_RED}Choice invalid.${RESET}"
                    ;;
            esac
            ;;
        9)
            local vm_name
            vm_name=$(select_vm_from_list "Select VM to restore") || return
            local snap_label
            snap_label=$(select_snapshot "${vm_name}") || {
                echo -e "  ${BRIGHT_RED}No snapshot selected.${RESET}"
                return
            }
            echo -e "  ${DIM}Restoring to:${RESET} ${BOLD}${snap_label}${RESET}"
            restore_snapshot "${vm_name}" "${snap_label}" || true
            ;;
        10)
            local vm_name
            vm_name=$(select_vm_from_list "Select VM for VPN") || return
            local vpn_config
            read -rp "$(echo -e "  ${BRIGHT_CYAN}Path to VPN config (.ovpn / WireGuard) > ${RESET}")" vpn_config
            [[ -z "${vpn_config}" ]] && { echo -e "${BRIGHT_RED}Config path required.${RESET}"; return; }
            [[ ! -f "${vpn_config}" ]] && { echo -e "${BRIGHT_RED}File not found: ${vpn_config}${RESET}"; return; }
            configure_vpn "${vm_name}" "${vpn_config}" || true
            ;;
        11)
            # ── Toolkit Manager ───────────────────────────────────────────
            clear
            list_toolkit_registry > /dev/null 2>&1 || true
            _display_toolkit_manager
            echo -ne "  ${BOLD}${BRIGHT_CYAN}BULL > ${RESET}"
            local tk_action
            read -r tk_action

            case "${tk_action}" in
                1)
                    clear
                    local vm_name
                    vm_name=$(select_vm_from_list "Select VM") || return
                    local tk_url
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}Git URL > ${RESET}")" tk_url
                    [[ -z "${tk_url}" ]] && { echo -e "  ${BRIGHT_RED}URL required.${RESET}"; read -r; return; }
                    install_toolkit "${vm_name}" "${tk_url}" || true
                    ;;
                2)
                    list_toolkit_registry > /dev/null 2>&1 || true
                    [[ "${#BULL_TOOLKIT_NAMES[@]}" -eq 0 ]] && { clear; echo -e "  ${BRIGHT_RED}No tools in Library.${RESET}"; read -rp "  ${BRIGHT_CYAN}Press Enter to continue...${RESET}"; return; }
                    clear
                    _display_toolkit_select "Select tool"
                    local tk_idx
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice > ${RESET}")" tk_idx
                    [[ ! "${tk_idx}" =~ ^[0-9]+$ ]] || [[ "${tk_idx}" -lt 1 ]] || [[ "${tk_idx}" -gt "${#BULL_TOOLKIT_NAMES[@]}" ]] && { echo -e "  ${BRIGHT_RED}Invalid selection.${RESET}"; read -r; return; }
                    local sel_url="${BULL_TOOLKIT_URLS[$((tk_idx-1))]}"
                    local vm_name
                    vm_name=$(select_vm_from_list "Select VM") || return
                    install_toolkit "${vm_name}" "${sel_url}" || true
                    ;;
                3)
                    clear
                    _display_toolkit_context
                    local save_url save_name _tmp_save_name
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}Git URL > ${RESET}")" save_url
                    [[ -z "${save_url}" ]] && { echo -e "  ${BRIGHT_RED}URL required.${RESET}"; return; }
                    _validate_toolkit_url "${save_url}" || return
                    save_name="$(basename "${save_url}" .git)"
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}Name (default: ${save_name}) > ${RESET}")" _tmp_save_name
                    [[ -n "${_tmp_save_name}" ]] && save_name="${_tmp_save_name}"
                    toolkit_save "${save_name}" "${save_url}" && echo -e "\n  ${BRIGHT_CYAN}'${save_name}' added to Library.${RESET}"
                    ;;
                4)
                    list_toolkit_registry > /dev/null 2>&1 || true
                    [[ "${#BULL_TOOLKIT_NAMES[@]}" -eq 0 ]] && { clear; echo -e "  ${BRIGHT_RED}No tools in Library.${RESET}"; read -rp "  ${BRIGHT_CYAN}Press Enter to continue...${RESET}"; return; }
                    clear
                    _display_toolkit_select "Remove from Library"
                    local tk_idx
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice > ${RESET}")" tk_idx
                    [[ ! "${tk_idx}" =~ ^[0-9]+$ ]] || [[ "${tk_idx}" -lt 1 ]] || [[ "${tk_idx}" -gt "${#BULL_TOOLKIT_NAMES[@]}" ]] && { echo -e "  ${BRIGHT_RED}Invalid selection.${RESET}"; return; }
                    local to_delete="${BULL_TOOLKIT_NAMES[$((tk_idx-1))]}"
                    toolkit_remove_from_registry "${to_delete}" && \
                        echo -e "\n  ${BRIGHT_CYAN}'${to_delete}' removed from Library.${RESET}"
                    ;;
                5)
                    list_toolkit_registry > /dev/null 2>&1 || true
                    [[ "${#BULL_TOOLKIT_NAMES[@]}" -eq 0 ]] && { clear; echo -e "  ${BRIGHT_RED}No tools in Library.${RESET}"; read -rp "  ${BRIGHT_CYAN}Press Enter to continue...${RESET}"; return; }
                    clear
                    _display_toolkit_select "Select tool"
                    local tk_idx
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice > ${RESET}")" tk_idx
                    [[ ! "${tk_idx}" =~ ^[0-9]+$ ]] || [[ "${tk_idx}" -lt 1 ]] || [[ "${tk_idx}" -gt "${#BULL_TOOLKIT_NAMES[@]}" ]] && { echo -e "  ${BRIGHT_RED}Invalid selection.${RESET}"; return; }
                    local sel_name="${BULL_TOOLKIT_NAMES[$((tk_idx-1))]}"
                    local sel_url="${BULL_TOOLKIT_URLS[$((tk_idx-1))]}"
                    clear
                    _display_toolkit_context
                    echo -e "${BRIGHT_CYAN}  ┌──────────────────────────────────────────────────────┐${RESET}"
                    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BOLD}${sel_name}${RESET}"
                    echo -e "${BRIGHT_CYAN}  │${RESET}  ${DIM}${sel_url}${RESET}"
                    echo -e "${BRIGHT_CYAN}  │                                                      │${RESET}"
                    echo -e "${BRIGHT_CYAN}  ├──────────────────────────────────────────────────────┤${RESET}"
                    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[1]${RESET}  Update on VM                                   ${BRIGHT_CYAN}│${RESET}"
                    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[2]${RESET}  Change URL                                     ${BRIGHT_CYAN}│${RESET}"
                    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[3]${RESET}  Rename                                         ${BRIGHT_CYAN}│${RESET}"
                    echo -e "${BRIGHT_CYAN}  │${RESET}  ${BRIGHT_RED}[0]${RESET}  Back                                           ${BRIGHT_CYAN}│${RESET}"
                    echo -e "${BRIGHT_CYAN}  └──────────────────────────────────────────────────────┘${RESET}"
                    local mod_choice
                    read -rp "$(echo -e "  ${BRIGHT_CYAN}Choice > ${RESET}")" mod_choice

                    case "${mod_choice}" in
                        1)
                            local vm_name
                            vm_name=$(select_vm_from_list "Select VM") || return
                            toolkit_pull "${vm_name}" "${sel_name}" || true
                            ;;
                        2)
                            local new_url
                            read -rp "$(echo -e "  ${BRIGHT_CYAN}Nouvelle URL > ${RESET}")" new_url
                            [[ -z "${new_url}" ]] && { echo -e "  ${BRIGHT_RED}URL required.${RESET}"; return; }
                            toolkit_save "${sel_name}" "${new_url}" && \
                                echo -e "\n  ${BRIGHT_CYAN}URL updated.${RESET}"
                            ;;
                        3)
                            local new_name
                            read -rp "$(echo -e "  ${BRIGHT_CYAN}Nouveau nom > ${RESET}")" new_name
                            [[ -z "${new_name}" ]] && { echo -e "  ${BRIGHT_RED}Nom requis.${RESET}"; return; }
                            toolkit_rename "${sel_name}" "${new_name}" && \
                                echo -e "\n  ${BRIGHT_CYAN}Renamed to '${new_name}'.${RESET}"
                            ;;
                        0|"")  ;;
                        *)
                            echo -e "  ${BRIGHT_RED}Choice invalid.${RESET}"
                            ;;
                    esac
                    ;;
                6)
                    list_toolkit_registry > /dev/null 2>&1 || true
                    [[ "${#BULL_TOOLKIT_NAMES[@]}" -eq 0 ]] && { clear; echo -e "  ${BRIGHT_RED}No tools in Library.${RESET}"; read -rp "  ${BRIGHT_CYAN}Press Enter to continue...${RESET}"; return; }
                    clear
                    _display_step "Update ALL" "Installing all tools on ALL running VMs"
                    echo ""
                    inventory_init
                    local vm_data
                    vm_data=$(jq -r '.vms[] | select(.status == "running") | .name' "${INVENTORY_FILE}" 2>/dev/null || echo "")
                    if [[ -z "${vm_data}" ]]; then
                        echo -e "  ${BRIGHT_RED}No running VMs found.${RESET}"
                        read -rp "  ${BRIGHT_CYAN}Press Enter to continue...${RESET}"
                    else
                        local vms_updated=0 vms_failed=0
                        while IFS= read -r vm_name; do
                            [[ -z "${vm_name}" ]] && continue
                            echo -e "  ${CYAN}Updating on ${vm_name}...${RESET}"
                            if install_registry_toolkits "${vm_name}"; then
                                (( vms_updated++ ))
                            else
                                (( vms_failed++ ))
                            fi
                        done <<< "${vm_data}"
                        echo ""
                        echo -e "  ${BRIGHT_CYAN}Done: ${vms_updated} VMs updated, ${vms_failed} failed.${RESET}"
                        read -rp "  ${BRIGHT_CYAN}Press Enter to continue...${RESET}"
                    fi
                    ;;
                0|"")
                    return
                    ;;
                *)
                    echo -e "  ${BRIGHT_RED}Choice invalid.${RESET}"
                    ;;
            esac
            ;;
        12)
            echo -e "\n${BOLD}${BRIGHT_CYAN}[ Global Status ]${RESET}\n"
            show_status || true
            read -rp "  ${BRIGHT_CYAN}Press Enter to continue...${RESET}"
            ;;
        13)
            echo -e "\n${BOLD}${BRIGHT_CYAN}[ Sync Inventory ]${RESET}\n"
            inventory_sync || true
            ;;
        14)
            echo -e "\n${BOLD}${BRIGHT_CYAN}[ System Check ]${RESET}\n"
            check_dependencies || true
            inventory_init
            mkdir -p "${BULL_VM_DIR}"
            
            # Add alias to shell RC files
            local bull_path="${SCRIPT_DIR}/bull.sh"
            local alias_line="alias bull='sudo ${bull_path}'"
            
            for rc_file in ~/.bashrc ~/.zshrc ~/.profile; do
                if [[ -f "${rc_file}" ]]; then
                    if ! grep -q "alias bull=" "${rc_file}" 2>/dev/null; then
                        echo "" >> "${rc_file}"
                        echo "# BULL alias (added by bull.sh)" >> "${rc_file}"
                        echo "${alias_line}" >> "${rc_file}"
                        echo "  ${DIM}Added alias to ${rc_file}${RESET}"
                    fi
                fi
            done
            
            echo
            log_info "BULL ready. Run 'bull' or 'source ~/.bashrc' to use."
            ;;
        0)
            echo -e "\n${BRIGHT_CYAN}Exiting BULL...${RESET}"
            exit 0
            ;;
        *)
            echo -e "\n${BRIGHT_RED}Invalid choice. Please try again.${RESET}"
            ;;
    esac
}

# =============================================================================
# CLI HELP (non-interactive usage)
# =============================================================================
show_help() {
    cat << EOF
${BOLD}BULL${RESET} v${BULL_VERSION} - Pentest Environment Toolkit

${BOLD}USAGE:${RESET}
    bull                           Launch interactive menu
    bull <command> [args]          Run a command directly

${BOLD}COMMANDS:${RESET}
    init                       Check system dependencies
    create <name> [options]    Create a new VM (Kali or Parrot)
    list                       List all VMs with status
    start <name>               Start a VM
    stop <name>                Stop a VM
    destroy <name>             Destroy a VM (irreversible)
    connect <name>             SSH into a running VM
    snapshot <name> [label]    Create a VM snapshot
    restore <name> <label>     Restore a VM to a snapshot
    vpn <name> <config>        Configure VPN with kill switch
    status                     Show global status overview
    sync                       Sync inventory with actual VM state
    show-pass <name>          Decrypt and show VM credentials
    toolkit <name> <url>       Install a toolkit from Git URL

${BOLD}CREATE OPTIONS:${RESET}
    --ram <MB>                 RAM in megabytes (default: ${DEFAULT_RAM})
    --cpu <N>                  CPU cores (default: ${DEFAULT_CPU})
    --resolution <WxH>         Display resolution (default: 1920x1080)
    --os <kali|parrot>         Guest OS (default: kali)
    --username <user>          VM username (default: kali/user)
    --password-file <path>     Read password from file (safer than --password)
    --keyboard <layout>        Keyboard layout (us/fr/de/etc.)

${BOLD}NOTE:${RESET} Parrot OS requires downloading a ~9GB OVA file on first run.

${BOLD}ENVIRONMENT:${RESET}
    BULL_HOME            Data directory (default: ~/.bull)
    BULL_DEBUG           Enable debug output (set to 1)
    BULL_DRY_RUN         Dry-run mode, no VM changes (set to 1)
    NO_COLOR                   Disable colored output

${BOLD}EXAMPLES:${RESET}
    bull init
    bull create kali-lab --ram 4096 --cpu 2 --resolution 2560x1440
    bull create parrot-lab --os parrot --ram 4096 --cpu 2 --keyboard fr
    bull start kali-lab
    bull connect kali-lab
    bull vpn kali-lab ~/vpn/config.ovpn
    bull destroy kali-lab

EOF
}

# =============================================================================
# CLI ARGUMENT PARSING (non-interactive mode)
# =============================================================================
COMMAND=""
VM_NAME=""
EXTRA_ARG=""
OPT_RAM="${DEFAULT_RAM}"
OPT_CPU="${DEFAULT_CPU}"
OPT_RESOLUTION=""
OPT_OS="${BULL_DEFAULT_OS}"
OPT_USERNAME=""
OPT_PASSWORD=""
OPT_PASSWORD_FILE=""
OPT_KEYBOARD=""

parse_arguments() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    COMMAND="$1"
    shift

    case "${COMMAND}" in
        -h|--help|help)
            show_help
            exit 0
            ;;
        -v|--version|version)
            echo "BULL v${BULL_VERSION}"
            exit 0
            ;;
    esac

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ram)
                OPT_RAM="${2:-}"
                shift 2
                ;;
            --cpu)
                OPT_CPU="${2:-}"
                shift 2
                ;;
            --resolution)
                OPT_RESOLUTION="${2:-}"
                shift 2
                ;;
            --os)
                OPT_OS="${2:-}"
                shift 2
                ;;
            --username)
                OPT_USERNAME="${2:-}"
                shift 2
                ;;
            --password-file)
                OPT_PASSWORD_FILE="${2:-}"
                shift 2
                ;;
            --password)
                # DEPRECATED: visible in ps aux. Use --password-file instead.
                OPT_PASSWORD="${2:-}"
                shift 2
                ;;
            --keyboard)
                OPT_KEYBOARD="${2:-}"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Run 'bull --help' for usage."
                exit 1
                ;;
            *)
                if [[ -z "${VM_NAME}" ]]; then
                    VM_NAME="$1"
                elif [[ -z "${EXTRA_ARG}" ]]; then
                    EXTRA_ARG="$1"
                else
                    log_error "Unexpected argument: $1"
                    exit 1
                fi
                shift
                ;;
        esac
    done
}

# =============================================================================
# CLI COMMAND DISPATCH (non-interactive mode)
# =============================================================================
execute_command() {
    case "${COMMAND}" in
        init)
            cmd_init
            ;;
        create)
            cmd_create
            ;;
        list|ls)
            cmd_list
            ;;
        start)
            cmd_start
            ;;
        stop)
            cmd_stop
            ;;
        destroy|rm)
            cmd_destroy
            ;;
        connect|ssh)
            cmd_connect
            ;;
        snapshot|snap)
            cmd_snapshot
            ;;
        restore)
            cmd_restore
            ;;
        vpn)
            cmd_vpn
            ;;
        status)
            cmd_status
            ;;
        sync)
            cmd_sync
            ;;
        toolkit)
            cmd_toolkit
            ;;
        view|gui)
            cmd_view
            ;;
        show-pass|showpass|credentials)
            cmd_show_pass
            ;;
        *)
            log_error "Unknown command: ${COMMAND}"
            echo "Run 'bull --help' for available commands."
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Command Implementations (CLI mode)
# ---------------------------------------------------------------------------
cmd_init() {
    echo -e "\n${BOLD}BULL${RESET} v${BULL_VERSION}\n"
    check_dependencies || exit 1
    inventory_init
    mkdir -p "${BULL_VM_DIR}"
    echo
    log_info "BULL ready. Run 'bull create <name>' to start."
}

cmd_create() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull create <name> [--ram MB] [--cpu N] [--resolution WxH] [--os kali|parrot] [--username USER] [--password PASS] [--keyboard fr]"
        exit 1
    }
    BULL_OS="${OPT_OS}"
    
    # Username: use CLI option or default
    BULL_CRED_USER="${OPT_USERNAME:-$(_os_default_user "${BULL_OS}")}"
    
    # Password: use --password-file (preferred), --password (deprecated), or generate one
    if [[ -n "${OPT_PASSWORD_FILE}" ]]; then
        if [[ ! -f "${OPT_PASSWORD_FILE}" ]]; then
            log_error "Password file not found: ${OPT_PASSWORD_FILE}"
            exit 1
        fi
        BULL_CRED_PASS=$(head -1 "${OPT_PASSWORD_FILE}" | tr -d '\n\r')
        # Wipe the password file contents after reading (one-time use)
        : > "${OPT_PASSWORD_FILE}" 2>/dev/null || log_warn "Could not wipe password file: ${OPT_PASSWORD_FILE}"
    elif [[ -n "${OPT_PASSWORD}" ]]; then
        BULL_CRED_PASS="${OPT_PASSWORD}"
        # Wipe from process environment as soon as possible
        OPT_PASSWORD=""
    else
        BULL_CRED_PASS=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9!@#%^*_-' | head -c 24)
        log_info "Password generated — use 'bull show-pass ${VM_NAME}' to reveal it later"
    fi
    
    # Keyboard: use CLI option or prompt
    if [[ -n "${OPT_KEYBOARD}" ]]; then
        BULL_KB_LAYOUT="${OPT_KEYBOARD}"
    else
        _prompt_keyboard
    fi
    
    # Resolution: use CLI option or prompt
    if [[ -z "${OPT_RESOLUTION}" ]]; then
        _prompt_resolution
    else
        BULL_RESOLUTION="${OPT_RESOLUTION}"
    fi
    
    clear
    log_info "Creating VM '${VM_NAME}' [${BULL_OS}]..."
    log_info "  RAM: ${OPT_RAM}MB | CPU: ${OPT_CPU} | Resolution: ${BULL_RESOLUTION}"
    log_info "  Username: ${BULL_CRED_USER} | Keyboard: ${BULL_KB_LAYOUT}"
    
    create_vm "${VM_NAME}" "${OPT_RAM}" "${OPT_CPU}" \
        "${BULL_CRED_USER}" "${BULL_CRED_PASS}" "${BULL_KB_LAYOUT}" "${BULL_RESOLUTION}" "${BULL_OS}"
    BULL_CRED_PASS=""
}

cmd_list() {
    inventory_list
    if [[ "${BULL_INTERACTIVE:-0}" == "1" ]]; then
        echo ""
        read -rp "${BRIGHT_CYAN}Press Enter to continue... " < /dev/tty
    fi
}

cmd_start() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull start <name>"
        exit 1
    }
    start_vm "${VM_NAME}"
}

cmd_stop() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull stop <name>"
        exit 1
    }
    stop_vm "${VM_NAME}"
}

cmd_destroy() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull destroy <name>"
        exit 1
    }
    destroy_vm "${VM_NAME}"
}

cmd_connect() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull connect <name>"
        exit 1
    }
    connect_vm "${VM_NAME}"
}

cmd_snapshot() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull snapshot <name> [label]"
        exit 1
    }
    snapshot_vm "${VM_NAME}" "${EXTRA_ARG}"
}

cmd_restore() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull restore <name> <label>"
        exit 1
    }
    require_argument "${EXTRA_ARG}" "snapshot label" || {
        echo "Usage: bull restore <name> <label>"
        exit 1
    }
    restore_snapshot "${VM_NAME}" "${EXTRA_ARG}"
}

cmd_vpn() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull vpn <name> <config.ovpn>"
        exit 1
    }
    require_argument "${EXTRA_ARG}" "VPN config file" || {
        echo "Usage: bull vpn <name> <config.ovpn>"
        exit 1
    }
    configure_vpn "${VM_NAME}" "${EXTRA_ARG}"
}

cmd_status() {
    show_status
}

cmd_sync() {
    inventory_sync
}

cmd_view() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull view <name>"
        exit 1
    }
    view_vm "${VM_NAME}"
}

cmd_show_pass() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull show-pass <name>"
        exit 1
    }
    _credentials_show "${VM_NAME}"
}

cmd_toolkit() {
    require_argument "${VM_NAME}" "vm name" || {
        echo "Usage: bull toolkit <name> <git-url>"
        exit 1
    }
    require_argument "${EXTRA_ARG}" "toolkit Git URL" || {
        echo "Usage: bull toolkit <name> <git-url>"
        exit 1
    }
    install_toolkit "${VM_NAME}" "${EXTRA_ARG}"
}

# =============================================================================
# TUI RENDER — clears screen, centers menu vertically, anchors prompt at bottom
# =============================================================================
_tui_render() {
    local rendered
    rendered=$(display_banner_with_menu)

    # Go to top-left and erase everything below
    printf '\033[H\033[J'

    # Print menu starting at the top, prompt immediately below
    printf '%s\n' "${rendered}"
    printf '\n'
    printf '\033[?25h'   # show cursor at prompt position only
    printf "  %s%sBULL > %s" "${BOLD}" "${BRIGHT_CYAN}" "${RESET}"
}

# =============================================================================
# INTERACTIVE MAIN LOOP
# =============================================================================
interactive_loop() {
    # Enter alternate screen buffer (preserves the user's previous terminal content)
    printf '\033[?1049h'
    # Hide cursor during splash + initial render
    printf '\033[?25l'
    # EXIT trap restores the terminal (triggered by the exit calls below too)
    trap '_tui_restore' EXIT
    # Ctrl+C / kill: call exit so the EXIT trap fires and cleans up
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    # Redraw on terminal resize (SIGWINCH)
    trap '_tui_render' SIGWINCH

    display_title_middle_screen
    sleep 2

    # Sync VM statuses against actual VirtualBox/Vagrant state at startup
    inventory_sync > /dev/null 2>&1 || true

    local choice
    while true; do
        printf '\033[?25l'   # hide cursor while redrawing
        _tui_render          # cursor is shown again inside _tui_render after drawing

        IFS= read -r choice || true   # read; SIGWINCH interrupts with empty choice

        [[ -z "${choice}" ]] && continue   # resize or empty → just redraw

        printf '\033[?25l'   # hide cursor while the action runs
        handle_menu_choice "${choice}" || true
    done
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================
main() {
    # Clear error log at start
    : > "${BULL_ERROR_LOG}" 2>/dev/null || true
    echo "[BULL] Starting..." >> "${BULL_ERROR_LOG}" 2>/dev/null || true

    setup_traps
    parse_arguments "$@"

    if [[ -z "${COMMAND}" ]]; then
        # Interactive mode: disable ERR trap to avoid TUI interference
        trap - ERR
        interactive_loop
    else
        # CLI mode: enable error log display
        show_error_log_on_err() {
            show_error_log
        }
        trap 'show_error_log_on_err' ERR
        execute_command
    fi
}

show_error_log() {
    if [[ -f "${BULL_ERROR_LOG}" ]] && [[ -s "${BULL_ERROR_LOG}" ]]; then
        echo "" >&2
        echo -e "${RED}=== Error Log ===${RESET}" >&2
        echo "Full log: ${BULL_ERROR_LOG}" >&2
        tail -30 "${BULL_ERROR_LOG}" 2>/dev/null >&2
        echo "" >&2
    fi
}

main "$@"
