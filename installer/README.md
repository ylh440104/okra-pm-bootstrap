# OKRAINSTALL

Three-stage OkraLinux installer. It reboots twice. See `DOCS/okrainstall.md`.

```text
Live CD   [1] partition, copy Base OS, plant phase=2, install GRUB, reboot
Base OS   [2] drivers, repository, packages, phase=3, reboot
Final OS  [3] account, timezone, update, remove the installer
```

The screen is a bash TUI (arrow keys, Enter). Stage 1 shows a progress bar while the Base OS is copied.

```bash
okrainstall              # detect the current stage
okrainstall --continue   # systemd on the installed disk
okrainstall --stage 1|2|3
```

```bash
./install-into-rootfs.sh /path/to/rootfs
```
