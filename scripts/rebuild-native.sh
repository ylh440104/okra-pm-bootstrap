#!/bin/bash
# rebuild-native.sh - rebuild the toolchain inside the userland, natively.
#
# This is the step the bootstrap has been missing. Everything up to here was
# cross compiled: a toolchain living on the runner produced every binary in the
# userland, so nothing in there ever built anything. Here the userland is
# entered and the toolchain is rebuilt by the compiler already inside it, which
# is what makes the system self hosting rather than merely self contained.
#
# It rebuilds binutils and gcc. glibc is deliberately left alone: replacing the
# C library of a running system in place needs a two phase install and a
# reboot, which is a separate exercise from proving the compiler compiles
# itself. That gap is reported at the end rather than glossed over.
#
# The inner script is a quoted heredoc, so its variables are the userland's.
# Settings reach it through the environment, which is also how the build knows
# how many jobs to run and which versions to fetch.
#
# Usage: rebuild-native.sh <rootfs-dir>
# Environment:
#   OKRA_JOBS               parallel make jobs (default 4)
#   OKRA_BINUTILS_VERSION   default 2.44, matching the cross toolchain
#   OKRA_GCC_VERSION        default 16.2.0, matching the cross toolchain
#   OKRA_GNU_MIRROR         default https://mirrors.kernel.org/gnu
# Return: 0 only when the userland built its own compiler and ran a program
#         with it. Any failure before that is reported and exits non-zero.
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

# Fingerprint() - a string that changes when the compiler binary changes.
# @Program: path under the rootfs, such as usr/bin/gcc.
# Return: 0. Prints the configuration line and the compiler's own build id.
#
# The first line of --version is just the version number, which is the same for
# the cross compiler and the one the system builds, so it cannot tell them
# apart. -v prints the configure line and a sha256 of the compiler's
# configuration, and those do differ between two builds.
Fingerprint() {
	local Program="$1"
	"$RootfsDirectory/lib64/ld-linux-x86-64.so.2" \
		--library-path "$RootfsDirectory/usr/lib64:$RootfsDirectory/usr/lib:$RootfsDirectory/lib64:$RootfsDirectory/lib" \
		"$RootfsDirectory/$Program" -v 2>&1 |
		grep -E 'Configured with|gcc version|sha256|build id' |
		tr -d '\r' | sort || true
}

# ShowToolchain() - print the version of the compiler or linker in the tree.
# @Program: path under the rootfs, such as usr/bin/gcc.
# Return: 0. Prints nothing useful if the program will not run.
ShowToolchain() {
	local Program="$1"
	"$RootfsDirectory/lib64/ld-linux-x86-64.so.2" \
		--library-path "$RootfsDirectory/usr/lib64:$RootfsDirectory/usr/lib:$RootfsDirectory/lib64:$RootfsDirectory/lib" \
		"$RootfsDirectory/$Program" --version 2>/dev/null | head -1 || true
}

echo "== fetching the sources into the userland"
# A native gcc build wants a few gigabytes of scratch space, so the room left is
# reported before anything is unpacked rather than as a failure mid-make.
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

# The fingerprint of the compiler before the rebuild. It has to be something
# that differs between the cross compiler and the one built in the userland, or
# the comparison below proves nothing.
echo "== the compiler that is about to be replaced"
ShowToolchain usr/bin/gcc
Before="$(Fingerprint usr/bin/gcc)"
[ -n "$Before" ] || { echo "rebuild-native: the userland gcc does not run" >&2; exit 1; }
echo "$Before" | sed 's/^/   /'

echo "== entering the userland"
# The heredoc is quoted, so everything inside runs as written in the userland.
# The settings it needs arrive as environment variables.
cat > "$RootfsDirectory/usr/src/native/inner.sh" <<'INNER'
#!/bin/bash
# Runs inside the Okra userland. Nothing here reaches outside it: the compiler,
# the linker, make and the sources are all in this tree.
set -uo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export TZ=UTC
export HOME=/root
export MAKEFLAGS="-j${OKRA_JOBS}"

cd /usr/src/native || exit 1

echo "== what is doing the building"
command -v gcc || exit 1
gcc --version | head -1
gcc -dumpmachine
command -v ld || exit 1
ld --version | head -1

echo "== extracting the sources"
rm -rf binutils-src gcc-src
mkdir -p binutils-src gcc-src
tar -xf binutils.tar.xz -C binutils-src --strip-components=1 || exit 1
tar -xf gcc.tar.xz -C gcc-src --strip-components=1 || exit 1
echo "== sources unpacked"

