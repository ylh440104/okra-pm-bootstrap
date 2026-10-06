#!/bin/bash
# rebuild-libc.sh - rebuild libxcrypt and glibc inside the userland.
#
# Two things are left cross built after rebuild-native.sh, and glibc is the one
# that matters most: it is the C library every other binary links against, so
# while it stays cross built the system is not really standing on itself.
#
# libxcrypt comes first. glibc stopped shipping libcrypt, perl links against it,
# and glibc's own build calls perl, so without it the C library cannot be
# rebuilt. It is also simply a package this system was missing: the kernel build
# had to fake it before.
#
# glibc is then rebuilt with the compiler the userland built for itself and
# installed over the running one. Same version, so the ABI does not move, and
# the install is a rename per file, so processes that are already running keep
# the library they started with. The old library and loader are copied aside
# first, so a failure here can be undone inside the same run rather than leaving
# a tree that cannot boot.
#
# Usage: rebuild-libc.sh <rootfs-dir>
# Environment:
#   OKRA_JOBS              parallel make jobs (default 4)
#   OKRA_GLIBC_VERSION     default 2.43, matching the cross toolchain
#   OKRA_LIBCRYPT_VERSION  default 4.4.36
#   OKRA_GNU_MIRROR        default https://mirrors.kernel.org/gnu
#   OKRA_LIBCRYPT_URL      default the libxcrypt release tarball
# Return: 0 only when the userland runs a program built against the C library it
#         compiled itself.
set -uo pipefail

RootfsDirectory="${1:?usage: rebuild-libc.sh <rootfs-dir>}"
Jobs="${OKRA_JOBS:-4}"
GlibcVersion="${OKRA_GLIBC_VERSION:-2.43}"
LibcryptVersion="${OKRA_LIBCRYPT_VERSION:-4.4.36}"
Mirror="${OKRA_GNU_MIRROR:-https://mirrors.kernel.org/gnu}"
LibcryptUrl="${OKRA_LIBCRYPT_URL:-https://github.com/besser82/libxcrypt/releases/download/v$LibcryptVersion/libxcrypt-$LibcryptVersion.tar.xz}"

[ -d "$RootfsDirectory" ] || { echo "rebuild-libc: no rootfs at $RootfsDirectory" >&2; exit 1; }
[ -x "$RootfsDirectory/usr/bin/gcc" ] || {
	echo "rebuild-libc: the userland has no gcc" >&2
	exit 1
}

Sources="$RootfsDirectory/usr/src/native"
mkdir -p "$Sources"

# Fetch() - download a source tarball if it is not already there.
# @Url: where to get it.
# @Target: where to put it.
# Return: 0 when the file exists and is not empty.
Fetch() {
	local Url="$1" Target="$2"
	[ -s "$Target" ] && return 0
	echo "== fetching $(basename "$Target")"
	curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -m 1800 -o "$Target" "$Url" || return 1
	[ -s "$Target" ] || return 1
	return 0
}

echo "== fetching the sources into the userland"
df -h "$RootfsDirectory" | tail -1
Fetch "$LibcryptUrl" "$Sources/libxcrypt.tar.xz" || {
	echo "rebuild-libc: could not fetch libxcrypt" >&2
	exit 1
}
Fetch "$Mirror/glibc/glibc-$GlibcVersion.tar.xz" "$Sources/glibc.tar.xz" || {
	echo "rebuild-libc: could not fetch glibc" >&2
	exit 1
}
ls -la "$Sources"

# The state of the library that is about to be replaced. The build id in the
# shared object changes when it is rebuilt, which is what shows the swap
# actually happened rather than the script quietly doing nothing.
echo "== the C library that is about to be replaced"
LibcPath="$(find "$RootfsDirectory" -maxdepth 3 -name 'libc.so.6' -print -quit 2>/dev/null)"
[ -n "$LibcPath" ] || { echo "rebuild-libc: no libc.so.6 in the tree" >&2; exit 1; }
echo "   $LibcPath"
file "$LibcPath" | sed 's/^/   /'
Before="$(readlink -f "$LibcPath")"
BeforeSum="$(sha256sum "$Before" | awk '{print $1}')"
echo "   sha256 $BeforeSum"

echo "== entering the userland"
cat > "$RootfsDirectory/usr/src/native/libc-inner.sh" <<'INNER'
#!/bin/bash
# Runs inside the Okra userland. The compiler, the linker and the sources are
# all in this tree.
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export TZ=UTC
export HOME=/root
export MAKEFLAGS="-j${OKRA_JOBS}"

cd /usr/src/native || exit 1

echo "== what is doing the building"
gcc --version | head -1
ld --version | head -1

echo "== building libxcrypt ${OKRA_LIBCRYPT_VERSION}, natively"
# perl links against libcrypt and glibc's build calls perl, so this has to exist
# before the C library can be rebuilt. The obsolete glibc API is enabled so the
# soname everything expects, libcrypt.so.1, is the one that gets installed.
rm -rf libxcrypt-src libxcrypt-build
mkdir libxcrypt-src libxcrypt-build
tar -xf libxcrypt.tar.xz -C libxcrypt-src --strip-components=1 || exit 1
cd libxcrypt-build || exit 1
../libxcrypt-src/configure \
	--prefix=/usr \
	--disable-static \
	--enable-hashes=strong,glibc \
	--enable-obsolete-api=glibc || exit 1
