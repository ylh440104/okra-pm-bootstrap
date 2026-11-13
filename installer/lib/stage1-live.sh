#!/bin/bash
# Stage 1 — LiveCD: partition/format → copy Base-OS → plant installer+marker → reboot.

stage1_live() {
    local src
    src=$(find_live_root) || die "live rootfs not found (expected $LIVE_ROOT)"

    ui_text 1 'Live CD' \
        'Stage 1' \
        '  partition and format the disk' \
        '  copy the Base OS' \
        '  plant the installer and phase marker' \
        '  reboot into stage 2' \
        '' \
        "Source: $src"
    ui_confirm 'Start stage 1?' || exit 0

    _stage1_select_targets
    _stage1_confirm_and_run
}

_stage1_select_targets() {
    local -a disk_lines disk_names menu_items
    local line name size model

    ui_text 1 'Select disk'
    mapfile -t disk_lines < <(list_disks)
    [ "${#disk_lines[@]}" -gt 0 ] || die 'no usable disks found'

    disk_names=()
    menu_items=()
    for line in "${disk_lines[@]}"; do
        IFS=$'\t' read -r name size model <<<"$line"
        disk_names+=("$name")
        menu_items+=("$name  ($size)  $model")
    done

    ui_menu 'Select disk' 'Choose the disk to use:' "${menu_items[@]}" || die 'cancelled'
    for i in "${!menu_items[@]}"; do
        if [ "${menu_items[$i]}" = "$UI_CHOICE" ]; then
            OKRA_DISK="${disk_names[$i]}"
            break
        fi
    done
    [ -b "$OKRA_DISK" ] || die "not a block device: $OKRA_DISK"

    ui_text 1 'Whole disk' \
        "Disk: $OKRA_DISK" \
        '' \
        'Whole-disk install erases the disk and creates a BIOS boot' \
        'partition, a 512 MiB EFI partition, and a root partition.'
    if ui_yesno 'Erase the whole disk?' y; then
        OKRA_WHOLE_DISK=1
        return
    fi
    OKRA_WHOLE_DISK=0

    ui_text 1 'Select partitions' "Disk: $OKRA_DISK"
    _stage1_pick_partition 'EFI partition' || die 'EFI partition required'
    OKRA_EFI=$UI_CHOICE
    _stage1_pick_partition 'Root partition' || die 'root partition required'
    OKRA_ROOT=$UI_CHOICE
    [ "$OKRA_EFI" != "$OKRA_ROOT" ] || die 'EFI and root must be different partitions'

    if ui_yesno 'Format the root partition as ext4? This erases it.' y; then
        OKRA_FORMAT_ROOT=1
    else
        OKRA_FORMAT_ROOT=0
    fi
}

_stage1_pick_partition() {
    local label=$1
    local -a lines names items
    local line name size fstype ptype

    mapfile -t lines < <(list_partitions)
    [ "${#lines[@]}" -gt 0 ] || return 1
    names=()
    items=()
    for line in "${lines[@]}"; do
        IFS=$'\t' read -r name size fstype ptype <<<"$line"
        names+=("$name")
        items+=("$name  $size  $fstype  $ptype")
    done
    ui_menu "$label" "Choose ${label}:" "${items[@]}" || return 1
    for i in "${!items[@]}"; do
        if [ "${items[$i]}" = "$UI_CHOICE" ]; then
            UI_CHOICE="${names[$i]}"
            return 0
        fi
    done
    return 1
}

_stage1_confirm_and_run() {
    local backend=${OKRAINSTALL_STAGE1_BACKEND:-/usr/libexec/okrainstall-stage1}
    local -a args
    local rc format

    local -a summary
    summary=(
        'About to install:'
        "  disk      $OKRA_DISK"
    )
    if [ "${OKRA_WHOLE_DISK:-0}" -eq 1 ]; then
        summary+=('  mode      whole disk (erase and partition)')
    else
        format=no
        [ "$OKRA_FORMAT_ROOT" -eq 1 ] && format=yes
        summary+=(
            "  EFI       $OKRA_EFI"
            "  root      $OKRA_ROOT"
            "  format    $format"
        )
    fi
    summary+=('  then      write phase=2 and reboot into stage 2')
    ui_text 1 'Confirm' "${summary[@]}"
    ui_confirm 'Write the Base OS to this disk?' || die 'cancelled'

    if [ ! -x "$backend" ] && [ -x "$OKRAINSTALL_ROOT/libexec/okrainstall-stage1" ]; then
        backend="$OKRAINSTALL_ROOT/libexec/okrainstall-stage1"
    fi
    [ -x "$backend" ] || die "stage 1 backend missing: $backend"

    if [ "${OKRA_WHOLE_DISK:-0}" -eq 1 ]; then
        args=(--whole-disk "$OKRA_DISK")
    else
        args=(--disk "$OKRA_DISK" --efi "$OKRA_EFI" --root "$OKRA_ROOT")
        [ "$OKRA_FORMAT_ROOT" -eq 1 ] && args+=(--format-root)
    fi

    set +e
    ui_exec_progress 1 'Installing' "$backend" "${args[@]}"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        mapfile -t err_lines < "$LOG_FILE" 2>/dev/null || err_lines=()
        if [ "${#err_lines[@]}" -gt 12 ]; then
            err_lines=("${err_lines[@]: -12}")
        fi
        ui_text 1 'Error' "stage 1 failed (exit $rc)" '' "${err_lines[@]}"
        ui_pause 'Press Enter to exit.'
        exit "$rc"
    fi

    ui_text 1 'Stage 1 done' \
        'The Base OS is on disk. Phase marker is 2.' \
        'Remove the live media if needed.' \
        'The system will reboot into stage 2.'
    ui_pause 'Press Enter to reboot'
    sync
    systemctl reboot || reboot
}
