#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky TUI Engine - Master Template v2.9.0 (Architecture Fixes)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM / Wayland
# Description: High-performance, robust TUI for config modification.
# Features:
#   - Secure `sed` Injection Prevention
#   - Nested Block Support (Fixes "Range Trap")
#   - Multiple Same-Name Block Support (Fixes "First Block Trap")
#   - Locale Safe (Fixes "Comma Bomb")
#   - Hyphen-Safe Pattern Escaping
#   - Terminal State Preservation (stty)
#   - Scrollable Viewport with Indicators
#   - Mouse Support (SGR 1006) with Scroll Wheel
#   - Page Up/Down, Home/End Navigation
#   - Visual "Unset" Detection for Debugging
#   - Post-Write Hook for Service Reloads
#   - FIXED: Mouse Regex Crash (v2.6.1)
#   - CRITICAL FIX: Navigation Exit Trap (v2.6.2)
#   - REFACTOR (v2.7.0): Split Grep/Sed escaping, fixed Navigate End trap.
#   - REFACTOR (v2.8.0): Consolidated write logic, Fixed Nameref Aliasing.
#   - HOTFIX (v2.8.1): Reverted mouse detection glob to fix click regression.
#   - FIX (v2.8.2): Fixed Duplicate Key Trap, Dependency crash, Mouse compat.
#   - ARCHITECTURE FIX (v2.9.0): Composite Keys (allow same label in multiple tabs).
#   - ROBUSTNESS (v2.9.0): Explicit stty blocking (prevents CPU spin).
#   - CLEANUP (v2.9.0): POSIX-safe arithmetic (removed `|| :` hacks).
# -----------------------------------------------------------------------------

set -euo pipefail

# CRITICAL FIX: The "Locale Bomb"
# Force standard C locale for numeric operations.
export LC_NUMERIC=C

# =============================================================================
# ▼ USER CONFIGURATION (EDIT THIS SECTION) ▼
# =============================================================================

readonly CONFIG_FILE="${HOME}/.config/hypr/change_me.conf"
readonly APP_TITLE="Dusky Template"
readonly APP_VERSION="v2.9.0"

# Dimensions & Layout
declare -ri MAX_DISPLAY_ROWS=14      # Rows of items to show before scrolling
declare -ri BOX_INNER_WIDTH=76       # Width of the UI box
declare -ri ITEM_START_ROW=5         # Row index where items begin rendering
declare -ri ADJUST_THRESHOLD=40      # X-pos threshold for mouse click adjustment
declare -ri ITEM_PADDING=32          # Text padding for labels

readonly -a TABS=("General" "Input" "Display" "Misc")

# Item Registration
# Syntax: register <tab_idx> "Label" "config_str" "DEFAULT_VALUE"
#
# config_str format: "key|type|block|min|max|step"
#   - key:   The config key name (e.g., "sensitivity", "tap-to-click")
#   - type:  bool, int, float, or cycle
#   - block: The block name containing this key (e.g., "input", "touchpad")
#   - min:   For int/float: minimum value. For cycle: comma-separated options
#   - max:   For int/float: maximum value. For cycle: unused
#   - step:  For int/float: increment step. For cycle: unused
#
register_items() {
    register 0 "Enable Logs"    'logs_enabled|bool|general|||'       "true"
    register 0 "Timeout (ms)"   'timeout|int|general|0|1000|50'      "100"
    register 1 "Sensitivity"    'sensitivity|float|input|-1.0|1.0|0.1' "0.0"
    register 2 "Accel Profile"  'accel_profile|cycle|input|flat,adaptive,custom||' "adaptive"
    register 2 "Border Size"    'border_size|int||0|10|1'            "2"
    register 3 "Shadow Color"   'col.shadow|cycle|general|0xee1a1a1a,0xff000000||' "0xee1a1a1a"
}

# -----------------------------------------------------------------------------
# Post-Write Hook
# This function is called IMMEDIATELY after a value is successfully written.
# -----------------------------------------------------------------------------
post_write_action() {
    # Example: Reload Waybar if it's running
    # pgrep -x waybar >/dev/null && killall -SIGUSR2 waybar
    : # Do nothing by default
}

# =============================================================================
# ▲ END OF USER CONFIGURATION ▲
# =============================================================================

# --- Pre-computed Constants ---
declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
readonly H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

# --- ANSI Constants ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_EOL=$'\033[K'
readonly CLR_EOS=$'\033[J'
readonly CLR_SCREEN=$'\033[2J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# Timeout for reading escape sequences (in seconds)
readonly ESC_READ_TIMEOUT=0.02

