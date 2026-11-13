#!/bin/bash
# Install OKRAINSTALL into a LiveCD rootfs (stage-1 capable).
set -euo pipefail

ROOTFS=${1:?usage: install-into-rootfs.sh ROOTFS}
HERE=$(cd "$(dirname "$0")" && pwd)

install -Dm755 "$HERE/bin/okrainstall" "$ROOTFS/usr/bin/okrainstall"
install -Dm755 "$HERE/libexec/okrainstall-stage1" "$ROOTFS/usr/libexec/okrainstall-stage1"
install -d \
    "$ROOTFS/usr/lib/okrainstall" \
    "$ROOTFS/usr/lib/okrainstall/hooks/stage2.d" \
    "$ROOTFS/usr/lib/okrainstall/hooks/stage3.d"
install -Dm644 "$HERE/lib/"*.sh "$ROOTFS/usr/lib/okrainstall/"
install -Dm644 "$HERE/stage2-packages.list" "$ROOTFS/usr/lib/okrainstall/stage2-packages.list"
install -Dm644 "$HERE/systemd/okrainstall-live.service" \
    "$ROOTFS/usr/lib/systemd/system/okrainstall-live.service"
install -Dm644 "$HERE/systemd/okrainstall-continue.service" \
    "$ROOTFS/usr/lib/systemd/system/okrainstall-continue.service"

# LiveCD: start stage 1 on tty1. Continue unit is planted on disk by stage1.
mkdir -p "$ROOTFS/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/okrainstall-live.service \
    "$ROOTFS/etc/systemd/system/multi-user.target.wants/okrainstall-live.service"
rm -f "$ROOTFS/etc/systemd/system/multi-user.target.wants/okrainstall.service"
rm -f "$ROOTFS/etc/systemd/system/multi-user.target.wants/okrainstall-continue.service"

mkdir -p "$ROOTFS/etc/systemd/system/getty.target.wants"
rm -f "$ROOTFS/etc/systemd/system/getty.target.wants/getty@tty1.service"
ln -sfn /usr/lib/systemd/system/getty@.service \
    "$ROOTFS/etc/systemd/system/getty.target.wants/getty@tty2.service"
ln -sfn /usr/lib/systemd/system/getty@.service \
    "$ROOTFS/etc/systemd/system/getty.target.wants/getty@tty3.service"

# Remove obsolete single-shot unit if present from older installs.
rm -f "$ROOTFS/usr/lib/systemd/system/okrainstall.service"
rm -f "$ROOTFS/usr/libexec/okrainstall-backend"

printf 'OKRAINSTALL (multi-reboot) installed into %s\n' "$ROOTFS"
