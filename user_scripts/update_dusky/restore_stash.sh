#!/usr/bin/env bash
# ==============================================================================
#  DUSKY SMART RESTORE & STASH MANAGER
#  Description: Intelligent interface for managing dotfile backups and stashes.
#               Distinguishes between auto-updates, recovery snapshots, and
#               manual edits. Safely restores states even with dirty work trees.
#  Context:     Arch Linux / Hyprland / Bash 5+ / UWSM Compliant
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------
readonly GIT_BIN="/usr/bin/git"
readonly DOTFILES_GIT_DIR="${HOME}/dusky"
readonly WORK_TREE="${HOME}"
readonly RESTORE_DIR_BASE="${HOME}/Documents/dusky_restores"

# State: Populated by list_stashes(), consumed by main()
declare -a STASH_LIST=()

# ------------------------------------------------------------------------------
# VISUAL CONFIGURATION
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly C_RESET=$'\e[0m'
    readonly C_BOLD=$'\e[1m'
    readonly C_DIM=$'\e[2m'
    readonly C_RED=$'\e[31m'
    readonly C_GREEN=$'\e[32m'
    readonly C_YELLOW=$'\e[33m'
    readonly C_BLUE=$'\e[34m'
    readonly C_MAGENTA=$'\e[35m'
    readonly C_CYAN=$'\e[36m'
else
    readonly C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN=''
    readonly C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
fi