# Internal marker for unset values
readonly UNSET_MARKER='«unset»'

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

# --- Data Structures ---
declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()

# Provisioned Tab Containers
# shellcheck disable=SC2034
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() TAB_ITEMS_3=() TAB_ITEMS_4=()
# shellcheck disable=SC2034
declare -a TAB_ITEMS_5=() TAB_ITEMS_6=() TAB_ITEMS_7=() TAB_ITEMS_8=() TAB_ITEMS_9=()

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

cleanup() {
    # Restore terminal state
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
    
    # Robustly restore original stty settings
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    printf '\n'
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Regex & Escaping ---

escape_sed_replacement() {
    local _esc_input=$1
    local -n _esc_out_ref=$2
    _esc_input=${_esc_input//\\/\\\\}
    _esc_input=${_esc_input//|/\\|}
    _esc_input=${_esc_input//&/\\&}
    _esc_input=${_esc_input//$'\n'/\\n}
    _esc_out_ref=$_esc_input
}

escape_sed_pattern() {
    local _esc_input=$1
    local -n _esc_out_ref=$2
    _esc_input=${_esc_input//\\/\\\\}
    _esc_input=${_esc_input//|/\\|}
    _esc_input=${_esc_input//./\\.}
    _esc_input=${_esc_input//\*/\\*}
    _esc_input=${_esc_input//\[/\\[}
    _esc_input=${_esc_input//\]/\\]}
    _esc_input=${_esc_input//^/\\^}
    _esc_input=${_esc_input//\$/\\\$}
    _esc_out_ref=$_esc_input
}

# --- Core Engine ---

register() {
    local -i tab_idx=$1
    local label=$2 config=$3 default_val=${4:-}
    
    local key type block min max step
    IFS='|' read -r key type block min max step <<< "$config"

    # Validate type
    case "$type" in
        bool|int|float|cycle) ;;
        *)
            printf '%s[FATAL]%s Invalid type for "%s": "%s"\n' \
                   "$C_RED" "$C_RESET" "$label" "$type" >&2
            exit 1
            ;;
    esac

    if (( tab_idx < 0 || tab_idx > 9 )); then
        printf '%s[FATAL]%s Tab index %d out of bounds\n' \
               "$C_RED" "$C_RESET" "$tab_idx" >&2
        exit 1
    fi

    # CRITICAL FIX v2.9.0: Composite Keys
    # Use Tab::Label as the key to allow identical labels in different tabs
    ITEM_MAP["${tab_idx}::${label}"]=$config
    [[ -n "$default_val" ]] && DEFAULTS["${tab_idx}::${label}"]=$default_val

    # shellcheck disable=SC2178
    local -n _reg_tab_ref="TAB_ITEMS_${tab_idx}"
    # shellcheck disable=SC2034
    _reg_tab_ref+=("$label")
}

populate_config_cache() {
    CONFIG_CACHE=()
    local key_part value_part key_name

    while IFS='=' read -r key_part value_part || [[ -n ${key_part:-} ]]; do
        [[ -z ${key_part:-} ]] && continue
        CONFIG_CACHE["$key_part"]=$value_part

        key_name=${key_part%%|*}
        if [[ -z ${CONFIG_CACHE["$key_name|"]:-} ]]; then
            CONFIG_CACHE["$key_name|"]=$value_part
        fi
    done < <(awk '
        BEGIN { depth = 0 }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/#.*/, "", line)

            tmpline = line
            while (match(tmpline, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                block_str = substr(tmpline, RSTART, RLENGTH)
                sub(/[[:space:]]*\{/, "", block_str)
                depth++
                block_stack[depth] = block_str
                tmpline = substr(tmpline, RSTART + RLENGTH)
            }

            if (line ~ /=/) {
                eq_pos = index(line, "=")
                if (eq_pos > 0) {
                    key = substr(line, 1, eq_pos - 1)
                    val = substr(line, eq_pos + 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    if (key != "") {
                        current_block = (depth > 0) ? block_stack[depth] : ""
                        print key "|" current_block "=" val
                    }
                }
            }

            n = gsub(/\}/, "}", line)
            while (n > 0 && depth > 0) { depth--; n-- }
        }
    ' "$CONFIG_FILE")
}

find_key_line_in_block() {
    local block_name=$1 key_name=$2 file=$3

    awk -v target_block="$block_name" -v target_key="$key_name" '
    BEGIN { depth = 0; in_target = 0; target_depth = 0 }
    {
        clean = $0; sub(/#.*/, "", clean)
        tmpline = clean
        while (match(tmpline, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
            block_str = substr(tmpline, RSTART, RLENGTH)
            sub(/[[:space:]]*\{/, "", block_str)
            depth++
            if (block_str == target_block && !in_target) {
                in_target = 1; target_depth = depth
            }
            tmpline = substr(tmpline, RSTART + RLENGTH)
        }
        if (in_target && clean ~ /=/) {
            eq_pos = index(clean, "=")
            if (eq_pos > 0) {
                k = substr(clean, 1, eq_pos - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                if (k == target_key) print NR
            }
        }
        n = gsub(/\}/, "}", clean)
        while (n > 0 && depth > 0) {
            if (in_target && depth == target_depth) { in_target = 0; target_depth = 0 }
            depth--; n--
        }
    }
    ' "$file"
}

write_value_to_file() {
    local key=$1 new_val=$2 block=${3:-}
    local current_val=${CONFIG_CACHE["$key|$block"]:-}
    
    [[ "$current_val" == "$new_val" ]] && return 0

    local safe_val safe_sed_key
    escape_sed_replacement "$new_val" safe_val
    escape_sed_pattern "$key" safe_sed_key

    if [[ -n $block ]]; then
        local target_output
        target_output=$(find_key_line_in_block "$block" "$key" "$CONFIG_FILE")
        [[ -z $target_output ]] && return 1
        
        local target_line
        while IFS= read -r target_line; do
            if [[ ! $target_line =~ ^[0-9]+$ ]] || (( target_line == 0 )); then continue; fi
            sed --follow-symlinks -i \
                "${target_line}s|^\([[:space:]]*${safe_sed_key}[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_val} |" \
                "$CONFIG_FILE"
        done <<< "$target_output"
    else
        sed --follow-symlinks -i \
            "s|^\([[:space:]]*${safe_sed_key}[[:space:]]*=[[:space:]]*\)[^#]*|\1${safe_val} |" \
            "$CONFIG_FILE"
    fi

    CONFIG_CACHE["$key|$block"]=$new_val
    [[ -z $block ]] && CONFIG_CACHE["$key|"]=$new_val
    return 0
}

load_tab_values() {
    # shellcheck disable=SC2178
    local -n _ltv_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${_ltv_items_ref[@]}"; do
        # v2.9.0: Composite Key Lookup
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP["${CURRENT_TAB}::${item}"]}"
        
        val=${CONFIG_CACHE["$key|$block"]:-}
        if [[ -z $val && -z $block ]]; then
            val=${CONFIG_CACHE["$key|"]:-}
        fi
        
        if [[ -z $val ]]; then
            VALUE_CACHE["${CURRENT_TAB}::${item}"]=$UNSET_MARKER
        else
            VALUE_CACHE["${CURRENT_TAB}::${item}"]=$val
        fi
    done
}

modify_value() {
    local label=$1
    local -i direction=$2
    local key type block min max step current new_val

    # v2.9.0: Composite Key Lookup
    IFS='|' read -r key type block min max step <<< "${ITEM_MAP["${CURRENT_TAB}::${label}"]}"
    current=${VALUE_CACHE["${CURRENT_TAB}::${label}"]:-}
    
    if [[ $current == "$UNSET_MARKER" || -z $current ]]; then
        current=${DEFAULTS["${CURRENT_TAB}::${label}"]:-}
        [[ -z $current ]] && current=${min:-0}
    fi

    case $type in
        int)
            if [[ ! $current =~ ^-?[0-9]+$ ]]; then current=${min:-0}; fi
            local -i int_step=${step:-1} int_val=$current
            # v2.9.0: Safe Arithmetic
            int_val=$(( int_val + direction * int_step ))
            
            if [[ -n $min ]] && (( int_val < min )); then int_val=$min; fi
            if [[ -n $max ]] && (( int_val > max )); then int_val=$max; fi
            new_val=$int_val
            ;;
        float)
            if [[ ! $current =~ ^-?[0-9]*\.?[0-9]+$ ]]; then current=${min:-0.0}; fi
            new_val=$(awk -v c="$current" -v dir="$direction" -v s="${step:-0.1}" \
                          -v mn="$min" -v mx="$max" 'BEGIN {
                val = c + (dir * s)
                if (mn != "" && val < mn) val = mn
                if (mx != "" && val > mx) val = mx
                printf "%.4g", val
            }')
            ;;
        bool)
            if [[ $current == "true" ]]; then new_val="false"; else new_val="true"; fi
            ;;
        cycle)
            local -a opts
            IFS=',' read -r -a opts <<< "$min"
            local -i count=${#opts[@]} idx=0 i
            (( count == 0 )) && return 0

            for (( i = 0; i < count; i++ )); do
                if [[ "${opts[i]}" == "$current" ]]; then idx=$i; break; fi
            done
            
            # v2.9.0: Safe Arithmetic
            idx=$(( idx + direction ))
            (( idx < 0 )) && idx=$(( count - 1 ))
            (( idx >= count )) && idx=0
            new_val=${opts[idx]}
            ;;
        *) return 0 ;;
    esac

    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["${CURRENT_TAB}::${label}"]=$new_val
        post_write_action
    fi
}

set_absolute_value() {
    local label=$1 new_val=$2
    local key type block

    # v2.9.0: Composite Key Lookup
    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP["${CURRENT_TAB}::${label}"]}"
    
    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["${CURRENT_TAB}::${label}"]=$new_val
        return 0
    fi
    return 1
}

reset_defaults() {
    # shellcheck disable=SC2178
    local -n _rd_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val
    local -i any_written=0

    for item in "${_rd_items_ref[@]}"; do
        # v2.9.0: Composite Key Lookup for Default
        def_val=${DEFAULTS["${CURRENT_TAB}::${item}"]:-}
        if [[ -n $def_val ]]; then
            if set_absolute_value "$item" "$def_val"; then
                any_written=1
            fi
        fi
    done

    if (( any_written )); then post_write_action; fi
    return 0
}

# --- UI Rendering ---

draw_ui() {
    local buf="" pad_buf="" padded_item="" item val display
    local -i i current_col=3 zone_start len count pad_needed
    local -i visible_len left_pad right_pad
    local -i visible_start visible_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}"$'\n'

    visible_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}"$'\n'

    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()

    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        len=${#name}
        zone_start=$current_col

        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi

        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        # v2.9.0: Safe Arithmetic
        current_col=$(( current_col + len + 4 ))
    done

    pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 ))
    if (( pad_needed > 0 )); then
        printf -v pad_buf '%*s' "$pad_needed" ''
        tab_line+="${pad_buf}"
    fi
    tab_line+="${C_MAGENTA}│${C_RESET}"

    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}"$'\n'

    # shellcheck disable=SC2178
    local -n _draw_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    count=${#_draw_items_ref[@]}

    if (( count == 0 )); then
        SELECTED_ROW=0; SCROLL_OFFSET=0
    else
        (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
        (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))

        if (( SELECTED_ROW < SCROLL_OFFSET )); then
            SCROLL_OFFSET=$SELECTED_ROW
        elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
            SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
        fi

        local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
        (( max_scroll < 0 )) && max_scroll=0
        (( SCROLL_OFFSET > max_scroll )) && SCROLL_OFFSET=$max_scroll
    fi

    visible_start=$SCROLL_OFFSET
    visible_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    (( visible_end > count )) && visible_end=$count

    if (( SCROLL_OFFSET > 0 )); then
        buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    for (( i = visible_start; i < visible_end; i++ )); do
        item=${_draw_items_ref[i]}
        # v2.9.0: Composite Key Lookup
        val=${VALUE_CACHE["${CURRENT_TAB}::${item}"]:-$UNSET_MARKER}

        case $val in
            true)              display="${C_GREEN}ON${C_RESET}" ;;
            false)             display="${C_RED}OFF${C_RESET}" ;;
            "$UNSET_MARKER")   display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
            *'$'*)             display="${C_MAGENTA}Dynamic${C_RESET}" ;;
            *)                 display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:$ITEM_PADDING}"

        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    local -i rows_rendered=$(( visible_end - visible_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    if (( count > MAX_DISPLAY_ROWS )); then
        local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
        if (( visible_end < count )); then
            buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        else
            buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"

    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    # shellcheck disable=SC2178
    local -n _nav_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#_nav_items_ref[@]}

    (( count == 0 )) && return 0
    # v2.9.0: Safe Arithmetic
    SELECTED_ROW=$(( SELECTED_ROW + dir ))

    (( SELECTED_ROW < 0 )) && SELECTED_ROW=$(( count - 1 ))
    (( SELECTED_ROW >= count )) && SELECTED_ROW=0
    return 0
}

navigate_page() {
    local -i dir=$1
    # shellcheck disable=SC2178
    local -n _navp_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#_navp_items_ref[@]}

    (( count == 0 )) && return 0
    # v2.9.0: Safe Arithmetic
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))

    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0
    (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))
    return 0
}

