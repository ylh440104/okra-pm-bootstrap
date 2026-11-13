#!/bin/bash
# Full-screen TUI for OKRAINSTALL. Bash and ANSI only (no dialog, no grep).

UI_STAGE=1
UI_TITLE='OKRAINSTALL'
UI_BODY=()
UI_BAR_WIDTH=46

# systemd opens TTYPath as stdin/stdout but TIOCSCTTY can fail. /dev/tty then
# returns ENXIO, so every frame was discarded and the VGA window stayed on the
# kernel log. Bind the VGA virtual terminal itself and write to stdout.
#
# Only when a virtual terminal is what the operator is looking at. A machine
# reached over a serial line has no tty1 in front of anyone, and moving the
# stream there hid the installer from the only console that could answer it.
ui_claim_console() {
    [ -n "${UI_CLAIMED+x}" ] && return 0
    UI_CLAIMED=1
    if [ -w /proc/sys/kernel/printk ]; then
        printf '1 4 1 7\n' >/proc/sys/kernel/printk 2>/dev/null || true
    fi
    # A serial console is detected by the device the service was handed. When
    # stdin is already a terminal, believe it and stay where we are.
    local target=tty1
    if [ -n "${OKRAINSTALL_TTY:-}" ]; then
        target=$OKRAINSTALL_TTY
    elif [ -t 0 ] && [ -c /dev/console ] && ! [ -c /dev/tty1 ]; then
        target=console
    fi
    if [ "$target" != console ] && [ -w /sys/class/tty/tty0/active ]; then
        printf '%s\n' "${target#tty}" >/sys/class/tty/tty0/active 2>/dev/null || true
    fi
    if [ -c "/dev/$target" ]; then
        exec <"/dev/$target" >"/dev/$target" 2>&1 || true
    fi
}

ui_restore_term() {
    ui_tty || return 0
    printf '\033[?25h' || true
    stty echo icanon 2>/dev/null || true
}

ui_tty() {
    if [ -z "${UI_TTY_OK+x}" ]; then
        ui_claim_console
        if [ -t 1 ]; then
            UI_TTY_OK=1
        else
            UI_TTY_OK=0
        fi
    fi
    [ "$UI_TTY_OK" -eq 1 ]
}

ui_out() {
    ui_tty || true
    printf '%s' "$*"
}

ui_clear() {
    ui_out $'\033[2J\033[H\033[?25l'
}

ui_frame() {
    local stage=${1:-$UI_STAGE}
    local title=${2:-$UI_TITLE}
    UI_STAGE=$stage
    UI_TITLE=$title
    if ! ui_tty; then
        printf '\n== stage %s/3  %s ==\n' "$stage" "$title"
        return
    fi
    ui_clear
    ui_out $'\n  OKRAINSTALL\n'
    ui_out "  Stage ${stage}/3    ${title}"$'\n'
    ui_out $'  ------------------------------------------------\n\n'
    printf 'okrainstall: tty1 stage %s %s\n' "$stage" "$title" >/dev/kmsg 2>/dev/null || true
}

trap 'ui_restore_term' EXIT INT TERM

ui_text() {
    local line
    UI_STAGE=$1
    UI_TITLE=$2
    shift 2
    UI_BODY=()
    for line in "$@"; do
        UI_BODY+=("$line")
    done
    ui_frame "$UI_STAGE" "$UI_TITLE"
    for line in "${UI_BODY[@]}"; do
        ui_out "  ${line}"$'\n'
    done
    ui_out $'\n'
}

ui_msg() {
    ui_out "  $*"$'\n'
}

ui_pause() {
    local prompt=${1:-Press Enter to continue}
    if ! ui_tty; then
        printf '%s\n' "$prompt"
        read -r _ || true
        return
    fi
    ui_out "  ${prompt}"$'\n'
    ui_restore_term
    read -r _ || true
    ui_out $'\033[?25l'
}

ui_read_key() {
    local k seq
    IFS= read -rsn1 k || return 1
    if [ "$k" = $'\033' ]; then
        if ! IFS= read -rsn1 -t 0.05 seq; then
            printf 'esc'
            return 0
        fi
        if [ "$seq" = '[' ]; then
            IFS= read -rsn1 -t 0.05 seq || seq=
            case "$seq" in
                A) printf 'up' ;;
                B) printf 'down' ;;
                *) printf 'esc' ;;
            esac
        else
            printf 'esc'
        fi
        return 0
    fi
    case "$k" in
        ''|$'\n'|$'\r'|' ') printf 'enter' ;;
        q|Q) printf 'quit' ;;
        k|K) printf 'up' ;;
        j|J) printf 'down' ;;
        y|Y) printf 'yes' ;;
        n|N) printf 'no' ;;
        *) printf 'other' ;;
    esac
}