# ------------------------------------------------------------------------------
# UTILITIES
# ------------------------------------------------------------------------------
log_info() { printf '%s[INFO]%s  %s\n' "${C_BLUE}" "${C_RESET}" "$1"; }
log_ok()   { printf '%s[OK]%s    %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn() { printf '%s[WARN]%s  %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
log_err()  { printf '%s[ERR]%s   %s\n' "${C_RED}" "${C_RESET}" "$1" >&2; }

# Wrapper for bare repository commands
dotgit() {
    "${GIT_BIN}" --git-dir="${DOTFILES_GIT_DIR}" --work-tree="${WORK_TREE}" "$@"
}

# ------------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ------------------------------------------------------------------------------
if [[ ! -d "${DOTFILES_GIT_DIR}" ]]; then
    log_err "Repository not found at ${DOTFILES_GIT_DIR}"
    exit 1
fi

if [[ -f "${DOTFILES_GIT_DIR}/index.lock" ]]; then
    log_err "Git is locked (index.lock exists)."
    log_warn "Run: rm -f ${DOTFILES_GIT_DIR}/index.lock"
    exit 1
fi

# ------------------------------------------------------------------------------
# UI COMPONENTS
# ------------------------------------------------------------------------------
print_header() {
    clear
    printf '%s================================================================%s\n' "${C_BLUE}" "${C_RESET}"
    printf '%s   DUSKY SMART RESTORE UTILITY%s\n' "${C_BOLD}${C_MAGENTA}" "${C_RESET}"
    printf '%s   Review, Export, and Restore your System Snapshots%s\n' "${C_DIM}" "${C_RESET}"
    printf '%s================================================================%s\n\n' "${C_BLUE}" "${C_RESET}"
}

# ------------------------------------------------------------------------------
# STASH PARSING & LISTING
# ------------------------------------------------------------------------------
list_stashes() {
    mapfile -t STASH_LIST < <(dotgit stash list)

    if [[ ${#STASH_LIST[@]} -eq 0 ]]; then
        printf '  %sNo stashes found. Your git stack is clean.%s\n\n' "${C_YELLOW}" "${C_RESET}"
        exit 0
    fi

    printf '  %s%-5s %-12s %-25s %s%s\n' "${C_DIM}" "ID" "TYPE" "TIMESTAMP/ID" "MESSAGE" "${C_RESET}"
    printf '  %s----------------------------------------------------------------%s\n' "${C_DIM}" "${C_RESET}"

    local i=0
    local line msg_raw msg
    local label color time_display clean_msg
    local tmp_date

    for line in "${STASH_LIST[@]}"; do
        # --- Pure Bash Parsing ---
        # Git stash format: "stash@{N}: On <branch>: <message>"
        #               or: "stash@{N}: WIP on <branch>: <hash> <message>"
        
        # 1. Get everything after the stash ref (remove "stash@{N}: ")
        msg_raw="${line#*: }"

        # 2. Get the actual message payload (remove branch info "On main: ")
        #    We keep msg_raw for checking the *type* of stash later.
        msg="${msg_raw#*: }"

        # 3. Trim leading whitespace from the display message
        msg="${msg#"${msg%%[![:space:]]*}"}"

        # --- Heuristic Analysis ---
        label=""
        color=""
        time_display=""
        clean_msg="${msg}"

        if [[ "${msg}" =~ orchestrator-auto-([0-9_\-]+) ]]; then
            label="UPDATE"
            color="${C_CYAN}"
            time_display="${BASH_REMATCH[1]}"
            clean_msg="Auto-Backup during system update"
        elif [[ "${msg}" =~ recovery-backup-([0-9]+) ]]; then
            label="RECOVER"
            color="${C_RED}"
            # Convert epoch to readable, with fallback
            if tmp_date=$(date -d "@${BASH_REMATCH[1]}" +'%Y-%m-%d %H:%M' 2>/dev/null); then
                time_display="${tmp_date}"
            else
                time_display="${BASH_REMATCH[1]}"
            fi
            clean_msg="Emergency snapshot from Force Sync"
        # Check msg_raw because 'WIP on'/'On' was stripped from 'msg'
        elif [[ "${msg_raw}" == "WIP on "* ]] || [[ "${msg_raw}" == "On "* ]]; then
            label="MANUAL"
            color="${C_BLUE}"
            time_display="--"
            clean_msg="Manual Save state / Work in Progress"
        else
            label="CUSTOM"
            color="${C_MAGENTA}"
            time_display="--"
        fi

        printf '  %s[%d]%s   %s%-10s%s   %-25s %s%s%s\n' \
            "${C_BOLD}" "${i}" "${C_RESET}" \
            "${color}" "${label}" "${C_RESET}" \
            "${time_display:0:24}" \
            "${C_DIM}" "${clean_msg:0:40}" "${C_RESET}"

        ((++i))
    done
    printf '\n'
}

# ------------------------------------------------------------------------------
# CORE LOGIC
# ------------------------------------------------------------------------------

# Resolve stash index to its immutable SHA.
get_stash_hash() {
    local idx="$1"
    local sha

    if ! sha=$(dotgit rev-parse "stash@{${idx}}" 2>/dev/null); then
        log_err "Failed to resolve stash@{${idx}}. It may have been dropped."
        return 1
    fi
    printf '%s' "${sha}"
}

# Export stash contents to a timestamped directory for inspection.
export_stash() {
    local stash_sha="$1"
    local restore_path="${RESTORE_DIR_BASE}/restored_backup_$(date +%Y%m%d_%H%M%S)"

    printf '\n%s[EXPORT MODE]%s\n' "${C_BLUE}" "${C_RESET}"
    log_info "Preparing to export files from snapshot (${stash_sha:0:12})..."

    if ! mkdir -p "${restore_path}"; then
        log_err "Failed to create directory: ${restore_path}"
        return 1
    fi

    if dotgit archive "${stash_sha}" | tar -x -C "${restore_path}"; then
        log_ok "Export successful!"
        printf '\n%s Files are located at:%s\n' "${C_GREEN}" "${C_RESET}"
        printf '  %s%s%s\n\n' "${C_BOLD}" "${restore_path}" "${C_RESET}"

        local open_choice
        read -r -p "  View exported files? [y/N] " open_choice
        if [[ "${open_choice}" =~ ^[Yy]$ ]]; then
            if command -v yazi &>/dev/null; then
                # TUI app: runs in current terminal
                yazi "${restore_path}"
            elif command -v ranger &>/dev/null; then
                # TUI app: runs in current terminal
                ranger "${restore_path}"
            elif command -v thunar &>/dev/null; then
                # GUI app: UWSM-compliant launch
                uwsm-app -- thunar "${restore_path}" &
                disown
            else
                ls -lA "${restore_path}"
            fi
        fi
    else
        log_err "Export failed. Please check permissions for ${restore_path}."
        return 1
    fi
}

# Apply a stash to the working tree, with automatic safety backup for dirty state.
apply_stash() {
    local stash_sha="$1"
    local confirm

    printf '\n%s[RESTORE MODE]%s\n' "${C_RED}" "${C_RESET}"
    printf '  You are about to overwrite your current configuration with an older snapshot.\n'

    # Check for dirty state
    if ! dotgit diff-index --quiet HEAD --; then
        printf '  %s[!] Local changes detected in your working directory.%s\n' "${C_YELLOW}" "${C_RESET}"
        printf '      Applying a stash now would normally fail or cause conflicts.\n'
        printf '      %sDusky Auto-Safety%s will stash these changes for you first.\n\n' "${C_GREEN}" "${C_RESET}"

        read -r -p "  Proceed with Safety Stash & Restore? [y/N] " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            log_info "Aborted by user."
            return 0
        fi

        log_info "Creating Safety Stash of current state..."
        if dotgit stash push -m "Safety-Stash-Before-Restore-$(date +%s)"; then
            log_ok "Current state saved. Working directory is clean."
        else
            log_err "Failed to create safety stash. Aborting to protect data."
            return 1
        fi
    else
        read -r -p "  Proceed with Restore? [y/N] " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            log_info "Aborted by user."
            return 0
        fi
    fi

    log_info "Applying snapshot (${stash_sha:0:12})..."

    # Use 'apply' instead of 'pop': keeps the backup in the stack for safety.
    if dotgit stash apply "${stash_sha}"; then
        printf '\n'
        log_ok "Configuration successfully restored!"
        printf '  The stash entry was kept in the list for safety.\n'
        printf '  If you are happy with the result, you can drop it manually.\n'
    else
        printf '\n'
        log_warn "Restore completed with CONFLICTS."
        printf '  Git could not auto-merge some files.\n'
        printf '  1. Open the files marked as "modified" to resolve conflicts.\n'
        printf '  2. Run "git add <file>" when fixed.\n'
        printf '  3. The backup snapshot is STILL in the stash list.\n'
    fi
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION
# ------------------------------------------------------------------------------
main() {
    print_header
    list_stashes # Populates global STASH_LIST

    local stash_count=${#STASH_LIST[@]}
    local idx

    printf 'Select a stash ID [0-%d] or "q" to quit: ' "$((stash_count - 1))"
    read -r idx

    [[ "${idx}" == "q" ]] && exit 0

    if [[ ! "${idx}" =~ ^[0-9]+$ ]] || ((idx >= stash_count)); then
        log_err "Invalid selection: '${idx}'"
        exit 1
    fi

    # Resolve SHA immediately to lock the target.
    # If we stash (action 1), indices shift, but this SHA remains valid.
    local target_sha
    if ! target_sha=$(get_stash_hash "${idx}"); then
        exit 1
    fi

    printf '\n%sSelected Stash:%s %s\n' "${C_BOLD}" "${C_RESET}" "${STASH_LIST[${idx}]}"
    printf 'Action:\n'
    printf '  %s[1]%s Overwrite/Restore System Config  %s(Safe Apply)%s\n' "${C_RED}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    printf '  %s[2]%s Export to Directory              %s(Inspect Files)%s\n' "${C_GREEN}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    printf '  %s[q]%s Quit\n' "${C_DIM}" "${C_RESET}"

    local action
    read -r -p "Choice > " action

    case "${action}" in
        1) apply_stash "${target_sha}" ;;
        2) export_stash "${target_sha}" ;;
        q) exit 0 ;;
        *) log_err "Invalid action: '${action}'"; exit 1 ;;
    esac
}

main