navigate_end() {
    local -i target=$1
    # shellcheck disable=SC2178
    local -n _nave_items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#_nave_items_ref[@]}

    (( count == 0 )) && return 0

    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
    return 0
}

adjust() {
    local -i dir=$1
    # shellcheck disable=SC2178
    local -n _adj_items_ref="TAB_ITEMS_${CURRENT_TAB}"

    (( ${#_adj_items_ref[@]} == 0 )) && return 0
    modify_value "${_adj_items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}

    # v2.9.0: Safe Arithmetic
    CURRENT_TAB=$(( CURRENT_TAB + dir ))
    
    (( CURRENT_TAB >= TAB_COUNT )) && CURRENT_TAB=0
    (( CURRENT_TAB < 0 )) && CURRENT_TAB=$(( TAB_COUNT - 1 ))

    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_tab_values
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        load_tab_values
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i start end
    local type zone

    local regex='^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$'

    if [[ $input =~ $regex ]]; then
        button=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
        y=${BASH_REMATCH[3]}
        type=${BASH_REMATCH[4]}

        if (( button == 64 )); then navigate -1; return 0; fi
        if (( button == 65 )); then navigate 1; return 0; fi

        [[ $type != "M" ]] && return 0

        if (( y == 3 )); then
            for (( i = 0; i < TAB_COUNT; i++ )); do
                zone=${TAB_ZONES[i]}
                start=${zone%%:*}
                end=${zone##*:}
                if (( x >= start && x <= end )); then set_tab "$i"; return 0; fi
            done
        fi

        # shellcheck disable=SC2178
        local -n _mouse_items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#_mouse_items_ref[@]}
        local -i item_row_start=$(( ITEM_START_ROW + 1 ))

        if (( y >= item_row_start && y < item_row_start + MAX_DISPLAY_ROWS )); then
            local -i clicked_idx=$(( y - item_row_start + SCROLL_OFFSET ))
            if (( clicked_idx >= 0 && clicked_idx < count )); then
                SELECTED_ROW=$clicked_idx
                if (( x > ADJUST_THRESHOLD )); then
                    if (( button == 0 )); then adjust 1; else adjust -1; fi
                fi
            fi
        fi
    fi
    return 0
}

# --- Main ---

main() {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        printf '%s[FATAL]%s Bash 4.3+ required (found %s)\n' \
               "$C_RED" "$C_RESET" "$BASH_VERSION" >&2
        exit 1
    fi

    if [[ ! -f $CONFIG_FILE ]]; then log_err "Config not found: $CONFIG_FILE"; exit 1; fi
    if [[ ! -r $CONFIG_FILE ]]; then log_err "Config not readable: $CONFIG_FILE"; exit 1; fi
    if [[ ! -w $CONFIG_FILE ]]; then log_err "Config not writable: $CONFIG_FILE"; exit 1; fi

    local _dep
    for _dep in awk sed; do
        if ! command -v "$_dep" &>/dev/null; then
            log_err "Required dependency not found: ${_dep}"
            exit 1
        fi
    done

    register_items
    populate_config_cache

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    
    # CRITICAL FIX v2.9.0: Explicitly enforce blocking mode to prevent CPU spin
    stty -icanon -echo min 1 time 0 2>/dev/null || :

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    load_tab_values

    local key seq char

    while true; do
        draw_ui

        IFS= read -rsn1 key || break

        if [[ $key == $'\x1b' ]]; then
            seq=""
            while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
                seq+="$char"
            done

            case $seq in
                '[Z')          switch_tab -1 ;;
                '[A'|'OA')     navigate -1 ;;
                '[B'|'OB')     navigate 1 ;;
                '[C'|'OC')     adjust 1 ;;
                '[D'|'OD')     adjust -1 ;;
                '[5~')         navigate_page -1 ;;
                '[6~')         navigate_page 1 ;;
                '[H'|'[1~')    navigate_end 0 ;;
                '[F'|'[4~')    navigate_end 1 ;;
                '['*'<'*)      handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)           navigate -1 ;;
                j|J)           navigate 1 ;;
                l|L)           adjust 1 ;;
                h|H)           adjust -1 ;;
                g)             navigate_end 0 ;;
                G)             navigate_end 1 ;;
                $'\t')         switch_tab 1 ;;
                r|R)           reset_defaults ;;
                q|Q|$'\x03')   break ;;
            esac
        fi
    done
}

main "$@"