make || exit 1
make install || exit 1
ldconfig 2>/dev/null || true
cd /usr/src/native || exit 1
echo "== libcrypt is in place"
ls -la /usr/lib/libcrypt.so.1 2>/dev/null || echo "   libcrypt.so.1 is missing" >&2

echo "== perl has to run, because glibc's build calls it"
perl -e 'print "   perl is working\n"' || {
	echo "perl still cannot run" >&2
	exit 1
}

echo "== building glibc ${OKRA_GLIBC_VERSION}, natively"
# The same options the cross toolchain used, minus the cross specific ones. The
# kernel headers it needs are already in /usr/include from the cross build.
rm -rf glibc-src glibc-build
mkdir glibc-src glibc-build
tar -xf glibc.tar.xz -C glibc-src --strip-components=1 || exit 1
cd glibc-build || exit 1
echo 'rootscheme: unix' > configparms
../glibc-src/configure \
	--prefix=/usr \
	--enable-kernel=5.10 \
	--disable-werror \
	--without-gd \
	--disable-nscd \
	--disable-static-c++-link-check \
	libc_cv_slibdir=/usr/lib \
	libc_cv_rtlddir=/lib64 || exit 1
make || exit 1

echo "== installing glibc over the running one"
# Same version, so the ABI is unchanged, and glibc installs by renaming each
# file into place, so what is already running keeps the library it started
# with. The build id after this is what the outer script compares.
make install || exit 1
ldconfig 2>/dev/null || true
cd /usr/src/native || exit 1

echo "== the C library now in place"
ls -la /usr/lib/libc.so.6 /lib64/ld-linux-x86-64.so.2 2>/dev/null

echo "== it still compiles and runs a program"
printf '%s\n' '#include <stdio.h>' 'int main(void) { printf("linked against the C library this system built\n"); return 0; }' > libc-hello.c
/usr/bin/gcc -O2 -o libc-hello libc-hello.c || exit 1
./libc-hello || exit 1

echo "== and the C++ runtime still works"
printf '%s\n' '#include <iostream>' 'int main() { std::cout << "and C++ still links" << std::endl; return 0; }' > libc-hello.cc
/usr/bin/g++ -O2 -o libc-helloxx libc-hello.cc || exit 1
./libc-helloxx || exit 1

echo "== done"
INNER
chmod +x "$RootfsDirectory/usr/src/native/libc-inner.sh"

# The old library is kept so this step can be undone without another run. The
# copy is outside the tree so the install cannot touch it.
BackupDirectory="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/okra-libc-backup"
rm -rf "$BackupDirectory"
mkdir -p "$BackupDirectory"
for Name in libc.so.6 ld-linux-x86-64.so.2; do
	Found="$(find "$RootfsDirectory" -maxdepth 3 -name "$Name" -print -quit 2>/dev/null)"
	[ -n "$Found" ] && cp -aL "$Found" "$BackupDirectory/$Name" 2>/dev/null || true
done
ls -la "$BackupDirectory"

for Point in proc sys dev dev/pts; do
	mkdir -p "$RootfsDirectory/$Point"
done
mount --bind /proc "$RootfsDirectory/proc" 2>/dev/null || true
mount --bind /sys "$RootfsDirectory/sys" 2>/dev/null || true
mount --bind /dev "$RootfsDirectory/dev" 2>/dev/null || true

CleanupMounts() {
	for Point in dev sys proc; do
		umount "$RootfsDirectory/$Point" 2>/dev/null || true
	done
}
trap CleanupMounts EXIT

chroot "$RootfsDirectory" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root \
	OKRA_JOBS="$Jobs" \
	OKRA_GLIBC_VERSION="$GlibcVersion" \
	OKRA_LIBCRYPT_VERSION="$LibcryptVersion" \
	/bin/bash /usr/src/native/libc-inner.sh
InnerStatus=$?
[ "$InnerStatus" -eq 0 ] || {
	echo "rebuild-libc: the in-userland rebuild failed with status $InnerStatus" >&2
	exit 1
}

CleanupMounts
trap - EXIT

echo "== the C library in the userland is now the one it built"
LibcPath="$(find "$RootfsDirectory" -maxdepth 3 -name 'libc.so.6' -print -quit 2>/dev/null)"
file "$LibcPath" | sed 's/^/   /'
AfterSum="$(sha256sum "$(readlink -f "$LibcPath")" | awk '{print $1}')"
echo "   sha256 $AfterSum"

# Without this the step could do nothing at all and still look like a pass,
# which has already happened once in this repository.
if [ "$BeforeSum" = "$AfterSum" ]; then
	echo "rebuild-libc: libc.so.6 is unchanged, so nothing was actually rebuilt" >&2
	exit 1
fi
echo "== and it is not the one that went in"
echo "   before: $BeforeSum"
echo "   after:  $AfterSum"

echo "== what is still cross built"
echo "   the 70 packages, which were cross compiled before this step existed"
echo "== done"