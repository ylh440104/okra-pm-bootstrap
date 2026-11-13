import sys
Path = sys.argv[1]
Text = open(Path, encoding='utf-8').read()
Old = 'if [ -f /cdrom/LiveOS/rootfs.squashfs ]; then\n            echo "LiveCD init: found rootfs on $dev"\n            break 2\n        fi'
New = 'if [ -f /cdrom/LiveOS/rootfs.squashfs ] || [ -f /cdrom/LiveOS/rootfs.ext4 ]; then\n            echo "LiveCD init: found rootfs on $dev"\n            break 2\n        fi'
assert Old in Text, 'probe not found'
Text = Text.replace(Old, New, 1)
Old = 'mount -t squashfs -o ro /cdrom/LiveOS/rootfs.squashfs /lower || halt_init "mount squashfs failed"'
New = ('if [ -f /cdrom/LiveOS/rootfs.squashfs ]; then\n'
       '    mount -t squashfs -o ro /cdrom/LiveOS/rootfs.squashfs /lower \\\n'
       '        || halt_init "mount squashfs failed"\n'
       'else\n'
       '    modprobe loop 2>/dev/null || true\n'
       '    mount -t ext4 -o ro,loop /cdrom/LiveOS/rootfs.ext4 /lower \\\n'
       '        || halt_init "mount ext4 failed"\n'
       'fi')
assert Old in Text, 'squashfs mount not found'
Text = Text.replace(Old, New, 1)
Old = ('if [ ! -x /newroot/bin/bash ] && [ -x /bin/bash ]; then\n'
       '    cp /bin/bash /newroot/bin/bash')
New = ('# line 74 earlier pointed /newroot/bin/bash at ../usr/bin/bash, which the\n'
       '# rootfs may not carry. cp cannot write through that link, so it says\n'
       '# "not writing through dangling symlink" and bash stays missing.\n'
       'rm -f /newroot/bin/bash /newroot/bin/sh /newroot/bin/ash\n'
       'if [ ! -x /newroot/bin/bash ] && [ -x /bin/bash ]; then\n'
       '    cp /bin/bash /newroot/bin/bash')
assert Old in Text, 'bash copy not found'
Text = Text.replace(Old, New, 1)
Old = (
	'ln -sf /dev/null /newroot/etc/systemd/system/systemd-udevd.service\n'
	'ln -sf /dev/null /newroot/etc/systemd/system/systemd-udev-trigger.service\n'
	'ln -sf /dev/null /newroot/etc/systemd/system/systemd-udev-settle.service\n'
	'ln -sf /dev/null /newroot/etc/systemd/system/systemd-hwdb-update.service\n'
	'ln -sf /dev/null /newroot/etc/systemd/system/kmod-static-nodes.service\n'
	'ln -sf /dev/null /newroot/etc/systemd/system/systemd-modules-load.service\n'
	'ln -sf /dev/null /newroot/etc/systemd/system/modprobe@fuse.service\n')
New = (
	'# udevd and the units that populate /dev stay unmasked. Without them there\n'
	'# are no device nodes and nothing else on the image works. The drop-in\n'
	'# written further down lifts the namespace restrictions that made a\n'
	'# masked udev seem necessary.\n')
assert Old in Text, 'mask block not found'
Text = Text.replace(Old, New, 1)
Old = ('rm -f /newroot/etc/systemd/system/sysinit.target.wants/debug-shell.service \\\n'
       '    /newroot/etc/systemd/system/sysinit.target.wants/systemd-udevd.service \\\n'
       '    /newroot/etc/systemd/system/sysinit.target.wants/systemd-udev-trigger.service \\\n'
       '    /newroot/etc/systemd/system/sysinit.target.wants/ldconfig.service \\\n'
       '    /newroot/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service \\\n'
       '    /newroot/etc/systemd/system/getty.target.wants/console-getty.service \\\n'
       '    /newroot/etc/systemd/system/getty.target.wants/getty@tty1.service\n')
New = ('rm -f /newroot/etc/systemd/system/sysinit.target.wants/debug-shell.service \\\n'
       '    /newroot/etc/systemd/system/sysinit.target.wants/ldconfig.service \\\n'
       '    /newroot/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service \\\n'
       '    /newroot/etc/systemd/system/getty.target.wants/console-getty.service \\\n'
       '    /newroot/etc/systemd/system/getty.target.wants/getty@tty1.service\n')
assert Old in Text, 'rm block not found'
Text = Text.replace(Old, New, 1)

Marker = """    /newroot/etc/systemd/system/getty.target.wants/getty@tty1.service
"""
Addition = """ln -sf /dev/null /newroot/etc/systemd/system/getty@tty1.service
"""
assert Marker in Text, 'getty wants tail not found'
Text = Text.replace(Marker, Marker + Addition, 1)

# The link is two source lines: the command, then its indented destination.
# Find them by shape instead of spelling the backslash into a literal.
SourceLines = Text.split("\n")
LinkStart = None
for Index, Line in enumerate(SourceLines):
    if Line.startswith("ln -sf /etc/systemd/system/autologin-console.service"):
        LinkStart = Index
        break
assert LinkStart is not None, "autologin link not found"
LinkEnd = LinkStart + 1
assert "multi-user.target.wants/autologin-console.service" in SourceLines[LinkEnd], \
    "autologin link destination not found"

Replacement = [
    "# Two programs want the console and only one can have it. Installing is what",
    "# the operator asked for by picking that menu entry, so when okra.install is",
    "# on the command line the installer takes the console and the unattended",
    "# shell steps aside; otherwise the shell keeps it and the image is usable",
    "# without installing anything.",
    "if [ -x /newroot/usr/bin/okrainstall ] && \\",
    "        grep -q okra.install /proc/cmdline 2>/dev/null; then",
    "    ln -sf /dev/null /newroot/etc/systemd/system/autologin-console.service",
    "else",
    SourceLines[LinkStart],
    SourceLines[LinkEnd],
    "fi",
]
SourceLines[LinkStart:LinkEnd + 1] = Replacement
Text = "\n".join(SourceLines)

open(Path, 'w', encoding='utf-8').write(Text)
print('init patched')