echo "== building binutils ${OKRA_BINUTILS_VERSION}, natively"
rm -rf binutils-build
mkdir binutils-build
cd binutils-build || exit 1
# gprofng is the profiler binutils bundles, and its libcollector does not build
# under gcc 16: iolib.c trips over a _Generic the newer compiler rejects. A
# toolchain does not need the profiler, so it is switched off.
../binutils-src/configure --prefix=/usr --disable-nls --disable-werror --disable-gprofng || exit 1
make || exit 1
make install || exit 1
cd /usr/src/native || exit 1
echo "== the linker now in place"
/usr/bin/ld --version | head -1

echo "== building gcc ${OKRA_GCC_VERSION}, natively"
# download_prerequisites is not run: it fetches gmp, mpfr and mpc from
# gcc.gnu.org with wget, and this userland's wget was built without HTTPS. The
# three libraries are already packages here - headers in /usr/include, libraries
# in /usr/lib - so the build is pointed at them instead. A system that can only
# rebuild itself by fetching its own dependencies again is not self hosting.
for Header in gmp.h mpfr.h mpc.h; do
	if [ ! -f "/usr/include/${Header}" ]; then
		echo "missing /usr/include/${Header}, which gcc needs to build" >&2
		exit 1
	fi
done
echo "== gmp, mpfr and mpc are already in the system"
rm -rf gcc-build
mkdir gcc-build
cd gcc-build || exit 1
# --disable-bootstrap builds gcc once with the compiler already present, rather
# than three times over to check the result is stable. One pass is what shows
# the system can compile its own compiler; the stability check is a separate
# question and would triple the time.
../gcc-src/configure \
	--prefix=/usr \
	--enable-languages=c,c++ \
	--disable-bootstrap \
	--disable-multilib \
	--disable-nls \
	--with-gmp=/usr --with-mpfr=/usr --with-mpc=/usr || exit 1
make || exit 1
make install || exit 1
cd /usr/src/native || exit 1

echo "== the compiler now in place"
/usr/bin/gcc --version | head -1
/usr/bin/gcc -dumpmachine

echo "== it compiles and runs a program"
printf '%s\n' '#include <stdio.h>' 'int main(void) { printf("built by the toolchain this system compiled for itself\n"); return 0; }' > hello.c
/usr/bin/gcc -O2 -o hello hello.c || exit 1
./hello || exit 1

echo "== and its C++ front end works too"
printf '%s\n' '#include <iostream>' 'int main() { std::cout << "and by its C++ front end" << std::endl; return 0; }' > hello.cc
/usr/bin/g++ -O2 -o helloxx hello.cc || exit 1
./helloxx || exit 1

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

# The settings travel through the environment, which is how they reach a
# quoted heredoc without the outer shell touching its variables.
chroot "$RootfsDirectory" /usr/bin/env -i \
	PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
	HOME=/root \
	OKRA_JOBS="$Jobs" \
	OKRA_BINUTILS_VERSION="$BinutilsVersion" \
	OKRA_GCC_VERSION="$GccVersion" \
	/bin/bash /usr/src/native/inner.sh
InnerStatus=$?
[ "$InnerStatus" -eq 0 ] || {
	echo "rebuild-native: the in-userland rebuild failed with status $InnerStatus" >&2
	exit 1
}

CleanupMounts
trap - EXIT

echo "== the toolchain in the userland is now the one it built"
ShowToolchain usr/bin/gcc
After="$(Fingerprint usr/bin/gcc)"
[ -n "$After" ] || { echo "rebuild-native: the rebuilt gcc does not run" >&2; exit 1; }
echo "$After" | sed 's/^/   /'

# The comparison is the point: without it a script that quietly did nothing
# would look exactly like one that worked, which is what happened once already.
if [ "$Before" = "$After" ]; then
	echo "rebuild-native: gcc is unchanged, so nothing was actually rebuilt" >&2
	echo "  before: $Before" >&2
	echo "  after:  $After" >&2
	exit 1
fi
echo "== and it is not the one that went in"
echo "   before:"
echo "$Before" | sed 's/^/     /'
echo "   after:"
echo "$After" | sed 's/^/     /'

echo "== what is still cross built"
echo "   glibc, the C library: replacing it in place needs a two phase install"
echo "   the 70 packages, which were cross compiled before this step existed"
echo "== done"