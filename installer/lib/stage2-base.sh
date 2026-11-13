#!/bin/bash
# Stage 2 — Base-OS first boot from disk:
# configure system and drivers → phase=3 → reboot.
# No repository exists yet, so this stage does not write repo files or install packages.

stage2_base() {
    printf 'OKRAINSTALL stage2\n' >/dev/kmsg 2>/dev/null || true
    ui_text 2 'Base OS' \
        'Stage 2' \
        '  configure the system' \
        '  load drivers' \
        '  mark phase 3 and reboot'
    log 'stage2 starting'

    ui_gauge 2 'Base OS setup' 15 'Configuring the base system'
    _stage2_configure_base
    _stage2_load_drivers
    _stage2_run_hooks

    write_phase 3
    write_state_kv LAST_STAGE 2
    write_state_kv LAST_STAGE_TS "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ui_gauge 2 'Base OS setup' 100 'Stage 2 complete'

    ui_text 2 'Stage 2 done' \
        'Phase marker is now 3.' \
        'The system will reboot into stage 3 (account, timezone, cleanup).'
    _stage2_kmsg 'waiting for Enter on tty1'
    ui_pause 'Press Enter to reboot'
    sync
    systemctl reboot || reboot
}

_stage2_kmsg() { printf 'stage2: %s\n' "$*" >/dev/kmsg 2>/dev/null || true; }

_stage2_configure_base() {
    log 'configuring base system'
    ui_gauge 2 'Base OS setup' 30 'Configuring the base system'

    if [ ! -s /etc/machine-id ]; then
        if command -v systemd-machine-id-setup >/dev/null 2>&1; then
            systemd-machine-id-setup
        else
            tr -d '-' </proc/sys/kernel/random/uuid >/etc/machine-id
        fi
    fi

    if [ ! -f /etc/locale.conf ]; then
        printf 'LANG=C.UTF-8\n' >/etc/locale.conf
    fi
    if [ ! -f /etc/vconsole.conf ]; then
        printf 'KEYMAP=us\n' >/etc/vconsole.conf
    fi

    if [ ! -s /etc/hostname ]; then
        printf 'okralinux\n' >/etc/hostname
    fi

    disable_unit okrainstall-live.service /
    enable_unit okrainstall-continue.service /
}

_stage2_load_drivers() {
    log 'loading drivers'
    ui_gauge 2 'Base OS setup' 45 'Loading drivers'
    local mod
    for mod in ext4 vfat overlay squashfs virtio_blk virtio_pci virtio_net \
               e1000 e1000e snd_hda_intel; do
        modprobe "$mod" 2>/dev/null || true
    done

    if command -v depmod >/dev/null 2>&1; then
        depmod -a 2>/dev/null || true
    fi
}

_stage2_run_hooks() {
    local hookdir=/usr/lib/okrainstall/hooks/stage2.d
    local hook
    [ -d "$hookdir" ] || return 0
    ui_gauge 2 'Base OS setup' 92 'Running stage 2 hooks'
    for hook in "$hookdir"/*; do
        [ -x "$hook" ] || continue
        log "running hook $(basename "$hook")"
        "$hook" || log "hook failed: $hook"
    done
}
