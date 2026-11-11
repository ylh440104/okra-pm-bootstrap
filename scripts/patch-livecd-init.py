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
open(Path, 'w', encoding='utf-8').write(Text)
print('init patched')