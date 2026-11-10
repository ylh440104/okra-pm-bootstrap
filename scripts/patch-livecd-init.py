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

open(Path, 'w', encoding='utf-8').write(Text)
print('init patched')