# ui_menu TITLE PROMPT item...
# Sets UI_CHOICE. Returns 1 if cancelled.
ui_menu() {
    local title=$1
    local prompt=$2
    shift 2
    local -a items=("$@")
    local sel=0 key i

    if [ "${#items[@]}" -eq 0 ]; then
        return 1
    fi

    if ! ui_tty; then
        printf '%s\n%s\n' "$title" "$prompt"
        select UI_CHOICE in "${items[@]}"; do
            [ -n "${UI_CHOICE:-}" ] && return 0
            printf 'invalid selection\n' >&2
        done
        return 1
    fi

    stty -echo -icanon time 0 min 1
    while true; do
        ui_frame "$UI_STAGE" "$title"
        if [ "${#UI_BODY[@]}" -gt 0 ]; then
            for i in "${UI_BODY[@]}"; do
                ui_out "  ${i}"$'\n'
            done
            ui_out $'\n'
        fi
        ui_out "  ${prompt}"$'\n\n'
        for i in "${!items[@]}"; do
            if [ "$i" -eq "$sel" ]; then
                ui_out "$(printf '  \033[7m > %s \033[0m\n' "${items[$i]}")"
            else
                ui_out "    ${items[$i]}"$'\n'
            fi
        done
        ui_out $'\n  Up/Down move    Enter select    q cancel\n'
        key=$(ui_read_key) || { ui_restore_term; return 1; }
        case "$key" in
            up)
                sel=$((sel - 1))
                [ "$sel" -lt 0 ] && sel=$((${#items[@]} - 1))
                ;;
            down)
                sel=$((sel + 1))
                [ "$sel" -ge ${#items[@]} ] && sel=0
                ;;
            enter|yes)
                UI_CHOICE=${items[$sel]}
                ui_restore_term
                ui_out $'\033[?25l'
                return 0
                ;;
            quit|esc|no)
                ui_restore_term
                return 1
                ;;
        esac
    done
}

ui_yesno() {
    local prompt=$1
    local default=${2:-y}
    local -a items=('Yes' 'No')
    local saved_title=$UI_TITLE

    if ! ui_tty; then
        local answer
        if [ "$default" = y ]; then
            read -r -p "$prompt [Y/n] " answer
            case "$answer" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
        fi
        read -r -p "$prompt [y/N] " answer
        case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
    fi

    UI_TITLE=$saved_title
    if [ "$default" = n ]; then
        ui_menu "$UI_TITLE" "$prompt" 'No' 'Yes' || return 1
        [ "$UI_CHOICE" = 'Yes' ]
        return
    fi
    ui_menu "$UI_TITLE" "$prompt" 'Yes' 'No' || return 1
    [ "$UI_CHOICE" = 'Yes' ]
}

ui_confirm() {
    ui_yesno "${1:-Continue?}" n
}

ui_input() {
    local prompt=$1
    local default=${2:-}
    ui_frame "$UI_STAGE" "$UI_TITLE"
    ui_out "  ${prompt}"$'\n'
    if [ -n "$default" ]; then
        ui_out "  default: ${default}"$'\n'
    fi
    ui_out $'\n  > '
    printf 'okrainstall: tty1 input: %s\n' "$prompt" >/dev/kmsg 2>/dev/null || true
    ui_restore_term
    IFS= read -r UI_VALUE || UI_VALUE=
    if [ -z "$UI_VALUE" ]; then
        UI_VALUE=$default
    fi
    ui_out $'\033[?25l'
}

ui_password() {
    local prompt=$1
    ui_frame "$UI_STAGE" "$UI_TITLE"
    ui_out "  ${prompt}"$'\n\n  > '
    printf 'okrainstall: tty1 input: %s\n' "$prompt" >/dev/kmsg 2>/dev/null || true
    ui_restore_term
    IFS= read -rs UI_VALUE || UI_VALUE=
    ui_out $'\n\033[?25l'
}

ui_gauge() {
    local stage=$1
    local title=$2
    local pct=$3
    local label=$4
    local filled empty i bar

    case "$pct" in
        ''|*[!0-9]*) pct=0 ;;
    esac
    [ "$pct" -gt 100 ] && pct=100

    filled=$((pct * UI_BAR_WIDTH / 100))
    empty=$((UI_BAR_WIDTH - filled))
    bar=
    for ((i = 0; i < filled; i++)); do bar+='#'; done
    for ((i = 0; i < empty; i++)); do bar+='.'; done

    if ! ui_tty; then
        printf 'progress %s%%  %s\n' "$pct" "$label"
        return
    fi

    ui_frame "$stage" "$title"
    ui_out "  ${label}"$'\n\n'
    ui_out "$(printf '  [%s] %3d%%\n' "$bar" "$pct")"
    ui_out $'\n  Do not power off.\n'
}

ui_error() {
    ui_text "${UI_STAGE:-!}" 'Error' "$*" '' 'Press Enter to exit.'
    ui_pause 'Press Enter to exit.'
}

# Run a command that prints "P<TAB>percent<TAB>label" on stdout.
# Returns the command's exit status.
ui_exec_progress() {
    local stage=$1
    local title=$2
    shift 2
    local fifo line pct msg last=-1 rc pid

    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    if ! : >>"$LOG_FILE" 2>/dev/null; then
        LOG_FILE=/tmp/okrainstall.log
        : >>"$LOG_FILE" 2>/dev/null || LOG_FILE=/dev/null
    fi
    fifo=$(mktemp -u /tmp/okra-progress.XXXXXX)
    mkfifo "$fifo"

    "$@" >"$fifo" 2>>"$LOG_FILE" &
    pid=$!
    while IFS= read -r line; do
        case "$line" in
            P$'\t'*)
                line=${line#P$'\t'}
                pct=${line%%$'\t'*}
                msg=${line#*$'\t'}
                if [ "$pct" != "$last" ]; then
                    ui_gauge "$stage" "$title" "$pct" "$msg"
                    last=$pct
                fi
                ;;
        esac
    done <"$fifo"
    wait "$pid"
    rc=$?
    rm -f "$fifo"
    return "$rc"
}
