#!/bin/bash
# Stage 3 — Final-OS: user/timezone config, updates, remove installer residue.

stage3_final() {
    local hostname user password timezone
    local pass1 pass2

    printf 'OKRAINSTALL stage3\n' >/dev/kmsg 2>/dev/null || true
    ui_text 3 'Account' \
        'Stage 3' \
        '  account and timezone' \
        '  remove installer files' \
        '  delete the phase marker'
    log 'stage3 starting'

    while true; do
        ui_input 'Hostname' 'okralinux'
        hostname=$UI_VALUE
        validate_hostname "$hostname" && break
        ui_text 3 'Account' 'Invalid hostname.'
        ui_pause
    done

    while true; do
        ui_input 'Username' ''
        user=$UI_VALUE
        validate_username "$user" && break
        ui_text 3 'Account' 'Invalid username (not root, letters, digits, _ and - only).'
        ui_pause
    done

    while true; do
        ui_password 'Password'
        pass1=$UI_VALUE
        ui_password 'Confirm password'
        pass2=$UI_VALUE
        [ -n "$pass1" ] || { ui_text 3 'Account' 'Password must not be empty.'; ui_pause; continue; }
        [ "$pass1" = "$pass2" ] && { password=$pass1; break; }
        ui_text 3 'Account' 'Passwords do not match.'
        ui_pause
    done

    ui_input 'Timezone (for example Asia/Shanghai)' 'UTC'
    timezone=$UI_VALUE

    ui_text 3 'Confirm' \
        "hostname   $hostname" \
        "user       $user" \
        "timezone   $timezone"
    ui_confirm 'Write this configuration and finish installation?' || die 'cancelled'

    ui_gauge 3 'Finishing' 20 'Writing account and timezone'
    _stage3_apply_user_config "$hostname" "$user" "$password" "$timezone"
    ui_gauge 3 'Finishing' 55 'Skipping software update'
    _stage3_system_update
    ui_gauge 3 'Finishing' 85 'Removing installer files'
    _stage3_cleanup
    ui_gauge 3 'Finishing' 100 'Installation complete'

    ui_text 3 'Done' \
        'The phase marker has been removed.' \
        'OkraLinux installation is complete.'
    if ui_yesno 'Reboot now?' n; then
        sync
        systemctl reboot || reboot
    fi
    ui_pause
}

_stage3_apply_user_config() {
    local hostname=$1 user=$2 password=$3 timezone=$4

    in_group() {
        local name=$1 line
        [ -f /etc/group ] || return 1
        while IFS= read -r line; do
            case "$line" in
                "$name":*) return 0 ;;
            esac
        done < /etc/group
        return 1
    }

    log 'applying user configuration'

    printf '%s\n' "$hostname" >/etc/hostname
    hostnamectl set-hostname "$hostname" 2>/dev/null || true

    if [ -d "/usr/share/zoneinfo/$timezone" ] || [ -f "/usr/share/zoneinfo/$timezone" ]; then
        ln -sfn "/usr/share/zoneinfo/$timezone" /etc/localtime
        printf 'Zone=%s\n' "$timezone" >/etc/timezone 2>/dev/null || true
        timedatectl set-timezone "$timezone" 2>/dev/null || true
    else
        log "timezone not found: $timezone (kept current)"
    fi

    if command -v useradd >/dev/null 2>&1; then
        if ! id "$user" >/dev/null 2>&1; then
            useradd -m -s /bin/bash "$user"
        fi
        if [ -n "$password" ] && command -v chpasswd >/dev/null 2>&1; then
            printf '%s:%s\n' "$user" "$password" | chpasswd
        fi
        if in_group wheel; then
            usermod -aG wheel "$user" 2>/dev/null || true
        fi
        if in_group sudo; then
            usermod -aG sudo "$user" 2>/dev/null || true
        fi
    fi
}

_stage3_system_update() {
    # No repository yet. Do not sync or install packages.
    log 'no repository; skipping system update'

    local hookdir=/usr/lib/okrainstall/hooks/stage3.d
    local hook
    [ -d "$hookdir" ] || return 0
    for hook in "$hookdir"/*; do
        [ -x "$hook" ] || continue
        log "running hook $(basename "$hook")"
        "$hook" || log "hook failed: $hook"
    done
}

_stage3_cleanup() {
    log 'cleaning installer residue'

    systemctl disable okrainstall-continue.service 2>/dev/null || true
    disable_unit okrainstall-continue.service /
    disable_unit okrainstall-live.service /

    mkdir -p /etc/systemd/system/getty.target.wants
    ln -sfn /usr/lib/systemd/system/getty@.service \
        /etc/systemd/system/getty.target.wants/getty@tty1.service
    # The install ran on the serial console, so the finished system should
    # offer a login there too. serial-getty@ is conditioned on the device
    # existing, so on hardware with no serial port the link is inert.
    if [ -e /usr/lib/systemd/system/serial-getty@.service ]; then
        ln -sfn /usr/lib/systemd/system/serial-getty@.service \
            /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service
        # The stock unit starts agetty with -o '-p -- \u' --keep-baud and a
        # terminal type taken from the environment; on this system that
        # agetty opens the line and produces no prompt at all, while the same
        # binary started by hand with -L and an explicit type does reach
        # login. Use the command line that was seen working.
        mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
        cat >/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf <<'GETTYOVERRIDE'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L 115200 ttyS0 linux
GETTYOVERRIDE
    fi
    systemctl daemon-reload 2>/dev/null || true
    # Write the command line systemd will actually run into the kernel log.
    # The console either shows a prompt or it does not, and there is no way to
    # ask a machine without a login what its getty was told; the next boot
    # reads this from the serial line instead.
    _getty_line=$(systemctl show serial-getty@ttyS0.service -p ExecStart 2>/dev/null)
    printf 'okrainstall: serial getty is %s\n' "${_getty_line:-unknown}" >/dev/kmsg 2>/dev/null || true
    printf 'okrainstall: getty override present: %s\n' \
        "$( [ -f /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf ] && echo yes || echo no )" \
        >/dev/kmsg 2>/dev/null || true

    rm -f /usr/bin/kanina-tui /usr/bin/kanina-live /usr/bin/kanina-installer \
          /usr/bin/kanina-wayland /usr/bin/kanina-wayland-session \
          /usr/libexec/kanina-install
    rm -rf /usr/lib/kanina
    rm -f /usr/lib/systemd/system/kanina-*.service
    rm -f /etc/systemd/system/multi-user.target.wants/kanina-*.service \
          /etc/systemd/system/graphical.target.wants/kanina-*.service

    rm -f /usr/bin/okrainstall \
          /usr/libexec/okrainstall-stage1 \
          /usr/libexec/okrainstall-backend
    rm -f /usr/lib/systemd/system/okrainstall-live.service \
          /usr/lib/systemd/system/okrainstall-continue.service
    rm -rf /usr/lib/okrainstall

    clear_marker
}
