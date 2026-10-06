#!/bin/bash
# rebuild-native.sh - rebuild the toolchain inside the userland, natively.
#
# This is the step the bootstrap has been missing. Everything up to here was
# cross compiled: a toolchain living on the runner produced every binary in the
# userland, so nothing in there ever built anything. Here the userland is
# entered and the toolchain is rebuilt by the compiler that is already inside
# it, which is what makes the system self hosting rather than merely self
# contained.
#
# It rebuilds binutils and gcc. glibc is deliberately left alone: replacing the
# C library of a running system in place needs a two phase install and a
# reboot, which is a separate exercise from proving the compiler compiles
# itself. That gap is reported at the end rather than glossed over.
#
# The sources are fetched into the userland and the builds happen there, so the
# compiler, the linker and the makefiles are all the userland's own.
#
# Usage: rebuild-native.sh <rootfs-dir>
# Environment:
#   OKRA_JOBS               parallel make jobs (default 4)
#   OKRA_BINUTILS_VERSION   default 2.44, matching the cross toolchain
#   OKRA_GCC_VERSION        default 16.2.0, matching the cross toolchain
#   OKRA_GNU_MIRROR         default https://mirrors.kernel.org/gnu
# Return: 0 when the userland builds and runs a program with its own new gcc.
set -uo pipefail

RootfsDirectory="${1:?usage: rebuild-native.sh <rootfs-dir>}"
Jobs="${OKRA_JOBS:-4}"
BinutilsVersion="${OKRA_BINUTILS_VERSION:-2.44}"
GccVersion="${OKRA_GCC_VERSION:-16.2.0}"
Mirror="${OKRA_GNU_MIRROR:-https://mirrors.kernel.org/gnu}"

[ -d "$RootfsDirectory" ] || { echo "rebuild-native: no rootfs at $RootfsDirectory" >&2; exit 1; }
[ -x "$RootfsDirectory/usr/bin/gcc" ] || {
	echo "rebuild-native: the userland has no gcc to rebuild with" >&2
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
# A native gcc build wants a few gigabytes of scratch space, so the room left
# is reported before anything is unpacked rather than as a failure in the
# middle of a make.
df -h "$RootfsDirectory" | tail -1
Fetch "$Mirror/binutils/binutils-$BinutilsVersion.tar.xz" "$Sources/binutils.tar.xz" || {
	echo "rebuild-native: could not fetch binutils" >&2
	exit 1
}
Fetch "$Mirror/gcc/gcc-$GccVersion/gcc-$GccVersion.tar.xz" "$Sources/gcc.tar.xz" || {
	echo "rebuild-native: could not fetch gcc" >&2
	exit 1
}
ls -la "$Sources"

# Record what the toolchain looked like before, so the change is visible in the
# log rather than only asserted.
echo "== the compiler that is about to be replaced"
"$RootfsDirectory/lib64/ld-linux-x86-64.so.2" \
	--library-path "$RootfsDirectory/usr/lib64:$RootfsDirectory/usr/lib:$RootfsDirectory/lib64:$RootfsDirectory/lib" \
	"$RootfsDirectory/usr/bin/gcc" --version 2>/dev/null | head -1 || true

echo "== entering the userland"
cat > "$RootfsDirectory/usr/src/native/inner.sh" <<INNER
#!/bin/bash
# Runs inside the Okra userland. Nothing here reaches outside it: the compiler,
# the linker, make and the sources are all in this tree.
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export TZ=UTC
export HOME=/root
export MAKEFLAGS=-j$Jobs

cd /usr/src/native || exit 1

echo "== what is doing the building"
command -v gcc
gcc --version | head -1
gcc -dumpmachine
command -v ld
ld --version | head -1

echo "== extracting the sources"
rm -rf binutils-src gcc-src
mkdir -p binutils-src gcc-src
tar -xf binutils.tar.xz -C binutils-src --strip-components=1 || exit 1
tar -xf gcc.tar.xz -C gcc-src --strip-components=1 || exit 1
echo "== binutils source at \$(du -sh binutils-src | cut -f1), gcc source at \$(du -sh gcc-src | cut -f1)"

echo "== building binutils $BinutilsVersion, natively"
rm -rf binutils-build
mkdir binutils-build
cd binutils-build || exit 1
../binutils-src/configure --prefix=/usr --disable-nls --disable-werror || exit 1
make -j$Jobs || exit 1
make install || exit 1
cd /usr/src/native || exit 1
echo "== the linker now in place"
/usr/bin/ld --version | head -1

echo "== fetching the gcc prerequisites"
cd /usr/src/native/gcc-src || exit 1
./contrib/download_prerequisites || exit 1
cd /usr/src/native || exit 1

echo "== building gcc $GccVersion, natively"
rm -rf gcc-build
mkdir gcc-build
cd gcc-build || exit 1
../gcc-src/configure --prefix=/usr --enable-languages=c,c++ --disable-multilib --disable-nls || exit 1
make -j$Jobs || exit 1
make install || exit 1
cd /usr/src/native || exit 1

echo "== the compiler now in place"
/usr/bin/gcc --version | head -1
/usr/bin/gcc -dumpmachine

echo "== it compiles and runs a program"
cat > /usr/src/native/hello.c <<'HELLO'
#include <stdio.h>

int main(void)
{
	printf("built by the toolchain this system compiled for itself\\n");
	return 0;
}
HELLO
/usr/bin/gcc -O2 -o /usr/src/native/hello /usr/src/native/hello.c || exit 1
/usr/src/native/hello || exit 1

echo "== and the C++ front end works too"
cat > /usr/src/native/hello.cc <<'HELLOXX'
#include <iostream>

int main()
{
	std::cout << "and by its C++ front end" << std::endl;
	return 0;
}
HELLOXX
/usr/bin/g++ -O2 -o /usr/src/native/helloxx /usr/src/native/hello.cc || exit 1
/usr/src/native/helloxx || exit 1

echo "== done"
INNER
chmod +x "$RootfsDirectory/usr/src/native/inner.sh"

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
	/bin/bash /usr/src/native/inner.sh || {
	echo "rebuild-native: the in-userland rebuild failed" >&2
	exit 1
}

CleanupMounts
trap - EXIT

echo "== the toolchain in the userland is now the one it built"
"$RootfsDirectory/lib64/ld-linux-x86-64.so.2" \
	--library-path "$RootfsDirectory/usr/lib64:$RootfsDirectory/usr/lib:$RootfsDirectory/lib64:$RootfsDirectory/lib" \
	"$RootfsDirectory/usr/bin/gcc" --version 2>/dev/null | head -1 || true

echo "== what is still cross built"
echo "   glibc, the C library: replacing it in place needs a two phase install"
echo "   the 70 packages, which were cross compiled before this step existed"
echo "== done"