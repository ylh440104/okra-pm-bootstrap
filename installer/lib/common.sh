#!/bin/bash
# Shared helpers and phase-marker protocol for OKRAINSTALL.
#
# Marker on the installed root:
#   /var/lib/okrainstall/phase   →  "2" or "3"
# Presence means installation is unfinished; the continue unit runs on boot.
# Stage 1 (LiveCD) creates phase=2. Stage 2 advances to 3. Stage 3 deletes it.

OKRAINSTALL_VERSION=0.3.0
# systemd does not put /bin on PATH. mount and umount are only in /bin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
OKRAINSTALL_LIB="${OKRAINSTALL_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OKRAINSTALL_ROOT="${OKRAINSTALL_ROOT:-$(cd "$OKRAINSTALL_LIB/.." && pwd)}"

MARKER_DIR=/var/lib/okrainstall
PHASE_FILE="$MARKER_DIR/phase"
STATE_FILE="$MARKER_DIR/state.env"
LOG_FILE="$MARKER_DIR/install.log"

LIVE_ROOT="${OKRAINSTALL_LIVE_ROOT:-/run/live/rootfs}"
LIVE_MEDIA="${OKRAINSTALL_LIVE_MEDIA:-/run/live/media}"

# Stage-1 plan (LiveCD session only).
OKRA_DISK=''
OKRA_EFI=''
OKRA_ROOT=''
OKRA_FORMAT_ROOT=1
OKRA_WHOLE_DISK=1

die() {
    if [ -t 1 ] && declare -F ui_error >/dev/null 2>&1; then
        ui_error "$*"
    else
        printf 'error: %s\n' "$*" >&2
    fi
    exit 1
}

log() {
    local msg
    msg=$(printf '%s\n' "$*")
    printf '%s\n' "$msg" >&2
    if [ -d "$MARKER_DIR" ] 2>/dev/null || mkdir -p "$MARKER_DIR" 2>/dev/null; then
        printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >>"$LOG_FILE" 2>/dev/null || true
    fi
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die 'OKRAINSTALL must run as root'
}

is_live_environment() {
    [ -d /run/live/rootfs ] && return 0
    [ -d /run/live/media ] && return 0
    # Base OS has no grep. Match the live flag with bash only.
    local cmdline
    cmdline=$(cat /proc/cmdline 2>/dev/null || true)
    case " $cmdline " in
        *" rd.live.image "*|*" rd.live.image="*) return 0 ;;
    esac
    return 1
}

read_phase() {
    if [ -f "$PHASE_FILE" ]; then
        tr -d '[:space:]' <"$PHASE_FILE"
    else
        printf ''
    fi
}

write_phase() {
    local phase=$1
    mkdir -p "$MARKER_DIR"
    printf '%s\n' "$phase" >"$PHASE_FILE"
    log "phase marker set to $phase"
}

clear_marker() {
    rm -rf "$MARKER_DIR"
}

write_state_kv() {
    mkdir -p "$MARKER_DIR"
    if [ ! -f "$STATE_FILE" ]; then
        printf '# OKRAINSTALL state\n' >"$STATE_FILE"
    fi
    local key=$1 value=$2 line found=0 tmp
    tmp=$(mktemp)
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key"=*)
                printf '%s=%s\n' "$key" "$value" >>"$tmp"
                found=1
                ;;
            *) printf '%s\n' "$line" >>"$tmp" ;;
        esac
    done <"$STATE_FILE"
    if [ "$found" -eq 0 ]; then
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
    mv "$tmp" "$STATE_FILE"
}

human_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        printf '%sG' $((bytes / 1073741824))
    elif [ "$bytes" -ge 1048576 ]; then
        printf '%sM' $((bytes / 1048576))
    else
        printf '%sK' $((bytes / 1024))
    fi
}

# Disks from sysfs. The Base OS has no lsblk.
list_disks() {
    local dev name sectors model bytes
    for dev in /sys/block/*; do
        [ -d "$dev" ] || continue
        name=${dev##*/}
        case "$name" in
            loop*|ram*|fd*|sr*|zram*|dm-*) continue ;;
        esac
        sectors=$(cat "$dev/size" 2>/dev/null || echo 0)
        bytes=$((sectors * 512))
        [ "$bytes" -gt 0 ] || continue
        model=$(cat "$dev/device/model" 2>/dev/null || true)
        model=${model#"${model%%[![:space:]]*}"}
        model=${model%"${model##*[![:space:]]}"}
        [ -n "$model" ] || model=-
        printf '%s\t%s\t%s\n' "/dev/$name" "$(human_bytes "$bytes")" "$model"
    done
}

list_partitions() {
    local disk name part pname sectors bytes fstype
    for disk in /sys/block/*; do
        [ -d "$disk" ] || continue
        name=${disk##*/}
        case "$name" in
            loop*|ram*|fd*|sr*|zram*) continue ;;
        esac
        for part in "$disk/$name"*; do
            [ -f "$part/partition" ] || continue
            pname=${part##*/}
            sectors=$(cat "$part/size" 2>/dev/null || echo 0)
            bytes=$((sectors * 512))
            fstype=$(blkid -s TYPE -o value "/dev/$pname" 2>/dev/null || true)
            [ -n "$fstype" ] || fstype=-
            printf '%s\t%s\t%s\t%s\n' "/dev/$pname" "$(human_bytes "$bytes")" "$fstype" -
        done
    done
}

read_state_kv() {
    local key=$1
    [ -f "$STATE_FILE" ] || return 1
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    . "$STATE_FILE"
    set +a
    eval "printf '%s\\n' \"\${$key-}\""
}

validate_username() {
    case "$1" in
        ''|*[!a-zA-Z0-9_-]*|root) return 1 ;;
        *) return 0 ;;
    esac
}

validate_hostname() {
    case "$1" in
        ''|*[!a-zA-Z0-9.-]*) return 1 ;;
        *) return 0 ;;
    esac
}

find_live_root() {
    if [ -d "$LIVE_ROOT" ]; then
        printf '%s\n' "$LIVE_ROOT"
        return 0
    fi
    if [ -d /run/media/rootfs ]; then
        printf '%s\n' /run/media/rootfs
        return 0
    fi
    return 1
}

enable_unit() {
    local unit=$1 root=${2:-/}
    mkdir -p "$root/etc/systemd/system/multi-user.target.wants"
    ln -sfn "/usr/lib/systemd/system/$unit" \
        "$root/etc/systemd/system/multi-user.target.wants/$unit"
}

disable_unit() {
    local unit=$1 root=${2:-/}
    rm -f "$root/etc/systemd/system/multi-user.target.wants/$unit"
}
